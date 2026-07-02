// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {StakedYuzuUSDV3Migration} from "./StakedYuzuUSDV3Migration.sol";

/**
 * @title StakedYuzuUSDV3RecoveryMigration
 * @notice Staked Yuzu USD V3 migration with recovery.
 */
contract StakedYuzuUSDV3RecoveryMigration is StakedYuzuUSDV3Migration {
    address private constant LOST_ADDRESS = 0x0000000000000000000000000000000000000001;
    address private constant RECOVERY_RECEIVER = 0x0000000000000000000000000000000000000002;
    uint256 private constant RECOVERY_AMOUNT = 1;

    /// @notice Migrates ownership to AccessControl and runs recovery.
    /// @param _admin The admin of the contract
    // slither-disable-next-line pess-unprotected-initialize
    function migrateToV3(address _admin) external virtual override reinitializer(3) whenPaused {
        _migrateToAccessControl(_admin);
        _burn(LOST_ADDRESS, RECOVERY_AMOUNT);
        _mint(RECOVERY_RECEIVER, RECOVERY_AMOUNT);
        emit Recovered(LOST_ADDRESS, RECOVERY_RECEIVER, RECOVERY_AMOUNT);
    }
}
