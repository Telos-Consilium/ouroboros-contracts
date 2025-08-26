// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IYuzuDefinitions {
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 tokens);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 tokens
    );
}
