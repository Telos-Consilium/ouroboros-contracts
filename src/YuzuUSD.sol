// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./interfaces/IYuzuUSDDefinitions.sol";

/**
 * @title YuzuUSD
 * @dev ERC20 token mintable by a designated minter.
 */
contract YuzuUSD is ERC20Burnable, ERC20Permit, Ownable2Step, IYuzuUSDDefinitions {
    address public minter;

    /**
     * @dev Sets the values for {name} and {symbol}.
     */
    constructor(string memory name_, string memory symbol_, address owner)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(owner)
    {}

    /**
     * @dev Sets {minter}.
     */
    function setMinter(address newMinter) external onlyOwner {
        address oldMinter = minter;
        minter = newMinter;
        emit MinterUpdated(oldMinter, newMinter);
    }

    /**
     * @dev Mints `amount` tokens to `to`.
     *
     * Only callable by the minter.
     */
    function mint(address to, uint256 amount) external {
        if (_msgSender() != minter) revert OnlyMinter();
        _mint(to, amount);
    }
}
