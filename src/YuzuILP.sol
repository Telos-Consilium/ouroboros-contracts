// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Order} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
import {IYuzuILPDefinitions} from "./interfaces/IYuzuILPDefinitions.sol";

import {YuzuProto} from "./proto/YuzuProto.sol";

/**
 * @title YuzuILP
 * @notice Insurance Liquidity Pool that accrues yield
 */
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
     * @notice Initializes the YuzuILP contract
     * @param __asset The address of the collateral token contract
     * @param __name The name of the YuzuILP token
     * @param __symbol The symbol of the YuzuILP token
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
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
    }

    /// @notice Updates the pool parameters including size and yield rate
    function updatePool(uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) external onlyRole(POOL_MANAGER_ROLE) {
        if (newDailyLinearYieldRatePpm > 1e6) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }

        poolSize = newPoolSize;
        dailyLinearYieldRatePpm = newDailyLinearYieldRatePpm;
        lastPoolUpdateTimestamp = block.timestamp;

        emit UpdatedPool(newPoolSize, newDailyLinearYieldRatePpm);
    }

    /// @notice See {IERC4626-totalAssets}
    function totalAssets() public view override returns (uint256) {
        uint256 yieldSinceUpdate = _yieldSinceUpdate(Math.Rounding.Floor);
        return poolSize + yieldSinceUpdate;
    }

    /// @notice See {IERC4626-convertToShares}
    function convertToShares(uint256 assets) public view virtual override returns (uint256 shares) {
        return _convertToSharesMinted(assets, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-convertToAssets}
    function convertToAssets(uint256 shares) public view virtual override returns (uint256 assets) {
        return _convertToAssetsDeposited(shares, Math.Rounding.Floor);
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
        return Math.min(_convertToSharesRedeemed(_maxWithdraw, Math.Rounding.Floor), ownerTokens);
    }

    /// @notice See {IERC4626-previewDeposit}
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToSharesMinted(assets, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-previewMint}
    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssetsDeposited(shares, Math.Rounding.Ceil);
    }

    /// @notice See {IERC4626-previewWithdraw}
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, redeemFeePpm);
        uint256 shares = _convertToSharesRedeemed(assets + fee, Math.Rounding.Ceil);
        return shares;
    }

    /// @notice See {IERC4626-previewRedeem}
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 assets = _convertToAssetsWithdrawn(shares, Math.Rounding.Floor);
        uint256 fee = _feeOnTotal(assets, redeemFeePpm);
        return assets - fee;
    }

    /// @notice Preview the amount of assets to receive when redeeming `shares` through an order after fees
    function previewRedeemOrder(uint256 shares) public view override returns (uint256) {
        uint256 assets = _convertToAssetsWithdrawn(shares, Math.Rounding.Floor);

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

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        poolSize += _discountYield(assets, Math.Rounding.Floor);
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets > poolSize) {
            revert InsufficientPoolSize(assets, poolSize);
        }
        poolSize -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _fillRedeemOrder(address caller, Order storage order) internal override {
        if (order.assets > poolSize) {
            revert InsufficientPoolSize(order.assets, poolSize);
        }
        poolSize -= order.assets;
        super._fillRedeemOrder(caller, order);
    }

    // function _convertToSharesMinted(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
    //     uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding(1 - uint256(rounding)));
    //     return Math.mulDiv(assets, totalSupply() + 10 ** _decimalsOffset(), _totalAssets + 1, rounding);
    // }

    // function _convertToSharesRedeemed(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
    //     return Math.mulDiv(assets, totalSupply() + 10 ** _decimalsOffset(), poolSize + 1, rounding);
    // }

    // function _convertToAssetsDeposited(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
    //     uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding(1 - uint256(rounding)));
    //     return Math.mulDiv(shares, _totalAssets + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    // }

    // function _convertToAssetsWithdrawn(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
    //     return Math.mulDiv(shares, poolSize + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    // }

    function _convertToSharesMinted(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        if (poolSize == 0) return assets * 10 ** _decimalsOffset();
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding(1 - uint256(rounding)));
        return Math.mulDiv(totalSupply(), assets, _totalAssets, rounding);
    }

    function _convertToSharesRedeemed(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        if (poolSize == 0) return totalSupply();
        return Math.mulDiv(totalSupply(), assets, poolSize, rounding);
    }

    function _convertToAssetsDeposited(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        if (totalSupply() == 0) return Math.ceilDiv(shares, 10 ** _decimalsOffset());
        uint256 _totalAssets = poolSize + _yieldSinceUpdate(Math.Rounding(1 - uint256(rounding)));
        return Math.mulDiv(_totalAssets, shares, totalSupply(), rounding);
    }

    function _convertToAssetsWithdrawn(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        if (totalSupply() == 0) return 0;
        return Math.mulDiv(poolSize, shares, totalSupply(), rounding);
    }

    /// @dev Returns the yield accrued since the last pool update.
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
     */
    function _discountYield(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        uint256 elapsedTime = _timeSinceUpdate();
        if (poolSize == 0 || dailyLinearYieldRatePpm == 0 || elapsedTime == 0) {
            return assets;
        }
        return Math.mulDiv(assets, 1e6 days, 1e6 days + dailyLinearYieldRatePpm * elapsedTime, rounding);
    }

    function _timeSinceUpdate() internal view returns (uint256) {
        return block.timestamp - lastPoolUpdateTimestamp;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
