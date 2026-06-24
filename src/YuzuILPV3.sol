// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {YuzuILPV2} from "./YuzuILPV2.sol";
import {IYuzuILPV3Definitions} from "./interfaces/IYuzuILPDefinitions.sol";
import {YuzuMinAmounts} from "./proto/YuzuMinAmounts.sol";
import {YuzuThrottle} from "./proto/YuzuThrottle.sol";

/**
 * @title YuzuILPV3
 * @notice YuzuILP with minimum mint amounts, per-block/daily throttling, a tighter daily yield ceiling,
 * optional share-price bounds on pool updates and distributions, a mint fee, and a continuous management fee
 * @dev yzILP has no instant redeem (only redeem orders), so the redeem throttle and minWithdraw floor
 * never bind; the order path is unguarded. THROTTLE_EXEMPT_ROLE holders bypass the throttle. Fee rates are
 * under FEE_MANAGER_ROLE.
 */
contract YuzuILPV3 is YuzuILPV2, YuzuMinAmounts, YuzuThrottle, IYuzuILPV3Definitions {
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    /// @notice Maximum daily linear yield rate, in ppm (1% per day)
    uint256 internal constant MAX_DAILY_YIELD_PPM = 10_000;

    /// @notice Maximum management fee, in ppm per year (10%)
    uint256 internal constant MAX_MANAGEMENT_FEE_PPM = 100_000;

    struct YuzuILPFeesStorage {
        uint256 _mintFeePpm;
        uint256 _managementFeeRatePpm;
        uint256 _cumulativeManagementFees;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.ilpfees")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuILPFeesStorageLocation =
        0x93ad02b05e4d8e5afd5c21de55a6b2405afe608b42c8806cefbe7bbeb87f7f00;

    /// @notice Reinitializes the contract for the V3 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitializeV3() external reinitializer(3) {
        _setRoleAdmin(THROTTLE_EXEMPT_ROLE, ADMIN_ROLE);
        _setRoleAdmin(FEE_MANAGER_ROLE, ADMIN_ROLE);
        _setMintThrottle(type(uint256).max, type(uint256).max);
        _setRedeemThrottle(type(uint256).max, type(uint256).max);
    }

    /// @dev Applies the tighter V3 yield ceiling, realizes the management fee accrued since the last
    /// update against the admin-reported gross {newPoolSize}, then runs the inherited logic on the net
    function updatePool(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm)
        public
        virtual
        override
    {
        if (newDailyLinearYieldRatePpm > MAX_DAILY_YIELD_PPM) {
            revert InvalidYield(newDailyLinearYieldRatePpm);
        }
        uint256 fee = _managementFeeSinceUpdate(Math.Rounding.Ceil);
        if (fee > 0) {
            YuzuILPFeesStorage storage $ = _getYuzuILPFeesStorage();
            uint256 cumulative = $._cumulativeManagementFees + fee;
            $._cumulativeManagementFees = cumulative;
            emit RealizedManagementFee(fee, cumulative);
        }
        super.updatePool(currentPoolSize, newPoolSize > fee ? newPoolSize - fee : 0, newDailyLinearYieldRatePpm);
    }

    /// @notice Update the pool and revert if the resulting share price leaves the band
    function updatePool(
        uint256 currentPoolSize,
        uint256 newPoolSize,
        uint256 newDailyLinearYieldRatePpm,
        uint256 minSharePrice,
        uint256 maxSharePrice
    ) external virtual {
        updatePool(currentPoolSize, newPoolSize, newDailyLinearYieldRatePpm);
        _checkSharePriceWithin(totalAssets(), minSharePrice, maxSharePrice);
    }

    /// @notice Distribute and revert if the projected end-of-distribution share price leaves the band
    function distribute(uint256 assets, uint256 period, uint256 minSharePrice, uint256 maxSharePrice)
        external
        virtual
    {
        distribute(assets, period);
        _checkSharePriceWithin(totalAssets() + assets, minSharePrice, maxSharePrice);
    }

    /// @inheritdoc YuzuThrottle
    /// @dev THROTTLE_EXEMPT_ROLE keys on the owner or receiver in both the views and the
    /// state-changing paths, the standard ERC-4626 principal. Caller-keying is reserved for
    /// vaults whose integration model is caller-keyed; the proto vaults have none.
    function _isThrottleExempt(address account) internal view override returns (bool) {
        return hasRole(THROTTLE_EXEMPT_ROLE, account);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMintThrottle(uint256 newBlockLimit, uint256 newDailyLimit)
        external
        virtual
        onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setMintThrottle(newBlockLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemThrottle(uint256 newBlockLimit, uint256 newDailyLimit)
        external
        virtual
        onlyRole(LIMIT_MANAGER_ROLE)
    {
        _setRedeemThrottle(newBlockLimit, newDailyLimit);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinDeposit(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinDeposit(newMin);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMinWithdraw(uint256 newMin) external virtual onlyRole(LIMIT_MANAGER_ROLE) {
        _setMinWithdraw(newMin);
    }

    /// @notice Fee charged on the deposit/mint path, in ppm of the assets in
    function mintFeePpm() public view returns (uint256) {
        return _getYuzuILPFeesStorage()._mintFeePpm;
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setMintFee(uint256 newFeePpm) external virtual onlyRole(FEE_MANAGER_ROLE) {
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        YuzuILPFeesStorage storage $ = _getYuzuILPFeesStorage();
        uint256 oldFee = $._mintFeePpm;
        $._mintFeePpm = newFeePpm;
        emit UpdatedMintFee(oldFee, newFeePpm);
    }

    /// @notice Management fee, in ppm per year, charged as a continuous drift on poolSize
    function managementFeeRatePpm() public view returns (uint256) {
        return _getYuzuILPFeesStorage()._managementFeeRatePpm;
    }

    /// @notice Total management fees withheld to the treasury, never credited to holders
    function cumulativeManagementFees() public view returns (uint256) {
        return _getYuzuILPFeesStorage()._cumulativeManagementFees;
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setManagementFee(uint256 newRatePpm) external virtual onlyRole(FEE_MANAGER_ROLE) {
        if (newRatePpm > MAX_MANAGEMENT_FEE_PPM) {
            revert FeeTooHigh(newRatePpm, MAX_MANAGEMENT_FEE_PPM);
        }
        // The drift clock is the pool-update clock; enabling a fee before the first update would
        // accrue from epoch and zero the NAV
        if (newRatePpm > 0 && lastPoolUpdateTimestamp == 0) {
            revert PoolNeverUpdated();
        }
        YuzuILPFeesStorage storage $ = _getYuzuILPFeesStorage();
        uint256 oldRate = $._managementFeeRatePpm;
        $._managementFeeRatePpm = newRatePpm;
        emit UpdatedManagementFee(oldRate, newRatePpm);
    }

    /// @dev Re-homed from REDEEM_MANAGER_ROLE so all fee rates sit under FEE_MANAGER_ROLE
    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemFee(uint256 newFeePpm) external virtual override onlyRole(FEE_MANAGER_ROLE) {
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = redeemFeePpm;
        redeemFeePpm = newFeePpm;
        emit UpdatedRedeemFee(oldFee, newFeePpm);
    }

    // slither-disable-next-line pess-strange-setter,pess-event-setter
    function setRedeemOrderFee(uint256 newFeePpm) external virtual override onlyRole(FEE_MANAGER_ROLE) {
        if (newFeePpm > 1e6) {
            revert FeeTooHigh(newFeePpm, 1e6);
        }
        uint256 oldFee = redeemOrderFeePpm;
        redeemOrderFeePpm = newFeePpm;
        emit UpdatedRedeemOrderFee(oldFee, newFeePpm);
    }

    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        uint256 maxAssets = Math.min(super.maxDeposit(receiver), _mintThrottleRemaining(receiver));
        return maxAssets < minDeposit() ? 0 : maxAssets;
    }

    /// @dev Saturates to the supply headroom when the throttle is effectively unlimited; the threshold
    /// keeps convertToShares from overflowing (ILP share price is admin-set and unbounded).
    function maxMint(address receiver) public view virtual override returns (uint256) {
        uint256 headroom = super.maxMint(receiver);
        uint256 remaining = _mintThrottleRemaining(receiver);
        uint256 shares = remaining >= type(uint128).max ? headroom : Math.min(headroom, convertToShares(remaining));
        return previewMint(shares) < minDeposit() ? 0 : shares;
    }

    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        _checkMinDeposit(assets);
        uint256 fee = _feeOnTotal(assets, mintFeePpm());
        if (fee > 0) {
            SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), feeReceiver, fee);
        }
        uint256 netAssets = assets - fee;
        uint256 tokens = super.deposit(netAssets, receiver);
        _consumeMintThrottle(receiver, netAssets);
        return tokens;
    }

    function mint(uint256 tokens, address receiver) public virtual override returns (uint256) {
        uint256 netAssets = previewMint(tokens);
        uint256 fee = _feeOnRaw(netAssets, mintFeePpm());
        _checkMinDeposit(netAssets + fee);
        if (fee > 0) {
            SafeERC20.safeTransferFrom(IERC20(asset()), _msgSender(), feeReceiver, fee);
        }
        uint256 assets = super.mint(tokens, receiver);
        _consumeMintThrottle(receiver, assets);
        return assets + fee;
    }

    function withdraw(uint256 assets, address receiver, address _owner) public virtual override returns (uint256) {
        _checkMinWithdraw(assets);
        return super.withdraw(assets, receiver, _owner);
    }

    function redeem(uint256 tokens, address receiver, address _owner) public virtual override returns (uint256) {
        (uint256 assets,) = _previewRedeem(tokens);
        _checkMinWithdraw(assets);
        return super.redeem(tokens, receiver, _owner);
    }

    /// @dev Reverts if the share price implied by {totalAssets_} is outside the band. The price is the
    /// asset value of one whole share. Skipped while there are no shares, when no price exists.
    function _checkSharePriceWithin(uint256 totalAssets_, uint256 minSharePrice, uint256 maxSharePrice) internal view {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return;
        }
        uint256 sharePrice = Math.mulDiv(totalAssets_, 10 ** decimals(), _totalSupply);
        if (sharePrice > maxSharePrice) {
            revert SharePriceTooHigh(sharePrice, maxSharePrice);
        }
        if (sharePrice < minSharePrice) {
            revert SharePriceTooLow(sharePrice, minSharePrice);
        }
    }

    /// @dev Management fee accrued since the last pool update: a negative drift on poolSize, the mirror
    /// of the yield accrual. The fee value stays in the treasury (lower NAV), never credited to holders.
    function _managementFeeSinceUpdate(Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(poolSize * managementFeeRatePpm(), _timeSinceUpdate(), 1e6 * 365 days, rounding);
    }

    /// @dev Subtracts the accrued management fee from total assets, floored at 0. The fee rounds against
    /// the caller (opposite the totalAssets rounding) so the reported value stays conservative.
    function _totalAssets(Math.Rounding rounding) internal view override(YuzuILPV2) returns (uint256) {
        uint256 total = super._totalAssets(rounding);
        uint256 fee = _managementFeeSinceUpdate(Math.Rounding(1 - uint256(rounding)));
        return fee >= total ? 0 : total - fee;
    }

    function _getYuzuILPFeesStorage() private pure returns (YuzuILPFeesStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuILPFeesStorageLocation
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    // slither-disable-next-line unused-state
    uint256[47] private __gap;
}
