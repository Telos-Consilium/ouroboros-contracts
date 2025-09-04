// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {IYuzuProtoDefinitions} from "../interfaces/proto/IYuzuProtoDefinitions.sol";

import {YuzuIssuer} from "./YuzuIssuer.sol";
import {YuzuOrderBook, Order} from "./YuzuOrderBook.sol";

abstract contract YuzuProto is
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    YuzuIssuer,
    YuzuOrderBook,
    AccessControlDefaultAdminRulesUpgradeable,
    PausableUpgradeable,
    IYuzuProtoDefinitions
{
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");

    address internal _asset;
    address internal _treasury;

    uint256 public redeemFeePpm;
    int256 public redeemOrderFeePpm;

    function __YuzuProto_init(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        uint256 _supplyCap,
        uint256 _fillWindow
    ) internal onlyInitializing {
        __YuzuProto_init_unchained(__asset, __name, __symbol, _admin, __treasury, _supplyCap, _fillWindow);
    }

    function __YuzuProto_init_unchained(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        uint256 _supplyCap,
        uint256 _fillWindow
    ) internal onlyInitializing {
        __ERC20_init(__name, __symbol);
        __ERC20Permit_init(__name);
        __YuzuIssuer_init(_supplyCap);
        __YuzuOrderBook_init(_fillWindow);
        __AccessControlDefaultAdminRules_init(0, _admin);

        if (__asset == address(0) || __treasury == address(0)) {
            revert InvalidZeroAddress();
        }

        _asset = __asset;
        _treasury = __treasury;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
    }

    function __yuzu_totalSupply() internal view override(YuzuIssuer) returns (uint256) {
        return totalSupply();
    }

    function __yuzu_balanceOf(address account) internal view override(YuzuIssuer, YuzuOrderBook) returns (uint256) {
        return balanceOf(account);
    }

    function __yuzu_burn(address account, uint256 amount) internal override(YuzuIssuer, YuzuOrderBook) {
        _burn(account, amount);
    }

    function __yuzu_spendAllowance(address _owner, address spender, uint256 amount)
        internal
        override(YuzuIssuer, YuzuOrderBook)
    {
        _spendAllowance(_owner, spender, amount);
    }

    function __yuzu_mint(address account, uint256 amount) internal override(YuzuIssuer) {
        _mint(account, amount);
    }

    function __yuzu_transfer(address from, address to, uint256 amount) internal override(YuzuOrderBook) {
        _transfer(from, to, amount);
    }

    /// @notice See {IERC4626-asset}
    function asset() public view override(YuzuIssuer, YuzuOrderBook) returns (address) {
        return _asset;
    }

    function treasury() public view override returns (address) {
        return _treasury;
    }

    /// @notice See {IERC4626-previewWithdraw}
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        uint256 tokens = _convertToShares(assets + fee, Math.Rounding.Ceil);
        return tokens;
    }

    /// @notice See {IERC4626-previewRedeem}
    function previewRedeem(uint256 tokens) public view virtual override returns (uint256) {
        uint256 assets = _convertToAssets(tokens, Math.Rounding.Floor);
        uint256 fee = _feeOnTotal(assets, redeemFeePpm);
        return assets - fee;
    }

    /// @notice Preview the amount of assets to receive when redeeming `tokens` with an order after fees
    function previewRedeemOrder(uint256 tokens) public view virtual override returns (uint256) {
        uint256 assets = _convertToAssets(tokens, Math.Rounding.Floor);
        return _applyFeeOrIncentiveOnTotal(assets, redeemOrderFeePpm);
    }

    function fillRedeemOrder(uint256 orderId) public virtual override onlyRole(ORDER_FILLER_ROLE) {
        super.fillRedeemOrder(orderId);
    }

    function withdrawCollateral(uint256 assets, address receiver) public virtual override onlyRole(ADMIN_ROLE) {
        super.withdrawCollateral(assets, receiver);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (token == address(this)) {
            uint256 outstandingBalance = balanceOf(address(this)) - totalPendingOrderSize();
            if (amount > outstandingBalance) {
                revert ExceededOutstandingBalance(amount, outstandingBalance);
            }
        } else if (token == _asset) {
            revert InvalidAssetRescue(token);
        }
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) {
            revert InvalidZeroAddress();
        }
        address oldTreasury = _treasury;
        _treasury = newTreasury;
        emit UpdatedTreasury(oldTreasury, newTreasury);
    }

    function setRedeemFee(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = redeemFeePpm;
        redeemFeePpm = newFeePpm;
        emit UpdatedRedeemFee(oldFee, newFeePpm);
    }

    function setRedeemOrderFee(int256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(SafeCast.toUint256(newFeePpm), 1e6);
        }
        int256 oldFee = redeemOrderFeePpm;
        redeemOrderFeePpm = newFeePpm;
        emit UpdatedRedeemOrderFee(oldFee, newFeePpm);
    }

    /// @notice Pauses all minting and redeeming functions
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses all minting and redeeming functions
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // slither-disable-next-line pess-strange-setter
    function setSupplyCap(uint256 newCap) external onlyRole(LIMIT_MANAGER_ROLE) {
        _setSupplyCap(newCap);
    }

    // slither-disable-next-line pess-strange-setter
    function setFillWindow(uint256 newWindow) external onlyRole(REDEEM_MANAGER_ROLE) {
        _setFillWindow(newWindow);
    }

    /// @dev Returns the assets available for withdrawal.
    function liquidityBufferSize() public view virtual override returns (uint256) {
        return super.liquidityBufferSize() - totalUnfinalizedOrderValue();
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 tokens)
        internal
        virtual
        override
        whenNotPaused
    {
        super._deposit(caller, receiver, assets, tokens);
    }

    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 tokens)
        internal
        virtual
        override
        whenNotPaused
    {
        super._withdraw(caller, receiver, _owner, assets, tokens);
    }

    function _createRedeemOrder(address caller, address receiver, address _owner, uint256 tokens, uint256 assets)
        internal
        virtual
        override
        whenNotPaused
        returns (uint256)
    {
        return super._createRedeemOrder(caller, receiver, _owner, tokens, assets);
    }

    function _finalizeRedeemOrder(Order storage order) internal virtual override whenNotPaused {
        super._finalizeRedeemOrder(order);
    }

    function _cancelRedeemOrder(Order storage order) internal virtual override whenNotPaused {
        super._cancelRedeemOrder(order);
    }

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees.
    function _feeOnRaw(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, 1e6, Math.Rounding.Ceil);
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees.
    function _feeOnTotal(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, feePpm + 1e6, Math.Rounding.Ceil);
    }

    /// @dev Applies a fee or incentive to an amount `assets` that already includes fees.
    function _applyFeeOrIncentiveOnTotal(uint256 assets, int256 feePpm) internal pure returns (uint256) {
        if (feePpm >= 0) {
            /// @dev Positive fee - reduce assets returned
            uint256 fee = _feeOnTotal(assets, SafeCast.toUint256(feePpm));
            return assets - fee;
        } else {
            /// @dev Negative fee (incentive) - increase assets returned
            uint256 incentive = _feeOnRaw(assets, SafeCast.toUint256(-feePpm));
            return assets + incentive;
        }
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 12;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
