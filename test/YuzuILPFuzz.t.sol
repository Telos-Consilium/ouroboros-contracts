import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {YuzuILP} from "../src/YuzuILP.sol";
import {Order} from "../src/YuzuILP.sol";

struct ContractState {
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 poolSize;
    uint256 userShares;
}

contract YuzuILPFuzz is Test {
    YuzuILP public ilp;
    ERC20Mock public asset;
    address public admin;
    address public treasury;
    address public limitManager;
    address public orderFiller;
    address public poolManager;
    address public user1;
    address public user2;

    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 private constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 private constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");

    ContractState private stateBefore;
    ContractState private stateAfter;

    function setUp() public {
        admin = makeAddr("admin");
        treasury = makeAddr("treasury");
        limitManager = makeAddr("limitManager");
        orderFiller = makeAddr("orderFiller");
        poolManager = makeAddr("poolManager");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock asset
        asset = new ERC20Mock();

        // Mint assets to users
        asset.mint(user1, 10_000e18);
        asset.mint(user2, 10_000e18);
        asset.mint(orderFiller, 10_000e18);

        // Deploy YuzuILP
        vm.prank(admin);
        ilp = new YuzuILP(IERC20(address(asset)), admin, treasury, type(uint256).max);

        // Set up roles
        vm.startPrank(admin);
        ilp.grantRole(LIMIT_MANAGER_ROLE, limitManager);
        ilp.grantRole(ORDER_FILLER_ROLE, orderFiller);
        ilp.grantRole(POOL_MANAGER_ROLE, poolManager);
        ilp.setTreasury(treasury);
        vm.stopPrank();
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_Deposit_AnyYield(
        uint256 initialShareSupply,
        uint256 initialPoolSize,
        uint256 dailyLinearYieldRatePpm,
        uint256 elapsedTime,
        uint256 assets
    ) public {
        initialShareSupply = bound(initialShareSupply, 1e17, 1_000e18);
        initialPoolSize = bound(initialPoolSize, 1e17, 1_000e18);
        dailyLinearYieldRatePpm = bound(dailyLinearYieldRatePpm, 1, 1e6);
        elapsedTime = bound(elapsedTime, 1, 7 days);
        assets = bound(assets, 1e17, 1_000e18);

        _testDeposit(initialShareSupply, initialPoolSize, dailyLinearYieldRatePpm, elapsedTime, assets);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_Deposit_NoYield(
        uint256 initialShareSupply,
        uint256 initialPoolSize,
        uint256 elapsedTime,
        uint256 assets
    ) public {
        initialShareSupply = bound(initialShareSupply, 1e17, 1_000e18);
        initialPoolSize = bound(initialPoolSize, 1e17, 1_000e18);
        elapsedTime = bound(elapsedTime, 1, 7 days);
        assets = bound(assets, 1e17, 1_000e18);

        _testDeposit(initialShareSupply, initialPoolSize, 0, elapsedTime, assets);

        // Total assets should equal pool size before and after the deposit
        assertEq(stateBefore.totalAssets, stateBefore.poolSize);
        assertEq(stateAfter.totalAssets, stateAfter.poolSize);

        // Total assets should be exactly equal to the initial pool size plus the assets deposited
        assertEq(stateAfter.totalAssets, stateBefore.poolSize + assets);

        // Redeeming the shares should return the assets deposited
        assertApproxEqRel(ilp.previewRedeem(stateAfter.userShares), assets, 1e6);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_Deposit_RealisticYield(
        uint256 initialShareSupply,
        uint256 initialPoolSize,
        uint256 dailyLinearYieldRatePpm,
        uint256 elapsedTime,
        uint256 assets
    ) public {
        initialShareSupply = bound(initialShareSupply, 1e17, 1_000e18);
        initialPoolSize = bound(initialPoolSize, 1e17, 1_000e18);
        dailyLinearYieldRatePpm = bound(dailyLinearYieldRatePpm, 1, 12_500); // 1.25% daily yield, 9000 APY%
        elapsedTime = bound(elapsedTime, 1, 1 days);
        assets = bound(assets, 1e17, 1_000e18);

        _testDeposit(initialShareSupply, initialPoolSize, dailyLinearYieldRatePpm, elapsedTime, assets);

        // Redeeming the shares should return the assets deposited minus the yield accrued since the last update
        uint256 assetsExclYield =
            Math.mulDiv(stateAfter.userShares, stateAfter.poolSize, stateAfter.totalSupply, Math.Rounding.Floor);
        uint256 redeemableAssets = ilp.previewRedeem(stateAfter.userShares);
        assertLe(redeemableAssets, assetsExclYield);
        assertApproxEqRel(redeemableAssets, assetsExclYield, 1e6);

        uint256 linearYieldSharePriceE18 = ilp.previewMint(1e18);
        uint256 exponentialYieldSharePriceE18 =
            _calculateSharePriceFFI(stateAfter.poolSize, stateAfter.totalSupply, dailyLinearYieldRatePpm, elapsedTime);

        assertGe(linearYieldSharePriceE18, exponentialYieldSharePriceE18);
        assertApproxEqRel(linearYieldSharePriceE18, exponentialYieldSharePriceE18, 2e13); // Deviation under 0.002%
    }

    function test_Deposit_RealisticYieldWorstCase() public {
        uint256 initialShareSupply = 2_000e18;
        uint256 initialPoolSize = 10_000e18;

        uint256 assets = 1e18;
        uint256 dailyLinearYieldRatePpm = 12_500; // 1.25% daily yield, 9000 APY%
        uint256 elapsedTime = 1 days / 2;

        _testDeposit(initialShareSupply, initialPoolSize, dailyLinearYieldRatePpm, elapsedTime, assets);

        uint256 linearYieldSharePriceE18 = ilp.previewMint(1e18);
        uint256 exponentialYieldSharePriceE18 =
            _calculateSharePriceFFI(stateAfter.poolSize, stateAfter.totalSupply, dailyLinearYieldRatePpm, elapsedTime);

        assertGe(linearYieldSharePriceE18, exponentialYieldSharePriceE18);
        assertApproxEqRel(linearYieldSharePriceE18, exponentialYieldSharePriceE18, 2e13); // Deviation under 0.002%
    }

    function _testDeposit(
        uint256 initialShareSupply,
        uint256 initialPoolSize,
        uint256 dailyLinearYieldRatePpm,
        uint256 elapsedTime,
        uint256 assets
    ) public returns (uint256) {
        // Mint total shares
        vm.startPrank(user1);
        asset.approve(address(ilp), initialShareSupply);
        ilp.deposit(initialShareSupply, user1);
        vm.stopPrank();

        vm.prank(poolManager);
        ilp.updatePool(initialPoolSize, 0, dailyLinearYieldRatePpm);
        vm.warp(block.timestamp + elapsedTime);

        uint256 totalAssetsBefore = ilp.totalAssets();
        uint256 totalSupplyBefore = ilp.totalSupply();
        uint256 poolSizeBefore = ilp.poolSize();

        stateBefore = ContractState({
            totalAssets: totalAssetsBefore,
            totalSupply: totalSupplyBefore,
            poolSize: poolSizeBefore,
            userShares: 0
        });

        vm.startPrank(user2);
        asset.approve(address(ilp), assets);
        uint256 shares = ilp.deposit(assets, user2);
        vm.stopPrank();

        uint256 totalAssetsAfter = ilp.totalAssets();
        uint256 totalSupplyAfter = ilp.totalSupply();
        uint256 poolSizeAfter = ilp.poolSize();
        uint256 userSharesAfter = ilp.balanceOf(user2);

        stateAfter = ContractState({
            totalAssets: totalAssetsAfter,
            totalSupply: totalSupplyAfter,
            poolSize: poolSizeAfter,
            userShares: userSharesAfter
        });

        // Total supply should increase by the amount of shares minted
        assertEq(totalSupplyAfter, initialShareSupply + shares);
        // User should hold the shares minted
        assertEq(userSharesAfter, shares);
        // Withdraw allowance should increase by the amount deposited
        assertEq(ilp.withdrawAllowance(), assets);

        // Pool size should increase
        assertGt(poolSizeAfter, initialPoolSize);
        // Pool size should never exceed the initial pool size plus the assets deposited
        assertLe(poolSizeAfter, initialPoolSize + assets);

        // Total assets should increase by the amount deposited and never exceed the total assets before the deposit
        // plus the assets deposited
        assertLe(totalAssetsAfter, totalAssetsBefore + assets);
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore + assets, 1e6);

        // The ratio of shares minted to total supply should match and never exceed the ratio of assets deposited to total assets
        uint256 expectedShares = Math.mulDiv(totalSupplyBefore, assets, totalAssetsBefore, Math.Rounding.Floor);
        assertLe(shares, expectedShares);
        assertApproxEqRel(shares, expectedShares, 1e6);

        // Depositing the same amount of assets should mint the same number of shares than the previous deposit
        assertApproxEqRel(ilp.previewDeposit(assets), shares, 1e6);

        // Redeeming the shares should never return more than the assets deposited
        assertLe(ilp.previewRedeem(shares), assets);

        return shares;
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_CreateRedeemOrder_AnyYield(
        uint256 initialShareSupply,
        uint256 initialPoolSize,
        uint256 dailyLinearYieldRatePpm,
        uint256 elapsedTime,
        uint256 shares
    ) public {
        initialShareSupply = bound(initialShareSupply, 1e17, 1_000e18);
        initialPoolSize = bound(initialPoolSize, 1e17, 1_000e18);
        dailyLinearYieldRatePpm = bound(dailyLinearYieldRatePpm, 1, 1e6);
        elapsedTime = bound(elapsedTime, 1, 7 days);
        shares = bound(shares, 1e17, initialShareSupply);

        _testCreateRedeemOrder(initialShareSupply, initialPoolSize, dailyLinearYieldRatePpm, elapsedTime, shares);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_CreateRedeemOrder_NoYield(
        uint256 initialShareSupply,
        uint256 initialPoolSize,
        uint256 elapsedTime,
        uint256 shares
    ) public {
        initialShareSupply = bound(initialShareSupply, 1e17, 1_000e18);
        initialPoolSize = bound(initialPoolSize, 1e17, 1_000e18);
        elapsedTime = bound(elapsedTime, 1, 7 days);
        shares = bound(shares, 1e17, initialShareSupply);

        uint256 assets = _testCreateRedeemOrder(initialShareSupply, initialPoolSize, 0, elapsedTime, shares);

        // Total assets should equal pool size before and after the deposit
        assertEq(stateBefore.totalAssets, stateBefore.poolSize);
        assertEq(stateAfter.totalAssets, stateAfter.poolSize);

        assertEq(stateAfter.poolSize, stateBefore.poolSize - assets);
        assertEq(stateAfter.totalAssets, stateBefore.totalAssets - assets);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_CreateRedeemOrder_RealisticYield(
        uint256 initialShareSupply,
        uint256 initialPoolSize,
        uint256 dailyLinearYieldRatePpm,
        uint256 elapsedTime,
        uint256 shares
    ) public {
        initialShareSupply = bound(initialShareSupply, 1e17, 1_000e18);
        initialPoolSize = bound(initialPoolSize, 1e17, 1_000e18);
        dailyLinearYieldRatePpm = bound(dailyLinearYieldRatePpm, 1, 12_500); // 1.25% daily yield, 9000 APY%
        elapsedTime = bound(elapsedTime, 1, 1 days);
        shares = bound(shares, 1e17, initialShareSupply);

        _testCreateRedeemOrder(initialShareSupply, initialPoolSize, dailyLinearYieldRatePpm, elapsedTime, shares);

        uint256 linearYieldSharePriceE18 = ilp.previewMint(1e18);
        uint256 exponentialYieldSharePriceE18 =
            _calculateSharePriceFFI(stateAfter.poolSize, stateAfter.totalSupply, dailyLinearYieldRatePpm, elapsedTime);

        if (stateAfter.totalAssets > 1e6) {
            assertApproxEqRel(linearYieldSharePriceE18, exponentialYieldSharePriceE18, 2e13);
        } else if (stateAfter.totalAssets == 0) {
            assertEq(linearYieldSharePriceE18, exponentialYieldSharePriceE18);
        }
    }

    function _testCreateRedeemOrder(
        uint256 initialShareSupply,
        uint256 initialPoolSize,
        uint256 dailyLinearYieldRatePpm,
        uint256 elapsedTime,
        uint256 shares
    ) public returns (uint256) {
        // Mint total shares
        vm.startPrank(user1);
        asset.approve(address(ilp), initialShareSupply);
        ilp.deposit(initialShareSupply, user1);
        ilp.transfer(user2, shares);
        vm.stopPrank();

        vm.prank(poolManager);
        ilp.updatePool(initialPoolSize, initialPoolSize, dailyLinearYieldRatePpm);
        vm.warp(block.timestamp + elapsedTime);

        shares = Math.min(shares, ilp.maxRedeem(user2));

        uint256 totalAssetsBefore = ilp.totalAssets();
        uint256 totalSupplyBefore = ilp.totalSupply();
        uint256 poolSizeBefore = ilp.poolSize();
        uint256 userSharesBefore = ilp.balanceOf(user2);

        stateBefore = ContractState({
            totalAssets: totalAssetsBefore,
            totalSupply: totalSupplyBefore,
            poolSize: poolSizeBefore,
            userShares: userSharesBefore
        });

        vm.startPrank(user2);
        ilp.approve(address(ilp), shares);
        (, uint256 assets) = ilp.createRedeemOrder(shares);
        vm.stopPrank();

        uint256 totalAssetsAfter = ilp.totalAssets();
        uint256 totalSupplyAfter = ilp.totalSupply();
        uint256 poolSizeAfter = ilp.poolSize();
        uint256 userSharesAfter = ilp.balanceOf(user2);

        stateAfter = ContractState({
            totalAssets: totalAssetsAfter,
            totalSupply: totalSupplyAfter,
            poolSize: poolSizeAfter,
            userShares: userSharesAfter
        });

        assertEq(poolSizeAfter, initialPoolSize - assets);
        assertLe(totalAssetsAfter, totalAssetsBefore - assets);

        // Total supply should decrease by the amount of shares minted
        assertEq(totalSupplyAfter, initialShareSupply - shares);
        // Share should have been burned
        assertEq(userSharesAfter, userSharesBefore - shares);
        // Withdraw allowance should decrease by the amount withdrawn
        assertEq(ilp.withdrawAllowance(), initialPoolSize - assets);

        // Total assets should decrease by the amount redeemed and never exceed the total assets before the deposit
        // minus the assets withdrawn
        assertLe(totalAssetsAfter, totalAssetsBefore - assets);

        // The ratio of assets withdrawn to the poolSize should match and never exceed the ratio of shares redeemed to total supply
        uint256 expectedAssets = Math.mulDiv(poolSizeBefore, shares, totalSupplyBefore, Math.Rounding.Floor);
        assertLe(assets, expectedAssets);

        // Redeeming the same amount of shares should return the same amount of assets than the previous redeem
        if (totalAssetsAfter > 1e6) {
            assertApproxEqRel(ilp.previewRedeem(shares), assets, 1e6);
        } else if (totalAssetsAfter == 0) {
            assertEq(ilp.previewRedeem(shares), shares);
        }

        return assets;
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
        if (res.length != 32) revert("Invalid FFI output length");
        return abi.decode(res, (uint256));
    }
}
