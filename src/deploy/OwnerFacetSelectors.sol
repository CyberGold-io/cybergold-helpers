// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {LiveFacetVersionRegistry} from "diamond-infra/helpers/LiveFacetVersionRegistry.sol";
import {OwnerPausableFacet} from "../facets/OwnerPausableFacet.sol";

/// @notice Selector tables for owner-gated base facets.
library OwnerFacetSelectors {
    /// @dev Return cut selectors.
    /// @return selectors Function selectors included in the facet selector table.
    function cutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = IDiamondCut.diamondCut.selector;
    }

    /// @dev Return generation-only live coordinator selectors.
    /// @return selectors Function selectors included in the live coordinator table.
    function liveCutSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IDiamondCut.diamondCut.selector;
        selectors[1] = LiveFacetVersionRegistry.facetGeneration.selector;
    }

    /// @dev Return loupe selectors.
    /// @return selectors Function selectors included in the facet selector table.
    function loupeSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IDiamondLoupe.facets.selector;
        selectors[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        selectors[2] = IDiamondLoupe.facetAddresses.selector;
        selectors[3] = IDiamondLoupe.facetAddress.selector;
        selectors[4] = IERC165.supportsInterface.selector;
    }

    /// @dev Return ownership selectors.
    /// @return selectors Function selectors included in the facet selector table.
    function ownershipSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
        selectors[2] = 0xe30c3978; // pendingOwner()
        selectors[3] = 0x79ba5097; // acceptOwnership()
        selectors[4] = 0x23452b9c; // cancelOwnershipTransfer()
    }

    /// @dev Return pause selectors.
    /// @return selectors Function selectors included in the facet selector table.
    function pauseSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = OwnerPausableFacet.pause.selector;
        selectors[1] = OwnerPausableFacet.unpause.selector;
        selectors[2] = bytes4(keccak256("paused()"));
    }
}
