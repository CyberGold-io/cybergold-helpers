// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {RouterRedemptionCoreBase} from "./RouterRedemptionCoreBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Generic aggregation of Core's complete current-state ERC-20/ERC-1155 redemption vector.
contract RouterRedeemFacet is RouterRedemptionCoreBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.redeem");

    /// @notice Bind this facet implementation to the release-wide immutable Permit2 identity.
    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) RouterRedemptionCoreBase(permit2_) {}

    /// @notice Preview one exact-input redemption aggregated into a nonzero ERC-20 output token.
    /// @param params Gross CYGLD input and requested ERC-20 output token.
    /// @param legs Compact adapter legs for positive non-direct ERC-20 Core outputs.
    /// @return preview Complete Core projection, aggregate constructed minimum, and fees.
    function previewRedeemToTokenExactIn(RedeemToTokenExactInParams calldata params, RedemptionSwapLeg[] calldata legs)
        external
        view
        returns (AggregatedRedemptionPreview memory preview)
    {
        if (params.outputToken == address(0)) revert ZeroAddress();
        return _previewAggregatedRedemption(params.grossCygldIn, params.outputToken, legs);
    }

    /// @notice Preview one exact-input redemption aggregated into native currency through wrapped native.
    /// @param grossCygldIn Exact CYGLD input before Helpers and Core fees.
    /// @param legs Compact adapter legs for positive non-WETH ERC-20 Core outputs.
    /// @return preview Complete Core projection, aggregate constructed minimum, and fees.
    function previewRedeemToNativeExactIn(uint256 grossCygldIn, RedemptionSwapLeg[] calldata legs)
        external
        view
        returns (AggregatedRedemptionPreview memory preview)
    {
        return _previewAggregatedRedemption(grossCygldIn, _wrappedNative(), legs);
    }

    function _previewAggregatedRedemption(uint256 grossCygldIn, address outputToken, RedemptionSwapLeg[] calldata legs)
        internal
        view
        returns (AggregatedRedemptionPreview memory preview)
    {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        (, uint256 helperFeeCygld, ICoreRedemption.RedemptionQuote memory corePreview) =
            _previewCoreRedemption(rs.coreDiamond, rs.helperFeePpm, grossCygldIn);
        preview.minimumAmountOut = _validateRoute(rs, corePreview.outputs, outputToken, legs);
        preview.projectedCoreOutputs = corePreview.outputs;
        preview.fees.protocolFeeCygld = corePreview.protocolFeeCygld;
        preview.fees.helperFeeCygld = helperFeeCygld;
    }

    function _validateRoute(
        LibAppStorage.RouterStorage storage rs,
        ICoreRedemption.TokenAmount[] memory coreOutputs,
        address outputToken,
        RedemptionSwapLeg[] calldata legs
    ) internal view returns (uint256 minimumAmountOut) {
        uint256 cursor;
        for (uint256 i; i < coreOutputs.length;) {
            ICoreRedemption.TokenAmount memory output = coreOutputs[i];
            if (output.kind == ICoreRedemption.TokenKind.ERC20 && output.amount != 0) {
                if (output.token == outputToken) {
                    minimumAmountOut += output.amount;
                } else {
                    if (cursor == legs.length) revert QuoteLengthMismatch(legs.length, cursor + 1);
                    RedemptionSwapLeg calldata leg = legs[cursor];
                    if (!_isAdapterApproved(rs, leg.adapter)) revert AdapterNotApproved(leg.adapter);
                    if (leg.minimumAmountOut == 0) revert ZeroLegMinimum(cursor);
                    minimumAmountOut += leg.minimumAmountOut;
                    ++cursor;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (cursor != legs.length) revert QuoteLengthMismatch(legs.length, cursor);
    }

    function _wrappedNative() internal view returns (address wrappedNative) {
        wrappedNative = _routerStorage().wrappedNative;
        if (wrappedNative == address(0)) revert WrappedNativeNotSet();
    }
}
