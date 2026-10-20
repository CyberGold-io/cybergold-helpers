// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {ITradeExactInput} from "../interfaces/ITradeExactInput.sol";
import {TradeExactInFacet} from "../facets/TradeExactInFacet.sol";
import {UniswapRoutingAdapter} from "../adapters/UniswapRoutingAdapter.sol";

/// @notice Local release building blocks; adding execution and retiring old callers are separate cuts.
library TradeExactInputDeployment {
    /// @notice Deploy the fixed-bound universal implementation and no-hook successor.
    /// @param helpers Existing Helpers Diamond and adapter recovery authority.
    /// @param router Pinned Universal Router 2.2.0 identity.
    /// @param permit2 Release-wide Permit2 identity.
    /// @param wrappedNative Wrapped native token configured in Helpers.
    /// @return facet Universal exact-input facet, bound to adapter.
    /// @return adapter No-hook native-aware multiprotocol adapter.
    function deploy(address helpers, address router, address permit2, address wrappedNative)
        internal
        returns (TradeExactInFacet facet, UniswapRoutingAdapter adapter)
    {
        adapter = new UniswapRoutingAdapter(helpers, router, permit2, wrappedNative);
        facet = new TradeExactInFacet(permit2, address(adapter));
    }

    /// @notice Selector added before owned callers switch to universal execution.
    /// @return result Sole execution selector; metadata/getters are not Diamond entrypoints.
    function selectors() internal pure returns (bytes4[] memory result) {
        result = new bytes4[](1);
        result[0] = ITradeExactInput.executeExactInput.selector;
    }

    /// @notice Exact inventoried execution removals, preserving all previews and exact-output selectors.
    /// @return result Twelve old execution selectors in family order.
    function retiredSelectors() internal pure returns (bytes4[] memory result) {
        result = new bytes4[](12);
        result[0] = 0xadfc9f4e; // swapExactInput
        result[1] = 0xf2c4c397; // redeemToNativeExactIn
        result[2] = 0x065600b2; // redeemToNativeExactInWithPermit
        result[3] = 0x300b4423; // redeemToNativeExactInWithPermit2
        result[4] = 0x3b25a19c; // redeemToTokenExactIn
        result[5] = 0x6fa6d883; // redeemToTokenExactInWithPermit
        result[6] = 0x1c0b4907; // redeemToTokenExactInWithPermit2
        result[7] = 0xc2f2261c; // redeemToBasketExactIn
        result[8] = 0xddf6a573; // redeemToBasketExactInWithPermit
        result[9] = 0x233f8db8; // redeemToBasketExactInWithPermit2
        result[10] = 0x705b2d0b; // issueFromBasketExactInWithMixedPermits
        result[11] = 0xe813952e; // issueFromBasketExactInWithPermit2
    }

    /// @notice Prepare additive activation without prematurely removing old caller entrypoints.
    /// @param facet Newly deployed universal implementation.
    /// @return cut Scoped additive cut for the existing validated upgrade coordinator.
    function activationCut(address facet) internal pure returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut(facet, IDiamond.FacetCutAction.Add, selectors());
    }

    /// @notice Prepare selector retirement after caller migration; adapter revocations remain admin operations.
    /// @return cut Explicit removal set, without unrelated selectors or initializer.
    function retirementCut() internal pure returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut(address(0), IDiamond.FacetCutAction.Remove, retiredSelectors());
    }
}
