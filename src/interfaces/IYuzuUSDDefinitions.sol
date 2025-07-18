// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IYuzuUSDDefinitions {
    event MinterUpdated(address oldMinter, address newMinter);

    error OnlyMinter();
}
