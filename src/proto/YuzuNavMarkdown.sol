// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IYuzuNavMarkdownDefinitions} from "../interfaces/proto/IYuzuProtoDefinitions.sol";

/**
 * @title YuzuNavMarkdown
 * @notice Admin-set backing value per share, used to mark a token down below par
 * @dev Tree-agnostic mixin with ERC-7201 namespaced storage. {nav} is the underlying-asset value
 * backing one share, scaled so that {NAV_PRECISION} is par. Consumers price against {_effectiveNav}
 * (capped at par, so a value above par never raises the payout) and call {_setNav} behind their own
 * access control. {_setNav} enforces a relative step cap in both directions plus a cooldown;
 * {_setNavStepCap}/{_setNavCooldown} adjust those guardrails. {_initNav} seeds the value once with
 * no checks. A nav of 0 is degenerate but defined: payouts go to 0 and the asset-to-share path
 * reverts on the division.
 */
abstract contract YuzuNavMarkdown is IYuzuNavMarkdownDefinitions {
    /// @notice Par backing of one share, in the same scale as {nav}
    uint256 internal constant NAV_PRECISION = 1e18;

    struct YuzuNavMarkdownStorage {
        uint256 _nav;
        uint256 _stepCapPpm;
        uint256 _cooldown;
        uint256 _lastUpdate;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.navmarkdown")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuNavMarkdownStorageLocation =
        0xbba33777aee3e8d94c5925677a78afa5780f0b9cf6f4464b380525cccd6c9300;

    /// @notice Backing value of one share, scaled so {NAV_PRECISION} is par
    function nav() public view returns (uint256) {
        return _getYuzuNavMarkdownStorage()._nav;
    }

    /// @notice Maximum relative change per nav update, in ppm of the current nav
    function navStepCapPpm() public view returns (uint256) {
        return _getYuzuNavMarkdownStorage()._stepCapPpm;
    }

    /// @notice Minimum seconds between nav updates
    function navCooldown() public view returns (uint256) {
        return _getYuzuNavMarkdownStorage()._cooldown;
    }

    /// @notice Timestamp of the last nav update
    function navLastUpdate() public view returns (uint256) {
        return _getYuzuNavMarkdownStorage()._lastUpdate;
    }

    /// @notice Whether the token is marked down, i.e. nav is below par
    function isMarkedDown() public view returns (bool) {
        return _getYuzuNavMarkdownStorage()._nav < NAV_PRECISION;
    }

    /// @dev Backing value used for pricing, capped at par so a value above par never raises the payout
    function _effectiveNav() internal view returns (uint256) {
        return Math.min(_getYuzuNavMarkdownStorage()._nav, NAV_PRECISION);
    }

    /// @dev Seeds the nav with no step or cooldown check; for one-time initialization
    function _initNav(uint256 initialNav) internal {
        YuzuNavMarkdownStorage storage $ = _getYuzuNavMarkdownStorage();
        uint256 oldNav = $._nav;
        $._nav = initialNav;
        emit UpdatedNav(oldNav, initialNav);
    }

    /// @dev Sets the nav under the relative step cap (both directions) and the cooldown
    function _setNav(uint256 newNav) internal {
        YuzuNavMarkdownStorage storage $ = _getYuzuNavMarkdownStorage();
        uint256 currentNav = $._nav;

        uint256 lastUpdate = $._lastUpdate;
        if (lastUpdate != 0) {
            uint256 readyAt = lastUpdate + $._cooldown;
            if (block.timestamp < readyAt) {
                revert NavCooldownActive(block.timestamp, readyAt);
            }
        }

        uint256 maxDelta = Math.mulDiv(currentNav, $._stepCapPpm, 1e6);
        uint256 delta = newNav > currentNav ? newNav - currentNav : currentNav - newNav;
        if (delta > maxDelta) {
            revert NavStepTooLarge(newNav, currentNav, maxDelta);
        }

        $._nav = newNav;
        $._lastUpdate = block.timestamp;
        emit UpdatedNav(currentNav, newNav);
    }

    function _setNavStepCap(uint256 newStepCapPpm) internal {
        if (newStepCapPpm > 1e6) {
            revert InvalidNavStepCap(newStepCapPpm, 1e6);
        }
        YuzuNavMarkdownStorage storage $ = _getYuzuNavMarkdownStorage();
        uint256 oldStepCapPpm = $._stepCapPpm;
        $._stepCapPpm = newStepCapPpm;
        emit UpdatedNavStepCap(oldStepCapPpm, newStepCapPpm);
    }

    function _setNavCooldown(uint256 newCooldown) internal {
        YuzuNavMarkdownStorage storage $ = _getYuzuNavMarkdownStorage();
        uint256 oldCooldown = $._cooldown;
        $._cooldown = newCooldown;
        emit UpdatedNavCooldown(oldCooldown, newCooldown);
    }

    function _getYuzuNavMarkdownStorage() private pure returns (YuzuNavMarkdownStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuNavMarkdownStorageLocation
        }
    }
}
