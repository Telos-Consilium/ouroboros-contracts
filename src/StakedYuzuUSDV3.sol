// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {StakedYuzuUSDV3Recovery} from "./StakedYuzuUSDV3Recovery.sol";

/**
 * @title StakedYuzuUSDV3
 * @notice Post-recovery implementation of StakedYuzuUSDV3; reinitialize is disabled and recovery code is dead.
 */
contract StakedYuzuUSDV3 is StakedYuzuUSDV3Recovery {
    // slither-disable-next-line pess-unprotected-initialize
    function reinitialize(address) external override {
        revert Initializable.InvalidInitialization();
    }
}
