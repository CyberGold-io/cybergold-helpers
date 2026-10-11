// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {HelpersDiamond} from "../diamond/HelpersDiamond.sol";
import {DiamondLiveInit} from "./DiamondLiveInit.sol";
import {DiamondCutOwnerLiveFacet} from "../facets/DiamondCutOwnerLiveFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {OwnershipFacet} from "../facets/OwnershipFacet.sol";
import {OwnerPausableFacet} from "../facets/OwnerPausableFacet.sol";
import {RouterAdminFacet} from "../facets/RouterAdminFacet.sol";
import {RouterIssuePreviewFacet} from "../facets/RouterIssuePreviewFacet.sol";
import {RouterIssueFacet} from "../facets/RouterIssueFacet.sol";
import {RouterIssueBasketFacet} from "../facets/RouterIssueBasketFacet.sol";
import {RouterRedeemFacet} from "../facets/RouterRedeemFacet.sol";
import {RouterRedeemBasketFacet} from "../facets/RouterRedeemBasketFacet.sol";
import {RecoveryShareReceiverFacet} from "../facets/RecoveryShareReceiverFacet.sol";

/// @notice Deployment types helpers for the helpers diamond.
library DeploymentTypes {
    /// @notice One optional pre-deployed facet selected by audited Ops evidence.
    /// @dev A zero address keeps the normal fresh-deployment path. Otherwise
    /// DeploymentHelper checks the full compiled deployed-runtime codehash.
    struct FacetOverride {
        address facet;
        bytes32 runtimeCodeHash;
    }

    /// @notice Optional pre-deployed implementations for canonical Helpers facets.
    /// @dev Each field remains bound to one reviewed logical selector role.
    struct FacetOverrides {
        FacetOverride cut;
        FacetOverride loupe;
        FacetOverride ownership;
        FacetOverride pause;
        FacetOverride admin;
        FacetOverride issuePreview;
        FacetOverride issue;
        FacetOverride issueBasket;
        FacetOverride redeem;
        FacetOverride redeemBasket;
        FacetOverride recoveryShareReceiver;
    }

    /// @notice Facet addresses grouped for diamond deployment and initialization.
    struct Facets {
        DiamondCutOwnerLiveFacet cut;
        ProtocolDiamondLoupeFacet loupe;
        OwnershipFacet ownership;
        OwnerPausableFacet pause;
        RouterAdminFacet admin;
        RouterIssuePreviewFacet issuePreview;
        RouterIssueFacet issue;
        RouterIssueBasketFacet issueBasket;
        RouterRedeemFacet redeem;
        RouterRedeemBasketFacet redeemBasket;
        RecoveryShareReceiverFacet recoveryShareReceiver;
    }

    /// @notice Addresses produced by a package deployment.
    struct DeployArtifacts {
        HelpersDiamond diamond;
        DiamondLiveInit diamondInit;
        Facets facets;
    }

    /// @notice Deployment parameters consumed by the package deployment helper.
    struct DeployConfig {
        address admin;
        address coreDiamond;
        address permit2;
        address wrappedNative;
        uint256 helperFeePpm;
        address[] approvedAdapters;
        FacetOverrides facetOverrides;
    }
}
