// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {PSMOVaultComposer} from "../src/ovault/PSMOVaultComposer.sol";

/// @dev Covers the bytes32 to address receiver decoding used by the OVault composer role checks.
contract PSMOVaultComposerTest is Test {
    function test_InitializesShareAllowances() public {
        ERC20Mock asset = new ERC20Mock();
        ERC20Mock shares = new ERC20Mock();
        address endpoint = makeAddr("endpoint");
        address assetOft = makeAddr("assetOft");
        address shareOft = makeAddr("shareOft");
        address psm = makeAddr("psm");

        vm.mockCall(psm, abi.encodeWithSignature("asset()"), abi.encode(address(asset)));
        vm.mockCall(psm, abi.encodeWithSignature("vault1()"), abi.encode(address(shares)));
        vm.mockCall(assetOft, abi.encodeWithSignature("token()"), abi.encode(address(asset)));
        vm.mockCall(assetOft, abi.encodeWithSignature("approvalRequired()"), abi.encode(true));
        vm.mockCall(assetOft, abi.encodeWithSignature("endpoint()"), abi.encode(endpoint));
        vm.mockCall(shareOft, abi.encodeWithSignature("token()"), abi.encode(address(shares)));
        vm.mockCall(shareOft, abi.encodeWithSignature("approvalRequired()"), abi.encode(true));
        vm.mockCall(endpoint, abi.encodeWithSignature("eid()"), abi.encode(uint32(1)));

        PSMOVaultComposer composer = new PSMOVaultComposer(psm, assetOft, shareOft);

        assertEq(shares.allowance(address(composer), psm), type(uint256).max);
        assertEq(shares.allowance(address(composer), shareOft), type(uint256).max);
    }

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
        this.bytes32toAddress(b);
    }
}
