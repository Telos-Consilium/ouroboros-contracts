// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {VaultComposerSync} from "@layerzerolabs/ovault-evm/contracts/VaultComposerSync.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/**
 * @title ProtoOVaultComposer
 * @notice Cross-chain vault composer enabling omnichain vault operations via LayerZero
 */
contract ProtoOVaultComposer is VaultComposerSync {
    bytes32 private constant PROTO_MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 private constant PROTO_REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    /**
     * @notice Creates a new cross-chain vault composer
     * @dev Initializes the composer with vault and OFT contracts for omnichain operations
     * @param _vault The vault contract implementing ERC4626 for deposit/redeem operations
     * @param _assetOFT The OFT contract for cross-chain asset transfers
     * @param _shareOFT The OFT contract for cross-chain share transfers
     */
    constructor(address _vault, address _assetOFT, address _shareOFT) VaultComposerSync(_vault, _assetOFT, _shareOFT) {}

    function _depositRequiredRole() internal pure virtual returns (bytes32) {
        return PROTO_MINTER_ROLE;
    }

    function _redeemRequiredRole() internal pure virtual returns (bytes32) {
        return PROTO_REDEEMER_ROLE;
    }

    /// @inheritdoc VaultComposerSync
    function _depositAndSend(
        bytes32 _depositor,
        uint256 _assetAmount,
        SendParam memory _sendParam,
        address _refundAddress,
        uint256 _msgValue
    ) internal virtual override {
        address receiverAddr = address(SafeCast.toUint160(uint256(_sendParam.to)));
        if (!IAccessControl(address(VAULT)).hasRole(_depositRequiredRole(), receiverAddr)) {
            revert ERC4626.ERC4626ExceededMaxDeposit(receiverAddr, _assetAmount, 0);
        }
        super._depositAndSend(_depositor, _assetAmount, _sendParam, _refundAddress, _msgValue);
    }

    /// @inheritdoc VaultComposerSync
    function _redeemAndSend(
        bytes32 _redeemer,
        uint256 _shareAmount,
        SendParam memory _sendParam,
        address _refundAddress,
        uint256 _msgValue
    ) internal virtual override {
        address redeemerAddr = address(SafeCast.toUint160(uint256(_redeemer)));
        if (!IAccessControl(address(VAULT)).hasRole(_redeemRequiredRole(), redeemerAddr)) {
            revert ERC4626.ERC4626ExceededMaxRedeem(redeemerAddr, _shareAmount, 0);
        }
        super._redeemAndSend(_redeemer, _shareAmount, _sendParam, _refundAddress, _msgValue);
    }
}
