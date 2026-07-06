// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IYuzuIssuerDefinitions} from "./interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuOrderBookDefinitions, Order, OrderStatus} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {IYuzuProtoDefinitions} from "./interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuV3RouterBase} from "./interfaces/IYuzuV3FacetRouters.sol";
import {
    ADMIN_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    ORDER_FILLER_ROLE,
    REDEEM_MANAGER_ROLE
} from "./libraries/YuzuV3Constants.sol";
import {YuzuV3Fees} from "./libraries/YuzuV3Fees.sol";

/**
 * @title YuzuV3FacetBase
 * @dev Shared facet surface for the V3 vaults, holding the single replica of the frozen proto storage
 * layout. Runs under delegatecall from the vault proxy; state is read through the vault's external
 * interface and written through the pinned slots and struct replicas below.
 */
abstract contract YuzuV3FacetBase is IYuzuIssuerDefinitions, IYuzuOrderBookDefinitions, IYuzuProtoDefinitions {
    // Storage replicas
    uint256 private constant YUZU_PROTO_TREASURY_SLOT = 1;
    uint256 private constant YUZU_PROTO_REDEEM_FEE_SLOT = 2;
    uint256 private constant YUZU_PROTO_REDEEM_ORDER_FEE_SLOT = 3;
    uint256 private constant YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT = 4;
    uint256 private constant IS_MINT_RESTRICTED_SHIFT = 160;
    uint256 private constant IS_REDEEM_RESTRICTED_SHIFT = 168;

    struct YuzuIssuerStorage {
        uint256 _supplyCap;
        uint256 _liquidityBufferTargetSize;
    }

    struct YuzuOrderBookStorage {
        uint256 _fillWindow;
        uint256 _totalPendingOrderSize;
        uint256 _totalUnfinalizedOrderValue;
        uint256 _orderCount;
        uint256 _minRedeemOrder;
        mapping(uint256 => Order) _orders;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.issuer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuIssuerStorageLocation =
        0x542408f99cbd5a3e32919127cd9d8984eb4635c3ab0f9f17273c636c42e08d00;

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.orderbook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuOrderBookStorageLocation =
        0x747f75a735bbbfd5f9552c4d2a106ffbc4ca977c3f429389a57413d9a643a500;

    // Order lifecycle
    function createRedeemOrder(uint256 tokens, address receiver, address owner) public returns (uint256) {
        IYuzuV3RouterBase router = IYuzuV3RouterBase(address(this));
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }
        uint256 maxTokens = router.maxRedeemOrder(owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeemOrder(owner, tokens, maxTokens);
        }
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 minTokens = $._minRedeemOrder;
        if (tokens < minTokens) {
            revert UnderMinRedeemOrder(tokens, minTokens);
        }
        uint256 feePpm = router.redeemOrderFeePpm();

        $._totalPendingOrderSize += tokens;
        uint256 orderId = $._orderCount;
        // slither-disable-next-line pess-dubious-typecast
        $._orders[orderId] = Order({
            assets: 0,
            tokens: tokens,
            owner: owner,
            receiver: receiver,
            controller: msg.sender,
            dueTime: SafeCast.toUint40(block.timestamp + $._fillWindow),
            status: OrderStatus.Pending,
            feePpm: uint24(feePpm)
        });
        $._orderCount++;

        if (msg.sender != owner) {
            router.__routerSpendAllowance(owner, msg.sender, tokens);
        }
        router.__routerTransfer(owner, address(this), tokens);

        // slither-disable-next-line reentrancy-events
        emit CreatedRedeemOrder(msg.sender, receiver, owner, orderId, tokens);
        return orderId;
    }

    function createRedeemOrderWithMaxFee(uint256 tokens, address receiver, address owner, uint256 maxFeePpm)
        external
        returns (uint256)
    {
        uint256 feePpm = IYuzuV3RouterBase(address(this)).redeemOrderFeePpm();
        if (feePpm > maxFeePpm) {
            revert FeeOverMaxFee(feePpm, maxFeePpm);
        }
        return createRedeemOrder(tokens, receiver, owner);
    }

    function finalizeRedeemOrder(uint256 orderId) external {
        IYuzuV3RouterBase router = IYuzuV3RouterBase(address(this));
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        Order storage order = $._orders[orderId];
        if (msg.sender != order.owner && msg.sender != order.controller) {
            revert UnauthorizedOrderFinalizer(msg.sender, order.owner, order.controller);
        }
        if (order.status != OrderStatus.Filled) {
            revert OrderNotFilled(orderId);
        }
        if (router.paused()) {
            revert PausableUpgradeable.EnforcedPause();
        }

        order.status = OrderStatus.Finalized;
        $._totalUnfinalizedOrderValue -= order.assets;

        SafeERC20.safeTransfer(IERC20(router.asset()), order.receiver, order.assets);

        // slither-disable-next-line reentrancy-events
        emit FinalizedRedeemOrder(msg.sender, order.receiver, order.owner, orderId, order.assets, order.tokens);
        // slither-disable-next-line reentrancy-events
        emit Withdraw(msg.sender, order.receiver, order.owner, order.assets, order.tokens);
    }

    /// @dev Order fillers may force-cancel any pending order, even while paused and before it is due.
    function cancelRedeemOrder(uint256 orderId) external {
        IYuzuV3RouterBase router = IYuzuV3RouterBase(address(this));
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        Order storage order = $._orders[orderId];
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (!IAccessControl(address(this)).hasRole(ORDER_FILLER_ROLE, msg.sender)) {
            if (router.paused()) {
                revert PausableUpgradeable.EnforcedPause();
            }
            if (msg.sender != order.owner && msg.sender != order.controller) {
                revert UnauthorizedOrderManager(msg.sender, order.owner, order.controller);
            }
            if (block.timestamp < order.dueTime) {
                revert OrderNotDue(orderId);
            }
        }

        order.status = OrderStatus.Cancelled;
        $._totalPendingOrderSize -= order.tokens;
        router.__routerTransfer(address(this), order.owner, order.tokens);

        // slither-disable-next-line reentrancy-events
        emit CancelledRedeemOrder(msg.sender, orderId);
    }

    // Views
    /// @notice Preview the assets paid out for redeeming {tokens} with an order at the current fee
    function previewRedeemOrder(uint256 tokens) external view returns (uint256) {
        IYuzuV3RouterBase router = IYuzuV3RouterBase(msg.sender);
        (uint256 assets,) = _orderValue(router, tokens, router.redeemOrderFeePpm());
        return assets;
    }

    // Config setters
    function setMinRedeemOrder(uint256 newMin) external {
        _checkRole(LIMIT_MANAGER_ROLE);
        YuzuOrderBookStorage storage $ = _getYuzuOrderBookStorage();
        uint256 oldMin = $._minRedeemOrder;
        $._minRedeemOrder = newMin;
        emit UpdatedMinRedeemOrder(oldMin, newMin);
    }

    function setRedeemFee(uint256 newFeePpm) external {
        _checkRole(FEE_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = _redeemFeePpm();
        _setRedeemFeePpm(newFeePpm);
        emit UpdatedRedeemFee(oldFee, newFeePpm);
    }

    function setRedeemOrderFee(uint256 newFeePpm) external {
        _checkRole(FEE_MANAGER_ROLE);
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = _redeemOrderFeePpm();
        _setRedeemOrderFeePpm(newFeePpm);
        emit UpdatedRedeemOrderFee(oldFee, newFeePpm);
    }

    function setIsMintRestricted(bool restricted) external {
        _checkRole(ADMIN_ROLE);
        bool oldValue =
            _setPackedBool(YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT, IS_MINT_RESTRICTED_SHIFT, restricted);
        emit UpdatedIsMintRestricted(oldValue, restricted);
    }

    function setIsRedeemRestricted(bool restricted) external {
        _checkRole(ADMIN_ROLE);
        bool oldValue =
            _setPackedBool(YUZU_PROTO_FEE_RECEIVER_AND_RESTRICTIONS_SLOT, IS_REDEEM_RESTRICTED_SHIFT, restricted);
        emit UpdatedIsRedeemRestricted(oldValue, restricted);
    }

    // Internal
    function _checkRole(bytes32 role) internal view {
        if (!IAccessControl(address(this)).hasRole(role, msg.sender)) {
            revert IAccessControl.AccessControlUnauthorizedAccount(msg.sender, role);
        }
    }

    /// @dev Values a redeem order: the tokens' worth at the current share price, minus the order fee.
    function _orderValue(IYuzuV3RouterBase router, uint256 tokens, uint256 feePpm)
        internal
        view
        returns (uint256 assets, uint256 fee)
    {
        uint256 grossAssets = router.convertToAssets(tokens);
        fee = YuzuV3Fees.feeOnTotal(grossAssets, feePpm);
        assets = grossAssets - fee;
    }

    // Storage accessors
    function _setPackedAddress(uint256 slot, address value) internal {
        uint256 mask = type(uint160).max;
        assembly {
            let oldValue := sload(slot)
            sstore(slot, or(and(oldValue, not(mask)), and(value, mask)))
        }
    }

    function _setPackedBool(uint256 slot, uint256 shift, bool value) internal returns (bool oldValue) {
        uint256 mask = 0xff << shift;
        uint256 oldSlot;
        assembly {
            oldSlot := sload(slot)
        }
        oldValue = ((oldSlot >> shift) & 0xff) != 0;
        uint256 newSlot = oldSlot & ~mask;
        if (value) {
            newSlot |= 1 << shift;
        }
        assembly {
            sstore(slot, newSlot)
        }
    }

    function _redeemFeePpm() internal view returns (uint256 value) {
        assembly {
            value := sload(YUZU_PROTO_REDEEM_FEE_SLOT)
        }
    }

    function _setRedeemFeePpm(uint256 value) internal {
        assembly {
            sstore(YUZU_PROTO_REDEEM_FEE_SLOT, value)
        }
    }

    function _redeemOrderFeePpm() internal view returns (uint256 value) {
        assembly {
            value := sload(YUZU_PROTO_REDEEM_ORDER_FEE_SLOT)
        }
    }

    function _setRedeemOrderFeePpm(uint256 value) internal {
        assembly {
            sstore(YUZU_PROTO_REDEEM_ORDER_FEE_SLOT, value)
        }
    }

    function _getYuzuIssuerStorage() internal pure returns (YuzuIssuerStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuIssuerStorageLocation
        }
    }

    function _getYuzuOrderBookStorage() internal pure returns (YuzuOrderBookStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuOrderBookStorageLocation
        }
    }
}
