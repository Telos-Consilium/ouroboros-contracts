// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./interfaces/IYuzuUSDDefinitions.sol";

/**
 * @title YuzuUSD
 * @dev ERC-20 token mintable by a designated minter.
 */
contract YuzuUSD is ERC20Burnable, ERC20Permit, Ownable2Step, IYuzuUSDDefinitions {
    address public minter;

    /**
     * @notice Initializes the YuzuUSD contract with a name, symbol, and owner.
     * @param name_ The name of the staked token, e.g. "Yuzu USD"
     * @param symbol_ The symbol of the staked token, e.g. "yzUSD"
     * @param owner The owner of the contract
     */
    constructor(string memory name_, string memory symbol_, address owner)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(owner)
    {}

    /**
     * @dev Sets the minter to {newMinter}.
     *
     * Emits a `MinterUpdated` event with the old and new minter addresses.
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
