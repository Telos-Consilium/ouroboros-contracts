// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IYuzuProtoDefinitions} from "./IYuzuProtoDefinitions.sol";
import {IYuzuIssuer} from "./IYuzuIssuer.sol";
import {IYuzuOrderBook} from "./IYuzuOrderBook.sol";

interface IYuzuProto is IERC20Metadata, IAccessControl, IYuzuProtoDefinitions, IYuzuIssuer, IYuzuOrderBook {
    function rescueTokens(address token, address to, uint256 amount) external;

    function redeemFeePpm() external view returns (uint256);
    function redeemOrderFeePpm() external view returns (int256);

    function setTreasury(address newTreasury) external;
    function setRedeemFeePpm(uint256 newFeePpm) external;
    function setRedeemOrderFeePpm(int256 newFeePpm) external;
    function setMaxDepositPerBlock(uint256 newMax) external;
    function setMaxWithdrawPerBlock(uint256 newMax) external;
    function setFillWindow(uint256 newWindow) external;
}
