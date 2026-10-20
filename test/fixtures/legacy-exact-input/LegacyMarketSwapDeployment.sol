// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IMarketSwap} from "src/interfaces/IMarketSwap.sol";
import {LegacyMarketSwapFacet as MarketSwapFacet} from "./LegacyMarketSwapFacet.sol";
import {UniswapMultiProtocolAdapter} from "src/adapters/UniswapMultiProtocolAdapter.sol";

/// @notice Scoped market extension for an existing Helpers Diamond.
library LegacyMarketSwapDeployment {
    /// @notice Deploy only the market facet and multi-protocol adapter.
    /// @param helpers Existing Diamond and adapter recovery authority.
    /// @param router Reviewed Universal Router 2.2.0 target.
    /// @param permit2 Existing release-wide Permit2 identity.
    /// @return facet New market implementation.
    /// @return adapter New fee-neutral venue adapter.
    function deploy(address helpers, address router, address permit2)
        internal
        returns (MarketSwapFacet facet, UniswapMultiProtocolAdapter adapter)
    {
        facet = new MarketSwapFacet(permit2);
        adapter = new UniswapMultiProtocolAdapter(helpers, router, permit2);
    }

    /// @notice Return only the two installed market selectors, excluding runtime metadata.
    /// @return result Market exact-input and exact-output selectors.
    function selectors() internal pure returns (bytes4[] memory result) {
        result = new bytes4[](2);
        result[0] = IMarketSwap.swapExactInput.selector;
        result[1] = IMarketSwap.swapExactOutput.selector;
    }

    /// @notice Build the additive cut consumed by the existing validated coordinator.
    /// @param facet Newly deployed market implementation.
    /// @return cut One scoped additive cut, without initializer or unrelated replacement.
    function facetCut(address facet) internal pure returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut(facet, IDiamond.FacetCutAction.Add, selectors());
    }
}
