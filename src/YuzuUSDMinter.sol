// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IYuzuUSDMinter.sol";
import "./interfaces/IYuzuUSDMinterDefinitions.sol";

/**
 * @title YuzuUSDMinter
 */
contract YuzuUSDMinter is
    AccessControlDefaultAdminRules,
    ReentrancyGuard,
    IYuzuUSDMinterDefinitions
{
    using SafeERC20 for IERC20;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE =
        keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant REDEEM_MANAGER_ROLE =
        keccak256("REDEEM_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    IYuzuUSD public immutable yzusd;
    address public immutable collateralToken;

    address public treasury;
    address public redeemFeeRecipient;

    mapping(uint256 => uint256) public mintedPerBlock;
    mapping(uint256 => uint256) public redeemedPerBlock;
    uint256 public maxMintPerBlock;
    uint256 public maxRedeemPerBlock;

    mapping(uint256 => Order) internal fastRedeemOrders;
    mapping(uint256 => Order) internal standardRedeemOrders;
    uint256 public fastRedeemOrderCount = 0;
    uint256 public standardRedeemOrderCount = 0;

    uint256 public instantRedeemFeeBps = 0;
    uint256 public fastRedeemFeeBps = 0;
    uint256 public standardRedeemFeeBps = 0;
    uint256 public fastFillWindow = 1 days;
    uint256 public standardFillWindow = 7 days;

    uint256 public currentPendingFastRedeemValue = 0;
    uint256 public currentPendingStandardRedeemValue = 0;

    modifier underMaxMintPerBlock(uint256 amount) {
        uint256 currentBlock = block.number;
        if (mintedPerBlock[currentBlock] + amount > maxMintPerBlock) {
            revert MaxMintPerBlockExceeded();
        }
        _;
    }

    modifier underMaxRedeemPerBlock(uint256 amount) {
        uint256 currentBlock = block.number;
        if (redeemedPerBlock[currentBlock] + amount > maxRedeemPerBlock) {
            revert MaxRedeemPerBlockExceeded();
        }
        _;
    }

    modifier underLiquidityBuffer(uint256 amount) {
        uint256 liquidityBufferSize = _getLiquidityBufferSize();
        if (amount > liquidityBufferSize) {
            revert ExceedsLiquidityBuffer();
        }
        _;
    }

    constructor(
        address _yzusd,
        address _collateralToken,
        address _admin,
        address _treasury,
        address _redeemFeeRecipient,
        uint256 _maxMintPerBlock,
        uint256 _maxRedeemPerBlock
    ) AccessControlDefaultAdminRules(0, msg.sender) {
        if (_yzusd == address(0)) revert InvalidZeroAddress();
        if (_collateralToken == address(0)) revert InvalidZeroAddress();
        if (_admin == address(0)) revert InvalidZeroAddress();
        if (_treasury == address(0)) revert InvalidZeroAddress();
        if (_redeemFeeRecipient == address(0)) revert InvalidZeroAddress();

        yzusd = IYuzuUSD(_yzusd);
        collateralToken = _collateralToken;

        treasury = _treasury;
        redeemFeeRecipient = _redeemFeeRecipient;
        maxMintPerBlock = _maxMintPerBlock;
        maxRedeemPerBlock = _maxRedeemPerBlock;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    function setRedeemFeeRecipient(
        address newRecipient
    ) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newRecipient == address(0)) revert InvalidZeroAddress();
        address oldRecipient = redeemFeeRecipient;
        redeemFeeRecipient = newRecipient;
        emit RedeemFeeRecipientUpdated(oldRecipient, newRecipient);
    }

    function setMaxMintPerBlock(
        uint256 newMaxMintPerBlock
    ) external onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMaxMintPerBlock = maxMintPerBlock;
        maxMintPerBlock = newMaxMintPerBlock;
        emit MaxMintPerBlockUpdated(oldMaxMintPerBlock, newMaxMintPerBlock);
    }

    function setMaxRedeemPerBlock(
        uint256 newMaxRedeemPerBlock
    ) external onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMaxRedeemPerBlock = maxRedeemPerBlock;
        maxRedeemPerBlock = newMaxRedeemPerBlock;
        emit MaxRedeemPerBlockUpdated(
            oldMaxRedeemPerBlock,
            newMaxRedeemPerBlock
        );
    }

    function setInstantRedeemFeeBps(
        uint256 newFeeBps
    ) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldFee = instantRedeemFeeBps;
        instantRedeemFeeBps = newFeeBps;
        emit InstantRedeemFeeBpsUpdated(oldFee, newFeeBps);
    }

    function setFastRedeemFeeBps(
        uint256 newFeeBps
    ) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldFee = fastRedeemFeeBps;
        fastRedeemFeeBps = newFeeBps;
        emit FastRedeemFeeBpsUpdated(oldFee, newFeeBps);
    }

    function setStandardRedeemFeeBps(
        uint256 newFeeBps
    ) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldFee = standardRedeemFeeBps;
        standardRedeemFeeBps = newFeeBps;
        emit StandardRedeemFeeBpsUpdated(oldFee, newFeeBps);
    }

    function setFastFillWindow(
        uint256 newWindow
    ) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldWindow = fastFillWindow;
        fastFillWindow = newWindow;
        emit FastFillWindowUpdated(oldWindow, newWindow);
    }

    function setStandardFillWindow(
        uint256 newWindow
    ) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldWindow = standardFillWindow;
        standardFillWindow = newWindow;
        emit StandardFillWindowUpdated(oldWindow, newWindow);
    }

    function mint(
        address to,
        uint256 amount
    ) external nonReentrant underMaxMintPerBlock(amount) {
        if (amount == 0) revert InvalidAmount();
        mintedPerBlock[block.number] += amount;
        _mint(msg.sender, to, amount);
        emit Minted(msg.sender, to, amount);
    }

    function instantRedeem(
        address to,
        uint256 amount
    )
        external
        nonReentrant
        underMaxRedeemPerBlock(amount)
        underLiquidityBuffer(amount)
    {
        if (amount == 0) revert InvalidAmount();
        redeemedPerBlock[block.number] += amount;
        uint256 fee = (amount * instantRedeemFeeBps) / 10_000;
        _instantRedeem(msg.sender, to, amount, fee);
        emit InstantRedeem(msg.sender, to, amount, fee);
        emit Redeemed(msg.sender, to, amount);
    }

    function fastRedeem(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 orderId = _createFastRedeemOrder(msg.sender, amount);
        emit FastRedeemOrderCreated(orderId, msg.sender, amount);
    }

    function fillFastRedeemOrder(
        uint256 orderId,
        address feeRecipient
    ) external nonReentrant onlyRole(ORDER_FILLER_ROLE) {
        Order storage order = fastRedeemOrders[orderId];
        if (order.amount == 0) revert InvalidOrder();
        _fillFastRedeemOrder(order, msg.sender, feeRecipient);
        emit FastRedeemOrderFilled(
            orderId,
            order.owner,
            msg.sender,
            feeRecipient,
            order.amount,
            order.feeBps
        );
        emit Redeemed(order.owner, order.owner, order.amount);
    }

    function cancelFastRedeemOrder(uint256 orderId) external nonReentrant {
        Order storage order = fastRedeemOrders[orderId];
        if (order.amount == 0) revert InvalidOrder();
        if (msg.sender != order.owner) revert Unauthorized();
        _cancelFastRedeemOrder(order);
        emit FastRedeemOrderCancelled(orderId);
    }

    function standardRedeem(
        uint256 amount
    ) external nonReentrant underMaxRedeemPerBlock(amount) {
        if (amount == 0) revert InvalidAmount();
        redeemedPerBlock[block.number] += amount;
        uint256 orderId = _createStandardRedeemOrder(msg.sender, amount);
        emit StandardRedeemOrderCreated(orderId, msg.sender, amount);
    }

    function fillStandardRedeemOrder(uint256 orderId) external nonReentrant {
        Order storage order = standardRedeemOrders[orderId];
        if (order.amount == 0) revert InvalidOrder();
        _fillStandardRedeemOrder(order);
        emit StandardRedeemOrderFilled(
            orderId,
            order.owner,
            order.amount,
            order.feeBps
        );
        emit Redeemed(order.owner, order.owner, order.amount);
    }

    function withdrawCollateral(
        uint256 amount,
        address to
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert InvalidAmount();
        uint256 outstandingBalance = _getOutstandingCollateralBalance();
        if (amount > outstandingBalance) revert ExceedsOutstandingBalance();
        IERC20(collateralToken).safeTransfer(to, amount);
        emit CollateralWithdrawn(amount, to);
    }

    function rescueTokens(
        address token,
        uint256 amount,
        address to
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert InvalidAmount();
        if (token == collateralToken || token == address(yzusd)) {
            revert InvalidToken();
        }
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueOutstandingYuzuUSD(
        uint256 amount,
        address to
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert InvalidAmount();
        uint256 outstandingBalance = _getOutstandingYuzuUSDBalance();
        if (amount > outstandingBalance) revert ExceedsOutstandingBalance();
        IERC20(yzusd).safeTransfer(to, amount);
    }

    function getFastRedeemOrder(
        uint256 orderId
    ) external view returns (Order memory) {
        return fastRedeemOrders[orderId];
    }

    function getStandardRedeemOrder(
        uint256 orderId
    ) external view returns (Order memory) {
        return standardRedeemOrders[orderId];
    }

    function _mint(address from, address to, uint256 amount) internal {
        IERC20(collateralToken).safeTransferFrom(from, treasury, amount);
        yzusd.mint(to, amount);
    }

    function _instantRedeem(
        address from,
        address to,
        uint256 amount,
        uint256 fee
    ) internal {
        uint256 amountAfterFee = amount - fee;
        yzusd.burnFrom(from, amount);
        IERC20(collateralToken).safeTransfer(to, amountAfterFee);
        if (fee > 0 && redeemFeeRecipient != address(this)) {
            IERC20(collateralToken).safeTransfer(redeemFeeRecipient, fee);
        }
    }

    function _createFastRedeemOrder(
        address owner,
        uint256 amount
    ) internal returns (uint256) {
        IERC20(yzusd).safeTransferFrom(owner, address(this), amount);
        uint256 orderId = fastRedeemOrderCount;
        fastRedeemOrders[orderId] = Order({
            amount: amount,
            owner: owner,
            feeBps: uint16(fastRedeemFeeBps),
            dueTime: uint40(block.timestamp + fastFillWindow),
            status: OrderStatus.Pending
        });
        fastRedeemOrderCount++;
        currentPendingFastRedeemValue += amount;
        return orderId;
    }

    function _fillFastRedeemOrder(
        Order storage order,
        address filler,
        address feeRecipient
    ) internal {
        if (order.status != OrderStatus.Pending) revert OrderNotPending();
        uint256 fee = (order.amount * order.feeBps) / 10_000;
        uint256 amountAfterFee = order.amount - fee;
        yzusd.burn(order.amount);
        IERC20(collateralToken).safeTransferFrom(
            filler,
            order.owner,
            amountAfterFee
        );
        if (fee > 0 && feeRecipient != filler) {
            IERC20(collateralToken).safeTransferFrom(filler, feeRecipient, fee);
        }
        order.status = OrderStatus.Filled;
        currentPendingFastRedeemValue -= order.amount;
    }

    function _cancelFastRedeemOrder(Order storage order) internal {
        if (order.status != OrderStatus.Pending) revert OrderNotPending();
        if (block.timestamp < order.dueTime) revert OrderNotDue();
        IERC20(yzusd).safeTransfer(order.owner, order.amount);
        order.status = OrderStatus.Cancelled;
        currentPendingFastRedeemValue -= order.amount;
    }

    function _createStandardRedeemOrder(
        address owner,
        uint256 amount
    ) internal returns (uint256) {
        IERC20(yzusd).safeTransferFrom(owner, address(this), amount);
        uint256 orderId = standardRedeemOrderCount;
        standardRedeemOrders[orderId] = Order({
            amount: amount,
            owner: owner,
            feeBps: uint16(standardRedeemFeeBps),
            dueTime: uint40(block.timestamp + standardFillWindow),
            status: OrderStatus.Pending
        });
        standardRedeemOrderCount++;
        currentPendingStandardRedeemValue += amount;
        return orderId;
    }

    function _fillStandardRedeemOrder(Order storage order) internal {
        if (order.status != OrderStatus.Pending) revert OrderNotPending();
        if (block.timestamp < order.dueTime) revert OrderNotDue();
        uint256 liquidityBufferSize = _getLiquidityBufferSize();
        if (order.amount > liquidityBufferSize) revert ExceedsLiquidityBuffer();
        uint256 fee = (order.amount * order.feeBps) / 10_000;
        uint256 amountAfterFee = order.amount - fee;
        yzusd.burn(order.amount);
        IERC20(collateralToken).safeTransfer(order.owner, amountAfterFee);
        if (fee > 0 && redeemFeeRecipient != address(this)) {
            IERC20(collateralToken).safeTransfer(redeemFeeRecipient, fee);
        }
        order.status = OrderStatus.Filled;
        currentPendingStandardRedeemValue -= order.amount;
    }

    function _getLiquidityBufferSize() internal view returns (uint256) {
        return IERC20(collateralToken).balanceOf(address(this));
    }

    function _getOutstandingCollateralBalance()
        internal
        view
        returns (uint256)
    {
        uint256 balance = IERC20(collateralToken).balanceOf(address(this));
        return balance - currentPendingStandardRedeemValue;
    }

    function _getOutstandingYuzuUSDBalance() internal view returns (uint256) {
        uint256 balance = IERC20(yzusd).balanceOf(address(this));
        return
            balance -
            currentPendingFastRedeemValue -
            currentPendingStandardRedeemValue;
    }
}
