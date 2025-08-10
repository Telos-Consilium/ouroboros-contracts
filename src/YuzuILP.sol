// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Order} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {IYuzuILPDefinitions} from "./interfaces/IYuzuILPDefinitions.sol";

import {YuzuProto} from "./proto/YuzuProto.sol";

contract YuzuILP is YuzuProto, IYuzuILPDefinitions {
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    uint256 public poolSize;
    uint256 public dailyLinearYieldRatePpm;
    uint256 public lastPoolUpdateTimestamp;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the YuzuUSDMinter contract with the specified parameters.
     * @param __asset The address of the collateral token contract.
     * @param __name The name of the YuzuUSD token.
     * @param __symbol The symbol of the YuzuUSD token.
     * @param _admin The admin of the contract.
     * @param __treasury The address of the treasury where collateral is sent.
     * @param _maxDepositPerBlock Maximum YuzuUSD that can be minted per block.
     * @param _maxWithdrawPerBlock Maximum YuzuUSD that can be redeemed per block.
     * @param _fillWindow The window in seconds during which redeem orders can be filled.
     *
     * Fees are set to 0 by default.
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
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
    }

    /**
     * @notice Updates the pool parameters including size, withdrawal allowance, and yield rate.
     *
     * Sets poolSize to newPoolSize, and {dailyLinearYieldRatePpm} to {newDailyLinearYieldRatePpm}.
     * Emits a `UpdatedPool` event with the new pool parameters.
     * Reverts if called by anyone but a pool manager.
     * Reverts if {newDailyLinearYieldRatePpm} exceeds 1e6 (100% daily yield).
     */
    function updatePool(uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) external onlyRole(POOL_MANAGER_ROLE) {
        if (newDailyLinearYieldRatePpm > 1e6) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }

        poolSize = newPoolSize;
        dailyLinearYieldRatePpm = newDailyLinearYieldRatePpm;
        lastPoolUpdateTimestamp = block.timestamp;

        emit UpdatedPool(newPoolSize, newDailyLinearYieldRatePpm);
    }

    /**
     * @notice Returns the total assets managed by the vault.
     *
     * Includes the pool size and the yield accrued since the last update.
     */
    function totalAssets() public view returns (uint256) {
        uint256 yieldSinceUpdate = _yieldSinceUpdate(Math.Rounding.Floor);
        return poolSize + yieldSinceUpdate;
    }

    /**
     * @notice Returns the number of shares minted for {assets}.
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToSharesMinted(assets);
    }

    /**
     * @notice Returns the amount of assets required to mint {shares}.
     */
    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssetsDeposited(shares);
    }

    /**
     * @notice Returns the number of shares redeemed for {assets}.
     */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redemptionFeePpm);
        uint256 shares = _convertToSharesRedeemed(assets + fee);
        return shares;
    }

    /**
     * @notice Returns the amount of assets withdrawn for {shares}.
     */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 assets = _convertToAssetsWithdrawn(shares);
        uint256 fee = _feeOnTotal(assets, redemptionFeePpm);
        return assets - fee;
    }

    function previewRedeemOrder(uint256 shares) public view override returns (uint256) {
        if (totalSupply() == 0) return 0;
        uint256 assets = Math.mulDiv(poolSize, shares, totalSupply(), Math.Rounding.Floor);

        if (redemptionOrderFeePpm >= 0) {
            // Positive fee - reduce assets returned
            uint256 fee = _feeOnTotal(assets, uint256(redemptionOrderFeePpm));
            return assets - fee;
        } else {
            // Negative fee (incentive) - increase assets returned
            uint256 incentive = _feeOnRaw(assets, uint256(-redemptionOrderFeePpm));
            return assets + incentive;
        }
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        poolSize += _discountYield(assets, Math.Rounding.Floor);
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        poolSize -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _fillRedeemOrder(address caller, Order storage order) internal override {
        poolSize -= order.assets;
        super._fillRedeemOrder(caller, order);
    }

    /**
     * @dev Internal function to convert {assets} to shares minted.
     * If the pool size is zero, assets are converted to shares 1:1 adjusted for decimals.
     */
    function _convertToSharesMinted(uint256 assets) internal view returns (uint256) {
        if (poolSize == 0) return assets * 10 ** _decimalsOffset();
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding.Ceil);
        return Math.mulDiv(totalSupply(), assets, _totalAssets, Math.Rounding.Floor);
    }

    /**
     * @dev Internal function to convert {assets} to shares redeemed.
     *
     * If the pool size is zero, the total supply must be redeemed.
     */
    function _convertToSharesRedeemed(uint256 assets) internal view returns (uint256) {
        if (poolSize == 0) return totalSupply();
        return Math.mulDiv(totalSupply(), assets, poolSize, Math.Rounding.Ceil);
    }

    /**
     * @dev Internal function to convert {shares} to assets deposited.
     *
     * If the pool size or the total supply is zero, shares are converted to assets 1:1 adjusted for decimals.
     * If the pool size is zero but the total supply is not, shares are minted at a loss for the depositor.
     * If the total supply is zero but the pool size is not, shares are minted at a profit for the depositor.
     */
    function _convertToAssetsDeposited(uint256 shares) internal view returns (uint256) {
        if (poolSize == 0 || totalSupply() == 0) return Math.ceilDiv(shares, 10 ** _decimalsOffset());
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding.Ceil);
        return Math.mulDiv(_totalAssets, shares, totalSupply(), Math.Rounding.Ceil);
    }

    /**
     * @dev Internal function to convert shares to assets withdrawn.
     *
     * If the total supply is zero, no assets can be withdrawn.
     */
    function _convertToAssetsWithdrawn(uint256 shares) internal view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return Math.mulDiv(poolSize, shares, totalSupply(), Math.Rounding.Floor);
    }

    /**
     * @dev Returns the yield accrued since the last pool update.
     *
     * Uses the daily linear yield rate and the time since the last update.
     * Returns the yield amount, rounded according to the specified rounding mode.
     */
    function _yieldSinceUpdate(Math.Rounding rounding) internal view returns (uint256) {
        uint256 elapsedTime = _timeSinceUpdate();
        if (poolSize == 0 || dailyLinearYieldRatePpm == 0 || elapsedTime == 0) {
            return 0;
        }
        uint256 yieldSinceUpdate = Math.mulDiv(poolSize * dailyLinearYieldRatePpm, elapsedTime, 1e6 days, rounding);
        return yieldSinceUpdate;
    }

    /**
     * @dev Returns the size of a deposit such that, if deposited at the time of the last pool update,
     * would have accrued yield making it worth {assets} now.
     *
     * Uses the daily linear yield rate and the time since the last update.
     * Returns the size of the deposit, rounded according to the specified rounding mode.
     */
    function _discountYield(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        uint256 elapsedTime = _timeSinceUpdate();
        if (poolSize == 0 || dailyLinearYieldRatePpm == 0 || elapsedTime == 0) {
            return assets;
        }
        return Math.mulDiv(assets, 1e6 days, 1e6 days + dailyLinearYieldRatePpm * elapsedTime, rounding);
    }

    /**
     * @dev Returns the number of seconds since the last pool update.
     */
    function _timeSinceUpdate() internal view returns (uint256) {
        return block.timestamp - lastPoolUpdateTimestamp;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[47] private __gap;
}
