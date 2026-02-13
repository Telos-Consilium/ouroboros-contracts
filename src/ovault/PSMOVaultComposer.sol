// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {IPSM} from "../interfaces/IPSM.sol";

import {ProtoOVaultComposer} from "./ProtoOVaultComposer.sol";

/**
 * @title PSMOVaultComposer
 * @notice Cross-chain vault composer enabling omnichain PSM operations via LayerZero
 */
contract PSMOVaultComposer is ProtoOVaultComposer {
    using SafeERC20 for IERC20;

    bytes32 private constant PSM_USER_ROLE = keccak256("USER_ROLE");

    /**
     * @notice Creates a new cross-chain PSM composer
     * @dev Initializes the composer with PSM and OFT contracts for omnichain operations
     * @param _vault The PSM contract implementing the relevant subset of ERC4626 for deposit/redeem operations
     * @param _assetOFT The OFT contract for cross-chain asset transfers
     * @param _shareOFT The OFT contract for cross-chain share transfers
     */
    constructor(address _vault, address _assetOFT, address _shareOFT)
        ProtoOVaultComposer(_vault, _assetOFT, _shareOFT)
    {}

    function _depositRequiredRole() internal pure virtual override returns (bytes32) {
        return PSM_USER_ROLE;
    }

    function _redeemRequiredRole() internal pure virtual override returns (bytes32) {
        return PSM_USER_ROLE;
    }

    /**
     * @dev Override to support a decoupled share token
     * @return shareERC20 The address of the share ERC20 token
     * @dev requirement Share token must match VAULT.vault1()
     * @dev requirement Share OFT must be an adapter (approvalRequired() returns true)
     */
    function _initializeShareToken() internal virtual override returns (address shareERC20) {
        shareERC20 = IOFT(SHARE_OFT).token();

        address vault1 = IPSM(address(VAULT)).vault1();
        if (shareERC20 != vault1) {
            revert ShareTokenNotVault(shareERC20, vault1);
        }

        if (!IOFT(SHARE_OFT).approvalRequired()) revert ShareOFTNotAdapter(SHARE_OFT);

        IERC20(shareERC20).forceApprove(SHARE_OFT, type(uint256).max);
    }
}
