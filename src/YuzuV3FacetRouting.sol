// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IYuzuOrderBookDefinitions} from "./interfaces/proto/IYuzuOrderBookDefinitions.sol";

/**
 * @title YuzuV3FacetRouting
 * @dev Routing plumbing for V3 vault implementations that delegate selected functions to a facet.
 * Holds the facet address and forwards the incoming calldata unchanged, so a routed function must be
 * the call's entrypoint; functions that are also called internally need an explicit facet call instead.
 */
abstract contract YuzuV3FacetRouting {
    address internal immutable _facet;

    constructor(address facet_) {
        if (facet_ == address(0)) {
            revert IYuzuOrderBookDefinitions.InvalidZeroAddress();
        }
        _facet = facet_;
    }

    function _delegateToFacet() internal {
        address facet = _facet;
        // slither-disable-next-line assembly,low-level-calls
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _staticcallFacet() internal view {
        address facet = _facet;
        // slither-disable-next-line assembly,low-level-calls
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := staticcall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _requireRouterSelfCall() internal view {
        if (msg.sender != address(this)) {
            revert();
        }
    }
}
