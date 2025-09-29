// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuIssuer} from "./IYuzuIssuer.sol";
import {IYuzuOrderBook} from "./IYuzuOrderBook.sol";

interface IYuzuProto is IYuzuIssuer, IYuzuOrderBook {
    function createRedeemOrderWithMaxFee(uint256 tokens, address receiver, address owner, uint256 maxFeePpm)
        external
        returns (uint256);

    function rescueTokens(address token, address to, uint256 amount) external;

    function feeReceiver() external view returns (address);
    function minRedeemOrder() external view returns (uint256);
    function redeemFeePpm() external view returns (uint256);
    function redeemOrderFeePpm() external view returns (uint256);

    function setTreasury(address newTreasury) external;
    function setSupplyCap(uint256 newCap) external;
    function setFillWindow(uint256 newWindow) external;
    function setMinRedeemOrder(uint256 newMin) external;
    function setRedeemFee(uint256 newFeePpm) external;
    function setRedeemOrderFee(int256 newFeePpm) external;
    function setIsMintRestricted(bool restricted) external;
    function setIsRedeemRestricted(bool restricted) external;

    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}
