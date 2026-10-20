// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {RouterRedemptionCoreBase} from "./RouterRedemptionCoreBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Direct delivery of Core's complete current-state ERC-20/ERC-1155 redemption vector.
contract RouterRedeemBasketFacet is RouterRedemptionCoreBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.redeem.basket");

    /// @notice Bind this facet implementation to the release-wide immutable Permit2 identity.
    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) RouterRedemptionCoreBase(permit2_) {}

    /// @notice Preview direct delivery of the complete mixed vector for one exact outer gross input.
    /// @param grossCygldIn Exact CYGLD input before Helpers and Core fees.
    /// @return preview Outer gross input, complete Core projection, and fee split.
    function previewRedeemToBasketExactIn(uint256 grossCygldIn)
        external
        view
        returns (BasketRedemptionExactInPreview memory preview)
    {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        ICoreRedemption.RedemptionQuote memory corePreview;
        (, preview.fees.helperFeeCygld, corePreview) =
            _previewCoreRedemption(rs.coreDiamond, rs.helperFeePpm, grossCygldIn);
        preview.projectedCoreOutputs = corePreview.outputs;
        preview.fees.protocolFeeCygld = corePreview.protocolFeeCygld;
    }

    /// @notice Construct the minimum outer gross input satisfying a complete mixed-output floor vector.
    /// @param minimumOutputs Complete canonical Core output identities and per-output minima.
    /// @return preview Minimum outer gross input, complete Core projection, and fee split.
    function previewRedeemToBasketExactOut(ICoreRedemption.TokenMinimum[] calldata minimumOutputs)
        external
        view
        returns (BasketRedemptionExactOutPreview memory preview)
    {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        ICoreRedemption.RedemptionQuote memory corePreview =
            ICoreRedemption(rs.coreDiamond).previewRedeemExactOut(minimumOutputs);
        _validateCoreQuote(rs.coreDiamond, corePreview.grossCygldIn, corePreview);
        _validateQuoteMinimums(corePreview.outputs, minimumOutputs);

        (preview.grossCygldIn, preview.fees.helperFeeCygld) = _grossForNet(corePreview.grossCygldIn, rs.helperFeePpm);
        preview.projectedCoreOutputs = corePreview.outputs;
        preview.fees.protocolFeeCygld = corePreview.protocolFeeCygld;
    }
}
