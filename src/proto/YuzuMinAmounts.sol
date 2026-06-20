// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuMinAmountsDefinitions} from "../interfaces/proto/IYuzuProtoDefinitions.sol";

/**
 * @title YuzuMinAmounts
 * @notice Minimum deposit and withdraw amounts for the instant mint/redeem paths
 * @dev Tree-agnostic mixin with ERC-7201 namespaced storage. Consumers expose `_setMinDeposit`/
 * `_setMinWithdraw` behind their own access control and call `_checkMinDeposit`/`_checkMinWithdraw`
 * on the instant paths. A minimum of 0 (the default) imposes no floor.
 */
abstract contract YuzuMinAmounts is IYuzuMinAmountsDefinitions {
    struct YuzuMinAmountsStorage {
        uint256 _minDeposit;
        uint256 _minWithdraw;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.minamounts")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuMinAmountsStorageLocation =
        0x3bac632b84cdc99ee809c17a81d1c3af6c49d197442158c702def7699ae31b00;

    function minDeposit() public view returns (uint256) {
        return _getYuzuMinAmountsStorage()._minDeposit;
    }

    function minWithdraw() public view returns (uint256) {
        return _getYuzuMinAmountsStorage()._minWithdraw;
    }

    function _setMinDeposit(uint256 newMin) internal {
        YuzuMinAmountsStorage storage $ = _getYuzuMinAmountsStorage();
        uint256 oldMin = $._minDeposit;
        $._minDeposit = newMin;
        emit UpdatedMinDeposit(oldMin, newMin);
    }

    function _setMinWithdraw(uint256 newMin) internal {
        YuzuMinAmountsStorage storage $ = _getYuzuMinAmountsStorage();
        uint256 oldMin = $._minWithdraw;
        $._minWithdraw = newMin;
        emit UpdatedMinWithdraw(oldMin, newMin);
    }

    function _checkMinDeposit(uint256 assets) internal view {
        uint256 min = minDeposit();
        if (assets < min) revert UnderMinDeposit(assets, min);
    }

    function _checkMinWithdraw(uint256 assets) internal view {
        uint256 min = minWithdraw();
        if (assets < min) revert UnderMinWithdraw(assets, min);
    }

    function _getYuzuMinAmountsStorage() private pure returns (YuzuMinAmountsStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuMinAmountsStorageLocation
        }
    }
}
