// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

// Base Yuzu interface for shared primitives across issuer/orderbook
interface IYuzu {
    function asset() external view returns (address);
}
