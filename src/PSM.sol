// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20Burnable, OrderStatus, Order, IPSMDefinitions} from "./interfaces/IPSMDefinitions.sol";

/**
 * @title PSM
 * @notice Module enabling instant chained mint/redeem operations across two vaults with a dedicated liquidity pool funding withdrawals
 */
contract PSM is AccessControlDefaultAdminRulesUpgradeable, ReentrancyGuardUpgradeable, IPSMDefinitions {
    using EnumerableSet for EnumerableSet.UintSet;

    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 internal constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 internal constant RESTRICTION_MANAGER_ROLE = keccak256("RESTRICTION_MANAGER_ROLE");

    bytes32 internal constant USER_ROLE = keccak256("USER_ROLE");

    IERC20 internal _asset;
    IERC4626 internal _vault0;
    IERC4626 internal _vault1;

    uint256 public minRedeemOrder;

    uint256 internal _orderCount;
    mapping(uint256 => Order) internal _orders;
    EnumerableSet.UintSet internal _pendingOrderIds;

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the PSM contract
     * @param __asset The address of the underlying asset token
     * @param __vault0 The first ERC4626 vault (yzUSD)
     * @param __vault1 The second ERC4626 vault (syzUSD)
     * @param _admin The admin of the contract
     */
    // slither-disable-next-line pess-multiple-storage-read
    function initialize(IERC20 __asset, IERC4626 __vault0, IERC4626 __vault1, address _admin, uint256 _minRedeemOrder)
        external
        initializer
    {
        __AccessControlDefaultAdminRules_init(0, _admin);
        __ReentrancyGuard_init();

        if (address(__asset) == address(0) || address(__vault0) == address(0) || address(__vault1) == address(0)) {
            revert InvalidZeroAddress();
        }

        if (__vault0.asset() != address(__asset)) {
            revert VaultAssetMismatch(address(__asset), __vault0.asset());
        }
        if (__vault1.asset() != address(__vault0)) {
            revert VaultAssetMismatch(address(__vault0), __vault1.asset());
        }

        _asset = __asset;
        _vault0 = __vault0;
        _vault1 = __vault1;

        minRedeemOrder = _minRedeemOrder;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(LIQUIDITY_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(RESTRICTION_MANAGER_ROLE, ADMIN_ROLE);

        _setRoleAdmin(USER_ROLE, RESTRICTION_MANAGER_ROLE);
    }

    /// @notice Returns the address of the underlying asset
    function asset() public view returns (address) {
        return address(_asset);
    }

    /// @notice Returns the address of the first vault
    function vault0() public view returns (address) {
        return address(_vault0);
    }

    /// @notice Returns the address of the second vault
    function vault1() public view returns (address) {
        return address(_vault1);
    }

    /// @notice Returns the total number of created redeem orders
    function orderCount() external view returns (uint256) {
        return _orderCount;
    }

    /// @notice Returns a redeem order by {orderId}
    function getRedeemOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    /// @notice Returns the number of pending redeem orders
    function pendingOrderCount() external view returns (uint256) {
        return _pendingOrderIds.length();
    }

    /// @notice Returns all pending order ids
    function getPendingOrderIds() external view returns (uint256[] memory) {
        uint256 length = _pendingOrderIds.length();
        uint256[] memory ids = new uint256[](length);
        for (uint256 idx = 0; idx < length; idx++) {
            ids[idx] = _pendingOrderIds.at(idx);
        }
        return ids;
    }

    /// @notice Preview shares minted for {assets}
    function previewDeposit(uint256 assets) external view returns (uint256) {
        uint256 assets1 = _vault0.previewDeposit(assets);
        return _vault1.previewDeposit(assets1);
    }

    /// @notice Preview assets withdrawn for {shares}
    function previewRedeem(uint256 shares) external view returns (uint256) {
        uint256 shares0 = _vault1.convertToAssets(shares);
        return _vault0.convertToAssets(shares0);
    }

    /// @notice Deposit {assets} for shares minted to {receiver}
    function deposit(uint256 assets, address receiver) public nonReentrant onlyRole(USER_ROLE) returns (uint256) {
        return _deposit(_msgSender(), receiver, assets);
    }

    /// @notice Redeem {shares} for assets withdrawn to {receiver}
    function redeem(uint256 shares, address receiver) public nonReentrant onlyRole(USER_ROLE) returns (uint256) {
        address caller = _msgSender();
        return _redeem(caller, caller, receiver, shares);
    }

    /// @notice Redeem {shares} and revert if slippage is exceeded
    function redeemWithSlippage(uint256 shares, address receiver, uint256 minAssets) external returns (uint256) {
        uint256 assets = redeem(shares, receiver);
        if (assets < minAssets) {
            revert WithdrewLessThanMinAssets(assets, minAssets);
        }
        return assets;
    }

    /// @notice Create a redeem order of {shares} for {receiver}
    function createRedeemOrder(uint256 shares, address receiver)
        external
        nonReentrant
        onlyRole(USER_ROLE)
        returns (uint256)
    {
        if (shares < minRedeemOrder) {
            revert UnderMinRedeemOrder(shares, minRedeemOrder);
        }
        return _createRedeemOrder(_msgSender(), receiver, shares);
    }

    /// @notice Deposit {assets} in liquidity and fill pending redeem orders by {orderIds}
    function fillRedeemOrders(uint256 assets, uint256[] calldata orderIds)
        external
        nonReentrant
        onlyRole(ORDER_FILLER_ROLE)
    {
        address caller = _msgSender();
        _depositLiquidity(caller, assets);
        for (uint256 idx = 0; idx < orderIds.length; idx++) {
            uint256 orderId = orderIds[idx];
            _fillRedeemOrder(caller, orderId);
        }
    }

    /// @notice Cancel pending redeem orders by {orderIds}
    function cancelRedeemOrders(uint256[] calldata orderIds) external nonReentrant onlyRole(ORDER_FILLER_ROLE) {
        address caller = _msgSender();
        for (uint256 idx = 0; idx < orderIds.length; idx++) {
            uint256 orderId = orderIds[idx];
            _cancelRedeemOrder(caller, orderId);
        }
    }

    /// @notice Deposit {assets} in liquidity
    function depositLiquidity(uint256 assets) external nonReentrant onlyRole(LIQUIDITY_MANAGER_ROLE) {
        _depositLiquidity(_msgSender(), assets);
    }

    /// @notice Withdraw {assets} of liquidity to {receiver}
    function withdrawLiquidity(uint256 assets, address receiver)
        external
        nonReentrant
        onlyRole(LIQUIDITY_MANAGER_ROLE)
    {
        _withdrawLiquidity(receiver, assets);
    }

    /// @notice Set the minimum redeem order size to {newMin}
    function setMinRedeemOrder(uint256 newMin) external onlyRole(REDEEM_MANAGER_ROLE) {
        uint256 oldMin = minRedeemOrder;
        minRedeemOrder = newMin;
        emit UpdatedMinRedeemOrder(oldMin, newMin);
    }

    function _deposit(address caller, address receiver, uint256 assets) internal returns (uint256) {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        SafeERC20.safeIncreaseAllowance(IERC20(asset()), vault0(), assets);
        uint256 shares0 = _vault0.deposit(assets, address(this));
        SafeERC20.safeIncreaseAllowance(IERC20(vault0()), vault1(), shares0);
        uint256 shares1 = _vault1.deposit(shares0, receiver);
        emit Deposit(caller, receiver, assets, shares1);
        return shares1;
    }

    // slither-disable-next-line calls-loop
    function _redeem(address caller, address _owner, address receiver, uint256 shares) internal returns (uint256) {
        uint256 assets1 = _vault1.redeem(shares, address(this), _owner);
        uint256 assets0 = _vault0.convertToAssets(assets1);
        IERC20Burnable(address(_vault0)).burn(assets1);
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets0);
        // slither-disable-next-line reentrancy-events
        emit Withdraw(caller, receiver, _owner, assets0, shares);
        return assets0;
    }

    function _createRedeemOrder(address _owner, address receiver, uint256 shares) internal returns (uint256) {
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }

        uint256 orderId = _orderCount;
        _orders[orderId] = Order({
            shares: shares,
            owner: _owner,
            receiver: receiver,
            createdAt: SafeCast.toUint40(block.timestamp),
            status: OrderStatus.Pending
        });
        _orderCount++;
        // slither-disable-next-line unused-return
        _pendingOrderIds.add(orderId);

        SafeERC20.safeTransferFrom(IERC20(vault1()), _owner, address(this), shares);

        emit CreatedRedeemOrder(_owner, receiver, _owner, orderId, shares);
        return orderId;
    }

    function _fillRedeemOrder(address caller, uint256 orderId) internal {
        Order storage order = _orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }

        order.status = OrderStatus.Filled;
        // slither-disable-next-line unused-return
        _pendingOrderIds.remove(orderId);

        uint256 assets = _redeem(caller, address(this), order.receiver, order.shares);

        emit FilledRedeemOrder(caller, order.receiver, order.owner, orderId, assets, order.shares);
    }

    function _cancelRedeemOrder(address caller, uint256 orderId) internal {
        Order storage order = _orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }

        SafeERC20.safeTransfer(IERC20(vault1()), order.owner, order.shares);

        order.status = OrderStatus.Cancelled;
        // slither-disable-next-line unused-return
        _pendingOrderIds.remove(orderId);

        emit CancelledRedeemOrder(caller, orderId);
    }

    function _depositLiquidity(address caller, uint256 assets) internal {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        emit DepositedLiquidity(caller, assets);
    }

    function _withdrawLiquidity(address receiver, uint256 assets) internal {
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        emit WithdrewLiquidity(receiver, assets);
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[43] private __gap;
}
