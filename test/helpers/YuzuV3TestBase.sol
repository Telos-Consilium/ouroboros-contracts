// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {YuzuUSD} from "../../src/YuzuUSD.sol";
import {YuzuUSDV2} from "../../src/YuzuUSDV2.sol";
import {YuzuUSDV3} from "../../src/YuzuUSDV3.sol";
import {YuzuUSDV3Facet} from "../../src/YuzuUSDV3Facet.sol";
import {YuzuILP} from "../../src/YuzuILP.sol";
import {YuzuILPV2} from "../../src/YuzuILPV2.sol";
import {YuzuILPV3} from "../../src/YuzuILPV3.sol";
import {YuzuILPV3Facet} from "../../src/YuzuILPV3Facet.sol";

contract YuzuV3USDT0Mock is ERC20Mock {
    function decimals() public pure virtual override returns (uint8) {
        return 6;
    }
}

abstract contract YuzuV3TestBase is Test {
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant LIMIT_MANAGER_ROLE = keccak256("LIMIT_MANAGER_ROLE");
    bytes32 internal constant REDEEM_MANAGER_ROLE = keccak256("REDEEM_MANAGER_ROLE");
    bytes32 internal constant THROTTLE_EXEMPT_ROLE = keccak256("THROTTLE_EXEMPT_ROLE");
    bytes32 internal constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 internal constant POOL_MANAGER_ROLE = keccak256("POOL_MANAGER_ROLE");
    bytes32 internal constant ORDER_FILLER_ROLE = keccak256("ORDER_FILLER_ROLE");
    bytes32 internal constant NAV_MANAGER_ROLE = keccak256("NAV_MANAGER_ROLE");

    YuzuV3USDT0Mock internal asset;
    YuzuUSDV3 internal yzusd;
    YuzuILPV3 internal yzilp;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal feeReceiver = makeAddr("feeReceiver");
    address internal limitManager = makeAddr("limitManager");
    address internal redeemManager = makeAddr("redeemManager");
    address internal feeManager = makeAddr("feeManager");
    address internal poolManager = makeAddr("poolManager");
    address internal navManager = makeAddr("navManager");
    address internal filler = makeAddr("filler");
    address internal user = makeAddr("user");
    address internal other = makeAddr("other");
    address internal exempt = makeAddr("exempt");

    function _newAsset() internal virtual returns (YuzuV3USDT0Mock) {
        return new YuzuV3USDT0Mock();
    }

    function _deployYuzuUSDV3() internal returns (YuzuUSDV3) {
        return _deployYuzuUSDV3(address(asset), "Token", "TKN", true);
    }

    function _deployYuzuUSDV3(address asset_) internal returns (YuzuUSDV3) {
        return _deployYuzuUSDV3(asset_, "Token", "TKN", true);
    }

    function _deployYuzuUSDV3(address asset_, string memory name, string memory symbol, bool runV2Reinitializer)
        internal
        returns (YuzuUSDV3 deployed)
    {
        address impl = address(new YuzuUSDV3(address(new YuzuUSDV3Facet())));
        bytes memory initData = abi.encodeWithSelector(
            YuzuUSD.initialize.selector,
            asset_,
            name,
            symbol,
            admin,
            treasury,
            feeReceiver,
            type(uint256).max,
            1 days,
            0
        );
        address proxy = address(new ERC1967Proxy(impl, initData));
        deployed = YuzuUSDV3(proxy);
        if (runV2Reinitializer) {
            YuzuUSDV2(proxy).reinitialize();
        }
        deployed.reinitializeV3();
    }

    function _deployYuzuILPV3() internal returns (YuzuILPV3) {
        return _deployYuzuILPV3(address(asset), "Token", "TKN", true);
    }

    function _deployYuzuILPV3(address asset_) internal returns (YuzuILPV3) {
        return _deployYuzuILPV3(asset_, "Token", "TKN", true);
    }

    function _deployYuzuILPV3(address asset_, string memory name, string memory symbol, bool runV2Reinitializer)
        internal
        returns (YuzuILPV3 deployed)
    {
        address impl = address(new YuzuILPV3(address(new YuzuILPV3Facet())));
        bytes memory initData = abi.encodeWithSelector(
            YuzuILP.initialize.selector,
            asset_,
            name,
            symbol,
            admin,
            treasury,
            feeReceiver,
            type(uint256).max,
            1 days,
            0
        );
        address proxy = address(new ERC1967Proxy(impl, initData));
        deployed = YuzuILPV3(proxy);
        if (runV2Reinitializer) {
            YuzuILPV2(proxy).reinitialize();
        }
        deployed.reinitializeV3();
    }

    function _approve(address owner, address spender) internal {
        vm.prank(owner);
        asset.approve(spender, type(uint256).max);
    }

    function _setupIlpPool(uint256 amount) internal {
        vm.prank(user);
        yzilp.deposit(amount, user);
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(amount, amount, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();
    }

    function _promoteIlpFees(uint256 yieldPpm) internal {
        uint256 poolSize = yzilp.poolSize();
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(poolSize, poolSize, yieldPpm);
        yzilp.endPoolUpdate();
        vm.stopPrank();
    }

    function _reportIlpPool(uint256 newPoolSize) internal {
        uint256 poolSize = yzilp.poolSize();
        vm.startPrank(admin);
        yzilp.startPoolUpdate();
        yzilp.updatePool(poolSize, newPoolSize, 0);
        yzilp.endPoolUpdate();
        vm.stopPrank();
    }
}
