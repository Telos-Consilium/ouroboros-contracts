// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

import {YuzuILPV3} from "./YuzuILPV3.sol";
import {IYuzuILPV3Definitions} from "./interfaces/IYuzuILPDefinitions.sol";

/**
 * @title YuzuILPV3Factory
 * @notice Deploys YuzuILPV3 transparent proxies at deterministic addresses
 * @dev The proxy address depends only on this factory address and the salt.
 */
contract YuzuILPV3Factory is AccessControl {
    bytes32 internal constant DEPLOYER_ROLE = keccak256("DEPLOYER_ROLE");

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
     * @param initParams Arguments forwarded to {YuzuILPV3-initializeV3}
     * @param configParams V3 configuration applied atomically at deploy
     * @return proxy The deployed proxy address
     */
    function deploy(
        bytes32 salt,
        address implementation,
        address proxyAdminOwner,
        IYuzuILPV3Definitions.InitParams calldata initParams,
        IYuzuILPV3Definitions.ConfigParams calldata configParams
    ) external onlyRole(DEPLOYER_ROLE) returns (address proxy) {
        if (implementation == address(0) || proxyAdminOwner == address(0)) {
            revert InvalidZeroAddress();
        }

        // slither-disable-next-line too-many-digits
        bytes memory initCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(
                implementation, proxyAdminOwner, abi.encodeCall(YuzuILPV3.initializeV3, (initParams, configParams))
            )
        );
        proxy = CREATE3.deployDeterministic(initCode, salt);

        // slither-disable-next-line reentrancy-events
        emit DeployedYuzuILPV3(proxy, salt, implementation, proxyAdminOwner);
    }

    /// @notice Address produced by a salt for this factory
    function predictAddress(bytes32 salt) external view returns (address) {
        return CREATE3.predictDeterministicAddress(salt);
    }
}
