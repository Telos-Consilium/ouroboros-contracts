// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {YuzuV3RestrictedSharesStorage} from "../storage/YuzuV3Storage.sol";

library YuzuV3RestrictedShares {
    function currentBlockRestrictedBalance(address account) internal view returns (uint256) {
        YuzuV3RestrictedSharesStorage.Restriction storage restriction =
            YuzuV3RestrictedSharesStorage.layout()._restrictions[account];
        // slither-disable-next-line incorrect-equality
        return restriction.blockNumber == block.number ? restriction.amount : 0;
    }

    function update(address from, address to, uint256 amount, uint256 fromBalance) internal {
        if (amount == 0 || from == to) {
            return;
        }

        YuzuV3RestrictedSharesStorage.Layout storage $ = YuzuV3RestrictedSharesStorage.layout();
        if (from != address(0)) {
            YuzuV3RestrictedSharesStorage.Restriction storage restriction = $._restrictions[from];
            // slither-disable-next-line incorrect-equality
            if (restriction.blockNumber == block.number && restriction.amount > fromBalance) {
                restriction.amount = fromBalance;
            }
        }

        if (to != address(0)) {
            YuzuV3RestrictedSharesStorage.Restriction storage restriction = $._restrictions[to];
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
