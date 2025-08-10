// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {YuzuILP} from "../src/YuzuILP.sol";

import {USDCMock} from "./YuzuProto.t.sol";

contract YuzuILPFuzz is Test {
    YuzuILP public ilp;
    USDCMock public asset;

    address public poolManager;

    // Role IDs (must match contract)
    bytes32 private constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    function setUp() public {
        poolManager = makeAddr("poolManager");

        // Deploy mock asset
        asset = new USDCMock();
        asset.mint(address(this), 1_000_000e6);

        // Deploy implementation and proxy-initialize
        YuzuILP implementation = new YuzuILP();
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            address(asset),
            "Yuzu ILP",
            "yzILP",
            address(this), // admin
            makeAddr("treasury"), // treasury
            1_000_000e6, // maxDepositPerBlock
            1_000_000e6, // maxWithdrawPerBlock
            1 days // fillWindow
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        ilp = YuzuILP(address(proxy));

        // Grant roles from admin
        ilp.grantRole(POOL_MANAGER_ROLE, address(this));

        // Approvals for deposits/orders
        asset.approve(address(ilp), type(uint256).max);
    }

    function testFuzz_PreviewMint(uint256 shareSupply, uint256 poolSize, uint256 yieldRatePpm, uint256 elapsedTime)
        public
    {
        shareSupply = bound(shareSupply, 100e18, 1_000e18);
        poolSize = bound(poolSize, 100e6, 1_000e6);
        yieldRatePpm = bound(yieldRatePpm, 0, 10_000); // 1%
        elapsedTime = bound(elapsedTime, 0, 7 days);

        ilp.mint(shareSupply, address(this));
        ilp.updatePool(poolSize, yieldRatePpm);

        vm.warp(block.timestamp + elapsedTime);

        uint256 sharePrice = ilp.previewMint(1e18);
        uint256 compoundYieldSharePrice = _calculateSharePriceFFI(poolSize, shareSupply, yieldRatePpm, elapsedTime);

        assertApproxEqRel(sharePrice, compoundYieldSharePrice, 10_000 * 1e12); // 10_000 ppm
    }

    function test_PreviewMint_WorstCase() public {
        uint256 shareSupply = 100e18;
        uint256 poolSize = 100e6;
        uint256 yieldRatePpm = 10_000; // 1%
        uint256 elapsedTime = 1 days / 2;

        ilp.mint(shareSupply, address(this));
        ilp.updatePool(poolSize, yieldRatePpm);

        vm.warp(block.timestamp + elapsedTime);

        uint256 sharePrice = ilp.previewMint(1e18);
        uint256 compoundYieldSharePrice = _calculateSharePriceFFI(poolSize, shareSupply, yieldRatePpm, elapsedTime);

        assertApproxEqRel(sharePrice, compoundYieldSharePrice, 13 * 1e12); // 13 ppm
    }

    function _calculateSharePriceFFI(
        uint256 poolSize,
        uint256 totalSupply,
        uint256 dailyLinearYieldRatePpm,
        uint256 elapsedTime
    ) internal returns (uint256) {
        string[] memory inputs = new string[](7);
        inputs[0] = "python3";
        inputs[1] = "scripts/math_helper.py";
        inputs[2] = "share_price";
        inputs[3] = vm.toString(poolSize);
        inputs[4] = vm.toString(totalSupply);
        inputs[5] = vm.toString(dailyLinearYieldRatePpm);
        inputs[6] = vm.toString(elapsedTime);

        bytes memory res = vm.ffi(inputs);
        require(res.length == 32, "Invalid FFI output length");
        return abi.decode(res, (uint256));
    }
}
