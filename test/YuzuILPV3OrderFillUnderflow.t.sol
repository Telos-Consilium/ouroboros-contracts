// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {YuzuILPV3FeesTest} from "./YuzuILPV3Fees.t.sol";

/// @notice Filling a redeem order must never underflow poolSize, even when a large management-fee
/// markdown has pushed the fee-net NAV far below the fee-free NAV. _fillRedeemOrder scales the net order
/// value up to gross terms (grossRedeemed = netRedeemed * grossTotalAssets / netTotalAssets, Ceil) before
/// subtracting the pool portion from poolSize; this fuzzes the markdown size and the redeemed fraction to
/// confirm the gross-scaled, Ceil-rounded deduction stays within poolSize.
contract YuzuILPV3OrderFillUnderflowTest is YuzuILPV3FeesTest {
    function testFuzz_OrderFill_NoPoolUnderflow(uint256 warpDays, uint256 redeemShares) public {
        _setupPool(); // poolSize 1000e6, supply 1000e18
        vm.prank(feeManager);
        yzilp.setManagementFee(100_000); // 10%/yr, the maximum
        _promote(0);

        warpDays = bound(warpDays, 0, 3000); // up to a deep fee markdown
        redeemShares = bound(redeemShares, 1e18, 1000e18); // up to the holder's full balance
        vm.warp(block.timestamp + warpDays * 1 days);

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(redeemShares, user, user);

        address filler = makeAddr("orderFiller");
        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, filler);
        asset.mint(filler, 10_000e6);
        vm.prank(filler);
        asset.approve(address(yzilp), type(uint256).max);

        vm.prank(filler);
        yzilp.fillRedeemOrder(orderId);

        assertLe(yzilp.poolSize(), 1000e6);
    }
}
