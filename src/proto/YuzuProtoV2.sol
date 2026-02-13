// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYuzuProtoV2Definitions} from "../interfaces/proto/IYuzuProtoDefinitions.sol";

import {YuzuIssuer} from "./YuzuIssuer.sol";
import {Order, OrderStatus, YuzuOrderBook} from "./YuzuOrderBook.sol";
import {YuzuProto} from "./YuzuProto.sol";

abstract contract YuzuProtoV2 is YuzuProto, IYuzuProtoV2Definitions {
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function __YuzuProtoV2_init(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        address _feeReceiver,
        uint256 _supplyCap,
        uint256 _fillWindow,
        uint256 _minRedeemOrder
    ) internal onlyInitializing {
        __YuzuProto_init(
            __asset, __name, __symbol, _admin, __treasury, _feeReceiver, _supplyCap, _fillWindow, _minRedeemOrder
        );
        __YuzuProtoV2_init_unchained();
    }

    function __YuzuProtoV2_init_unchained() internal onlyInitializing {
        _setRoleAdmin(BURNER_ROLE, ADMIN_ROLE);
    }

    /// @notice Returns true if receiver is allowed to mint, false otherwise
    function canMint(address receiver) public view virtual returns (bool) {
        if (paused()) {
            return false;
        }
        if (isMintRestricted && !hasRole(MINTER_ROLE, receiver)) {
            return false;
        }
        return true;
    }

    /// @notice Returns true if owner is allowed to redeem, false otherwise
    function canRedeem(address _owner) public view virtual returns (bool) {
        if (paused()) {
            return false;
        }
        if (isRedeemRestricted && !hasRole(REDEEMER_ROLE, _owner)) {
            return false;
        }
        return true;
    }

    /// @notice Returns true if owner is allowed to create a redeem order, false otherwise
    function canCreateRedeemOrder(address _owner) public view virtual returns (bool) {
        if (paused()) {
            return false;
        }
        if (isRedeemRestricted && !hasRole(REDEEMER_ROLE, _owner)) {
            return false;
        }
        return true;
    }

    /// @notice Returns true if owner is allowed to burn tokens, false otherwise
    function canBurn(address _owner) public view virtual returns (bool) {
        return hasRole(BURNER_ROLE, _owner);
    }

    /// @inheritdoc YuzuProto
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (!canMint(receiver)) {
            return 0;
        }
        return YuzuIssuer.maxDeposit(receiver);
    }

    /// @inheritdoc YuzuProto
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (!canMint(receiver)) {
            return 0;
        }
        return YuzuIssuer.maxMint(receiver);
    }

    /// @inheritdoc YuzuProto
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        if (!canRedeem(_owner)) {
            return 0;
        }
        uint256 maxAssets = _maxWithdraw(_owner);
        uint256 fee = _feeOnTotal(maxAssets, redeemFeePpm);
        return Math.min(previewRedeem(_maxRedeem(_owner)), maxAssets - fee);
    }

    /// @inheritdoc YuzuProto
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        if (!canRedeem(_owner)) {
            return 0;
        }
        return YuzuIssuer.maxRedeem(_owner);
    }

    /// @inheritdoc YuzuProto
    function maxRedeemOrder(address _owner) public view virtual override returns (uint256) {
        if (!canCreateRedeemOrder(_owner)) {
            return 0;
        }
        return YuzuOrderBook.maxRedeemOrder(_owner);
    }

    /// @notice Returns the maximum amount of tokens that can be burned by an owner
    function maxBurn(address _owner) public view virtual returns (uint256) {
        if (!canBurn(_owner)) {
            return 0;
        }
        return balanceOf(_owner);
    }

    /// @inheritdoc YuzuOrderBook
    function cancelRedeemOrder(uint256 orderId) public virtual override {
        address caller = _msgSender();
        Order storage order = _getOrder(orderId);
        if (order.status != OrderStatus.Pending) {
            revert OrderNotPending(orderId);
        }
        if (!hasRole(ORDER_FILLER_ROLE, caller)) {
            _requireNotPaused();
            if (caller != order.owner && caller != order.controller) {
                revert UnauthorizedOrderManager(caller, order.owner, order.controller);
            }
            if (block.timestamp < order.dueTime) {
                revert OrderNotDue(orderId);
            }
        }

        YuzuOrderBook._cancelRedeemOrder(order);

        emit CancelledRedeemOrder(caller, orderId);
    }

    /// @notice Burn tokens
    function burn(uint256 tokens) public virtual {
        address _owner = _msgSender();
        uint256 maxTokens = maxBurn(_owner);
        if (tokens > maxTokens) {
            revert ExceededMaxBurn(_owner, tokens, maxTokens);
        }
        _burn(_owner, tokens);
    }

    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 tokens, uint256 fee)
        internal
        virtual
        override
    {
        YuzuIssuer._withdraw(caller, receiver, _owner, assets, tokens, fee);
        if (fee > 0) {
            SafeERC20.safeTransfer(IERC20(asset()), feeReceiver, fee);
        }
    }
}
