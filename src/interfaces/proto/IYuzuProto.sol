// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IYuzuIssuer} from "./IYuzuIssuer.sol";
import {IYuzuOrderBook} from "./IYuzuOrderBook.sol";

interface IYuzuProto is IYuzuIssuer, IYuzuOrderBook {
    function totalAssets() external view returns (uint256);

    function rescueTokens(address token, address to, uint256 amount) external;

    function redeemFeePpm() external view returns (uint256);
    function redeemOrderFeePpm() external view returns (int256);

    function setTreasury(address newTreasury) external;
    function setRedeemFee(uint256 newFeePpm) external;
    function setRedeemOrderFee(int256 newFeePpm) external;
    function setMaxDepositPerBlock(uint256 newMax) external;
    function setMaxWithdrawPerBlock(uint256 newMax) external;
    function setFillWindow(uint256 newWindow) external;
}
