// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IYuzuDefinitions} from "./IYuzuDefinitions.sol";

interface IYuzuIssuerDefinitions is IYuzuDefinitions {
    error ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ExceededMaxMint(address receiver, uint256 token, uint256 max);
    error ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error ExceededMaxRedeem(address owner, uint256 token, uint256 max);
    error ExceededLiquidityBuffer(uint256 requested, uint256 buffer);

    event UpdatedSupplyCap(uint256 oldCap, uint256 newCap);
    event WithdrawnCollateral(address indexed receiver, uint256 assets);
}
