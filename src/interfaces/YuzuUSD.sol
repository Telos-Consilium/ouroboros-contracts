// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IYuzuProto} from "./proto/IYuzuProto.sol";

interface IYuzuUSD is IYuzuProto {
    function initialize(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        uint256 _maxDepositPerBlock,
        uint256 _maxWithdrawPerBlock,
        uint256 _fillWindow
    ) external;
}
