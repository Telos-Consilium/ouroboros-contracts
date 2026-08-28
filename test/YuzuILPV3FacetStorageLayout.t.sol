// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {YuzuILPV2} from "../src/YuzuILPV2.sol";

/// @notice Pins each base storage slot YuzuILPV3Facet reaches by raw slot under delegatecall, so a
/// layout shift fails here instead of silently corrupting storage. Keep in sync with YuzuILPV3Facet.
contract YuzuILPV3FacetStorageLayoutTest is Test {
    uint256 private constant TREASURY_SLOT = 1;
    uint256 private constant REDEEM_FEE_SLOT = 2;
    uint256 private constant REDEEM_ORDER_FEE_SLOT = 3;
    uint256 private constant FEE_RECEIVER_AND_RESTRICTIONS_SLOT = 4;
    uint256 private constant IS_MINT_RESTRICTED_SHIFT = 160;
    uint256 private constant IS_REDEEM_RESTRICTED_SHIFT = 168;
    uint256 private constant POOL_SIZE_SLOT = 55;
    uint256 private constant DAILY_LINEAR_YIELD_RATE_PPM_SLOT = 56;
    uint256 private constant LAST_POOL_UPDATE_TIMESTAMP_SLOT = 57;
    uint256 private constant IS_UPDATING_POOL_SLOT = 100;
    uint256 private constant LAST_DISTRIBUTED_AMOUNT_SLOT = 101;
    uint256 private constant LAST_DISTRIBUTION_PERIOD_SLOT = 102;
    uint256 private constant LAST_DISTRIBUTION_TIMESTAMP_SLOT = 103;
    uint256 private constant FULLY_DISTRIBUTED_SINCE_UPDATE_SLOT = 104;
    uint256 private constant REDEEMED_DISTRIBUTIONS_SINCE_UPDATE_SLOT = 105;

    YuzuILPV2 private ilp;

    function setUp() public {
        ilp = new YuzuILPV2();
    }

    function _store(uint256 slot, uint256 value) internal {
        vm.store(address(ilp), bytes32(slot), bytes32(value));
    }

    function test_Layout_Treasury() public {
        address sentinel = address(0xA11CE);
        _store(TREASURY_SLOT, uint256(uint160(sentinel)));
        assertEq(ilp.treasury(), sentinel);
    }

    function test_Layout_RedeemFee() public {
        _store(REDEEM_FEE_SLOT, 12_345);
        assertEq(ilp.redeemFeePpm(), 12_345);
    }

    function test_Layout_RedeemOrderFee() public {
        _store(REDEEM_ORDER_FEE_SLOT, 23_456);
        assertEq(ilp.redeemOrderFeePpm(), 23_456);
    }

    function test_Layout_FeeReceiver() public {
        address sentinel = address(0xBEEF);
        _store(FEE_RECEIVER_AND_RESTRICTIONS_SLOT, uint256(uint160(sentinel)));
        assertEq(ilp.feeReceiver(), sentinel);
    }

    function test_Layout_IsMintRestricted() public {
        _store(FEE_RECEIVER_AND_RESTRICTIONS_SLOT, uint256(1) << IS_MINT_RESTRICTED_SHIFT);
        assertTrue(ilp.isMintRestricted());
        assertFalse(ilp.isRedeemRestricted());
    }

    function test_Layout_IsRedeemRestricted() public {
        _store(FEE_RECEIVER_AND_RESTRICTIONS_SLOT, uint256(1) << IS_REDEEM_RESTRICTED_SHIFT);
        assertTrue(ilp.isRedeemRestricted());
        assertFalse(ilp.isMintRestricted());
    }

    function test_Layout_PoolSize() public {
        _store(POOL_SIZE_SLOT, 777e18);
        assertEq(ilp.poolSize(), 777e18);
    }

    function test_Layout_DailyLinearYieldRatePpm() public {
        _store(DAILY_LINEAR_YIELD_RATE_PPM_SLOT, 9_999);
        assertEq(ilp.dailyLinearYieldRatePpm(), 9_999);
    }

    function test_Layout_LastPoolUpdateTimestamp() public {
        _store(LAST_POOL_UPDATE_TIMESTAMP_SLOT, 1_700_000_000);
        assertEq(ilp.lastPoolUpdateTimestamp(), 1_700_000_000);
    }

    function test_Layout_IsUpdatingPool() public {
        _store(IS_UPDATING_POOL_SLOT, 1);
        assertTrue(ilp.isUpdatingPool());
    }

    function test_Layout_LastDistributedAmount() public {
        _store(LAST_DISTRIBUTED_AMOUNT_SLOT, 555e18);
        assertEq(ilp.lastDistributedAmount(), 555e18);
    }

    function test_Layout_LastDistributionPeriod() public {
        _store(LAST_DISTRIBUTION_PERIOD_SLOT, 7 days);
        assertEq(ilp.lastDistributionPeriod(), 7 days);
    }

    function test_Layout_LastDistributionTimestamp() public {
        _store(LAST_DISTRIBUTION_TIMESTAMP_SLOT, 1_700_000_001);
        assertEq(ilp.lastDistributionTimestamp(), 1_700_000_001);
    }

    /// @dev Accumulators are internal; a fresh instance has period 0, so distributedSinceUpdate() is just slot 104.
    function test_Layout_DistributionAccumulators() public {
        uint256 fullyDistributed = 2e18;
        uint256 redeemedDistributions = 5e17;
        _store(FULLY_DISTRIBUTED_SINCE_UPDATE_SLOT, fullyDistributed);
        _store(REDEEMED_DISTRIBUTIONS_SINCE_UPDATE_SLOT, redeemedDistributions);
        assertEq(ilp.distributedSinceUpdate(), fullyDistributed, "slot 104 fullyDistributed");
        assertEq(ilp.netDistributedSinceUpdate(), fullyDistributed - redeemedDistributions, "slot 105 redeemed");
    }
}
