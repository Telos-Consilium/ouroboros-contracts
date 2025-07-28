// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IYuzuUSDMinter.sol";
import "./interfaces/IYuzuUSDMinterDefinitions.sol";

/**
 * @title YuzuUSDMinter
 * @dev Mints and redeems YuzuUSD tokens in exchange for 1:1 collateral tokens.
 * Deposited collateral is sent to an external treasury.
 * Implements three distinct redemption mechanisms with different speed, cost, and risk trade-offs.
 */
contract YuzuUSDMinter is
    Initializable,
    AccessControlDefaultAdminRulesUpgradeable,
    ReentrancyGuardUpgradeable,
    IYuzuUSDMinterDefinitions
{
    using SafeERC20 for IERC20;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    IYuzuUSD public yzusd;
    address public collateralToken;

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

    uint256 public instantRedeemFeePpm = 0;
    uint256 public fastRedeemFeePpm = 0;
    uint256 public standardRedeemFeePpm = 0;
    uint256 public fastFillWindow = 1 days;
    uint256 public standardFillWindow = 7 days;

    uint256 public currentPendingFastRedeemValue = 0;
    uint256 public currentPendingStandardRedeemValue = 0;

    /**
     * @dev Reverts if minting {amount} would exceed the maximum allowed per block.
     */
    modifier underMaxMintPerBlock(uint256 amount) {
        uint256 currentBlock = block.number;
        if (mintedPerBlock[currentBlock] + amount > maxMintPerBlock) {
            revert MaxMintPerBlockExceeded(amount, maxMintPerBlock);
        }
        _;
    }

    /**
     * @dev Reverts if redeeming {amount} would exceed the maximum allowed per block.
     */
    modifier underMaxRedeemPerBlock(uint256 amount) {
        uint256 currentBlock = block.number;
        if (redeemedPerBlock[currentBlock] + amount > maxRedeemPerBlock) {
            revert MaxRedeemPerBlockExceeded(amount, maxRedeemPerBlock);
        }
        _;
    }

    /**
     * @dev Reverts if {amount} exceeds the liquidity buffer size.
     */
    modifier underLiquidityBuffer(uint256 amount) {
        uint256 liquidityBufferSize = _getLiquidityBufferSize();
        if (amount > liquidityBufferSize) {
            revert LiquidityBufferExceeded(amount, liquidityBufferSize);
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Sets {yzusd}, {collateralToken}, {treasury}, {redeemFeeRecipient},
     * {maxMintPerBlock}, and {maxRedeemPerBlock} and sets up the roles.
     *
     * Fees are set to 0 by default.
     * Fast and standard fill windows are set to 1 day and 7 days, respectively.
     */
    function initialize(
        address _yzusd,
        address _collateralToken,
        address _admin,
        address _treasury,
        address _redeemFeeRecipient,
        uint256 _maxMintPerBlock,
        uint256 _maxRedeemPerBlock
    ) external initializer {
        __AccessControlDefaultAdminRules_init(0, _admin);
        __ReentrancyGuard_init();

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

        fastRedeemOrderCount = 0;
        standardRedeemOrderCount = 0;

        instantRedeemFeePpm = 0;
        fastRedeemFeePpm = 0;
        standardRedeemFeePpm = 0;
        fastFillWindow = 1 days;
        standardFillWindow = 7 days;

        currentPendingFastRedeemValue = 0;
        currentPendingStandardRedeemValue = 0;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
    }

    /**
     * @dev Sets {treasury}.
     *
     * Only callable by the admin.
     */
    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @dev Sets {redeemFeeRecipient}.
     *
     * Only callable by the redeem manager.
     */
    function setRedeemFeeRecipient(address newRecipient) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newRecipient == address(0)) revert InvalidZeroAddress();
        address oldRecipient = redeemFeeRecipient;
        redeemFeeRecipient = newRecipient;
        emit RedeemFeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @dev Sets {maxMintPerBlock}.
     *
     * Only callable by the limit manager.
     */
    function setMaxMintPerBlock(uint256 newMaxMintPerBlock) external onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMaxMintPerBlock = maxMintPerBlock;
        maxMintPerBlock = newMaxMintPerBlock;
        emit MaxMintPerBlockUpdated(oldMaxMintPerBlock, newMaxMintPerBlock);
    }

    /**
     * @dev Sets {maxRedeemPerBlock}.
     *
     * Only callable by the limit manager.
     */
    function setMaxRedeemPerBlock(uint256 newMaxRedeemPerBlock) external onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMaxRedeemPerBlock = maxRedeemPerBlock;
        maxRedeemPerBlock = newMaxRedeemPerBlock;
        emit MaxRedeemPerBlockUpdated(oldMaxRedeemPerBlock, newMaxRedeemPerBlock);
    }

    /**
     * @dev Sets {instantRedeemFeePpm}.
     *
     * Only callable by the redeem manager.
     */
    function setInstantRedeemFeePpm(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert InvalidFeePpm(newFeePpm);
        uint256 oldFee = instantRedeemFeePpm;
        instantRedeemFeePpm = newFeePpm;
        emit InstantRedeemFeePpmUpdated(oldFee, newFeePpm);
    }

    /**
     * @dev Sets {fastRedeemFeePpm}.
     *
     * Only callable by the redeem manager.
     */
    function setFastRedeemFeePpm(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert InvalidFeePpm(newFeePpm);
        uint256 oldFee = fastRedeemFeePpm;
        fastRedeemFeePpm = newFeePpm;
        emit FastRedeemFeePpmUpdated(oldFee, newFeePpm);
    }

    /**
     * @dev Sets {standardRedeemFeePpm}.
     *
     * Only callable by the redeem manager.
     */
    function setStandardRedeemFeePpm(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert InvalidFeePpm(newFeePpm);
        uint256 oldFee = standardRedeemFeePpm;
        standardRedeemFeePpm = newFeePpm;
        emit StandardRedeemFeePpmUpdated(oldFee, newFeePpm);
    }

    /**
     * @dev Sets {fastFillWindow}.
     *
     * Only callable by the redeem manager.
     */
    function setFastFillWindow(uint256 newWindow) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldWindow = fastFillWindow;
        fastFillWindow = newWindow;
        emit FastFillWindowUpdated(oldWindow, newWindow);
    }

    /**
     * @dev Sets {standardFillWindow}.
     *
     * Only callable by the redeem manager.
     */
    function setStandardFillWindow(uint256 newWindow) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldWindow = standardFillWindow;
        standardFillWindow = newWindow;
        emit StandardFillWindowUpdated(oldWindow, newWindow);
    }

    /**
     * @dev Returns the amount of collateral required to mint {amount} of yzusd.
     */
    function previewMint(uint256 amount) public pure returns (uint256) {
        return amount;
    }

    /**
     * @dev Returns the amount of collateral withdrawn for a redeem of {amount} of yzusd.
     */
    function previewInstantRedeem(uint256 amount) public view returns (uint256) {
        uint256 fee = Math.mulDiv(amount, instantRedeemFeePpm, 1e6, Math.Rounding.Ceil);
        return amount - fee;
    }

    /**
     * @dev Mints {amount} of yzusd to {to}.
     */
    function mint(address to, uint256 amount) external nonReentrant underMaxMintPerBlock(amount) {
        if (amount == 0) revert InvalidZeroAmount();
        mintedPerBlock[block.number] += amount;
        _mint(_msgSender(), to, amount);
        emit Minted(_msgSender(), to, amount);
    }

    /**
     * @dev Instant redeems {amount} of yzusd to {to}.
     *
     * Charges a fee of {instantRedeemFeePpm} ppm.
     * Reverts if the amount exceeds the maximum redeem per block.
     * Reverts if the amount exceeds the liquidity buffer size.
     */
    function instantRedeem(address to, uint256 amount)
        external
        nonReentrant
        underMaxRedeemPerBlock(amount)
        underLiquidityBuffer(amount)
        returns (uint256)
    {
        if (amount == 0) revert InvalidZeroAmount();
        redeemedPerBlock[block.number] += amount;
        uint256 fee = Math.mulDiv(amount, instantRedeemFeePpm, 1e6, Math.Rounding.Ceil);
        _instantRedeem(_msgSender(), to, amount, fee);
        emit InstantRedeem(_msgSender(), to, amount, fee);
        emit Redeemed(_msgSender(), to, amount);
        return amount - fee;
    }

    /**
     * @dev Creates a fast redeem order for {amount} of yzusd.
     *
     * Reverts if the amount is zero.
     * Reverts if the amount exceeds the maximum redeem per block.
     * Reverts if the amount exceeds the liquidity buffer size.
     */
    function createFastRedeemOrder(uint256 amount) external nonReentrant returns (uint256) {
        if (amount == 0) revert InvalidZeroAmount();
        uint256 orderId = _createFastRedeemOrder(_msgSender(), amount);
        emit FastRedeemOrderCreated(orderId, _msgSender(), amount);
        return orderId;
    }

    /**
     * @dev Fills a fast redeem order with {orderId} by transferring the amount to the owner.
     *
     * Only callable by an order filler.
     * The fee is transferred to {feeRecipient}.
     * Reverts if the order is not pending.
     * Reverts if the order is not due.
     * Reverts if the amount exceeds the liquidity buffer size.
     */
    function fillFastRedeemOrder(uint256 orderId, address feeRecipient)
        external
        nonReentrant
        onlyRole(ORDER_FILLER_ROLE)
    {
        Order storage order = fastRedeemOrders[orderId];
        if (order.amount == 0) revert InvalidOrder(orderId);
        if (order.status != OrderStatus.Pending) revert OrderNotPending(orderId);

        uint256 fee = Math.mulDiv(order.amount, order.feePpm, 1e6, Math.Rounding.Ceil);
        _fillFastRedeemOrder(order, _msgSender(), feeRecipient, fee);

        emit FastRedeemOrderFilled(orderId, order.owner, _msgSender(), feeRecipient, order.amount, fee);
        emit Redeemed(order.owner, order.owner, order.amount);
    }

    /**
     * @dev Cancels a fast redeem order with {orderId}.
     *
     * Only callable by the owner of the order.
     * Reverts if the order does not exist.
     * Reverts if the order is not pending.
     * Emits a FastRedeemOrderCancelled event.
     */
    function cancelFastRedeemOrder(uint256 orderId) external nonReentrant {
        Order storage order = fastRedeemOrders[orderId];
        if (order.amount == 0) revert InvalidOrder(orderId);
        if (_msgSender() != order.owner) revert Unauthorized();
        if (order.status != OrderStatus.Pending) revert OrderNotPending(orderId);
        if (block.timestamp < order.dueTime) revert OrderNotDue(orderId);

        _cancelFastRedeemOrder(order);

        emit FastRedeemOrderCancelled(orderId);
    }

    /**
     * @dev Creates a standard redeem order for {amount} of yzusd.
     *
     * Reverts if the amount is zero.
     * Reverts if the amount exceeds the maximum redeem per block.
     */
    function createStandardRedeemOrder(uint256 amount)
        external
        nonReentrant
        underMaxRedeemPerBlock(amount)
        returns (uint256)
    {
        if (amount == 0) revert InvalidZeroAmount();
        redeemedPerBlock[block.number] += amount;
        uint256 orderId = _createStandardRedeemOrder(_msgSender(), amount);
        emit StandardRedeemOrderCreated(orderId, _msgSender(), amount);
        return orderId;
    }

    /**
     * @dev Fills a standard redeem order with {orderId} by transferring the amount to the owner.
     *
     * Callable by anyone, not just the owner.
     * Reverts if the order is not pending.
     * Reverts if the order is not due.
     * Reverts if the amount exceeds the liquidity buffer size.
     */
    function fillStandardRedeemOrder(uint256 orderId) external nonReentrant {
        Order storage order = standardRedeemOrders[orderId];
        if (order.amount == 0) revert InvalidOrder(orderId);
        if (order.status != OrderStatus.Pending) revert OrderNotPending(orderId);
        if (block.timestamp < order.dueTime) revert OrderNotDue(orderId);
        uint256 bufferSize = _getLiquidityBufferSize();
        if (order.amount > bufferSize) revert LiquidityBufferExceeded(order.amount, bufferSize);

        uint256 fee = Math.mulDiv(order.amount, order.feePpm, 1e6, Math.Rounding.Ceil);
        _fillStandardRedeemOrder(order, fee);

        emit StandardRedeemOrderFilled(orderId, order.owner, order.amount, fee);
        emit Redeemed(order.owner, order.owner, order.amount);
    }

    /**
     * @dev Withdraws {amount} of collateral to {to}.
     *
     * Only callable by the admin.
     * Reverts if the order is not pending.
     * Reverts if the order is not due.
     */
    function withdrawCollateral(address to, uint256 amount) external nonReentrant onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert InvalidZeroAmount();
        uint256 outstandingCollateral = _getOutstandingCollateralBalance();
        if (amount > outstandingCollateral) revert OutstandingBalanceExceeded(amount, outstandingCollateral);

        IERC20(collateralToken).safeTransfer(to, amount);

        emit CollateralWithdrawn(to, amount);
    }

    /**
     * @dev Rescues tokens from the contract.
     *
     * Only callable by the admin.
     * Tokens that are the underlying asset of the vault cannot be rescued.
     */
    function rescueTokens(address token, address to, uint256 amount) external nonReentrant onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert InvalidZeroAmount();
        if (token == collateralToken || token == address(yzusd)) {
            revert InvalidToken(token);
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @dev Returns a fast redeem order by its ID.
     */
    function getFastRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return fastRedeemOrders[orderId];
    }

    /**
     * @dev Returns a standard redeem order by its ID.
     */
    function getStandardRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return standardRedeemOrders[orderId];
    }

    /**
     * @dev Internal function to handle deposits.
     *
     * Transfers collateral from {from} to the treasury and mints yzusd to {to}. 
     */
    function _mint(address from, address to, uint256 amount) internal {
        IERC20(collateralToken).safeTransferFrom(from, treasury, amount);
        yzusd.mint(to, amount);
    }

    /**
     * @dev Internal function to handle instant redeems.
     *
     * Burns yzusd from {from} and transfers collateral to {to}.
     * Transfers the fee to the redeem fee recipient if applicable.
     */
    function _instantRedeem(address from, address to, uint256 amount, uint256 fee) internal {
        uint256 amountAfterFee = amount - fee;
        yzusd.burnFrom(from, amount);
        IERC20(collateralToken).safeTransfer(to, amountAfterFee);
        if (fee > 0 && redeemFeeRecipient != address(this)) {
            IERC20(collateralToken).safeTransfer(redeemFeeRecipient, fee);
        }
    }

    /**
     * @dev Internal function to create a fast redeem order.
     *
     * Transfers yzusd from {owner} to the contract and creates a fast redeem order.
     * Returns the order ID.
     */
    function _createFastRedeemOrder(address owner, uint256 amount) internal returns (uint256) {
        currentPendingFastRedeemValue += amount;
        IERC20(yzusd).safeTransferFrom(owner, address(this), amount);
        uint256 orderId = fastRedeemOrderCount;
        fastRedeemOrders[orderId] = Order({
            amount: amount,
            owner: owner,
            feePpm: uint32(fastRedeemFeePpm),
            dueTime: uint40(block.timestamp + fastFillWindow),
            status: OrderStatus.Pending
        });
        fastRedeemOrderCount++;
        return orderId;
    }

    /**
     * @dev Internal function to fill a fast redeem order.
     *
     * Marks the order as filled, updates the current pending fast redeem value,
     * and transfers the assets to the owner.
     * Transfers the fee to the fee recipient if applicable.
     */
    function _fillFastRedeemOrder(Order storage order, address filler, address feeRecipient, uint256 fee) internal {
        order.status = OrderStatus.Filled;
        currentPendingFastRedeemValue -= order.amount;
        uint256 amountAfterFee = order.amount - fee;
        yzusd.burn(order.amount);
        IERC20(collateralToken).safeTransferFrom(filler, order.owner, amountAfterFee);
        if (fee > 0 && feeRecipient != filler) {
            IERC20(collateralToken).safeTransferFrom(filler, feeRecipient, fee);
        }
    }

    /**
     * @dev Internal function to cancel a fast redeem order.
     *
     * Marks the order as cancelled, updates the current pending fast redeem value,
     * and transfers the yzusd back to the owner.
     */
    function _cancelFastRedeemOrder(Order storage order) internal {
        order.status = OrderStatus.Cancelled;
        currentPendingFastRedeemValue -= order.amount;
        IERC20(yzusd).safeTransfer(order.owner, order.amount);
    }

    /**
     * @dev Internal function to create a standard redeem order.
     *
     * Transfers yzusd from {owner} to the contract and creates a standard redeem order.
     * Returns the order ID.
     */
    function _createStandardRedeemOrder(address owner, uint256 amount) internal returns (uint256) {
        currentPendingStandardRedeemValue += amount;
        IERC20(yzusd).safeTransferFrom(owner, address(this), amount);
        uint256 orderId = standardRedeemOrderCount;
        standardRedeemOrders[orderId] = Order({
            amount: amount,
            owner: owner,
            feePpm: uint32(standardRedeemFeePpm),
            dueTime: uint40(block.timestamp + standardFillWindow),
            status: OrderStatus.Pending
        });
        standardRedeemOrderCount++;
        return orderId;
    }

    /**
     * @dev Internal function to fill a standard redeem order.
     *
     * Marks the order as filled, updates the current pending standard redeem value,
     * and transfers the assets to the owner.
     * Transfers the fee to the redeem fee recipient if applicable.
     */
    function _fillStandardRedeemOrder(Order storage order, uint256 fee) internal {
        order.status = OrderStatus.Filled;
        currentPendingStandardRedeemValue -= order.amount;
        uint256 amountAfterFee = order.amount - fee;
        yzusd.burn(order.amount);
        IERC20(collateralToken).safeTransfer(order.owner, amountAfterFee);
        if (fee > 0 && redeemFeeRecipient != address(this)) {
            IERC20(collateralToken).safeTransfer(redeemFeeRecipient, fee);
        }
    }

    /**
     * @dev Returns the current liquidity buffer size.
     */
    function _getLiquidityBufferSize() internal view returns (uint256) {
        return IERC20(collateralToken).balanceOf(address(this));
    }

    /**
     * @dev Returns the current outstanding collateral balance.
     *
     * This is the total collateral minus the current pending standard redeem value.
     */
    function _getOutstandingCollateralBalance() internal view returns (uint256) {
        uint256 balance = IERC20(collateralToken).balanceOf(address(this));
        return balance - currentPendingStandardRedeemValue;
    }

    /**
     * @dev Returns the current outstanding YuzuUSD balance.
     *
     * This is the total YuzuUSD minus the current pending fast and standard redeem values.
     */
    function _getOutstandingYuzuUSDBalance() internal view returns (uint256) {
        uint256 balance = IERC20(yzusd).balanceOf(address(this));
        return balance - currentPendingFastRedeemValue - currentPendingStandardRedeemValue;
    }
}
