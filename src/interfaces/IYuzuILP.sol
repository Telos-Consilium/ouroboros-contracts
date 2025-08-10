// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IYuzuILPDefinitions} from "./IYuzuILPDefinitions.sol";
import {IYuzuProto} from "./proto/IYuzuProto.sol";

interface IYuzuILP is IYuzuProto, IYuzuILPDefinitions {
    function initialize(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock,
        uint256 _fillWindow
    ) external;

    function updatePool(uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm) external;

    function totalAssets() external view returns (uint256);
    function poolSize() external view returns (uint256);
    function dailyLinearYieldRatePpm() external view returns (uint256);
    function lastPoolUpdateTimestamp() external view returns (uint256);
}
