// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
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
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    address internal _asset;
    address internal _treasury;

    uint8 private _underlyingDecimals;

    uint256 public redeemFeePpm;
    uint256 public redeemOrderFeePpm;
    address public feeReceiver;
    bool public isMintRestricted;
    bool public isRedeemRestricted;

    function __YuzuProto_init(
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
        __YuzuProto_init_unchained(
            __asset, __name, __symbol, _admin, __treasury, _feeReceiver, _supplyCap, _fillWindow, _minRedeemOrder
        );
    }

    function __YuzuProto_init_unchained(
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
        __ERC20_init(__name, __symbol);
        __ERC20Permit_init(__name);
        __YuzuIssuer_init(_supplyCap);
        __YuzuOrderBook_init(_fillWindow, _minRedeemOrder);
        __AccessControlDefaultAdminRules_init(0, _admin);
        __Pausable_init();

        if (__asset == address(0) || __treasury == address(0)) {
            revert InvalidZeroAddress();
        }
        if (_feeReceiver == address(0)) {
            revert InvalidZeroAddress();
        }

        _asset = __asset;
        _treasury = __treasury;
        feeReceiver = _feeReceiver;
        isMintRestricted = true;
        isRedeemRestricted = true;

        _grantRole(ADMIN_ROLE, _admin);
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEM_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(ORDER_FILLER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(MINTER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(REDEEMER_ROLE, ADMIN_ROLE);

        (bool success, uint8 assetDecimals) = _tryGetAssetDecimals(IERC20(__asset));
        _underlyingDecimals = success ? assetDecimals : 18;
    }

    /// @dev Attempts to fetch the asset decimals. A return value of false indicates that the attempt failed in some way.
    function _tryGetAssetDecimals(IERC20 asset_) private view returns (bool ok, uint8 assetDecimals) {
        // slither-disable-next-line pess-arbitrary-call-destination-tainted,low-level-calls
        (bool success, bytes memory encodedDecimals) =
            address(asset_).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (success && encodedDecimals.length >= 32) {
            uint256 returnedDecimals = abi.decode(encodedDecimals, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                // slither-disable-next-line pess-dubious-typecast
                return (true, uint8(returnedDecimals));
            }
        }
        return (false, 0);
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

    function decimals() public view virtual override returns (uint8) {
        return _underlyingDecimals + _decimalsOffset();
    }

    /// @notice See {IERC4626-asset}
    function asset() public view override(YuzuIssuer, YuzuOrderBook) returns (address) {
        return _asset;
    }

    function treasury() public view override returns (address) {
        return _treasury;
    }

    /// @notice See {IERC4626-maxDeposit}
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        if (isMintRestricted) {
            if (!hasRole(MINTER_ROLE, receiver)) {
                return 0;
            }
        }
        return super.maxDeposit(receiver);
    }

    /// @notice See {IERC4626-maxMint}
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        if (isMintRestricted) {
            if (!hasRole(MINTER_ROLE, receiver)) {
                return 0;
            }
        }
        return super.maxMint(receiver);
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        if (isRedeemRestricted) {
            if (!hasRole(REDEEMER_ROLE, _owner)) {
                return 0;
            }
        }
        uint256 maxAssets = _maxWithdraw(_owner);
        uint256 fee = _feeOnTotal(maxAssets, redeemFeePpm);
        return Math.min(previewRedeem(_maxRedeem(_owner)), maxAssets - fee);
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        if (isRedeemRestricted) {
            if (!hasRole(REDEEMER_ROLE, _owner)) {
                return 0;
            }
        }
        return super.maxRedeem(_owner);
    }

    /// @notice Return the maximum amount of shares that can be redeemed by `_owner` in a single order
    function maxRedeemOrder(address _owner) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        if (isRedeemRestricted) {
            if (!hasRole(REDEEMER_ROLE, _owner)) {
                return 0;
            }
        }
        return super.maxRedeemOrder(_owner);
    }

    /// @notice Preview the amount of assets to receive when redeeming `tokens` with an order after fees
    function previewRedeemOrder(uint256 tokens) public view override returns (uint256) {
        (uint256 assets,) = _previewRedeemOrder(tokens, redeemOrderFeePpm);
        return assets;
    }

    function createRedeemOrderWithMaxFee(uint256 tokens, address receiver, address _owner, uint256 maxFeePpm)
        public
        virtual
        returns (uint256)
    {
        if (redeemOrderFeePpm > maxFeePpm) {
            revert FeeOverMaxFee(redeemOrderFeePpm, maxFeePpm);
        }
        return createRedeemOrder(tokens, receiver, _owner);
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

    function setRedeemOrderFee(uint256 newFeePpm) external onlyRole(REDEEM_MANAGER_ROLE) {
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = redeemOrderFeePpm;
        redeemOrderFeePpm = newFeePpm;
        emit UpdatedRedeemOrderFee(oldFee, newFeePpm);
    }

    function setFeeReceiver(address newFeeReceiver) external onlyRole(ADMIN_ROLE) {
        if (newFeeReceiver == address(0)) {
            revert InvalidZeroAddress();
        }
        address oldFeeReceiver = feeReceiver;
        feeReceiver = newFeeReceiver;
        emit UpdatedFeeReceiver(oldFeeReceiver, newFeeReceiver);
    }

    /// @notice Pause all mint and redeem functions
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpause all mint and redeem functions
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

    // slither-disable-next-line pess-strange-setter
    function setMinRedeemOrder(uint256 newValue) external onlyRole(REDEEM_MANAGER_ROLE) {
        _setMinRedeemOrder(newValue);
    }

    function setIsMintRestricted(bool restricted) external onlyRole(ADMIN_ROLE) {
        bool oldValue = isMintRestricted;
        isMintRestricted = restricted;
        emit UpdatedIsMintRestricted(oldValue, restricted);
    }

    function setIsRedeemRestricted(bool restricted) external onlyRole(ADMIN_ROLE) {
        bool oldValue = isRedeemRestricted;
        isRedeemRestricted = restricted;
        emit UpdatedIsRedeemRestricted(oldValue, restricted);
    }

    /// @dev Returns the assets available for withdrawal
    function liquidityBufferSize() public view virtual override returns (uint256) {
        return super.liquidityBufferSize() - totalUnfinalizedOrderValue();
    }

    function _previewWithdraw(uint256 assets) public view virtual override returns (uint256, uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        uint256 tokens = _convertToShares(assets + fee, Math.Rounding.Ceil);
        return (tokens, fee);
    }

    function _previewRedeem(uint256 tokens) public view virtual override returns (uint256, uint256) {
        uint256 assets = _convertToAssets(tokens, Math.Rounding.Floor);
        uint256 fee = _feeOnTotal(assets, redeemFeePpm);
        return (assets - fee, fee);
    }

    function _previewRedeemOrder(uint256 shares, uint256 feePpm)
        public
        view
        virtual
        override
        returns (uint256, uint256)
    {
        uint256 assets = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 fee = _feeOnTotal(assets, feePpm);
        return (assets - fee, fee);
    }

    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 tokens, uint256 fee)
        internal
        virtual
        override
        whenNotPaused
    {
        super._withdraw(caller, receiver, _owner, assets, tokens, fee);
        if (fee > 0) {
            SafeERC20.safeTransfer(IERC20(asset()), feeReceiver, fee);
        }
    }

    function _finalizeRedeemOrder(Order storage order) internal virtual override whenNotPaused {
        super._finalizeRedeemOrder(order);
    }

    function _cancelRedeemOrder(Order storage order) internal virtual override whenNotPaused {
        super._cancelRedeemOrder(order);
    }

    function _newRedeemOrder(address caller, address receiver, address _owner, uint256 tokens)
        internal
        view
        virtual
        override
        returns (Order memory)
    {
        Order memory order = super._newRedeemOrder(caller, receiver, _owner, tokens);
        // slither-disable-next-line pess-dubious-typecast
        order.feePpm = uint24(redeemOrderFeePpm);
        return order;
    }

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees
    function _feeOnRaw(uint256 assets, uint256 feePpm) internal pure returns (uint256) {
        return Math.mulDiv(assets, feePpm, 1e6, Math.Rounding.Ceil);
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees
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
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
