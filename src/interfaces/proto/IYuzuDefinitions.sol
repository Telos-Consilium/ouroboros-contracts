// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IYuzuDefinitions {
    error ExceededMaxDeposit(address receiver, uint256 assets, uint256 max);
    error ExceededMaxMint(address receiver, uint256 token, uint256 max);
    error ExceededMaxWithdraw(address owner, uint256 assets, uint256 max);
    error ExceededMaxRedeem(address owner, uint256 token, uint256 max);

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 token);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 token
    );
}
