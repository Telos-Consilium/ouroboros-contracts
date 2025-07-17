// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import "./IYuzuUSD.sol";

interface IYuzuUSDMinter is IAccessControlDefaultAdminRules {
    function setTreasury(address newTreasury) external;
    function setMaxMintPerBlock(uint256 newMaxMintPerBlock) external;
    function setMaxRedeemPerBlock(uint256 newMaxRedeemPerBlock) external;
    function mint(address to, uint256 amount) external;
    function redeem(address to, uint256 amount) external;
    function yzusd() external view returns (IYuzuUSD);
    function collateralToken() external view returns (address);
    function treasury() external view returns (address);
    function mintedPerBlock(
        uint256 blockNumber
    ) external view returns (uint256);
    function redeemedPerBlock(
        uint256 blockNumber
    ) external view returns (uint256);
    function maxMintPerBlock() external view returns (uint256);
    function maxRedeemPerBlock() external view returns (uint256);
}
