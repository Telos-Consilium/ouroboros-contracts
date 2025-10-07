// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IYuzuILPDefinitions {
    error InvalidYield(uint256 provided);
    error InvalidCurrentPoolSize(uint256 provided, uint256 actual);

    event UpdatedPool(uint256 oldPoolSize, uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm);
}
