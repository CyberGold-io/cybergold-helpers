// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RouterIssueSettlementBase} from "./RouterIssueSettlementBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";

/// @notice Read-only construction helpers for retained token and native issuance routes.
contract RouterIssuePreviewFacet is RouterIssueSettlementBase {
    /// @notice Bind this facet implementation to the release-wide immutable Permit2 identity.
    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) RouterIssueSettlementBase(permit2_) {}

    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.issue.preview");

    /// @notice Preview direct-basket issuance from caller-defined per-asset input budgets.
    /// @param maximumAmountsIn Input ceilings ordered exactly like Core's current issuance assets.
    /// @return preview Recipient net output, fee split, exact Core lots, and current ordered assets.
    function previewIssueFromBasketExactIn(uint256[] calldata maximumAmountsIn)
        external
        view
        returns (BasketIssueExactInPreview memory preview)
    {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        uint256 coreNetCygldOut;
        (coreNetCygldOut, preview.fees.protocolFeeCygld, preview.amountsInExact, preview.orderedCoreAssets) =
            ICyberGoldCore(rs.coreDiamond).previewIssueFromBasketExactIn(maximumAmountsIn);
        _validateCoreBasketAmounts(preview.orderedCoreAssets, preview.amountsInExact);
        if (coreNetCygldOut == 0) revert AmountTooSmallAfterFees();

        preview.fees.helperFeeCygld = Math.mulDiv(coreNetCygldOut, rs.helperFeePpm, PPM_DENOMINATOR);
        preview.netCygldOut = coreNetCygldOut - preview.fees.helperFeeCygld;
    }

    /// @notice Preview the direct-basket inputs required for one exact recipient net CYGLD output.
    /// @param netCygldOut Exact CYGLD amount the recipient must receive after the Helpers fee.
    /// @return preview Fee split, exact Core lots, and current ordered assets.
    function previewIssueFromBasketExactOut(uint256 netCygldOut)
        external
        view
        returns (BasketIssueExactOutPreview memory preview)
    {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        uint256 coreNetCygldOut;
        (coreNetCygldOut, preview.fees.helperFeeCygld) = _grossForNet(netCygldOut, rs.helperFeePpm);
        (preview.fees.protocolFeeCygld, preview.amountsInExact, preview.orderedCoreAssets) =
            _previewCoreIssueExactOut(rs, coreNetCygldOut);
    }

    /// @notice Preview exact-output issuance from one nonzero ERC-20 input token.
    /// @param params Token identity, caller input ceiling, and desired net CYGLD output.
    /// @param legs Compact positional swap legs for non-direct Core inputs.
    /// @return preview Ordered Core assets and protocol/Helpers fee amounts.
    function previewIssueFromTokenExactOut(IssueFromTokenExactOutParams calldata params, IssueSwapLeg[] calldata legs)
        external
        view
        returns (IssueExactOutPreview memory preview)
    {
        if (params.inputToken == address(0)) revert ZeroAddress();
        return _previewIssueExactOut(params.inputToken, params.maximumInputAmount, params.netCygldOut, legs);
    }

    /// @notice Conservatively preview the exact-output route constructible from a fixed ERC-20 budget.
    /// @param params Token identity and fixed caller input budget.
    /// @param legs Compact positional swap legs whose minima construct the Core input vector.
    /// @return preview Constructible net CYGLD output, ordered Core assets, and fee amounts.
    function previewIssueFromTokenExactIn(IssueFromTokenExactInParams calldata params, IssueSwapLeg[] calldata legs)
        external
        view
        returns (IssueExactInPreview memory preview)
    {
        if (params.inputToken == address(0)) revert ZeroAddress();
        return _previewIssueExactIn(params.inputToken, params.inputAmount, legs);
    }

    /// @notice Preview exact-output issuance from native ETH normalized to wrapped native.
    /// @param params Native input ceiling and desired net CYGLD output.
    /// @param legs Compact positional swap legs for every Core input.
    /// @return preview Ordered Core assets and protocol/Helpers fee amounts.
    function previewIssueFromNativeExactOut(IssueFromNativeExactOutParams calldata params, IssueSwapLeg[] calldata legs)
        external
        view
        returns (IssueExactOutPreview memory preview)
    {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        if (rs.wrappedNative == address(0)) revert WrappedNativeNotSet();
        return _previewIssueExactOut(rs.wrappedNative, params.maximumNativeIn, params.netCygldOut, legs);
    }

    /// @notice Conservatively preview the exact-output route constructible from a fixed native budget.
    /// @param nativeAmountIn Fixed native input budget.
    /// @param legs Compact positional swap legs whose minima construct the Core input vector.
    /// @return preview Constructible net CYGLD output, ordered Core assets, and fee amounts.
    function previewIssueFromNativeExactIn(uint256 nativeAmountIn, IssueSwapLeg[] calldata legs)
        external
        view
        returns (IssueExactInPreview memory preview)
    {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        if (rs.wrappedNative == address(0)) revert WrappedNativeNotSet();
        return _previewIssueExactIn(rs.wrappedNative, nativeAmountIn, legs);
    }

    /// @dev Preview one exact-output route without calling an adapter or quoter.
    function _previewIssueExactOut(
        address normalizedInputToken,
        uint256 maximumInputAmount,
        uint256 netCygldOut,
        IssueSwapLeg[] calldata legs
    ) internal view returns (IssueExactOutPreview memory preview) {
        if (maximumInputAmount == 0 || netCygldOut == 0) revert ZeroInputAmount();

        LibAppStorage.RouterStorage storage rs = _routerStorage();
        (uint256 coreNetCygldOut, uint256 helperFeeCygld) = _grossForNet(netCygldOut, rs.helperFeePpm);
        uint256[] memory requiredAmounts;
        (preview.fees.protocolFeeCygld, requiredAmounts, preview.orderedCoreAssets) =
            _previewCoreIssueExactOut(rs, coreNetCygldOut);
        _validateExactOutIssueLegs(
            rs, preview.orderedCoreAssets, requiredAmounts, normalizedInputToken, maximumInputAmount, legs
        );
        preview.fees.helperFeeCygld = helperFeeCygld;
    }

    /// @dev Construct one conservative Core exact-input vector without invoking an adapter or quoter.
    function _previewIssueExactIn(address normalizedInputToken, uint256 inputAmount, IssueSwapLeg[] calldata legs)
        internal
        view
        returns (IssueExactInPreview memory preview)
    {
        if (inputAmount == 0) revert ZeroInputAmount();

        LibAppStorage.RouterStorage storage rs = _routerStorage();
        address[] memory currentCoreAssets = _loadBasketAssets();
        uint256[] memory currentCoreTargetsPpm = ICyberGoldCore(rs.coreDiamond).basketTargetsPpm();
        uint256[] memory constructedAmounts = _buildExactInCoreInputs(
            rs, currentCoreAssets, currentCoreTargetsPpm, normalizedInputToken, inputAmount, legs
        );

        uint256 coreNetCygldOut;
        uint256[] memory amountsInExact;
        (coreNetCygldOut, preview.fees.protocolFeeCygld, amountsInExact, preview.orderedCoreAssets) =
            ICyberGoldCore(rs.coreDiamond).previewIssueFromBasketExactIn(constructedAmounts);
        _validateCoreBasketAmounts(preview.orderedCoreAssets, amountsInExact);
        _validateOrderedBasketAssets(currentCoreAssets, preview.orderedCoreAssets);
        if (coreNetCygldOut == 0) revert AmountTooSmallAfterFees();

        preview.fees.helperFeeCygld = Math.mulDiv(coreNetCygldOut, rs.helperFeePpm, PPM_DENOMINATOR);
        preview.netCygldOut = coreNetCygldOut - preview.fees.helperFeeCygld;
    }
}
