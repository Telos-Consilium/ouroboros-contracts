// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

struct InBlockUsage {
    uint256 _blockNumber;
    uint256 _usage;
}

library LibInBlockUsage {
    function usage(InBlockUsage memory u) internal view returns (uint256) {
        if (block.number == u._blockNumber) {
            return uint256(u._usage);
        } else {
            return 0;
        }
    }

    function use(InBlockUsage storage u, uint256 amount) internal {
        if (block.number == u._blockNumber) {
            u._usage += amount;
        } else {
            u._blockNumber = block.number;
            u._usage = amount;
        }
    }
}
