// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract PSMOVaultComposerTest is Test {
    function bytes32toAddress(bytes32 b) public pure returns (address) {
        return address(SafeCast.toUint160(uint256(b)));
    }

    function test_Bytes32ToAddress() public {
        bytes32 b = 0x0000000000000000000000001234567890abcdef1234567890abcdef12345678;
        address a = bytes32toAddress(b);
        assertEq(a, 0x1234567890AbcdEF1234567890aBcdef12345678);
    }

    function test_Bytes32ToAddress_Zero() public {
        bytes32 b = 0x0000000000000000000000000000000000000000000000000000000000000000;
        address a = bytes32toAddress(b);
        assertEq(a, 0x0000000000000000000000000000000000000000);
    }

    function test_Bytes32ToAddress_Revert() public {
        bytes32 b = 0x0000000000000000000000010000000000000000000000000000000000000000;
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(160), uint256(b))
        );
        address a = this.bytes32toAddress(b);
    }
}
