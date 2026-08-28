// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {StakedYuzuUSDV2} from "./StakedYuzuUSDV2.sol";
import {IStakedYuzuUSDV3Definitions} from "./interfaces/IStakedYuzuUSDDefinitions.sol";

/**
 * @title StakedYuzuUSDV3Recovery
 * @notice Interim implementation that moves the shares lost to an unreachable address.
 * @dev Installed only for the one transaction that runs {recover}; the proxy is then upgraded to
 * StakedYuzuUSDV3, whose reinitialize performs the AccessControl migration.
 */
contract StakedYuzuUSDV3Recovery is StakedYuzuUSDV2, IStakedYuzuUSDV3Definitions {
    address private constant LOST_ADDRESS = 0xB3a9009c89a3Fc46314C2df642d920c244C61c06;
    address private constant RECOVERY_RECEIVER = 0xAFFcbAb01F7C2B3D533198B741C9E32Df2d78616;
    uint256 private constant RECOVERY_AMOUNT = 2_913_260.544695655463689601 ether;

    /// @notice Moves the lost shares to the recovery receiver.
    /// @dev Gated to the proxy admin.
    // slither-disable-next-line pess-unprotected-initialize
    function recover() external virtual reinitializer(3) whenPaused {
        if (msg.sender != ERC1967Utils.getAdmin()) revert UnauthorizedReinitializer(msg.sender);
        _burn(LOST_ADDRESS, RECOVERY_AMOUNT);
        _mint(RECOVERY_RECEIVER, RECOVERY_AMOUNT);
        emit Recovered(LOST_ADDRESS, RECOVERY_RECEIVER, RECOVERY_AMOUNT);
    }
}
