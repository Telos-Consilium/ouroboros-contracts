// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IYuzuUSDDefinitions {
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);

    error CannotRenounceOwnership();
    error OnlyMinter();
}
