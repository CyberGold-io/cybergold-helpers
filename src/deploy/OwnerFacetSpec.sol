// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {OwnerFacetSelectors} from "./OwnerFacetSelectors.sol";

/// @notice FacetSpec helpers for owner-gated base facets.
library OwnerFacetSpec {
    /// @dev Return base.
    /// @param cut Diamond cut entries or DiamondCut facet address used by the helper.
    /// @param loupe Diamond loupe facet address included in selector specs.
    /// @param ownership Ownership facet address included in helper selector specs.
    /// @param pause Pausable facet address included in selector specs.
    /// @param includePause Whether to include the pausable facet in generated specs.
    /// @return specs Facet specification entries assembled by the helper.
    function base(address cut, address loupe, address ownership, address pause, bool includePause)
        internal
        pure
        returns (FacetSpec.Entry[] memory specs)
    {
        uint256 count = 3;
        if (includePause) count++;
        specs = new FacetSpec.Entry[](count);
        uint256 idx;
        specs[idx++] = FacetSpec.Entry({name: "cut", facet: cut, selectors: OwnerFacetSelectors.cutSelectors()});
        specs[idx++] = FacetSpec.Entry({name: "loupe", facet: loupe, selectors: OwnerFacetSelectors.loupeSelectors()});
        specs[idx++] =
            FacetSpec.Entry({name: "ownership", facet: ownership, selectors: OwnerFacetSelectors.ownershipSelectors()});
        if (includePause) {
            specs[idx++] =
                FacetSpec.Entry({name: "pause", facet: pause, selectors: OwnerFacetSelectors.pauseSelectors()});
        }
    }

    /// @dev Return owner-gated base specs using the generation-only live coordinator.
    function liveBase(address cut, address loupe, address ownership, address pause, bool includePause)
        internal
        pure
        returns (FacetSpec.Entry[] memory specs)
    {
        specs = base(cut, loupe, ownership, pause, includePause);
        specs[0].selectors = OwnerFacetSelectors.liveCutSelectors();
    }
}
