// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

enum OrderStatus {
    Nil,
    Pending,
    Executed
}

struct Order {
    uint256 assets;
    uint256 shares;
    address owner;
    address receiver;
    address controller;
    uint40 dueTime;
    OrderStatus status;
}

struct IntegrationConfig {
    bool canSkipRedeemDelay;
    bool waiveRedeemFee;
}

interface IStakedYuzuUSDDefinitions {
    error InvalidZeroAddress();
    error RedeemDelayTooHigh(uint256 provided, uint256 max);
    error FeeTooHigh(uint256 provided, uint256 max);
    error UnauthorizedOrderFinalizer(address caller, address receiver, address controller);
    error OrderNotPending(uint256 orderId);
    error OrderNotDue(uint256 orderId);
    error InvalidAssetRescue(address token);
    error WithdrawNotSupported();
    error RedeemNotSupported();
    error ExceededMaxRedeemOrder(address owner, uint256 token, uint256 max);
    error WithdrewLessThanMinAssets(uint256 assets, uint256 min);
    error DistributionInProgress();
    error NoDistributionInProgress();
    error DistributionPeriodTooLow(uint256 provided, uint256 min);
    error DistributionPeriodTooHigh(uint256 provided, uint256 max);

    event InitiatedRedeem(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 orderId,
        uint256 assets,
        uint256 shares,
        uint256 fee
    );
    event FinalizedRedeem(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 orderId,
        uint256 assets,
        uint256 shares
    );
    event UpdatedRedeemDelay(uint256 oldDelay, uint256 newDelay);
    event UpdatedRedeemFee(uint256 oldFee, uint256 newFee);
    event UpdatedFeeReceiver(address oldFeeReceiver, address newFeeReceiver);
    event Distributed(uint256 assets, uint256 period);
    event TerminatedDistribution(uint256 undistributed, address receiver);
}

interface IStakedYuzuUSDV2Definitions {
    error ExceededRescuableBalance(uint256 rescue, uint256 max);

    event UpdatedIntegration(address indexed integration, bool canSkipRedeemDelay, bool waiveRedeemFee);
}
