// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IYuzuILPDefinitions {
    error InvalidYield(uint256 provided);
    error InvalidPoolSize(uint256 provided);

    event UpdatedPool(uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm);
}
