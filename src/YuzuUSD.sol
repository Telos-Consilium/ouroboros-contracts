// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./interfaces/IYuzuUSDDefinitions.sol";

/**
 * @title YuzuUSD
 */
contract YuzuUSD is ERC20Burnable, ERC20Permit, Ownable2Step, IYuzuUSDDefinitions {
    address public minter;

    constructor(
        address owner
    ) ERC20("Yuzu USD", "yzUSD") ERC20Permit("Yuzu USD") Ownable(owner) {}

    function setMinter(address newMinter) external onlyOwner {
        address oldMinter = minter;
        minter = newMinter;
        emit MinterUpdated(oldMinter, newMinter);
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert OnlyMinter();
        _mint(to, amount);
    }
}
