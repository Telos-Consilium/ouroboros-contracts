// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    /// @notice Preview the amount of shares to receive when depositing `assets`
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return assets * 10 ** _decimalsOffset();
    }

    /// @notice Preview the amount of assets needed to mint `shares`
    function previewMint(uint256 tokens) public view override returns (uint256) {
        return Math.ceilDiv(tokens, 10 ** _decimalsOffset());
    }

    /// @notice Preview the amount of shares needed to withdraw `assets` including fees
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        uint256 tokens = previewDeposit(assets + fee);
        return tokens;
    }

    /// @notice Preview the amount of assets to receive when redeeming `shares` after fees
    function previewRedeem(uint256 tokens) public view override returns (uint256) {
        uint256 assets = previewMint(tokens);
        uint256 fee = _feeOnTotal(assets, redeemFeePpm);
        return assets - fee;
    }

    /// @notice Preview the amount of assets to receive when redeeming `shares` after fees
    function previewRedeemOrder(uint256 tokens) public view override returns (uint256) {
        uint256 assets = previewMint(tokens);

        if (redeemOrderFeePpm >= 0) {
            // Positive fee - reduce assets returned
            uint256 fee = _feeOnTotal(assets, uint256(redeemOrderFeePpm));
            return assets - fee;
        } else {
            // Negative fee (incentive) - increase assets returned
            uint256 incentive = _feeOnRaw(assets, uint256(-redeemOrderFeePpm));
            return assets + incentive;
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
