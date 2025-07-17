// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";

interface IYuzuUSDMinterDefinitions {
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event MaxMintPerBlockUpdated(uint256 oldMax, uint256 newMax);
    event MaxRedeemPerBlockUpdated(uint256 oldMax, uint256 newMax);

    error InvalidZeroAddress();
    error MaxMintPerBlockExceeded();
    error MaxRedeemPerBlockExceeded();
}
