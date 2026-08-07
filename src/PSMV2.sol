// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IERC20Burnable, IMinWithdraw, IRedeemThrottle, IRestrictedShares} from "./interfaces/IPSMDefinitions.sol";
import {REDEEM_FEE_EXEMPT_ROLE} from "./libraries/YuzuV3Constants.sol";
import {PSM} from "./PSM.sol";
import {YuzuMinAmounts} from "./proto/YuzuMinAmounts.sol";
import {YuzuThrottle} from "./proto/YuzuThrottle.sol";

/**
 * @title PSMV2
 * @notice PSM with V2 limits and throttles
 * @dev Mint and redeem throttles apply to their instant paths; the same-block restriction applies to instant redemption.
 * @dev Requires vault1 to expose {redeemThrottleRemaining}, {currentBlockRestrictedBalance}, and {minWithdraw}.
 */
contract PSMV2 is PSM, YuzuMinAmounts, YuzuThrottle {
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant SAME_BLOCK_EXEMPT_ROLE = keccak256("SAME_BLOCK_EXEMPT_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");

    /// @notice Reinitializes the contract for the V2 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize() external reinitializer(2) {
        _setRoleAdmin(LIMIT_MANAGER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(SAME_BLOCK_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setMintThrottle(type(uint256).max, type(uint256).max);
        _setRedeemThrottle(type(uint256).max, type(uint256).max);
    }

    /// @inheritdoc YuzuThrottle
    function _isThrottleExempt(address account) internal view override returns (bool) {
        return hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    function _isSameBlockExempt(address account) private view returns (bool) {
        return hasRole(SAME_BLOCK_EXEMPT_ROLE, account);
    }

    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit)
        external
        virtual
        onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setMintThrottle(newBlockLimit, newDailyLimit);
    }

    function setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit)
        external
        virtual
        onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setRedeemThrottle(newBlockLimit, newDailyLimit);
    }

    function setMinDeposit(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinDeposit(newMin);
    }

    function setMinWithdraw(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinWithdraw(newMin);
    }

    /// @inheritdoc PSM
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = Math.min(super.maxDeposit(receiver), _mintThrottleRemaining(receiver));
        return maxAssets < minDeposit() ? 0 : maxAssets;
    }

    /// @inheritdoc PSM
    /// @dev Never over-reports; may under-report by at most one share.
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        if (!_canRedeem() || !hasRole(USER_ROLE, _owner)) {
            return 0;
        }

        uint256 maxShares = _vault1.balanceOf(_owner);
        if (!_isSameBlockExempt(_owner)) {
            uint256 restricted = _restrictedShares(_owner);
            uint256 mature = maxShares > restricted ? maxShares - restricted : 0;
            if (maxShares > mature) {
                maxShares = mature;
            }
        }

        uint256 innerRemaining = IRedeemThrottle(vault1()).redeemThrottleRemaining(address(this));
        if (_vault1AssetsGross(maxShares) > innerRemaining) {
            maxShares = _vault1.convertToShares(innerRemaining);
        }

        // Compare in asset terms before inverting so an unlimited budget skips a potentially overflowing inverse.
        uint256 liq = liquidity();
        if (_netRedeemAssets(maxShares) > liq) {
            maxShares = Math.min(maxShares, _netSharesWithinBudget(liq));
        }
        uint256 outerRemaining = _redeemThrottleRemaining(_owner);
        if (_netRedeemAssets(maxShares) > outerRemaining) {
            maxShares = Math.min(maxShares, _netSharesWithinBudget(outerRemaining));
        }

        if (_vault1AssetsNet(maxShares) < IMinWithdraw(vault1()).minWithdraw()) {
            return 0;
        }
        return _netRedeemAssets(maxShares) < minWithdraw() ? 0 : maxShares;
    }

    /// @dev Shares received by the owner in the current block, read from vault1. A vault without
    /// {currentBlockRestrictedBalance} reverts here, so the restriction fails closed.
    function _restrictedShares(address _owner) private view returns (uint256) {
        return IRestrictedShares(vault1()).currentBlockRestrictedBalance(_owner);
    }

    /// @inheritdoc PSM
    /// @dev {PSM-deposit} applies the reentrancy guard; the trailing throttle write touches only storage.
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(assets);
        uint256 shares = super.deposit(assets, receiver);
        _consumeMintThrottle(receiver, assets);
        return shares;
    }

    /// @inheritdoc PSM
    /// @dev {PSM-redeem} applies the reentrancy guard; the trailing throttle write touches only storage.
    /// For owners without SAME_BLOCK_EXEMPT_ROLE, {maxRedeem} excludes shares received this block before
    /// {PSM-redeem} pulls them into the PSM.
    function redeem(uint256 shares, address receiver, address _owner) public virtual override returns (uint256) {
        uint256 assetsOut = super.redeem(shares, receiver, _owner);
        _checkMinWithdraw(assetsOut);
        _consumeRedeemThrottle(_owner, assetsOut);
        return assetsOut;
    }

    function _createRedeemOrder(address caller, address receiver, address _owner, uint256 shares)
        internal
        virtual
        override
        returns (uint256)
    {
        _checkMinWithdraw(_netRedeemAssets(shares));
        return super._createRedeemOrder(caller, receiver, _owner, shares);
    }

    /// @inheritdoc PSM
    /// @dev Nets the inner-vault redeem fee the PSM actually pays; fee-free when the PSM is exempt.
    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        return _netRedeemAssets(shares);
    }

    /// @dev Deposits into the staked vault as the principal and forwards the shares, so the vault's
    /// receiver-keyed limits and exemptions apply to the PSM rather than to the recipient.
    function _deposit(address caller, address receiver, uint256 assets) internal virtual override returns (uint256) {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        SafeERC20.safeIncreaseAllowance(IERC20(asset()), vault0(), assets);
        uint256 shares0 = _vault0.deposit(assets, address(this));
        SafeERC20.safeIncreaseAllowance(IERC20(vault0()), vault1(), shares0);
        uint256 shares1 = _vault1.deposit(shares0, address(this));
        SafeERC20.safeTransfer(IERC20(vault1()), receiver, shares1);
        // slither-disable-next-line reentrancy-events
        emit Deposit(caller, receiver, assets, shares1);
        return shares1;
    }

    /// @dev Pulls the owner's staked shares and redeems as the principal, so the vault's owner-keyed
    /// limits and exemptions apply to the PSM; mirrors the order path, which already escrows shares
    /// before filling. The pull consumes the same share allowance the direct redeem consumed.
    // slither-disable-next-line calls-loop
    function _redeem(address caller, address receiver, address _owner, uint256 shares)
        internal
        virtual
        override
        returns (uint256)
    {
        if (_owner != address(this)) {
            // slither-disable-next-line arbitrary-send-erc20
            SafeERC20.safeTransferFrom(IERC20(vault1()), _owner, address(this), shares);
        }
        uint256 assets1 = _vault1.redeem(shares, address(this), address(this));
        uint256 assets0 = _vault0.convertToAssets(assets1);
        IERC20Burnable(address(_vault0)).burn(assets1);
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets0);
        // slither-disable-next-line reentrancy-events
        emit Withdraw(caller, receiver, _owner, assets0, shares);
        return assets0;
    }

    function _redeemFeeExempt() private view returns (bool) {
        return IAccessControl(vault1()).hasRole(REDEEM_FEE_EXEMPT_ROLE, address(this));
    }

    /// @dev Inner-vault assets, gross of the redeem fee.
    function _vault1AssetsGross(uint256 shares) private view returns (uint256) {
        return _vault1.convertToAssets(shares);
    }

    /// @dev Inner-vault assets, net of the redeem fee the PSM pays.
    function _vault1AssetsNet(uint256 shares) private view returns (uint256) {
        return _redeemFeeExempt() ? _vault1.convertToAssets(shares) : _vault1.previewRedeem(shares);
    }

    /// @dev Inner-vault shares for a net-assets target; the non-exempt branch (previewWithdraw)
    /// rounds up, the exempt branch (convertToShares) down.
    function _vault1SharesForNet(uint256 assets) private view returns (uint256) {
        return _redeemFeeExempt() ? _vault1.convertToShares(assets) : _vault1.previewWithdraw(assets);
    }

    /// @dev Underlying assets, net of the inner fee.
    function _netRedeemAssets(uint256 shares) private view returns (uint256) {
        return _vault0.convertToAssets(_vault1AssetsNet(shares));
    }

    /// @dev Shares for a net underlying budget; the inner conversion rounds up only in the
    /// non-exempt branch.
    function _netSharesForAssets(uint256 assets) private view returns (uint256) {
        return _vault1SharesForNet(_vault0.convertToShares(assets));
    }

    /// @dev Net stays within budget, under-reporting by at most one share; previewWithdraw is the only
    /// up-rounding step, so one decrement removes any overshoot.
    function _netSharesWithinBudget(uint256 budget) private view returns (uint256 shares) {
        shares = _netSharesForAssets(budget);
        if (shares > 0 && _netRedeemAssets(shares) > budget) {
            shares--;
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
