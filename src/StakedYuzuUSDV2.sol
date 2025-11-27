// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {StakedYuzuUSD} from "./StakedYuzuUSD.sol";
import {IntegrationConfig, IStakedYuzuUSDV2Definitions} from "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSDV2
 * @notice Upgraded version with integration whitelist, fee waivers, and instant redeem/withdraw paths.
 */
contract StakedYuzuUSDV2 is StakedYuzuUSD, IStakedYuzuUSDV2Definitions {
    mapping(address => IntegrationConfig) internal integrations;

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address _owner) public view override returns (uint256) {
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

    /// @notice See {IERC4626-previewWithdraw}
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        (uint256 shares,) = _previewWithdraw(assets);
        return shares;
    }

    /// @notice See {IERC4626-previewRedeem}
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        (uint256 assets,) = _previewRedeem(shares);
        return assets;
    }

    function getIntegration(address integration) external view returns (IntegrationConfig memory) {
        return integrations[integration];
    }

    /**
     * @notice Instant withdraw for whitelisted integrations; regular users should use initiateRedeem().
     */
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }

        (uint256 shares, uint256 fee) = _previewWithdraw(assets);
        address caller = _msgSender();
        _withdraw(caller, receiver, owner, shares, assets, fee);

        return shares;
    }

    /**
     * @notice Instant redeem for whitelisted integrations; regular users should use initiateRedeem().
     */
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }

        (uint256 assets, uint256 fee) = _previewRedeem(shares);
        address caller = _msgSender();
        _withdraw(caller, receiver, owner, shares, assets, fee);

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

    function _withdraw(address caller, address receiver, address owner, uint256 shares, uint256 assets, uint256 fee)
        internal
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        if (fee > 0) {
            SafeERC20.safeTransfer(IERC20(asset()), feeReceiver, fee);
        }

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    uint256[49] private __gap;
}
