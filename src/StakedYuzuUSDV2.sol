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

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address _owner) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        if (redeemDelay > 0 && !integrations[_msgSender()].canSkipRedeemDelay) {
            return 0;
        }
        (uint256 assets,) = _previewRedeem(balanceOf(_owner));
        return assets;
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address _owner) public view virtual override returns (uint256) {
        if (paused()) {
            return 0;
        }
        if (redeemDelay > 0 && !integrations[_msgSender()].canSkipRedeemDelay) {
            return 0;
        }
        return ERC4626Upgradeable.maxRedeem(_owner);
    }

    function lastDistributionTimestamp() external view returns (uint256) {
        return lastDistributionTime;
    }

    function getIntegration(address integration) external view returns (IntegrationConfig memory) {
        return integrations[integration];
    }

    /// @notice See {IERC4626-withdraw}
    function withdraw(uint256 assets, address receiver, address _owner) public override returns (uint256) {
        uint256 maxAssets = maxWithdraw(_owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(_owner, assets, maxAssets);
        }

        (uint256 shares, uint256 fee) = _previewWithdraw(assets);
        address caller = _msgSender();
        _withdraw(caller, receiver, _owner, shares, assets, fee);

        return shares;
    }

    /// @notice See {IERC4626-redeem}
    function redeem(uint256 shares, address receiver, address _owner) public override returns (uint256) {
        uint256 maxShares = maxRedeem(_owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(_owner, shares, maxShares);
        }

        (uint256 assets, uint256 fee) = _previewRedeem(shares);
        address caller = _msgSender();
        _withdraw(caller, receiver, _owner, shares, assets, fee);

        return assets;
    }

    /// @notice Withdraw assets and revert if slippage is exceeded
    function withdrawWithSlippage(uint256 assets, address receiver, address owner, uint256 maxShares)
        external
        returns (uint256)
    {
        uint256 shares = withdraw(assets, receiver, owner);
        if (shares > maxShares) {
            revert RedeemedMoreThanMaxShares(shares, maxShares);
        }
        return shares;
    }

    /// @notice Redeem shares and revert if slippage is exceeded
    function redeemWithSlippage(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        returns (uint256)
    {
        uint256 assets = redeem(shares, receiver, owner);
        if (assets < minAssets) {
            revert WithdrewLessThanMinAssets(assets, minAssets);
        }
        return assets;
    }

    function setIntegration(address integration, bool canSkipRedeemDelay, bool waiveRedeemFee) external onlyOwner {
        if (integration == address(0)) {
            revert InvalidZeroAddress();
        }
        integrations[integration] =
            IntegrationConfig({canSkipRedeemDelay: canSkipRedeemDelay, waiveRedeemFee: waiveRedeemFee});
        emit UpdatedIntegration(integration, canSkipRedeemDelay, waiveRedeemFee);
    }

    function rescueTokens(address token, address receiver, uint256 amount) public override {
        if (token == asset()) {
            uint256 rescuableBalance = IERC20(asset()).balanceOf(address(this)) - totalPendingOrderValue;
            if (amount > rescuableBalance) {
                revert ExceededRescuableBalance(amount, rescuableBalance);
            }
        }
        super.rescueTokens(token, receiver, amount);
    }

    function _callerRedeemFeePpm() internal view returns (uint256) {
        if (integrations[_msgSender()].waiveRedeemFee) {
            return 0;
        }
        return redeemFeePpm;
    }

    function _previewWithdraw(uint256 assets) internal view override returns (uint256, uint256) {
        uint256 fee = _feeOnRaw(assets, _callerRedeemFeePpm());
        uint256 shares = ERC4626Upgradeable.previewWithdraw(assets + fee);
        return (shares, fee);
    }

    function _previewRedeem(uint256 shares) internal view override returns (uint256, uint256) {
        uint256 assets = ERC4626Upgradeable.previewRedeem(shares);
        uint256 fee = _feeOnTotal(assets, _callerRedeemFeePpm());
        return (assets - fee, fee);
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
