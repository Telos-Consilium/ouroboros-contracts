// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {YuzuMinAmounts} from "../src/proto/YuzuMinAmounts.sol";
import {YuzuThrottle} from "../src/proto/YuzuThrottle.sol";
import {YuzuV3RestrictedShares} from "../src/libraries/YuzuV3RestrictedShares.sol";
import {
    YuzuILPDistributionV3Storage,
    YuzuILPFeesV3Storage,
    YuzuMinAmountsV3Storage,
    YuzuNavMarkdownV3Storage,
    YuzuRestrictedSharesV3Storage,
    YuzuThrottleV3Storage
} from "../src/storage/YuzuV3Storage.sol";
import {LIMIT_MANAGER_ROLE, REDEEM_MANAGER_ROLE} from "./helpers/TestRoles.sol";
import {YuzuV3TestBase} from "./helpers/YuzuV3TestBase.sol";

/// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))
function _erc7201(string memory id) pure returns (bytes32) {
    return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
}

contract MinAmountsHarness is YuzuMinAmounts {}

contract ThrottleHarness is YuzuThrottle {}

contract RestrictedSharesHarness {
    function currentBlockRestrictedBalance(address account) external view returns (uint256) {
        return YuzuV3RestrictedShares.currentBlockRestrictedBalance(account);
    }
}

/// @notice Pins every V3 ERC-7201 storage location to the value derived from its namespace string. Each
/// location is hardcoded independently in the proto mixin (private) and the YuzuV3Storage library
/// (internal); if the two drift, a namespace splits across two slots and state silently corrupts. Part one
/// anchors each library constant to the canonical formula; part two proves each mixin resolves the same
/// namespace to that same slot. Complements YuzuILPV3FacetStorageLayout, which pins the raw sequential slots.
contract YuzuV3StorageLayoutTest is Test {
    // Library locations match their namespace string

    function test_Location_MinAmounts() public pure {
        assertEq(YuzuMinAmountsV3Storage.LOCATION, _erc7201("yuzu.storage.minamounts"));
    }

    function test_Location_Throttle() public pure {
        assertEq(YuzuThrottleV3Storage.LOCATION, _erc7201("yuzu.storage.throttle"));
    }

    function test_Location_RestrictedShares() public pure {
        assertEq(YuzuRestrictedSharesV3Storage.LOCATION, _erc7201("yuzu.storage.restrictedshares"));
    }

    function test_Location_NavMarkdown() public pure {
        assertEq(YuzuNavMarkdownV3Storage.LOCATION, _erc7201("yuzu.storage.navmarkdown"));
    }

    function test_Location_IlpFees() public pure {
        assertEq(YuzuILPFeesV3Storage.LOCATION, _erc7201("yuzu.storage.ilpfees"));
    }

    function test_Location_IlpDistribution() public pure {
        assertEq(YuzuILPDistributionV3Storage.LOCATION, _erc7201("yuzu.storage.ilpdistribution"));
    }

    // Proto mixins resolve the same namespace to the library slot. The mixin location is a private constant,
    // so it is observed by storing at the library slot and reading back through the mixin getter.

    function test_MixinMatchesLibrary_MinAmounts() public {
        MinAmountsHarness h = new MinAmountsHarness();
        bytes32 base = YuzuMinAmountsV3Storage.LOCATION;
        vm.store(address(h), base, bytes32(uint256(111)));
        vm.store(address(h), bytes32(uint256(base) + 1), bytes32(uint256(222)));
        assertEq(h.minDeposit(), 111, "minDeposit at base slot");
        assertEq(h.minWithdraw(), 222, "minWithdraw at base + 1");
    }

    function test_MixinMatchesLibrary_Throttle() public {
        ThrottleHarness h = new ThrottleHarness();
        bytes32 base = YuzuThrottleV3Storage.LOCATION;
        // blockLimit is the first field of Throttle; _mintThrottle starts at base, _redeemThrottle six slots later.
        vm.store(address(h), base, bytes32(uint256(333)));
        vm.store(address(h), bytes32(uint256(base) + 6), bytes32(uint256(444)));
        assertEq(h.getMintThrottle().blockLimit, 333, "mint throttle at base slot");
        assertEq(h.getRedeemThrottle().blockLimit, 444, "redeem throttle at base + 6");
    }

    function test_RestrictedShares_RecordLayout() public {
        RestrictedSharesHarness h = new RestrictedSharesHarness();
        address who = address(0xA11CE);
        bytes32 elem = keccak256(abi.encode(who, YuzuRestrictedSharesV3Storage.LOCATION));
        // Restriction.blockNumber at the element base slot, Restriction.amount at base + 1.
        vm.store(address(h), elem, bytes32(block.number));
        vm.store(address(h), bytes32(uint256(elem) + 1), bytes32(uint256(1234)));
        assertEq(h.currentBlockRestrictedBalance(who), 1234, "amount at record base + 1 for the current block");

        // A record stored for a past block reads as zero.
        vm.store(address(h), elem, bytes32(uint256(block.number) - 1));
        assertEq(h.currentBlockRestrictedBalance(who), 0, "stale record reads zero");
    }
}

/// @notice Pins the issuer and orderbook ERC-7201 namespaces, which YuzuILPV3Facet hardcodes as its own
/// private copies of the proto-base (YuzuIssuer/YuzuOrderBook) locations and reaches under delegatecall. The
/// base and facet run on the same proxy, so a drift between the two copies corrupts a live vault outright.
/// The base copy is anchored to the formula by storing at the computed slot and reading a base getter; the
/// facet copy is proven equal to the base by writing through a facet setter and reading it back through the
/// base getter.
contract YuzuV3IssuerOrderBookLayoutTest is YuzuV3TestBase {
    function setUp() public {
        asset = _newAsset();
        yzilp = _deployYuzuILPV3(address(asset), "Token", "TKN", false);
        yzusd = _deployYuzuUSDV3(address(asset));

        vm.startPrank(admin);
        yzilp.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        yzilp.grantRole(REDEEM_MANAGER_ROLE, redeemManager);
        yzusd.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        yzusd.grantRole(REDEEM_MANAGER_ROLE, redeemManager);
        vm.stopPrank();
    }

    // issuer: _supplyCap (field 0), _liquidityBufferTargetSize (field 1)

    function test_IssuerLocation_BaseMatchesFormula() public {
        bytes32 base = _erc7201("yuzu.storage.issuer");
        vm.store(address(yzilp), base, bytes32(uint256(111)));
        vm.store(address(yzilp), bytes32(uint256(base) + 1), bytes32(uint256(222)));
        assertEq(yzilp.cap(), 111, "supplyCap at issuer base slot");
        assertEq(yzilp.liquidityBufferTargetSize(), 222, "liquidityBufferTargetSize at base + 1");
    }

    function test_IssuerLocation_FacetMatchesBase() public {
        vm.prank(limitManager);
        yzilp.setSupplyCap(777);
        assertEq(yzilp.cap(), 777, "facet setSupplyCap visible through base getter");
    }

    // orderbook: _fillWindow (field 0), _totalPendingOrderSize (field 1),
    // _totalUnfinalizedOrderValue (field 2), _orderCount (field 3), _minRedeemOrder (field 4),
    // _orders mapping (field 5)

    function test_OrderBookLocation_BaseMatchesFormula() public {
        bytes32 base = _erc7201("yuzu.storage.orderbook");
        vm.store(address(yzilp), base, bytes32(uint256(123)));
        vm.store(address(yzilp), bytes32(uint256(base) + 1), bytes32(uint256(456)));
        vm.store(address(yzilp), bytes32(uint256(base) + 2), bytes32(uint256(789)));
        vm.store(address(yzilp), bytes32(uint256(base) + 3), bytes32(uint256(9)));
        vm.store(address(yzilp), bytes32(uint256(base) + 4), bytes32(uint256(55)));
        assertEq(yzilp.fillWindow(), 123, "fillWindow at orderbook base slot");
        assertEq(yzilp.totalPendingOrderSize(), 456, "totalPendingOrderSize at base + 1");
        assertEq(yzilp.totalUnfinalizedOrderValue(), 789, "totalUnfinalizedOrderValue at base + 2");
        assertEq(yzilp.orderCount(), 9, "orderCount at base + 3");
        assertEq(yzilp.minRedeemOrder(), 55, "minRedeemOrder at base + 4");
    }

    function test_OrderBookLocation_FacetMatchesBase() public {
        vm.prank(redeemManager);
        yzilp.setFillWindow(3600);
        assertEq(yzilp.fillWindow(), 3600, "facet setFillWindow visible through base getter");

        vm.prank(limitManager);
        yzilp.setMinRedeemOrder(42);
        assertEq(yzilp.minRedeemOrder(), 42, "facet setMinRedeemOrder visible through base getter");
    }

    // The facet's fillRedeemOrder reads orders from its private copy of the _orders mapping at field 5.
    // Pin that slot to the formula so a shift is caught here rather than by an OrderNotPending revert.
    function test_OrderBookLocation_OrdersMappingBaseSlot() public {
        bytes32 base = _erc7201("yuzu.storage.orderbook");
        uint256 orderId = 7;
        bytes32 elementSlot = keccak256(abi.encode(orderId, uint256(base) + 5));
        // Order.assets is the first field of the struct, so it sits at the element base slot.
        vm.store(address(yzilp), elementSlot, bytes32(uint256(4242)));
        assertEq(yzilp.getRedeemOrder(orderId).assets, 4242, "order.assets at orders mapping base + 5");
    }

    // yzUSD twins: the shared facet base replicates the same orderbook layout for both vaults, so the
    // pins must hold against the yzUSD proxy as well.

    function test_OrderBookLocation_BaseMatchesFormula_YzUSD() public {
        bytes32 base = _erc7201("yuzu.storage.orderbook");
        vm.store(address(yzusd), base, bytes32(uint256(123)));
        vm.store(address(yzusd), bytes32(uint256(base) + 1), bytes32(uint256(456)));
        vm.store(address(yzusd), bytes32(uint256(base) + 2), bytes32(uint256(789)));
        vm.store(address(yzusd), bytes32(uint256(base) + 3), bytes32(uint256(9)));
        vm.store(address(yzusd), bytes32(uint256(base) + 4), bytes32(uint256(55)));
        assertEq(yzusd.fillWindow(), 123, "fillWindow at orderbook base slot");
        assertEq(yzusd.totalPendingOrderSize(), 456, "totalPendingOrderSize at base + 1");
        assertEq(yzusd.totalUnfinalizedOrderValue(), 789, "totalUnfinalizedOrderValue at base + 2");
        assertEq(yzusd.orderCount(), 9, "orderCount at base + 3");
        assertEq(yzusd.minRedeemOrder(), 55, "minRedeemOrder at base + 4");
    }

    function test_OrderBookLocation_FacetMatchesBase_YzUSD() public {
        vm.prank(redeemManager);
        yzusd.setFillWindow(3600);
        assertEq(yzusd.fillWindow(), 3600, "facet setFillWindow visible through base getter");

        vm.prank(limitManager);
        yzusd.setMinRedeemOrder(42);
        assertEq(yzusd.minRedeemOrder(), 42, "facet setMinRedeemOrder visible through base getter");
    }

    function test_OrderBookLocation_OrdersMappingBaseSlot_YzUSD() public {
        bytes32 base = _erc7201("yuzu.storage.orderbook");
        uint256 orderId = 7;
        bytes32 elementSlot = keccak256(abi.encode(orderId, uint256(base) + 5));
        vm.store(address(yzusd), elementSlot, bytes32(uint256(4242)));
        assertEq(yzusd.getRedeemOrder(orderId).assets, 4242, "order.assets at orders mapping base + 5");
    }
}

/// @notice Pins the field offsets of the ilpfees namespace through the router getters. The router
/// and, under delegatecall, the facet both address these fields by their position in the Layout
/// struct, so inserting or reordering fields shifts every later slot and fails here. New fields
/// must be appended and extend this pin.
contract YuzuV3IlpFeesLayoutTest is YuzuV3TestBase {
    function setUp() public {
        asset = _newAsset();
        yzilp = _deployYuzuILPV3(address(asset), "Token", "TKN", false);
    }

    function test_IlpFeesLayout_FieldOffsets() public {
        bytes32 base = YuzuILPFeesV3Storage.LOCATION;
        for (uint256 i = 0; i < 9; i++) {
            vm.store(address(yzilp), bytes32(uint256(base) + i), bytes32(i + 1));
        }
        assertEq(yzilp.mintFeePpm(), 1, "_mintFeePpm at base");
        assertEq(yzilp.managementFeeRatePpm(), 2, "_managementFeeRatePpm at base + 1");
        assertEq(yzilp.cumulativeManagementFees(), 3, "_cumulativeManagementFees at base + 2");
        assertEq(yzilp.pendingManagementFeeRatePpm(), 4, "_pendingManagementFeeRatePpm at base + 3");
        assertEq(yzilp.performanceFeeRatePpm(), 5, "_performanceFeeRatePpm at base + 4");
        assertEq(yzilp.pendingPerformanceFeeRatePpm(), 6, "_pendingPerformanceFeeRatePpm at base + 5");
        assertEq(yzilp.highWaterMark(), 7, "_highWaterMark at base + 6");
        assertEq(yzilp.cumulativePerformanceFees(), 8, "_cumulativePerformanceFees at base + 7");
        assertEq(yzilp.creditSecondsSinceUpdate(), 9, "_creditSecondsSinceUpdate at base + 8");
    }

    function test_IlpDistributionLayout_FieldOffsets() public {
        bytes32 base = YuzuILPDistributionV3Storage.LOCATION;
        vm.store(address(yzilp), base, bytes32(uint256(11)));
        vm.store(address(yzilp), bytes32(uint256(base) + 1), bytes32(uint256(22)));
        assertEq(yzilp.minDistributionPeriod(), 11, "_minDistributionPeriod at base");
        assertEq(yzilp.maxDistributionPpm(), 22, "_maxDistributionPpm at base + 1");
    }
}
