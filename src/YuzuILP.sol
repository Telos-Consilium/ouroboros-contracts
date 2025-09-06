// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Order, OrderStatus} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";
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
     * @param _supplyCap The maximum supply of YuzuILP tokens
     * @param _fillWindow The fill window in seconds after which redeem order become cancellable
     */
    function initialize(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        address _feeReceiver,
        uint256 _supplyCap,
        uint256 _fillWindow,
        uint256 _minRedeemOrder
    ) external initializer {
        __YuzuProto_init(
            __asset, __name, __symbol, _admin, __treasury, _feeReceiver, _supplyCap, _fillWindow, _minRedeemOrder
        );
        _setRoleAdmin(POOL_MANAGER_ROLE, ADMIN_ROLE);
    }

    /// @notice Updates the pool parameters including size and yield rate
    function updatePool(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm)
        external
        whenPaused
        onlyRole(POOL_MANAGER_ROLE)
    {
        if (currentPoolSize != poolSize) {
            revert InvalidCurrentPoolSize(currentPoolSize, poolSize);
        }
        if (newDailyLinearYieldRatePpm > 1e6) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }

        poolSize = newPoolSize;
        dailyLinearYieldRatePpm = newDailyLinearYieldRatePpm;
        lastPoolUpdateTimestamp = block.timestamp;

        emit UpdatedPool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
    }

    /// @notice See {IERC4626-totalAssets}
    function totalAssets() public view override returns (uint256) {
        return _totalAssets(Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-maxDeposit}
    function maxDeposit(address receiver) public view override returns (uint256) {
        uint256 _maxMint = maxMint(receiver);
        uint256 _totalSupply = totalSupply();

        /// @dev _convertToAssets(_maxMint, Math.Rounding.Floor) with an overflow check
        if (_totalSupply == 0) {
            return Math.ceilDiv(_maxMint, 10 ** _decimalsOffset());
        }
        uint256 totalAssets_ = _totalAssets(Math.Rounding.Floor);
        // slither-disable-next-line unused-return
        (uint256 high,) = Math.mul512(totalAssets_, _maxMint);
        if (high >= _totalSupply) {
            return type(uint256).max;
        }

        return Math.mulDiv(totalAssets_, _maxMint, _totalSupply, Math.Rounding.Floor);
    }

    /// @notice See {IERC4626-maxWithdraw}
    function maxWithdraw(address) public view override returns (uint256) {
        return 0;
    }

    /// @notice See {IERC4626-maxRedeem}
    function maxRedeem(address) public view override returns (uint256) {
        return 0;
    }

    function _totalAssets(Math.Rounding rounding) internal view returns (uint256) {
        uint256 yieldSinceUpdate = _yieldSinceUpdate(rounding);
        return poolSize + yieldSinceUpdate;
    }

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (poolSize == 0) {
            return assets * 10 ** _decimalsOffset();
        }
        uint256 totalAsset_ = _totalAssets(Math.Rounding(1 - uint256(rounding)));
        return Math.mulDiv(totalSupply(), assets, totalAsset_, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (totalSupply() == 0) {
            return Math.ceilDiv(shares, 10 ** _decimalsOffset());
        }
        uint256 totalAsset_ = _totalAssets(rounding);
        return Math.mulDiv(totalAsset_, shares, totalSupply(), rounding);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        poolSize += _discountYield(assets, Math.Rounding.Floor);
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares, uint256 fee)
        internal
        override
    {
        revert();
    }

    function _fillRedeemOrder(address caller, Order storage order, uint256 assets, uint256 fee)
        internal
        virtual
        override
    {
        super._fillRedeemOrder(caller, order, assets, fee);
        poolSize -= _discountYield(assets + fee, Math.Rounding.Ceil);
    }

    /// @dev Returns the yield accrued since the last pool update.
    function _yieldSinceUpdate(Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(poolSize * dailyLinearYieldRatePpm, _timeSinceUpdate(), 1e6 days, rounding);
    }

    /**
     * @dev Returns the size of a deposit such that, if deposited at the time of the last pool update,
     * would have accrued yield making it worth {assets} now.
     */
    function _discountYield(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(assets, 1e6 days, 1e6 days + dailyLinearYieldRatePpm * _timeSinceUpdate(), rounding);
    }

    function _timeSinceUpdate() internal view returns (uint256) {
        return block.timestamp - lastPoolUpdateTimestamp;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[50] private __gap;
}
