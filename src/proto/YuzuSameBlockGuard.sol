// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuSameBlockGuardDefinitions} from "../interfaces/proto/IYuzuProtoDefinitions.sol";

/**
 * @title YuzuSameBlockGuard
 * @notice Same-block mint and redeem guard
 * @dev Uses ERC-7201 namespaced storage. Exempt accounts are not stamped or blocked.
 */
abstract contract YuzuSameBlockGuard is IYuzuSameBlockGuardDefinitions {
    struct YuzuSameBlockGuardStorage {
        mapping(address => uint256) _lastMintBlock;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.sameblockguard")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YuzuSameBlockGuardStorageLocation =
        0xaca45614502cdf54c71f9031d97993837104eaf27a6531196fcefc0ea3a7a400;

    /// @dev Exemption policy hook; the guard applies to every account unless overridden
    function _isSameBlockGuardExempt(address) internal view virtual returns (bool) {
        return false;
    }

    function lastMintBlock(address account) external view returns (uint256) {
        return _getYuzuSameBlockGuardStorage()._lastMintBlock[account];
    }

    function _recordMintBlock(address receiver, uint256 amount) internal {
        // slither-disable-next-line incorrect-equality
        if (amount == 0 || _isSameBlockGuardExempt(receiver)) {
            return;
        }
        _getYuzuSameBlockGuardStorage()._lastMintBlock[receiver] = block.number;
    }

    function _checkSameBlockRedeem(address _owner) internal view {
        if (_isSameBlockGuardExempt(_owner)) {
            return;
        }
        // slither-disable-next-line incorrect-equality
        if (_getYuzuSameBlockGuardStorage()._lastMintBlock[_owner] == block.number) {
            revert SameBlockMintRedeem(_owner);
        }
    }

    function _getYuzuSameBlockGuardStorage() private pure returns (YuzuSameBlockGuardStorage storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := YuzuSameBlockGuardStorageLocation
        }
    }
}
