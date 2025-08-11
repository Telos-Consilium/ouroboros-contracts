// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

struct InBlockUsage {
    uint64 _blockNumber;
    uint192 _usage;
}

library LibInBlockUsage {
    function usage(InBlockUsage memory u) internal view returns (uint256) {
        if (block.number == u._blockNumber) {
            return uint256(u._usage);
        } else {
            return 0;
        }
    }

    function use(InBlockUsage storage u, uint256 _amount) internal {
        uint192 amount = SafeCast.toUint192(_amount);
        if (block.number == u._blockNumber) {
            u._usage += amount;
        } else {
            u._blockNumber = uint64(block.number);
            u._usage = amount;
        }
    }
}
