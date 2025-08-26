// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IYuzuILPDefinitions {
    error InvalidYield(uint256 provided);
    error InvalidPoolSize(uint256 provided);
    error InsufficientPoolSize(uint256 required, uint256 available);

    event UpdatedPool(uint256 newPoolSize, uint256 newDailyLinearYieldRatePpm);
}
