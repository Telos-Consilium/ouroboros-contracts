// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IRedeemFee, OrderStatus, Order, IPSMDefinitions} from "./interfaces/IPSMDefinitions.sol";

contract PSM is AccessControlDefaultAdminRulesUpgradeable, ReentrancyGuardUpgradeable, IPSMDefinitions {
    using EnumerableSet for EnumerableSet.UintSet;

    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 internal constant LIQUIDITY_MANAGER_ROLE = keccak256("LIQUIDITY_MANAGER_ROLE");
    bytes32 internal constant RESTRICTION_MANAGER_ROLE = keccak256("RESTRICTION_MANAGER_ROLE");

    bytes32 internal constant USER_ROLE = keccak256("USER_ROLE");

    IERC20 internal _asset;
    IERC4626 internal _vault0;
    IERC4626 internal _vault1;

    uint256 internal _orderCount;
    mapping(uint256 => Order) internal _orders;
    EnumerableSet.UintSet internal _pendingOrderIds;

    constructor() {
        _disableInitializers();
    }

    function initialize(IERC20 __asset, IERC4626 __vault0, IERC4626 __vault1, address _admin) external initializer {
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

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(LIQUIDITY_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(RESTRICTION_MANAGER_ROLE, ADMIN_ROLE);

        _setRoleAdmin(USER_ROLE, RESTRICTION_MANAGER_ROLE);
    }

    function asset() public view returns (address) {
        return address(_asset);
    }

    function vault0() public view returns (address) {
        return address(_vault0);
    }

    function vault1() public view returns (address) {
        return address(_vault1);
    }

    function orderCount() public view returns (uint256) {
        return _orderCount;
    }

    function getRedeemOrder(uint256 orderId) public view returns (Order memory) {
        return _orders[orderId];
    }

    function pendingOrderCount() public view returns (uint256) {
        return _pendingOrderIds.length();
    }

    function getPendingOrderIds(uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256 length = _pendingOrderIds.length();
        if (offset >= length) {
            return new uint256[](0);
        }
        uint256 end = offset + limit;
        if (end > length) {
            end = length;
        }
        uint256 size = end - offset;
        uint256[] memory ids = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            ids[i] = _pendingOrderIds.at(offset + i);
        }
        return ids;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        uint256 shares0 = _vault0.previewDeposit(assets);
        return _vault1.previewDeposit(shares0);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        uint256 assets1 = _vault1.convertToAssets(shares);
        return _vault0.convertToAssets(assets1);
    }

    function deposit(uint256 assets, address receiver) external nonReentrant onlyRole(USER_ROLE) returns (uint256) {
        return _deposit(_msgSender(), receiver, assets);
    }

    function redeem(uint256 shares, address receiver) external nonReentrant onlyRole(USER_ROLE) returns (uint256) {
        address caller = _msgSender();
        return _redeem(caller, caller, receiver, shares);
    }

    function createRedeemOrder(uint256 shares, address receiver)
        external
        nonReentrant
        onlyRole(USER_ROLE)
        returns (uint256)
    {
        return _createRedeemOrder(_msgSender(), receiver, shares);
    }

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

    function cancelRedeemOrders(uint256[] calldata orderIds) external nonReentrant onlyRole(ORDER_FILLER_ROLE) {
        address caller = _msgSender();
        for (uint256 idx = 0; idx < orderIds.length; idx++) {
            uint256 orderId = orderIds[idx];
            _cancelRedeemOrder(caller, orderId);
        }
    }

    function depositLiquidity(uint256 assets) external nonReentrant onlyRole(LIQUIDITY_MANAGER_ROLE) {
        _depositLiquidity(_msgSender(), assets);
    }

    function withdrawLiquidity(uint256 assets, address receiver)
        external
        nonReentrant
        onlyRole(LIQUIDITY_MANAGER_ROLE)
    {
        _withdrawLiquidity(receiver, assets);
    }

    function _deposit(address caller, address receiver, uint256 assets) internal returns (uint256) {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        SafeERC20.forceApprove(IERC20(asset()), vault0(), assets);
        uint256 shares0 = _vault0.deposit(assets, address(this));
        SafeERC20.forceApprove(IERC20(vault0()), vault1(), shares0);
        uint256 shares1 = _vault1.deposit(shares0, receiver);
        emit Deposit(caller, receiver, assets, shares1);
        return shares1;
    }

    function _redeem(address caller, address owner, address receiver, uint256 shares) internal returns (uint256) {
        uint256 shares0 = _vault1.redeem(shares, address(this), owner);
        uint256 currentFee = IRedeemFee(vault0()).redeemFeePpm();
        if (currentFee != 0) IRedeemFee(vault0()).setRedeemFee(0);
        uint256 assets0 = _vault0.previewRedeem(shares0);
        SafeERC20.safeTransfer(IERC20(asset()), vault0(), assets0);
        uint256 assets = _vault0.redeem(shares0, receiver, address(this));
        if (currentFee != 0) IRedeemFee(vault0()).setRedeemFee(currentFee);
        emit Withdraw(caller, receiver, owner, assets, shares);
        return assets;
    }

    function _createRedeemOrder(address owner, address receiver, uint256 shares) internal returns (uint256) {
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }

        uint256 orderId = orderCount();
        _orders[orderId] = Order({
            owner: owner,
            receiver: receiver,
            shares: shares,
            status: OrderStatus.Pending,
            createdAt: uint40(block.timestamp)
        });
        _orderCount++;
        _pendingOrderIds.add(orderId);

        SafeERC20.safeTransferFrom(IERC20(vault1()), owner, address(this), shares);

        emit CreatedRedeemOrder(owner, receiver, owner, orderId, shares);
        return orderId;
    }

    function _fillRedeemOrder(address caller, uint256 orderId) internal {
        Order storage order = _orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }

        uint256 assets = _redeem(caller, address(this), order.receiver, order.shares);

        order.status = OrderStatus.Filled;
        _pendingOrderIds.remove(orderId);

        emit FilledRedeemOrder(caller, order.receiver, order.owner, orderId, assets, order.shares);
    }

    function _cancelRedeemOrder(address caller, uint256 orderId) internal {
        Order storage order = _orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }

        SafeERC20.safeTransfer(IERC20(vault1()), order.owner, order.shares);

        order.status = OrderStatus.Cancelled;
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

    uint256[43] private __gap;
}
