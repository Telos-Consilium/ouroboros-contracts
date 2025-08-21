// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {YuzuProto} from "./proto/YuzuProto.sol";

/**
 * @title YuzuUSD
 * @notice YuzuUSD token implementation with 1:1 peg to underlying asset
 */
contract YuzuUSD is YuzuProto {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the YuzuUSD contract
     * @param __asset The address of the collateral token contract
     * @param __name The name of the YuzuUSD token
     * @param __symbol The symbol of the YuzuUSD token
     * @param _admin The admin of the contract
     * @param __treasury The address of the treasury where collateral is sent
     * @param _maxDepositPerBlock Maximum collateral that can be deposited per block
     * @param _maxWithdrawPerBlock Maximum collateral that can be withdrawn per block
     * @param _fillWindow The fill window in seconds after which redeem order become cancellable
     */
    function initialize(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock,
        uint256 _fillWindow
    ) external initializer {
        __YuzuProto_init(
            __asset, __name, __symbol, _admin, __treasury, _maxDepositPerBlock, _maxWithdrawPerBlock, _fillWindow
        );
    }

    /// @notice See {IERC4626-totalAssets}
    function totalAssets() public view override returns (uint256) {
        return _convertToAssets(totalSupply(), Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-convertToShares}
    function convertToShares(uint256 assets) public view virtual override returns (uint256 shares) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-convertToAssets}
    function convertToAssets(uint256 shares) public view virtual override returns (uint256 assets) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 remainingAllowance = _getRemainingWithdrawAllowance();
        uint256 liquidityBuffer = _getLiquidityBufferSize();
        uint256 ownerTokens = __yuzu_balanceOf(owner);
        uint256 _maxWithdraw = Math.min(remainingAllowance, liquidityBuffer);
        return Math.min(previewRedeem(ownerTokens), _maxWithdraw);
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 remainingAllowance = _getRemainingWithdrawAllowance();
        uint256 liquidityBuffer = _getLiquidityBufferSize();
        uint256 ownerTokens = __yuzu_balanceOf(owner);
        uint256 _maxWithdraw = Math.min(remainingAllowance, liquidityBuffer);
        return Math.min(_convertToShares(_maxWithdraw, Math.Rounding.Floor), ownerTokens);
    }

    /// @notice See {IERC4626-previewDeposit}
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-previewMint}
    function previewMint(uint256 tokens) public view override returns (uint256) {
        return _convertToAssets(tokens, Math.Rounding.Ceil);
    }

    /// @notice See {IERC4626-previewWithdraw}
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        uint256 tokens = previewDeposit(assets + fee);
        return tokens;
    }

    /// @notice See {IERC4626-previewRedeem}
    function previewRedeem(uint256 tokens) public view override returns (uint256) {
        uint256 assets = _convertToAssets(tokens, Math.Rounding.Floor);
        uint256 fee = _feeOnTotal(assets, redeemFeePpm);
        return assets - fee;
    }

    /// @notice Preview the amount of assets to receive when redeeming `tokens` through an order after fees
    function previewRedeemOrder(uint256 tokens) public view override returns (uint256) {
        uint256 assets = _convertToAssets(tokens, Math.Rounding.Floor);

        if (redeemOrderFeePpm >= 0) {
            /// @dev Positive fee - reduce assets returned
            uint256 fee = _feeOnTotal(assets, SafeCast.toUint256(redeemOrderFeePpm));
            return assets - fee;
        } else {
            /// @dev Negative fee (incentive) - increase assets returned
            uint256 incentive = _feeOnRaw(assets, SafeCast.toUint256(-redeemOrderFeePpm));
            return assets + incentive;
        }
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return assets * 10 ** _decimalsOffset();
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        if (rounding == Math.Rounding.Floor) {
            return shares / 10 ** _decimalsOffset();
        } else {
            return Math.ceilDiv(shares, 10 ** _decimalsOffset());
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
