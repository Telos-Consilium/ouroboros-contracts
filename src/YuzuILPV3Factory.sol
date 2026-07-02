// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

import {YuzuILP} from "./YuzuILP.sol";
import {YuzuILPV3} from "./YuzuILPV3.sol";

/**
 * @title YuzuILPV3Factory
 * @notice Deploys YuzuILPV3 transparent proxies at deterministic addresses
 * @dev Proxies are deployed via CREATE3, so a proxy address depends only on this
 * factory's address and the salt. When the factory itself is deployed at the same
 * address on multiple chains, the same salt yields the same proxy address on every
 * chain with standard CREATE and CREATE2 address derivation, regardless of the
 * implementation address or initialization arguments used there. Initialization
 * runs inside the proxy constructor and the V3 reinitializer
 * is invoked in the same transaction, so a proxy is never observable in a partially
 * initialized state.
 */
contract YuzuILPV3Factory is AccessControl {
    bytes32 public constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

    /// @notice Arguments forwarded to {YuzuILP-initialize}
    /// @dev The admin receives DEFAULT_ADMIN_ROLE and ADMIN_ROLE directly; the
    /// factory itself never holds any role on the deployed vault
    struct InitParams {
        address asset;
        string name;
        string symbol;
        address admin;
        address treasury;
        address feeReceiver;
        uint256 supplyCap;
        uint256 fillWindow;
        uint256 minRedeemOrder;
    }

    event DeployedYuzuILPV3(
        address indexed proxy, bytes32 indexed salt, address indexed implementation, address proxyAdminOwner
    );

    error InvalidZeroAddress();

    constructor(address rootAdmin) {
        if (rootAdmin == address(0)) {
            revert InvalidZeroAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, rootAdmin);
    }

    /**
     * @notice Deploys and fully initializes a YuzuILPV3 proxy at a deterministic address
     * @param salt Determines the proxy address together with this factory's address;
     * a salt can be used at most once per factory deployment
     * @param implementation The YuzuILPV3 implementation to back the proxy
     * @param proxyAdminOwner Owner of the ProxyAdmin created by the proxy constructor
     * @param params Arguments forwarded to {YuzuILP-initialize}
     * @return proxy The deployed proxy address
     */
    function deploy(bytes32 salt, address implementation, address proxyAdminOwner, InitParams calldata params)
        external
        onlyRole(DEPLOYER_ROLE)
        returns (address proxy)
    {
        if (implementation == address(0) || proxyAdminOwner == address(0)) {
            revert InvalidZeroAddress();
        }

        // slither-disable-next-line too-many-digits
        bytes memory initCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                implementation,
                proxyAdminOwner,
                abi.encodeCall(
                    YuzuILP.initialize,
                    (
                        params.asset,
                        params.name,
                        params.symbol,
                        params.admin,
                        params.treasury,
                        params.feeReceiver,
                        params.supplyCap,
                        params.fillWindow,
                        params.minRedeemOrder
                    )
                )
            )
        );
        proxy = CREATE3.deployDeterministic(initCode, salt);
        YuzuILPV3(proxy).reinitialize();

        // slither-disable-next-line reentrancy-events
        emit DeployedYuzuILPV3(proxy, salt, implementation, proxyAdminOwner);
    }

    /// @notice Address a given salt will produce, on any chain where this factory
    /// is deployed at its own current address
    function predictAddress(bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt);
    }
}
