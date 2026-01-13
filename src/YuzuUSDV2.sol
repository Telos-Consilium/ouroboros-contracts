// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {YuzuOrderBook} from "./proto/YuzuOrderBook.sol";
import {YuzuProtoV2} from "./proto/YuzuProtoV2.sol";
import {YuzuUSD} from "./YuzuUSD.sol";

/**
 * @title YuzuUSDV2
 * @notice YuzuUSD with forced cancellations
 */
contract YuzuUSDV2 is YuzuUSD, YuzuProtoV2 {
    /// @notice Reinitializes the contract for V2 upgrade
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize() external reinitializer(2) {
        __YuzuProtoV2_init_unchained();
    }

    function cancelRedeemOrder(uint256 orderId) public virtual override(YuzuOrderBook, YuzuProtoV2) {
        YuzuProtoV2.cancelRedeemOrder(orderId);
    }
}
