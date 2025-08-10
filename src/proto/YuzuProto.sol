// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AccessControlDefaultAdminRulesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlDefaultAdminRulesUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYuzuProtoDefinitions} from "../interfaces/proto/IYuzuProtoDefinitions.sol";

import {YuzuIssuer} from "./YuzuIssuer.sol";
import {YuzuOrderBook} from "./YuzuOrderBook.sol";

abstract contract YuzuProto is
    ERC20Upgradeable,
    YuzuIssuer,
    YuzuOrderBook,
    AccessControlDefaultAdminRulesUpgradeable,
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
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock,
        uint256 _fillWindow
    ) internal onlyInitializing {
        __YuzuProto_init_unchained(
            __asset, __name, __symbol, _admin, __treasury, _maxDepositPerBlock, _maxWithdrawPerBlock, _fillWindow
        );
    }

    function __YuzuProto_init_unchained(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock,
        uint256 _fillWindow
    ) internal onlyInitializing {
        __ERC20_init(__name, __symbol);
        __YuzuIssuer_init(_maxDepositPerBlock, _maxWithdrawPerBlock);
        __YuzuOrderBook_init(_fillWindow);
        __AccessControlDefaultAdminRules_init(0, _admin);

        if (_admin == address(0)) revert InvalidZeroAddress();
        if (__asset == address(0)) revert InvalidZeroAddress();
        if (__treasury == address(0)) revert InvalidZeroAddress();

        _asset = __asset;
        _treasury = __treasury;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
    }

    function __yuzu_balanceOf(address account) public view override(YuzuIssuer, YuzuOrderBook) returns (uint256) {
        return balanceOf(account);
    }

    function __yuzu_burn(address account, uint256 amount) internal override(YuzuIssuer, YuzuOrderBook) {
        _burn(account, amount);
    }

    function __yuzu_spendAllowance(address owner, address spender, uint256 amount)
        internal
        override(YuzuIssuer, YuzuOrderBook)
    {
        _spendAllowance(owner, spender, amount);
    }

    function __yuzu_mint(address account, uint256 amount) internal override(YuzuIssuer) {
        _mint(account, amount);
    }

    function __yuzu_transfer(address from, address to, uint256 amount) internal override(YuzuOrderBook) {
        _transfer(from, to, amount);
    }

    function asset() public view override(YuzuIssuer, YuzuOrderBook) returns (address) {
        return _asset;
    }

    function treasury() public view override returns (address) {
        return _treasury;
    }

    function fillRedeemOrder(uint256 orderId) public override onlyRole(ORDER_FILLER_ROLE) {
        super.fillRedeemOrder(orderId);
    }

    function withdrawCollateral(uint256 assets, address receiver) public override onlyRole(ADMIN_ROLE) {
        super.withdrawCollateral(assets, receiver);
    }

    function rescueTokens(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (token == address(this)) {
            uint256 outstandingBalance = balanceOf(address(this)) - currentPendingOrderValue() * 10 ** _decimalsOffset();
            if (amount > outstandingBalance) {
                revert ExceededOutstandingBalance(amount, outstandingBalance);
            }
        }
        SafeERC20.safeTransfer(IERC20(token), to, amount);
    }

    function setTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) {
        if (newTreasury == address(0)) revert InvalidZeroAddress();
        address oldTreasury = _treasury;
        _treasury = newTreasury;
        emit UpdatedTreasury(oldTreasury, newTreasury);
    }

    function setRedeemFeePpm(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) revert InvalidRedeemFee(newFeePpm);
        uint256 oldFee = redeemFeePpm;
        redeemFeePpm = newFeePpm;
        emit UpdatedRedeemFee(oldFee, newFeePpm);
    }

    function setRedeemOrderFeePpm(int256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6 || newFeePpm < -1e6) revert InvalidRedeemOrderFee(newFeePpm);
        int256 oldFee = redeemOrderFeePpm;
        redeemOrderFeePpm = newFeePpm;
        emit UpdatedRedeemOrderFee(oldFee, newFeePpm);
    }

    function setMaxDepositPerBlock(uint256 newMaxDepositPerBlock) external onlyRole(LIMIT_MANAGER_ROLE) {
        _setMaxDepositPerBlock(newMaxDepositPerBlock);
    }

    function setMaxWithdrawPerBlock(uint256 newMaxWithdrawPerBlock) external onlyRole(LIMIT_MANAGER_ROLE) {
        _setMaxWithdrawPerBlock(newMaxWithdrawPerBlock);
    }

    function setFillWindow(uint256 newWindow) external onlyRole(REDEEM_MANAGER_ROLE) {
        _setFillWindow(newWindow);
    }

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees.
    function _feeOnRaw(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, 1e6, Math.Rounding.Ceil);
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees.
    function _feeOnTotal(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, feePpm + 1e6, Math.Rounding.Ceil);
    }

    function _decimalsOffset() internal view virtual returns (uint8) {
        return 12;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
