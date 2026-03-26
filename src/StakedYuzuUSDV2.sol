// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {StakedYuzuUSD} from "./StakedYuzuUSD.sol";
import {IntegrationConfig, IStakedYuzuUSDV2Definitions} from "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSDV2
 * @notice StakedYuzuUSD with integration support and instant redeem/withdraw paths
 */
contract StakedYuzuUSDV2 is StakedYuzuUSD, IStakedYuzuUSDV2Definitions {
    mapping(address => IntegrationConfig) internal integrations;

    /// @notice Reinitializes the contract for V2 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize() external reinitializer(2) {
        __EIP712_init(name(), "2");
    }

    /// @notice Returns true if receiver is allowed to mint, false otherwise
    function canMint(address receiver) public view returns (bool) {
        return !paused();
    }

    /// @notice Returns true if owner is allowed to redeem, false otherwise
    function canRedeem(address _owner) public view returns (bool) {
        if (paused()) {
            return false;
        }
        if (redeemDelay > 0 && !integrations[_owner].canSkipRedeemDelay) {
            return false;
        }
        return true;
    }

    /// @notice Returns true if owner is allowed to create a redeem order, false otherwise
    function canCreateRedeemOrder(address _owner) public view returns (bool) {
        return !paused();
    }

    /// @inheritdoc StakedYuzuUSD
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (!canMint(receiver)) {
            return 0;
        }
        return ERC4626Upgradeable.maxDeposit(receiver);
    }

    /// @inheritdoc StakedYuzuUSD
    function maxMint(address receiver) public view virtual override returns (uint256) {
        if (!canMint(receiver)) {
            return 0;
        }
        return ERC4626Upgradeable.maxMint(receiver);
    }

    /// @inheritdoc StakedYuzuUSD
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        if (!canRedeem(_owner)) {
            return 0;
        }
        (uint256 assets,) = _previewRedeem(balanceOf(_owner));
        return assets;
    }

    /// @inheritdoc StakedYuzuUSD
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        if (!canRedeem(_owner)) {
            return 0;
        }
        return ERC4626Upgradeable.maxRedeem(_owner);
    }

    /// @inheritdoc StakedYuzuUSD
    function maxRedeemOrder(address _owner) public view virtual override returns (uint256) {
        if (!canCreateRedeemOrder(_owner)) {
            return 0;
        }
        return ERC4626Upgradeable.maxRedeem(_owner);
    }

    /// @inheritdoc StakedYuzuUSD
    function withdraw(uint256 assets, address receiver, address _owner) public override returns (uint256) {
        address caller = _msgSender();
        uint256 callerFeePpm = _redeemFeePpmFor(caller);
        uint256 maxAssets = maxWithdraw(_owner);
        if (assets > maxAssets) {
            // Integrations can bypass the redeem delay at execution time
            if (!integrations[caller].canSkipRedeemDelay || paused()) {
                revert ERC4626ExceededMaxWithdraw(_owner, assets, maxAssets);
            }
            (uint256 maxAssetsForIntegration,) = _previewRedeemWithFee(balanceOf(_owner), callerFeePpm);
            if (assets > maxAssetsForIntegration) {
                revert ERC4626ExceededMaxWithdraw(_owner, assets, maxAssetsForIntegration);
            }
        }

        (uint256 shares, uint256 fee) = _previewWithdrawWithFee(assets, callerFeePpm);
        _withdraw(caller, receiver, _owner, shares, assets, fee);

        return shares;
    }

    /// @inheritdoc StakedYuzuUSD
    function redeem(uint256 shares, address receiver, address _owner) public override returns (uint256) {
        address caller = _msgSender();
        uint256 maxShares = maxRedeem(_owner);
        if (shares > maxShares) {
            // Integrations can bypass the redeem delay at execution time
            if (!integrations[caller].canSkipRedeemDelay || paused()) {
                revert ERC4626ExceededMaxRedeem(_owner, shares, maxShares);
            }
            maxShares = ERC4626Upgradeable.maxRedeem(_owner);
            if (shares > maxShares) {
                revert ERC4626ExceededMaxRedeem(_owner, shares, maxShares);
            }
        }

        (uint256 assets, uint256 fee) = _previewRedeemWithFee(shares, _redeemFeePpmFor(caller));
        _withdraw(caller, receiver, _owner, shares, assets, fee);

        return assets;
    }

    /// @inheritdoc StakedYuzuUSD
    function initiateRedeem(uint256 shares, address receiver, address _owner)
        public
        override
        returns (uint256, uint256)
    {
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }
        uint256 maxShares = maxRedeemOrder(_owner);
        if (shares > maxShares) {
            revert ExceededMaxRedeemOrder(_owner, shares, maxShares);
        }

        address caller = _msgSender();
        (uint256 assets, uint256 fee) = _previewRedeemWithFee(shares, _redeemFeePpmFor(caller));
        uint256 orderId = _initiateRedeem(caller, receiver, _owner, assets, shares, fee);

        emit InitiatedRedeem(caller, receiver, _owner, orderId, assets, shares, fee);

        return (orderId, assets);
    }

    /// @notice Withdraw assets and revert if slippage is exceeded
    function withdrawWithSlippage(uint256 assets, address receiver, address _owner, uint256 maxShares)
        external
        returns (uint256)
    {
        uint256 shares = withdraw(assets, receiver, _owner);
        if (shares > maxShares) {
            revert RedeemedMoreThanMaxShares(shares, maxShares);
        }
        return shares;
    }

    /// @notice Redeem shares and revert if slippage is exceeded
    function redeemWithSlippage(uint256 shares, address receiver, address _owner, uint256 minAssets)
        external
        returns (uint256)
    {
        uint256 assets = redeem(shares, receiver, _owner);
        if (assets < minAssets) {
            revert WithdrewLessThanMinAssets(assets, minAssets);
        }
        return assets;
    }

    /// @inheritdoc StakedYuzuUSD
    function rescueTokens(address token, address receiver, uint256 amount) public override {
        if (token == asset()) {
            uint256 rescuableBalance = IERC20(asset()).balanceOf(address(this)) - totalPendingOrderValue;
            if (amount > rescuableBalance) {
                revert ExceededRescuableBalance(amount, rescuableBalance);
            }
        }
        super.rescueTokens(token, receiver, amount);
    }

    function setIntegration(address integration, bool canSkipRedeemDelay, bool waiveRedeemFee) external onlyOwner {
        if (integration == address(0)) {
            revert InvalidZeroAddress();
        }
        integrations[integration] =
            IntegrationConfig({canSkipRedeemDelay: canSkipRedeemDelay, waiveRedeemFee: waiveRedeemFee});
        emit UpdatedIntegration(integration, canSkipRedeemDelay, waiveRedeemFee);
    }

    function getIntegration(address integration) external view returns (IntegrationConfig memory) {
        return integrations[integration];
    }

    function lastDistributionTimestamp() external view returns (uint256) {
        return lastDistributionTime;
    }

    function _redeemFeePpmFor(address account) internal view returns (uint256) {
        if (integrations[account].waiveRedeemFee) {
            return 0;
        }
        return redeemFeePpm;
    }

    function _previewWithdrawWithFee(uint256 assets, uint256 feePpm) internal view returns (uint256, uint256) {
        uint256 fee = _feeOnRaw(assets, feePpm);
        uint256 shares = ERC4626Upgradeable.previewWithdraw(assets + fee);
        return (shares, fee);
    }

    function _previewRedeemWithFee(uint256 shares, uint256 feePpm) internal view returns (uint256, uint256) {
        uint256 assets = ERC4626Upgradeable.previewRedeem(shares);
        uint256 fee = _feeOnTotal(assets, feePpm);
        return (assets - fee, fee);
    }

    function _previewWithdraw(uint256 assets) internal view override returns (uint256, uint256) {
        return _previewWithdrawWithFee(assets, redeemFeePpm);
    }

    function _previewRedeem(uint256 shares) internal view override returns (uint256, uint256) {
        return _previewRedeemWithFee(shares, redeemFeePpm);
    }

    function _withdraw(address caller, address receiver, address _owner, uint256 shares, uint256 assets, uint256 fee)
        internal
    {
        if (caller != _owner) {
            _spendAllowance(_owner, caller, shares);
        }
        _burn(_owner, shares);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        if (fee > 0) {
            SafeERC20.safeTransfer(IERC20(asset()), feeReceiver, fee);
        }

        emit Withdraw(caller, receiver, _owner, assets, shares);
    }

    function _undistributedAssets() internal view override returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (lastDistributionPeriod == 0) {
            return 0;
        }
        return super._undistributedAssets();
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[49] private __gap;
}
