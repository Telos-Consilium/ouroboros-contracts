// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IYuzuILPDefinitions {
    error InvalidYield(uint256 provided);
    error InvalidCurrentPoolSize(uint256 provided, uint256 actual);

    event UpdatedPool(uint256 oldPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm);
}

interface IYuzuILPV2Definitions {
    error DistributionInProgress();
    error NoDistributionInProgress();
    error NoPoolUpdateInProgress();
    error DistributionPeriodTooLow(uint256 provided, uint256 min);
    error DistributionPeriodTooHigh(uint256 provided, uint256 max);

    event Distributed(uint256 assets, uint256 period);
    event TerminatedDistribution(uint256 undistributed);
    event UpdatedMinDistributionPeriod(uint256 oldPeriod, uint256 newPeriod);
}

interface IYuzuILPV3Definitions {
    /// @notice Arguments matching {YuzuILP-initialize}
    struct InitParams {
        address asset;
        string name;
        string symbol;
        address admin;
        address treasury;
        address feeReceiver;
        uint256 supplyCap;
        uint256 fillWindow;
        uint256 minRedeemOrder;
    }

    /// @notice V3-only configuration applied at fresh-deploy init
    struct ConfigParams {
        bool isMintRestricted;
        bool isRedeemRestricted;
        uint256 mintFeePpm;
        uint256 redeemOrderFeePpm;
        uint256 pendingManagementFeeRatePpm;
        uint256 pendingPerformanceFeeRatePpm;
    }

    error SharePriceTooHigh(uint256 sharePrice, uint256 max);
    error SharePriceTooLow(uint256 sharePrice, uint256 min);
    error ZeroTotalAssets();
    error AlreadyInitialized();
    error NotMigrating();
    error PoolFeeEroded();
    error InitializationDisabled();
    error DistributionAmountTooHigh(uint256 provided, uint256 max);

    event UpdatedMintFee(uint256 oldFee, uint256 newFee);
    event UpdatedPendingManagementFee(uint256 oldRatePpm, uint256 newRatePpm);
    event RealizedManagementFee(uint256 assets, uint256 cumulative);
    /// @dev The reported pool could not cover the accrued management fee; only the realized
    /// portion was booked and the shortfall is not carried forward.
    event ManagementFeeShortfall(uint256 accrued, uint256 realized, uint256 netPool);
    event UpdatedPendingPerformanceFee(uint256 oldRatePpm, uint256 newRatePpm);
    event RealizedPerformanceFee(uint256 assets, uint256 cumulative);
    event UpdatedMaxDistributionPpm(uint256 oldMaxPpm, uint256 newMaxPpm);
}
