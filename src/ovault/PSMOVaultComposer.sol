// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {VaultComposerSync} from "@layerzerolabs/ovault-evm/contracts/VaultComposerSync.sol";
import {IOFT} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import {IPSM} from "../interfaces/IPSM.sol";

/**
 * @title PSMOVaultComposer
 * @notice Cross-chain vault composer enabling omnichain vault operations via LayerZero
 */
contract PSMOVaultComposer is VaultComposerSync {
    using SafeERC20 for IERC20;

    /**
     * @notice Creates a new cross-chain vault composer
     * @dev Initializes the composer with vault and OFT contracts for omnichain operations
     * @param _vault The vault contract implementing ERC4626 for deposit/redeem operations
     * @param _assetOFT The OFT contract for cross-chain asset transfers
     * @param _shareOFT The OFT contract for cross-chain share transfers
     */
    constructor(address _vault, address _assetOFT, address _shareOFT) VaultComposerSync(_vault, _assetOFT, _shareOFT) {}

    /**
     * @dev Override to support decoupled share token (e.g., PSM.vault1()).
     * @return shareERC20 The address of the share ERC20 token
     * @dev requirement Share token must be the VAULT.vault1()
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
