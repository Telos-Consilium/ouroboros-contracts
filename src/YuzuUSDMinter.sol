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
    uint256 public fastRedeemOrderCount;
    uint256 public standardRedeemOrderCount;

    uint256 public instantRedeemFeePpm;
    uint256 public fastRedeemFeePpm;
    uint256 public standardRedeemFeePpm;
    uint256 public fastFillWindow;
    uint256 public standardRedeemDelay;

    uint256 public currentPendingFastRedeemValue;
    uint256 public currentPendingStandardRedeemValue;

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
     * @notice Initializes the YuzuUSDMinter contract with the specified parameters.
     * @param _yzusd The address of the YuzuUSD token contract.
     * @param _collateralToken The address of the collateral token contract.
     * @param _admin The admin of the contract.
     * @param _treasury The address of the treasury where collateral is sent.
     * @param _redeemFeeRecipient The address that receives redemption fees.
     * @param _maxMintPerBlock Maximum YuzuUSD that can be minted per block.
     * @param _maxRedeemPerBlock Maximum YuzuUSD that can be redeemed per block.
     *
     * Fees are set to 0 by default.
     * Fast fill window and standard redeem delay are set to 1 day and 7 days, respectively.
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
        standardRedeemDelay = 7 days;

        currentPendingFastRedeemValue = 0;
        currentPendingStandardRedeemValue = 0;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
    }

    /**
     * @notice Sets the treasury address to {newTreasury}.
     *
     * Emits a `TreasuryUpdated` event with the old and new treasury addresses.
     * Reverts if called by anyone but an admin.
     * Reverts if {newTreasury} is the zero address.
     */
    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress();
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Sets the redemptions fee recipient address to {newRecipient}.
     *
     * Emits a `RedeemFeeRecipientUpdated` event with the old and new recipient addresses.
     * Reverts if called by anyone but a redeem manager.
     * Reverts if {newRecipient} is the zero address.
     */
    function setRedeemFeeRecipient(address newRecipient) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newRecipient == address(0)) revert InvalidZeroAddress();
        address oldRecipient = redeemFeeRecipient;
        redeemFeeRecipient = newRecipient;
        emit RedeemFeeRecipientUpdated(oldRecipient, newRecipient);
    }

    /**
     * @notice Sets the maximum mint per block to {newMaxMintPerBlock}.
     *
     * Emits a `MaxMintPerBlockUpdated` event with the old and new limits.
     * Reverts if called by anyone but a limit manager.
     */
    function setMaxMintPerBlock(uint256 newMaxMintPerBlock) external onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMaxMintPerBlock = maxMintPerBlock;
        maxMintPerBlock = newMaxMintPerBlock;
        emit MaxMintPerBlockUpdated(oldMaxMintPerBlock, newMaxMintPerBlock);
    }

    /**
     * @notice Sets the maximum redemption per block to {newMaxRedeemPerBlock}.
     *
     * Emits a `MaxRedeemPerBlockUpdated` event with the old and new limits.
     * Reverts if called by anyone but a limit manager.
     */
    function setMaxRedeemPerBlock(uint256 newMaxRedeemPerBlock) external onlyRole(LIMIT_MANAGER_ROLE) {
        uint256 oldMaxRedeemPerBlock = maxRedeemPerBlock;
        maxRedeemPerBlock = newMaxRedeemPerBlock;
        emit MaxRedeemPerBlockUpdated(oldMaxRedeemPerBlock, newMaxRedeemPerBlock);
    }

    /**
     * @notice Sets the instant redemptions fee to {newFeePpm}.
     *
     * Emits an `InstantRedeemFeePpmUpdated` event with the old and new fees.
     * Reverts if called by anyone but a redeem manager.
     * Reverts if {newFeePpm} is greater than 1,000,000 (100%).
     */
    function setInstantRedeemFeePpm(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert InvalidFeePpm(newFeePpm);
        uint256 oldFee = instantRedeemFeePpm;
        instantRedeemFeePpm = newFeePpm;
        emit InstantRedeemFeePpmUpdated(oldFee, newFeePpm);
    }

    /**
     * @notice Sets the fast redemptions fee to {newFeePpm}.
     *
     * Emits a `FastRedeemFeePpmUpdated` event with the old and new fees.
     * Reverts if called by anyone but a redeem manager.
     * Reverts if {newFeePpm} is greater than 1,000,000 (100%).
     */
    function setFastRedeemFeePpm(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert InvalidFeePpm(newFeePpm);
        uint256 oldFee = fastRedeemFeePpm;
        fastRedeemFeePpm = newFeePpm;
        emit FastRedeemFeePpmUpdated(oldFee, newFeePpm);
    }

    /**
     * @notice Sets the standard redemptions fee to {newFeePpm}.
     *
     * Emits a `StandardRedeemFeePpmUpdated` event with the old and new fees.
     * Reverts if called by anyone but a redeem manager.
     * Reverts if {newFeePpm} is greater than 1,000,000 (100%).
     */
    function setStandardRedeemFeePpm(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert InvalidFeePpm(newFeePpm);
        uint256 oldFee = standardRedeemFeePpm;
        standardRedeemFeePpm = newFeePpm;
        emit StandardRedeemFeePpmUpdated(oldFee, newFeePpm);
    }

    /**
     * @notice Sets the fast fill window to {newWindow}.
     *
     * Emits a `FastFillWindowUpdated` event with the old and new windows.
     * Reverts if called by anyone but a redeem manager.
     */
    function setFastFillWindow(uint256 newWindow) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldWindow = fastFillWindow;
        fastFillWindow = newWindow;
        emit FastFillWindowUpdated(oldWindow, newWindow);
    }

    /**
     * @notice Sets the standard redeem delay to {newDelay}.
     *
     * Emits a `StandardRedeemDelayUpdated` event with the old and new delays.
     * Reverts if called by anyone but a redeem manager.
     */
    function setStandardRedeemDelay(uint256 newDelay) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldDelay = standardRedeemDelay;
        standardRedeemDelay = newDelay;
        emit StandardRedeemDelayUpdated(oldDelay, newDelay);
    }

    /**
     * @notice Returns the amount of collateral required to mint {amount} of yzusd.
     *
     * Returns the collateral amount (1:1 with yzusd).
     */
    function previewMint(uint256 amount) public pure returns (uint256) {
        return amount;
    }

    /**
     * @notice Returns the amount of collateral withdrawn for an instant redemption of {amount} of yzusd.
     *
     * Returns the collateral amount after deducting the instant redemptions fee.
     */
    function previewInstantRedeem(uint256 amount) public view returns (uint256) {
        uint256 fee = Math.mulDiv(amount, instantRedeemFeePpm, 1e6, Math.Rounding.Ceil);
        return amount - fee;
    }

    /**
     * @notice Returns the amount of collateral withdrawn for a fast redemption of {amount} of yzusd.
     *
     * Returns the collateral amount after deducting the fast redemptions fee.
     */
    function previewFastRedeem(uint256 amount) public view returns (uint256) {
        uint256 fee = Math.mulDiv(amount, fastRedeemFeePpm, 1e6, Math.Rounding.Ceil);
        return amount - fee;
    }

    /**
     * @notice Returns the amount of collateral withdrawn for a standard redemption of {amount} of yzusd.
     *
     * Returns the collateral amount after deducting the standard redemptions fee.
     */
    function previewStandardRedeem(uint256 amount) public view returns (uint256) {
        uint256 fee = Math.mulDiv(amount, standardRedeemFeePpm, 1e6, Math.Rounding.Ceil);
        return amount - fee;
    }

    /**
     * @notice Mints {amount} of yzusd to {to}.
     *
     * Emits a `Minted` event with the caller, recipient, and amount.
     * Reverts if the amount is zero.
     * Reverts if the amount exceeds the maximum mint per block.
     */
    function mint(address to, uint256 amount) external nonReentrant underMaxMintPerBlock(amount) {
        if (amount == 0) revert InvalidZeroAmount();
        mintedPerBlock[block.number] += amount;
        _mint(_msgSender(), to, amount);
        emit Minted(_msgSender(), to, amount);
    }

    /**
     * @notice Instant redeems {amount} of yzusd to {to}.
     *
     * Returns the amount of collateral transferred to {to} after fees.
     * Charges a fee of {instantRedeemFeePpm} ppm.
     * Emits an `InstantRedeem` event with the caller, recipient, amount, and fee.
     * Emits a `Redeemed` event with the caller, recipient, and amount.
     * Reverts if the amount is zero.
     * Reverts if the amount exceeds the maximum redemption per block.
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
     * @notice Creates a fast redemption order for {amount} of yzusd.
     *
     * Returns the order ID.
     * Emits a `FastRedeemOrderCreated` event with the order ID, order owner, and amount.
     * Reverts if the amount is zero.
     */
    function createFastRedeemOrder(uint256 amount) external nonReentrant returns (uint256) {
        if (amount == 0) revert InvalidZeroAmount();
        uint256 orderId = _createFastRedeemOrder(_msgSender(), amount);
        emit FastRedeemOrderCreated(orderId, _msgSender(), amount);
        return orderId;
    }

    /**
     * @notice Fills a fast redemption order with {orderId} by transferring the amount to the owner.
     *
     * The fee is transferred to {feeRecipient}.
     * Emits a `FastRedeemOrderFilled` event with the order ID, owner, filler, fee recipient, amount, and fee.
     * Emits a `Redeemed` event with the order owner, recipient, and amount.
     * Reverts if called by anyone but an order filler.
     * Reverts if the order does not exist.
     * Reverts if the order is not pending.
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
     * @notice Cancels a fast redemption order with {orderId}.
     *
     * Emits a `FastRedeemOrderCancelled` event with the order ID.
     * Reverts if called by anyone but the order owner.
     * Reverts if the order does not exist.
     * Reverts if the order is not pending.
     * Reverts if the order is not yet due for cancellation.
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
     * @notice Creates a standard redemption order for {amount} of yzusd.
     *
     * Returns the order ID.
     * Emits a `StandardRedeemOrderCreated` event with the order ID, order owner, and amount.
     * Reverts if the amount is zero.
     * Reverts if the amount exceeds the maximum redemption per block.
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
     * @notice Fills a standard redemption order with {orderId} by transferring the amount to the owner.
     *
     * Emits a `StandardRedeemOrderFilled` event with the order ID, owner, amount, and fee.
     * Emits a `Redeemed` event with the order owner, recipient, and amount.
     * Reverts if the order does not exist.
     * Reverts if the order is not pending.
     * Reverts if the order is not yet due.
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
     * @notice Withdraws {amount} of collateral to {to}.
     *
     * Emits a `CollateralWithdrawn` event with the recipient and amount.
     * Reverts if called by anyone but an admin.
     * Reverts if the amount is zero.
     * Reverts if the amount exceeds the outstanding collateral balance.
     */
    function withdrawCollateral(address to, uint256 amount) external nonReentrant onlyRole(ADMIN_ROLE) {
        if (amount == 0) revert InvalidZeroAmount();
        uint256 outstandingCollateral = _getOutstandingCollateralBalance();
        if (amount > outstandingCollateral) revert OutstandingBalanceExceeded(amount, outstandingCollateral);

        IERC20(collateralToken).safeTransfer(to, amount);

        emit CollateralWithdrawn(to, amount);
    }

    /**
     * @notice Transfers {amount} of {token} held by the contract to {to}.
     *
     * Reverts if called by anyone but an admin.
     * Reverts if {token} is the collateral token or yzusd token.
     */
    function rescueTokens(address token, address to, uint256 amount) external nonReentrant onlyRole(ADMIN_ROLE) {
        if (token == collateralToken || token == address(yzusd)) {
            revert InvalidToken(token);
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Returns a fast redemption order by its ID.
     */
    function getFastRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return fastRedeemOrders[orderId];
    }

    /**
     * @notice Returns a standard redemption order by its ID.
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
     * @dev Internal function to handle instant redemptions.
     *
     * Burns yzusd from {from} and transfers collateral to {to}.
     * Transfers the fee to the redemptions fee recipient if applicable.
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
     * @dev Internal function to create a fast redemption order.
     *
     * Transfers yzusd from {owner} to the contract and creates a fast redemption order.
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
     * @dev Internal function to fill a fast redemption order.
     *
     * Marks the order as filled, updates the current pending fast redemption value,
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
     * @dev Internal function to cancel a fast redemption order.
     *
     * Marks the order as cancelled, updates the current pending fast redemption value,
     * and transfers the yzusd back to the owner.
     */
    function _cancelFastRedeemOrder(Order storage order) internal {
        order.status = OrderStatus.Cancelled;
        currentPendingFastRedeemValue -= order.amount;
        IERC20(yzusd).safeTransfer(order.owner, order.amount);
    }

    /**
     * @dev Internal function to create a standard redemption order.
     *
     * Transfers yzusd from {owner} to the contract and creates a standard redemption order.
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
            dueTime: uint40(block.timestamp + standardRedeemDelay),
            status: OrderStatus.Pending
        });
        standardRedeemOrderCount++;
        return orderId;
    }

    /**
     * @dev Internal function to fill a standard redemption order.
     *
     * Marks the order as filled, updates the current pending standard redemption value,
     * and transfers the assets to the owner.
     * Transfers the fee to the redemption fee recipient if applicable.
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
     *
     * Returns the total collateral balance held by the contract.
     */
    function _getLiquidityBufferSize() internal view returns (uint256) {
        return IERC20(collateralToken).balanceOf(address(this));
    }

    /**
     * @dev Returns the current outstanding collateral balance.
     *
     * Returns the total collateral minus the current pending standard redemption value.
     */
    function _getOutstandingCollateralBalance() internal view returns (uint256) {
        uint256 balance = IERC20(collateralToken).balanceOf(address(this));
        return balance - currentPendingStandardRedeemValue;
    }

    /**
     * @dev Returns the current outstanding YuzuUSD balance.
     *
     * Returns the total YuzuUSD minus the current pending fast and standard redemption values.
     */
    function _getOutstandingYuzuUSDBalance() internal view returns (uint256) {
        uint256 balance = IERC20(yzusd).balanceOf(address(this));
        return balance - currentPendingFastRedeemValue - currentPendingStandardRedeemValue;
    }
}
