// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {RouterIssueBasketFacet} from "src/facets/RouterIssueBasketFacet.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {RouterIssueSettlementBase} from "src/facets/RouterIssueSettlementBase.sol";
import {LibAppStorage} from "src/diamond/LibAppStorage.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";

/// @notice Test-only retired execution bodies; active previews and exact-output code are inherited from production.
contract LegacyRouterIssueBasketFacet is RouterIssueBasketFacet {
    /// @notice Bind this facet implementation to the release-wide immutable Permit2 identity.
    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) RouterIssueBasketFacet(permit2_) {}

    /// @notice Issue from ordered per-asset budgets with token-native, Permit2, or existing allowances.
    /// @param request Recipient and minimum net CYGLD output.
    /// @param inputs Caller budgets and authorizations in complete Core order, including zero-required members.
    /// @param permit2 Compact signed Permit2 batch for only the Permit2-authorized inputs in Core order.
    /// @return result Realized recipient output, fee split, and actual Core input debits.
    function issueFromBasketExactInWithMixedPermits(
        BasketIssueExactInRequest calldata request,
        BasketIssueInput[] calldata inputs,
        Permit2BatchParams calldata permit2
    ) external whenNotPaused nonReentrant returns (BasketIssueResult memory result) {
        if (request.recipient == address(0) || request.recipient == address(this)) revert InvalidRecipient();
        if (request.minimumNetCygldOut == 0) revert ZeroFinalMinimum();

        LibAppStorage.RouterStorage storage rs = _routerStorage();
        uint256[] memory budgets = new uint256[](inputs.length);
        for (uint256 i; i < inputs.length; ++i) {
            budgets[i] = inputs[i].maximumInputAmount;
        }
        BasketIssueContext memory ctx;
        ctx.recipient = request.recipient;
        (ctx.coreNetCygldOut, ctx.protocolFeeCygld, ctx.maximumCoreInputs, ctx.assets) =
            ICyberGoldCore(rs.coreDiamond).previewIssueFromBasketExactIn(budgets);
        _validateCoreBasketAmounts(ctx.assets, ctx.maximumCoreInputs);
        uint256 permit2Count = _validateMixedInputs(inputs, permit2.permit, ctx.assets, ctx.maximumCoreInputs);
        if (ctx.coreNetCygldOut == 0) revert AmountTooSmallAfterFees();
        ctx.helperFeeCygld = Math.mulDiv(ctx.coreNetCygldOut, rs.helperFeePpm, PPM_DENOMINATOR);
        uint256 netCygldOut = ctx.coreNetCygldOut - ctx.helperFeeCygld;
        if (netCygldOut < request.minimumNetCygldOut) {
            revert InsufficientOutput(request.minimumNetCygldOut, netCygldOut);
        }
        return _executeMixedBasketIssue(rs, ctx, inputs, permit2, permit2Count);
    }

    /// @notice Issue from signed per-asset budgets while accepting any recipient net above a floor.
    /// @dev The signed Permit2 permissions are the sole caller-bound asset order and input budgets.
    /// @param request Recipient and minimum net CYGLD output.
    /// @param permit Atomic ordered basket authorization and signature.
    /// @return result Realized recipient output, fee split, and actual Core input debits.
    function issueFromBasketExactInWithPermit2(
        BasketIssueExactInRequest calldata request,
        Permit2BatchParams calldata permit
    ) external whenNotPaused nonReentrant returns (BasketIssueResult memory result) {
        if (request.recipient == address(0) || request.recipient == address(this)) revert InvalidRecipient();
        if (request.minimumNetCygldOut == 0) revert ZeroFinalMinimum();

        LibAppStorage.RouterStorage storage rs = _routerStorage();
        uint256[] memory signedBudgets = _copySignedAmounts(permit.permit);
        uint256 coreNetCygldOut;
        uint256 protocolFeeCygld;
        uint256[] memory amountsInExact;
        address[] memory orderedCoreAssets;
        (coreNetCygldOut, protocolFeeCygld, amountsInExact, orderedCoreAssets) =
            ICyberGoldCore(rs.coreDiamond).previewIssueFromBasketExactIn(signedBudgets);
        _validateCoreBasketAmounts(orderedCoreAssets, amountsInExact);
        _validatePermitBatch(permit.permit, orderedCoreAssets, amountsInExact);
        if (coreNetCygldOut == 0) revert AmountTooSmallAfterFees();

        uint256 helperFeeCygld = Math.mulDiv(coreNetCygldOut, rs.helperFeePpm, PPM_DENOMINATOR);
        uint256 netCygldOut = coreNetCygldOut - helperFeeCygld;
        if (netCygldOut < request.minimumNetCygldOut) {
            revert InsufficientOutput(request.minimumNetCygldOut, netCygldOut);
        }

        return _executeBasketIssue(
            rs,
            request.recipient,
            permit,
            orderedCoreAssets,
            amountsInExact,
            coreNetCygldOut,
            helperFeeCygld,
            protocolFeeCygld
        );
    }

    /// @dev Copy signed per-asset ceilings into the memory vector consumed by Core previews and settlement.
    function _copySignedAmounts(ISignatureTransfer.PermitBatchTransferFrom calldata permit)
        internal
        pure
        returns (uint256[] memory amounts)
    {
        uint256 count = permit.permitted.length;
        amounts = new uint256[](count);
        for (uint256 i; i < count;) {
            amounts[i] = permit.permitted[i].amount;
            unchecked {
                ++i;
            }
        }
    }
}
