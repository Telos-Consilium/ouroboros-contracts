// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

interface IYuzuUSD is IERC20, IERC20Metadata, IERC20Permit {
    // Burn functions
    function burn(uint256 value) external;
    function burnFrom(address account, uint256 value) external;

    // Minter functions
    function mint(address account, uint256 amount) external;

    // View functions
    function minter() external view returns (address);
}
