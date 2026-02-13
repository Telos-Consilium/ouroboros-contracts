// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuProto, IYuzuProtoV2} from "./proto/IYuzuProto.sol";

interface IYuzuUSD is IYuzuProto {
    function initialize(
        address __asset,
        string memory __name,
        string memory __symbol,
        address _admin,
        address __treasury,
        address _feeReceiver,
        uint256 _supplyCap,
        uint256 _fillWindow,
        uint256 _minRedeemOrder
    ) external;
}

interface IYuzuUSDV2 is IYuzuUSD, IYuzuProtoV2 {
    function reinitialize() external;
}
