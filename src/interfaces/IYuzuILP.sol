// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuProto, IYuzuProtoV2} from "./proto/IYuzuProto.sol";

interface IYuzuILP is IYuzuProto {
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
    ) external;

    function updatePool(uint256 currentPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) external;

    function poolSize() external view returns (uint256);
    function dailyLinearYieldRatePpm() external view returns (uint256);
    function lastPoolUpdateTimestamp() external view returns (uint256);
}

interface IYuzuILPV2 is IYuzuILP, IYuzuProtoV2 {
    function reinitialize() external;

    function startPoolUpdate() external;
    function endPoolUpdate() external;
    function isUpdatingPool() external view returns (bool);

    function lastDistributedAmount() external view returns (uint256);
    function lastDistributionPeriod() external view returns (uint256);
    function lastDistributionTimestamp() external view returns (uint256);

    function distribute(uint256 assets, uint256 period) external;
    function terminateDistribution() external;
    function distributedSinceUpdate() external view returns (uint256);
    function netDistributedSinceUpdate() external view returns (uint256);
}
