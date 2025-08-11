// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IYuzuDefinitions} from "./IYuzuDefinitions.sol";

interface IYuzuIssuerDefinitions is IYuzuDefinitions {
    error ExceededLiquidityBuffer(uint256 requested, uint256 buffer);

    event UpdatedMaxDepositPerBlock(uint256 oldLimit, uint256 newLimit);
    event UpdatedMaxWithdrawPerBlock(uint256 oldLimit, uint256 newLimit);
    event WithdrawnCollateral(address indexed receiver, uint256 assets);
}
