// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

interface IYuzuUSDMinter is IAccessControlDefaultAdminRules {
    function setTreasury(address newTreasury) external;
    function setMaxMintPerBlock(uint256 newMaxMintPerBlock) external;
    function setMaxRedeemPerBlock(uint256 newMaxRedeemPerBlock) external;
    function mint(address to, uint256 amount) external;
    function redeem(address to, uint256 amount) external;
}
