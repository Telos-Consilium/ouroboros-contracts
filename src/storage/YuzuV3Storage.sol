// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Throttle} from "../interfaces/proto/IYuzuThrottleDefinitions.sol";

library YuzuMinAmountsV3Storage {
    struct Layout {
        uint256 _minDeposit;
        uint256 _minWithdraw;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.minamounts")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCATION = 0x3bac632b84cdc99ee809c17a81d1c3af6c49d197442158c702def7699ae31b00;

    function layout() internal pure returns (Layout storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := LOCATION
        }
    }
}

library YuzuThrottleV3Storage {
    struct Layout {
        Throttle _mintThrottle;
        Throttle _redeemThrottle;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.throttle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCATION = 0x0b7c362ff29744eee18a40453a4b4ef5d7bd130da15027ce5dd041799a288e00;

    function layout() internal pure returns (Layout storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := LOCATION
        }
    }
}

library YuzuRestrictedSharesV3Storage {
    struct Restriction {
        uint256 blockNumber;
        uint256 amount;
    }

    struct Layout {
        mapping(address => Restriction) _restrictions;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.restrictedshares")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCATION = 0x6640948ddaf4f725e158ddd802cd097cb6a3e22fadb04689cd03dc5493988600;

    function layout() internal pure returns (Layout storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := LOCATION
        }
    }
}

library YuzuNavMarkdownV3Storage {
    struct Layout {
        uint256 _nav;
        uint256 _stepCapPpm;
        uint256 _cooldown;
        uint256 _lastUpdate;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.navmarkdown")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCATION = 0xbba33777aee3e8d94c5925677a78afa5780f0b9cf6f4464b380525cccd6c9300;

    function layout() internal pure returns (Layout storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := LOCATION
        }
    }
}

library YuzuILPFeesV3Storage {
    struct Layout {
        uint256 _mintFeePpm;
        uint256 _managementFeeRatePpm;
        uint256 _cumulativeManagementFees;
        uint256 _pendingManagementFeeRatePpm;
        uint256 _performanceFeeRatePpm;
        uint256 _pendingPerformanceFeeRatePpm;
        uint256 _highWaterMark;
        uint256 _cumulativePerformanceFees;
    }

    // keccak256(abi.encode(uint256(keccak256("yuzu.storage.ilpfees")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant LOCATION = 0x93ad02b05e4d8e5afd5c21de55a6b2405afe608b42c8806cefbe7bbeb87f7f00;

    function layout() internal pure returns (Layout storage $) {
        // slither-disable-next-line assembly
        assembly {
            $.slot := LOCATION
        }
    }
}
