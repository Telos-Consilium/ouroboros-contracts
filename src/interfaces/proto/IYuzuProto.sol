// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuIssuer} from "./IYuzuIssuer.sol";
import {IYuzuOrderBook} from "./IYuzuOrderBook.sol";

interface IYuzuProto is IYuzuIssuer, IYuzuOrderBook {
    function rescueTokens(address token, address to, uint256 amount) external;

    function redeemFeePpm() external view returns (uint256);
    function redeemOrderFeePpm() external view returns (int256);

    function setTreasury(address newTreasury) external;
    function setRedeemFee(uint256 newFeePpm) external;
    function setRedeemOrderFee(int256 newFeePpm) external;
    function setFillWindow(uint256 newWindow) external;
    function setSupplyCap(uint256 newCap) external;
}
