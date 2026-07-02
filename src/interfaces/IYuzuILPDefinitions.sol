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

    event UpdatedMintFee(uint256 oldFeePpm, uint256 newFeePpm);
    event UpdatedPendingManagementFee(uint256 oldRatePpm, uint256 newRatePpm);
    event RealizedManagementFee(uint256 assets, uint256 cumulative);
    event UpdatedPendingPerformanceFee(uint256 oldRatePpm, uint256 newRatePpm);
    event RealizedPerformanceFee(uint256 assets, uint256 cumulative);
}
