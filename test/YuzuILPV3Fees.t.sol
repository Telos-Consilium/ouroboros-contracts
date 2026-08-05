// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IYuzuProtoDefinitions, IYuzuMinAmountsDefinitions} from "../src/interfaces/proto/IYuzuProtoDefinitions.sol";
import {IYuzuIssuerDefinitions} from "../src/interfaces/proto/IYuzuIssuerDefinitions.sol";
import {IYuzuILPV2Definitions, IYuzuILPV3Definitions} from "../src/interfaces/IYuzuILPDefinitions.sol";
import {
    ADMIN_ROLE,
    DISTRIBUTOR_ROLE,
    FEE_MANAGER_ROLE,
    LIMIT_MANAGER_ROLE,
    ORDER_FILLER_ROLE,
    POOL_MANAGER_ROLE,
    REDEEM_MANAGER_ROLE
} from "./helpers/TestRoles.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

contract YuzuILPV3FeesTest is YuzuV3TestBase, IYuzuProtoDefinitions, IYuzuILPV2Definitions, IYuzuILPV3Definitions {
    function setUp() public {
        asset = _newAsset();
        asset.mint(user, 10_000_000e6);
        yzilp = _deployYuzuILPV3();

        vm.startPrank(admin);
        yzilp.grantRole(FEE_MANAGER_ROLE, feeManager);
        yzilp.grantRole(REDEEM_MANAGER_ROLE, redeemManager);
        yzilp.setIsMintRestricted(false);
        yzilp.setIsRedeemRestricted(false);
        vm.stopPrank();

        _approve(user, address(yzilp));
    }

    function _setMintFee(uint256 ppm) internal {
        vm.prank(feeManager);
        yzilp.setMintFee(ppm);
    }

    // --- mint fee on the deposit/mint paths ---

    function test_MintFee_DefaultsToZero() public {
        assertEq(yzilp.mintFeePpm(), 0);

        vm.prank(user);
        uint256 shares = yzilp.deposit(100e6, user);
        assertEq(shares, 100e18);
        assertEq(asset.balanceOf(feeReceiver), 0);
    }

    function test_MintFee_OnDeposit() public {
        _setMintFee(100_000); // 10%

        // 110 in: 10 fee to receiver, 100 net backing 100e18 shares
        vm.prank(user);
        uint256 shares = yzilp.deposit(110e6, user);
        assertEq(shares, 100e18);
        assertEq(yzilp.balanceOf(user), 100e18);
        assertEq(asset.balanceOf(feeReceiver), 10e6);
    }

    function test_MintFee_OnMint() public {
        _setMintFee(100_000); // 10%

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 paid = yzilp.mint(100e18, user);

        // 100 net for the shares + 10 fee on top
        assertEq(paid, 110e6);
        assertEq(yzilp.balanceOf(user), 100e18);
        assertEq(asset.balanceOf(feeReceiver), 10e6);
        assertEq(balBefore - asset.balanceOf(user), 110e6);
    }

    function test_SetMintFee_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedMintFee(0, 100_000);
        _setMintFee(100_000);
        assertEq(yzilp.mintFeePpm(), 100_000);
    }

    function test_SetMintFee_Revert_TooHigh() public {
        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 1e6 + 1, 1e6));
        yzilp.setMintFee(1e6 + 1);
    }

    function test_SetMintFee_Revert_NotFeeManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, FEE_MANAGER_ROLE)
        );
        yzilp.setMintFee(100_000);
    }

    // --- redeem fee setters re-homed onto FEE_MANAGER_ROLE ---

    function test_SetRedeemFee_RequiresFeeManager() public {
        vm.prank(feeManager);
        yzilp.setRedeemFee(5_000);
        assertEq(yzilp.redeemFeePpm(), 5_000);
    }

    function test_SetRedeemFee_Revert_RedeemManagerRejected() public {
        vm.prank(redeemManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, redeemManager, FEE_MANAGER_ROLE
            )
        );
        yzilp.setRedeemFee(5_000);
    }

    function test_SetRedeemOrderFee_RequiresFeeManager() public {
        vm.prank(feeManager);
        yzilp.setRedeemOrderFee(3_000);
        assertEq(yzilp.redeemOrderFeePpm(), 3_000);

        vm.prank(redeemManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, redeemManager, FEE_MANAGER_ROLE
            )
        );
        yzilp.setRedeemOrderFee(3_000);
    }

    // --- feeReceiver stays under ADMIN_ROLE ---

    function test_SetFeeReceiver_StaysAdmin() public {
        address newReceiver = makeAddr("newReceiver");
        vm.prank(admin);
        yzilp.setFeeReceiver(newReceiver);
        assertEq(yzilp.feeReceiver(), newReceiver);
    }

    function test_SetFeeReceiver_Revert_FeeManagerRejected() public {
        vm.prank(feeManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, feeManager, ADMIN_ROLE)
        );
        yzilp.setFeeReceiver(makeAddr("newReceiver"));
    }

    function test_FeeManagerRole_AdminIsAdminRole() public view {
        assertEq(yzilp.getRoleAdmin(FEE_MANAGER_ROLE), ADMIN_ROLE);
    }

    // --- management fee ---

    function _setupPool() internal {
        vm.startPrank(admin);
        yzilp.grantRole(POOL_MANAGER_ROLE, admin);
        yzilp.grantRole(DISTRIBUTOR_ROLE, admin);
        vm.stopPrank();
        _setupIlpPool(1000e6);
    }

    function _promote(uint256 yieldPpm) internal {
        _promoteIlpFees(yieldPpm);
    }

    function _reportPool(uint256 newPoolSize) internal {
        _reportIlpPool(newPoolSize);
    }

    function _expectedManagementFee(uint256 poolSize, uint256 elapsed) internal view returns (uint256) {
        return Math.mulDiv(poolSize * yzilp.managementFeeRatePpm(), elapsed, 1e6 * 365 days, Math.Rounding.Ceil);
    }

    function test_ManagementFee_DefaultsToZero() public view {
        assertEq(yzilp.managementFeeRatePpm(), 0);
        assertEq(yzilp.pendingManagementFeeRatePpm(), 0);
        assertEq(yzilp.cumulativeManagementFees(), 0);
    }

    function test_PreviewDeposit_UsesCeilRoundedActiveDistribution() public {
        _setupPool();

        vm.prank(admin);
        yzilp.distribute(1, 1 days);
        vm.warp(block.timestamp + 1);

        assertEq(yzilp.totalAssets(), 1000e6);
        uint256 expectedShares = 1000e6 * yzilp.totalSupply() / (1000e6 + 1);
        assertEq(yzilp.previewDeposit(1000e6), expectedShares);
    }

    function test_SetPendingManagementFee_Deferred() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        // Staged, not yet live
        assertEq(yzilp.pendingManagementFeeRatePpm(), 100_000);
        assertEq(yzilp.managementFeeRatePpm(), 0);
        // The next update promotes it
        _promote(0);
        assertEq(yzilp.managementFeeRatePpm(), 100_000);
    }

    function test_ManagementFee_DriftsNavDown() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10%/yr, live next period
        _promote(0);

        assertEq(yzilp.totalAssets(), 1000e6);
        vm.warp(block.timestamp + 365 days);
        // 10% of 1000e6 accrued to the treasury over a year, lowering reported NAV
        assertEq(yzilp.totalAssets(), 900e6);
    }

    function test_ManagementFee_RealizedAtUpdatePool() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promote(0);
        vm.warp(block.timestamp + 365 days);

        // Admin reports the gross (1000e6); the contract nets the accrued 100e6 into poolSize
        _reportPool(1000e6);

        assertEq(yzilp.poolSize(), 900e6);
        assertEq(yzilp.cumulativeManagementFees(), 100e6);
        assertEq(yzilp.totalAssets(), 900e6);
    }

    function test_ManagementFee_RealizedEmitsEvent() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promote(0);
        vm.warp(block.timestamp + 365 days);

        vm.prank(admin);
        yzilp.startPoolUpdate();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit RealizedManagementFee(100e6, 100e6);
        vm.prank(admin);
        yzilp.updatePool(1000e6, 1000e6, 0);
    }

    function test_SetPendingManagementFee_EmitsEvent() public {
        _setupPool();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedPendingManagementFee(0, 20_000);
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(20_000);
        // Event reflects the staged transition; the rate is not live until the next update
        assertEq(yzilp.pendingManagementFeeRatePpm(), 20_000);
        assertEq(yzilp.managementFeeRatePpm(), 0);
    }

    function test_SetPendingManagementFee_Revert_TooHigh() public {
        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 100_000 + 1, 100_000));
        yzilp.setPendingManagementFee(100_000 + 1);
    }

    function test_SetPendingManagementFee_Revert_NotFeeManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, FEE_MANAGER_ROLE)
        );
        yzilp.setPendingManagementFee(20_000);
    }

    // --- performance fee ---

    function test_PerformanceFee_DefaultsToZero() public view {
        assertEq(yzilp.performanceFeeRatePpm(), 0);
        assertEq(yzilp.pendingPerformanceFeeRatePpm(), 0);
        assertEq(yzilp.cumulativePerformanceFees(), 0);
    }

    function test_HighWaterMark_SetAtFirstUpdate() public {
        _setupPool();
        // 1000e6 of assets over 1000e18 shares is 1e6 per whole share
        assertEq(yzilp.highWaterMark(), 1e6);
    }

    function test_SetPendingPerformanceFee_Deferred() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        assertEq(yzilp.pendingPerformanceFeeRatePpm(), 200_000);
        assertEq(yzilp.performanceFeeRatePpm(), 0);
        _promote(0);
        assertEq(yzilp.performanceFeeRatePpm(), 200_000);
    }

    function test_SetPendingPerformanceFee_EmitsEvent() public {
        _setupPool();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit UpdatedPendingPerformanceFee(0, 200_000);
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
    }

    function test_SetPendingPerformanceFee_Revert_TooHigh() public {
        vm.prank(feeManager);
        vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector, 500_000 + 1, 500_000));
        yzilp.setPendingPerformanceFee(500_000 + 1);
    }

    function test_SetPendingPerformanceFee_Revert_NotFeeManager() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, FEE_MANAGER_ROLE)
        );
        yzilp.setPendingPerformanceFee(200_000);
    }

    function test_PerformanceFee_MarksDownGainAboveHWM() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000); // 20%
        _promote(10_000); // live, plus 1%/day yield

        vm.warp(block.timestamp + 10 days); // +10% yield = +100e6 over poolSize 1000e6
        // net of management fee is 1100e6; mark is 1000e6; 20% of the 100e6 gain is 20e6
        assertEq(yzilp.totalAssets(), 1080e6);
    }

    function test_PerformanceFee_RealizedAndAdvancesHWM() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(10_000);
        vm.warp(block.timestamp + 10 days);

        vm.prank(admin);
        yzilp.startPoolUpdate();
        vm.expectEmit(false, false, false, true, address(yzilp));
        emit RealizedPerformanceFee(20e6, 20e6);
        vm.prank(admin);
        yzilp.updatePool(1000e6, 1100e6, 0);

        assertEq(yzilp.poolSize(), 1080e6);
        assertEq(yzilp.cumulativePerformanceFees(), 20e6);
        // Mark advances to the pre-fee net-of-management high: 1100e6 / 1000 = 1.1e6
        assertEq(yzilp.highWaterMark(), 1.1e6);
    }

    function test_PerformanceFee_ChargedOnDistributionAboveHWM() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(0);

        vm.prank(admin);
        yzilp.distribute(100e6, 1 days);
        vm.warp(block.timestamp + 1 days); // fully vested
        // net of management fee is 1100e6; mark is 1000e6; 20% of the 100e6 gain is 20e6
        assertEq(yzilp.totalAssets(), 1080e6);
    }

    function test_PerformanceFee_RecoveryToHWMFree() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(0);

        _reportPool(900e6); // a loss below the mark, no fee
        assertEq(yzilp.cumulativePerformanceFees(), 0);
        _reportPool(1000e6); // recovery back up to the mark, still no fee
        assertEq(yzilp.cumulativePerformanceFees(), 0);
        _reportPool(1100e6); // now above the mark: fee on the 100e6 above 1000e6
        assertEq(yzilp.cumulativePerformanceFees(), 20e6);
    }

    function test_PerformanceFee_TracksNetPriceDelta_WithLiveManagementFee() public {
        _setupPool(); // pool 1000e6, supply 1000e18, share price 1e6

        vm.startPrank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10%/year
        yzilp.setPendingPerformanceFee(200_000); // 20% of netOfManagementFee gains above the high-water mark
        vm.stopPrank();
        _promote(0);

        uint256 interval = 365 days / 10;
        uint256 shareUnit = 10 ** yzilp.decimals();
        uint256 supply = yzilp.totalSupply();
        uint256 startingMarkPrice = yzilp.highWaterMark();
        uint256 startingMarkAssets = Math.mulDiv(startingMarkPrice, supply, shareUnit);
        uint256 peakNetOfManagementAssets = startingMarkAssets;
        uint256 expectedManagementFees;
        uint256 cumulativeGrossToNetMarkdown;
        uint256 firstHighNetOfManagementAssets;
        uint256 performanceFeesAtFirstHigh;

        assertEq(startingMarkPrice, 1e6);
        assertEq(startingMarkAssets, 1000e6);
        assertEq(yzilp.managementFeeRatePpm(), 100_000);
        assertEq(yzilp.performanceFeeRatePpm(), 200_000);

        // At the first new high, 1300e6 gross less 10e6 management fee sets netOfManagementFee
        // to 1290e6. Performance fee applies to its 290e6 excess over the high-water-mark assets.
        {
            uint256 reportedGrossPool = 1300e6;
            uint256 managementFee = _expectedManagementFee(yzilp.poolSize(), interval);
            assertEq(managementFee, 10e6);
            uint256 netOfManagementFee = reportedGrossPool - managementFee;

            vm.warp(yzilp.lastPoolUpdateTimestamp() + interval);
            _reportPool(reportedGrossPool);

            expectedManagementFees += managementFee;
            peakNetOfManagementAssets = Math.max(peakNetOfManagementAssets, netOfManagementFee);
            firstHighNetOfManagementAssets = netOfManagementFee;
            performanceFeesAtFirstHigh = yzilp.cumulativePerformanceFees();
            cumulativeGrossToNetMarkdown += reportedGrossPool - yzilp.poolSize();

            assertEq(yzilp.cumulativeManagementFees(), expectedManagementFees);
            assertEq(performanceFeesAtFirstHigh, 58e6);
        }

        // Below the first netOfManagementFee high, the update realizes management fee but no
        // performance fee.
        {
            uint256 reportedGrossPool = 1100e6;
            uint256 managementFee = _expectedManagementFee(yzilp.poolSize(), interval);
            uint256 netOfManagementFee = reportedGrossPool - managementFee;

            vm.warp(yzilp.lastPoolUpdateTimestamp() + interval);
            _reportPool(reportedGrossPool);

            expectedManagementFees += managementFee;
            cumulativeGrossToNetMarkdown += reportedGrossPool - yzilp.poolSize();

            assertLt(netOfManagementFee, firstHighNetOfManagementAssets);
            assertEq(yzilp.cumulativeManagementFees(), expectedManagementFees);
            assertEq(yzilp.cumulativePerformanceFees(), performanceFeesAtFirstHigh);
        }

        // Recover exactly to the prior netOfManagementFee asset level. The entire
        // down-and-back-up leg remains performance-fee free despite another management fee.
        {
            uint256 managementFee = _expectedManagementFee(yzilp.poolSize(), interval);
            uint256 reportedGrossPool = firstHighNetOfManagementAssets + managementFee;
            uint256 netOfManagementFee = reportedGrossPool - managementFee;

            vm.warp(yzilp.lastPoolUpdateTimestamp() + interval);
            _reportPool(reportedGrossPool);

            expectedManagementFees += managementFee;
            cumulativeGrossToNetMarkdown += reportedGrossPool - yzilp.poolSize();

            assertEq(netOfManagementFee, firstHighNetOfManagementAssets);
            assertEq(yzilp.cumulativeManagementFees(), expectedManagementFees);
            assertEq(yzilp.cumulativePerformanceFees(), performanceFeesAtFirstHigh);
        }

        // Cross the prior netOfManagementFee high. Only the new portion above that high
        // is subject to the performance fee.
        {
            uint256 reportedGrossPool = 1500e6;
            uint256 managementFee = _expectedManagementFee(yzilp.poolSize(), interval);
            uint256 netOfManagementFee = reportedGrossPool - managementFee;

            vm.warp(yzilp.lastPoolUpdateTimestamp() + interval);
            _reportPool(reportedGrossPool);

            expectedManagementFees += managementFee;
            peakNetOfManagementAssets = Math.max(peakNetOfManagementAssets, netOfManagementFee);
            cumulativeGrossToNetMarkdown += reportedGrossPool - yzilp.poolSize();

            assertGt(yzilp.cumulativePerformanceFees(), performanceFeesAtFirstHigh);
        }

        // Express the expected fee through peak netOfManagementFee per share. With fixed supply,
        // it equals the fee rate times (peak price - starting highWaterMark) times supply.
        uint256 peakNetOfManagementPrice = Math.mulDiv(peakNetOfManagementAssets, shareUnit, supply);
        uint256 netNewHighAssets = Math.mulDiv(peakNetOfManagementPrice - startingMarkPrice, supply, shareUnit);
        uint256 expectedPerformanceFees =
            Math.mulDiv(yzilp.performanceFeeRatePpm(), netNewHighAssets, 1e6, Math.Rounding.Ceil);

        assertEq(peakNetOfManagementPrice, 1_487_100);
        assertEq(expectedManagementFees, 46_096_800);
        assertEq(expectedPerformanceFees, 97_420_000);
        assertApproxEqAbs(yzilp.cumulativePerformanceFees(), expectedPerformanceFees, 2);
        assertEq(yzilp.cumulativeManagementFees(), expectedManagementFees);
        assertEq(yzilp.highWaterMark(), peakNetOfManagementPrice);
        assertEq(yzilp.totalSupply(), supply);

        // For these non-saturating updates, each reportedGrossPool - poolSize delta equals
        // the management and performance fees realized by that update.
        assertEq(cumulativeGrossToNetMarkdown, yzilp.cumulativeManagementFees() + yzilp.cumulativePerformanceFees());
    }

    function test_PerformanceFee_EnableIsNotRetroactive() public {
        _setupPool();
        // The pool climbs from 1000e6 to 1500e6 while the fee is off
        _reportPool(1500e6);
        assertEq(yzilp.highWaterMark(), 1.5e6);

        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(0); // goes live with the mark already at the 1.5e6 high

        _reportPool(1600e6); // fee only on the 100e6 made after enabling
        assertEq(yzilp.cumulativePerformanceFees(), 20e6);
    }

    function test_PerformanceFee_DepositDoesNotTriggerFee() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000);
        _promote(0);

        // A deposit lifts assets and supply together, leaving the per-share price at the mark
        vm.prank(user);
        yzilp.deposit(500e6, user);
        assertEq(yzilp.totalAssets(), 1500e6);

        _reportPool(1500e6);
        assertEq(yzilp.cumulativePerformanceFees(), 0);
    }

    // A redeem order is priced at the fee-net share price, so filling it is a fair redeem that must not
    // move the share price for the remaining holders. Probes the _fillRedeemOrder pool/distribution split,
    // which sizes itself off the fee-free totalAssets while the payout was priced off the fee-net totalAssets.
    function test_OrderFill_PreservesSharePriceAtFill_WithLiveManagementFee() public {
        _setupPool(); // poolSize 1000e6, supply 1000e18
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10%/yr
        _promote(0);

        vm.warp(block.timestamp + 365 days); // markdown 100e6, share price 0.9

        uint256 sharePriceBefore = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(100e18, user, user); // 10% of supply

        uint256 pendingBefore = yzilp.totalPendingOrderSize();
        uint256 unfinalizedBefore = yzilp.totalUnfinalizedOrderValue();

        address filler = makeAddr("filler");
        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, filler);
        asset.mint(filler, 1_000e6);
        vm.prank(filler);
        asset.approve(address(yzilp), type(uint256).max);
        vm.prank(filler);
        yzilp.fillRedeemOrder(orderId);

        // The fill reaches the two orderbook counters through the facet's private copy of the storage
        // struct. Reading them back through the base getter proves that copy stays field-aligned: if the two
        // adjacent slots were swapped, pending would rise instead of fall and unfinalized would fall.
        assertEq(
            yzilp.totalPendingOrderSize(), pendingBefore - 100e18, "pending order size not reduced by filled tokens"
        );
        assertGt(yzilp.totalUnfinalizedOrderValue(), unfinalizedBefore, "unfinalized order value not raised by fill");

        uint256 sharePriceAfter = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();
        assertApproxEqAbs(sharePriceAfter, sharePriceBefore, 1, "order fill moved the share price while a fee was live");
    }

    // The public quote and the fill settlement must price an order identically: an order filled right
    // after being quoted settles at exactly the quoted assets, with fees and yield accrual live.
    function test_OrderFill_SettlesAtPreviewRedeemOrderQuote() public {
        _setupPool();
        vm.startPrank(feeManager);
        yzilp.setRedeemOrderFee(10_000); // 1%
        yzilp.setPendingManagementFee(100_000); // 10%/yr
        vm.stopPrank();
        _promote(0);

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(100e18, user, user);

        vm.warp(block.timestamp + 100 days); // management fee accrual live at fill time

        uint256 quote = yzilp.previewRedeemOrder(100e18);

        address orderFiller = makeAddr("parityFiller");
        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, orderFiller);
        asset.mint(orderFiller, 1_000e6);
        _approve(orderFiller, address(yzilp));
        vm.prank(orderFiller);
        yzilp.fillRedeemOrder(orderId);

        assertEq(yzilp.getRedeemOrder(orderId).assets, quote, "fill settled away from the previewRedeemOrder quote");
    }

    function testFuzz_OrderFill_NoPoolUnderflow(uint256 warpDays, uint256 redeemShares) public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promote(0);

        warpDays = bound(warpDays, 0, 3000);
        redeemShares = bound(redeemShares, 1e18, 1000e18);
        vm.warp(block.timestamp + warpDays * 1 days);

        vm.prank(user);
        uint256 orderId = yzilp.createRedeemOrder(redeemShares, user, user);

        address orderFiller = makeAddr("orderFiller");
        vm.prank(admin);
        yzilp.grantRole(ORDER_FILLER_ROLE, orderFiller);
        asset.mint(orderFiller, 10_000e6);
        vm.prank(orderFiller);
        asset.approve(address(yzilp), type(uint256).max);

        vm.prank(orderFiller);
        yzilp.fillRedeemOrder(orderId);

        assertLe(yzilp.poolSize(), 1000e6);
    }

    // --- deposit neutrality under live fees ---

    // A deposit is priced at the fee-net share price, so it must not move the share price for existing
    // holders. Probes the _deposit gross-up, which credits poolSize in fee-free units while the payment
    // was priced off the fee-net totalAssets.
    function test_Deposit_PreservesSharePriceAtEntry_WithLiveManagementFee() public {
        _setupPool(); // poolSize 1000e6, supply 1000e18
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10%/yr
        _promote(0);

        vm.warp(block.timestamp + 365 days); // markdown 100e6, share price 0.9

        uint256 sharePriceBefore = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();

        vm.prank(user);
        uint256 shares = yzilp.deposit(90e6, user);
        assertEq(shares, 100e18);

        // 90e6 net buys 90e6 of pool units, which bear management fee only from now on
        assertEq(yzilp.poolSize(), 1090e6);

        uint256 sharePriceAfter = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();
        assertApproxEqAbs(sharePriceAfter, sharePriceBefore, 1, "deposit moved the share price while a fee was live");
    }

    function test_Mint_PreservesSharePriceAtEntry_WithLiveManagementFee() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promote(0);

        vm.warp(block.timestamp + 365 days);

        uint256 sharePriceBefore = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();

        vm.prank(user);
        uint256 paid = yzilp.mint(100e18, user);
        assertEq(paid, 90e6);
        assertEq(yzilp.poolSize(), 1090e6);

        uint256 sharePriceAfter = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();
        assertApproxEqAbs(sharePriceAfter, sharePriceBefore, 1, "mint moved the share price while a fee was live");
    }

    function test_Deposit_PreservesSharePriceAtEntry_WithPerformanceFeeAboveHWM() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingPerformanceFee(200_000); // 20%
        _promote(10_000); // 1%/day yield

        vm.warp(block.timestamp + 10 days); // +100e6 gross yield, 20e6 marked down, share price 1.08

        uint256 sharePriceBefore = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();

        vm.prank(user);
        uint256 shares = yzilp.deposit(108e6, user);
        assertEq(shares, 100e18);

        // 108e6 net buys 110e6 of fee-free assets, worth 100e6 at the last update
        assertEq(yzilp.poolSize(), 1100e6);

        uint256 sharePriceAfter = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();
        assertApproxEqAbs(sharePriceAfter, sharePriceBefore, 1, "deposit moved the share price above the mark");
    }

    // Management fee accrues on poolSize but not on distributed assets, so the deposit credit must be
    // converted through the pool bucket's own fee-net value rather than the blended totals ratio.
    function test_Deposit_PreservesSharePriceAtEntry_WithOutstandingDistribution() public {
        _setupPool(); // poolSize 1000e6, supply 1000e18
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10%/yr
        _promote(0);

        vm.prank(admin);
        yzilp.distribute(500e6, 1 days);
        vm.warp(block.timestamp + 365 days); // fully vested; 1500e6 gross, 100e6 fee, 1400e6 net

        uint256 sharePriceBefore = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();

        vm.prank(user);
        uint256 shares = yzilp.deposit(140e6, user);
        assertEq(shares, 100e18);

        // 140e6 net buys 140e6 of pool units, which bear management fee only from now on;
        // the distribution bucket bears no management fee and takes no part of the credit
        assertEq(yzilp.poolSize(), 1_140_000_000);

        uint256 sharePriceAfter = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();
        assertApproxEqAbs(
            sharePriceAfter, sharePriceBefore, 1, "deposit moved the share price with a distribution outstanding"
        );
    }

    // Once the accrued fee consumes the pool bucket's entire value, pool units are worthless and no
    // credit can price a deposit; deposits must close until a pool update resets the fee accrual.
    function test_Deposit_ClosedWhenPoolFeeEroded() public {
        _setupPool(); // poolSize 1000e6
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10%/yr
        _promote(0);

        vm.prank(admin);
        yzilp.distribute(500e6, 1 days);
        vm.warp(block.timestamp + 11 * 365 days); // accrued fee 1100e6 exceeds the 1000e6 pool

        // Distributions keep net assets positive while the pool bucket is fully eroded
        assertEq(yzilp.totalAssets(), 400e6);
        assertEq(yzilp.maxDeposit(user), 0);
        assertEq(yzilp.maxMint(user), 0);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IYuzuIssuerDefinitions.ExceededMaxDeposit.selector, user, 100e6, 0));
        yzilp.deposit(100e6, user);

        // A pool update settles the accrued fee (1500e6 gross reported, 1100e6 netted) and reopens deposits
        _reportPool(1500e6);
        assertEq(yzilp.poolSize(), 400e6);
        assertGt(yzilp.maxDeposit(user), 0);
        vm.prank(user);
        yzilp.deposit(100e6, user);
    }

    function testFuzz_Deposit_NeverDecreasesSharePrice(
        uint256 mgmtPpm,
        uint256 perfPpm,
        uint256 yieldPpm,
        uint256 distroAssets,
        uint256 warpSecs,
        uint256 assets
    ) public {
        _setupPool();
        mgmtPpm = bound(mgmtPpm, 0, 100_000);
        perfPpm = bound(perfPpm, 0, 500_000);
        yieldPpm = bound(yieldPpm, 0, 10_000);
        distroAssets = bound(distroAssets, 0, 500e6);
        warpSecs = bound(warpSecs, 0, 365 days);
        assets = bound(assets, 1, 1_000_000e6);

        vm.startPrank(feeManager);
        yzilp.setPendingManagementFee(mgmtPpm);
        yzilp.setPendingPerformanceFee(perfPpm);
        vm.stopPrank();
        _promote(yieldPpm);

        if (distroAssets > 0) {
            vm.prank(admin);
            yzilp.distribute(distroAssets, 1 days);
        }

        vm.warp(block.timestamp + warpSecs);
        asset.mint(user, assets);

        uint256 sharePriceBefore = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();

        vm.prank(user);
        yzilp.deposit(assets, user);

        uint256 sharePriceAfter = yzilp.totalAssets() * 1e18 / yzilp.totalSupply();
        assertGe(sharePriceAfter + 1, sharePriceBefore, "deposit decreased the share price");
    }

    function test_TerminateDistribution_FreezesAtVested() public {
        _setupPool(); // poolSize 1000e6

        uint256 start = block.timestamp;
        vm.prank(admin);
        yzilp.distribute(100e6, 5 days);

        vm.warp(start + 1 days); // 1/5 vested
        assertEq(yzilp.totalAssets(), 1020e6);

        vm.expectEmit(false, false, false, true, address(yzilp));
        emit TerminatedDistribution(80e6);
        vm.prank(admin);
        yzilp.terminateDistribution();

        assertEq(yzilp.totalAssets(), 1020e6);
        vm.warp(start + 100 days);
        assertEq(yzilp.totalAssets(), 1020e6, "totalAssets kept rising after termination");
    }

    function test_TerminateDistribution_Revert_NotDistributor() public {
        _setupPool();
        vm.prank(admin);
        yzilp.distribute(50e6, 1 days);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, DISTRIBUTOR_ROLE)
        );
        yzilp.terminateDistribution();
    }

    // --- mint fee preview and max coupling ---

    function testFuzz_MintFee_PreviewDepositMatchesDeposit(uint256 feePpm, uint256 assets) public {
        _setupPool();
        feePpm = bound(feePpm, 0, 1e6);
        assets = bound(assets, 1, 1_000_000e6);
        _setMintFee(feePpm);

        uint256 previewed = yzilp.previewDeposit(assets);
        uint256 balanceBefore = yzilp.balanceOf(user);
        vm.prank(user);
        uint256 tokens = yzilp.deposit(assets, user);

        assertEq(tokens, previewed);
        assertEq(yzilp.balanceOf(user) - balanceBefore, previewed);
    }

    function testFuzz_MintFee_PreviewMintMatchesMint(uint256 feePpm, uint256 tokens) public {
        _setupPool();
        feePpm = bound(feePpm, 0, 1e6);
        tokens = bound(tokens, 1, 1_000_000e18);
        _setMintFee(feePpm);

        uint256 previewedCost = yzilp.previewMint(tokens);
        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        uint256 paid = yzilp.mint(tokens, user);

        assertEq(paid, previewedCost);
        assertEq(balanceBefore - asset.balanceOf(user), previewedCost);
    }

    function testFuzz_MintFee_DepositMaxDepositExhaustsThrottle(uint256 feePpm) public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        feePpm = bound(feePpm, 0, 1e6);
        _setMintFee(feePpm);
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 500e6);
        vm.stopPrank();

        uint256 maxAssets = yzilp.maxDeposit(user);
        vm.prank(user);
        yzilp.deposit(maxAssets, user);

        assertEq(yzilp.maxDeposit(user), 0);
    }

    function testFuzz_MintFee_DepositAboveMaxReverts(uint256 feePpm) public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        feePpm = bound(feePpm, 0, 1e6);
        _setMintFee(feePpm);
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 500e6);
        vm.stopPrank();

        uint256 maxAssets = yzilp.maxDeposit(user);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IYuzuIssuerDefinitions.ExceededMaxDeposit.selector, user, maxAssets + 1, maxAssets)
        );
        yzilp.deposit(maxAssets + 1, user);
    }

    function test_MintFee_MaxDepositIsGrossOfFee() public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        _setMintFee(100_000); // 10%
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 100e6);
        vm.stopPrank();

        // 100 net budget costs 110 gross at a 10% fee
        assertEq(yzilp.maxDeposit(user), 110e6);
    }

    function test_MintFee_MaxDepositMinClampUsesGross() public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        _setMintFee(100_000); // 10%
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 100e6);
        yzilp.setMinDeposit(110e6);
        vm.stopPrank();

        assertEq(yzilp.maxDeposit(user), 110e6);

        vm.prank(admin);
        yzilp.setMinDeposit(110e6 + 1);
        assertEq(yzilp.maxDeposit(user), 0);
    }

    function test_MintFee_MaxMintMinClampUsesGrossCost() public {
        _setupPool();
        // roll past the setup deposit's daily throttle usage
        vm.warp(block.timestamp + 1 days);
        _setMintFee(100_000); // 10%
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMintThrottle(type(uint256).max, 100e6);
        yzilp.setMinDeposit(110e6);
        vm.stopPrank();

        // 100e18 tokens cost 110e6 gross, meeting the minimum exactly
        assertEq(yzilp.maxMint(user), 100e18);

        vm.prank(admin);
        yzilp.setMinDeposit(110e6 + 1);
        assertEq(yzilp.maxMint(user), 0);
    }

    function test_MintFee_MinDepositAppliesToGrossInput() public {
        _setupPool();
        _setMintFee(100_000); // 10%
        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, admin);
        yzilp.setMinDeposit(110e6);
        vm.stopPrank();

        vm.prank(user);
        yzilp.deposit(110e6, user);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IYuzuMinAmountsDefinitions.UnderMinDeposit.selector, 110e6 - 1, 110e6));
        yzilp.deposit(110e6 - 1, user);
    }

    // --- accrued fee getters ---

    function _setupBothFees(uint256 yieldPpm) internal {
        _setupPool();
        vm.startPrank(feeManager);
        yzilp.setPendingManagementFee(100_000); // 10% per year
        yzilp.setPendingPerformanceFee(200_000); // 20% above the benchmark
        vm.stopPrank();
        _promote(yieldPpm);
    }

    // Gross minus both accrued fees is the fee-net total: the getters decompose pricing exactly
    // while no clamp binds.
    function test_AccruedFeeGetters_DecomposeTotalAssets() public {
        _setupBothFees(10_000); // 1% per day arms the benchmark crossing

        uint256 start = yzilp.lastPoolUpdateTimestamp();
        vm.warp(start + 100 days);

        uint256 gross = yzilp.grossTotalAssets();
        uint256 managementFee = yzilp.accruedManagementFee();
        uint256 performanceFee = yzilp.accruedPerformanceFee();
        assertGt(managementFee, 0, "fixture: no management accrual");
        assertGt(performanceFee, 0, "fixture: benchmark not crossed");
        assertEq(yzilp.totalAssets(), gross - managementFee - performanceFee, "getters do not decompose pricing");
    }

    // At a gross-neutral mark the getters report exactly what the update books.
    function test_AccruedFeeGetters_MatchBookedAmountsAtGrossNeutralUpdate() public {
        _setupBothFees(10_000);

        uint256 start = yzilp.lastPoolUpdateTimestamp();
        vm.warp(start + 100 days);

        uint256 accruedManagement = yzilp.accruedManagementFee();
        uint256 accruedPerformance = yzilp.accruedPerformanceFee();
        assertGt(accruedPerformance, 0, "fixture: benchmark not crossed");

        _reportPool(yzilp.grossTotalAssets());

        assertEq(yzilp.cumulativeManagementFees(), accruedManagement, "management booking diverges from getter");
        assertEq(yzilp.cumulativePerformanceFees(), accruedPerformance, "performance booking diverges from getter");
    }

    // Freshly updated and empty states accrue nothing; below the benchmark the performance
    // getter reads zero while the management getter accrues.
    function test_AccruedFeeGetters_ZeroOnFreshEmptyAndBelowBenchmarkStates() public {
        _setupBothFees(0);

        assertEq(yzilp.grossTotalAssets(), 1000e6);
        assertEq(yzilp.accruedManagementFee(), 0);
        assertEq(yzilp.accruedPerformanceFee(), 0);

        uint256 start = yzilp.lastPoolUpdateTimestamp();
        vm.warp(start + 365 days);
        assertEq(yzilp.accruedManagementFee(), 100e6);
        assertEq(yzilp.accruedPerformanceFee(), 0, "performance accrued below the benchmark");

        // The mark realizes exactly the accrued fee, leaving an empty pool that accrues nothing
        _reportPool(100e6);
        assertEq(yzilp.grossTotalAssets(), 0);
        vm.warp(start + 730 days);
        assertEq(yzilp.accruedManagementFee(), 0);
        assertEq(yzilp.accruedPerformanceFee(), 0);
    }

    // A dust pool consumed by its accrued fee reads as clamped: the fee getter covers the pool
    // and pricing floors at zero.
    function test_AccruedFeeGetters_DustPoolClampsPricingToZero() public {
        _setupPool();
        vm.prank(feeManager);
        yzilp.setPendingManagementFee(100_000);
        _promote(0);
        _reportPool(1);

        uint256 start = yzilp.lastPoolUpdateTimestamp();
        vm.warp(start + 365 days);

        assertEq(yzilp.grossTotalAssets(), 1);
        assertEq(yzilp.accruedManagementFee(), 1);
        assertEq(yzilp.totalAssets(), 0, "fee-consumed dust pool priced above zero");
    }
}
