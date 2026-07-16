// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {YuzuRestrictedSharesV3Storage} from "../storage/YuzuV3Storage.sol";

library YuzuV3RestrictedShares {
    function currentBlockRestrictedBalance(address account) internal view returns (uint256) {
        YuzuRestrictedSharesV3Storage.Restriction storage restriction =
            YuzuRestrictedSharesV3Storage.layout()._restrictions[account];
        // slither-disable-next-line incorrect-equality
        return restriction.blockNumber == block.number ? restriction.amount : 0;
    }

    function update(address from, address to, uint256 amount, uint256 fromBalance) internal {
        if (amount == 0 || from == to) {
            return;
        }

        YuzuRestrictedSharesV3Storage.Layout storage $ = YuzuRestrictedSharesV3Storage.layout();
        if (from != address(0)) {
            YuzuRestrictedSharesV3Storage.Restriction storage restriction = $._restrictions[from];
            // slither-disable-next-line incorrect-equality
            if (restriction.blockNumber == block.number && restriction.amount > fromBalance) {
                restriction.amount = fromBalance;
            }
        }

        if (to != address(0)) {
            YuzuRestrictedSharesV3Storage.Restriction storage restriction = $._restrictions[to];
            // slither-disable-next-line incorrect-equality
            if (restriction.blockNumber == block.number) {
                restriction.amount += amount;
            } else {
                restriction.blockNumber = block.number;
                restriction.amount = amount;
            }
        }
    }
}
