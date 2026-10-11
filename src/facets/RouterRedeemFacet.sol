// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {RouterRedemptionCoreBase} from "./RouterRedemptionCoreBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Generic aggregation of Core's complete current-state ERC-20/ERC-1155 redemption vector.
contract RouterRedeemFacet is RouterRedemptionCoreBase {
    using SafeERC20 for IERC20;

    /// @notice Normalized caller request shared by token and native redemption entrypoints.
    /// @param grossCygldIn Exact CYGLD input before Helpers and Core fees.
    /// @param outputTokenRaw Requested ERC-20 output, or zero for the dedicated native route.
    /// @param recipient Account receiving both aggregate output and positive recovery shares.
    /// @param minimumAmountOut Minimum aggregate ERC-20 or native output accepted by the caller.
    /// @param expectedCoreOutputs Complete caller-bound Core output descriptors and minima.
    /// @param outputIsNative Whether wrapped-native output is unwrapped before payout.
    struct RedemptionOperation {
        uint256 grossCygldIn;
        address outputTokenRaw;
        address recipient;
        uint256 minimumAmountOut;
        ICoreRedemption.TokenMinimum[] expectedCoreOutputs;
        bool outputIsNative;
    }

    /// @notice One execution's parties, fee split, Core preview, and balance baselines.
    /// @param payer Account supplying the exact gross CYGLD input.
    /// @param core Configured Core diamond and CYGLD/ERC-1155 token identity.
    /// @param outputToken Normalized ERC-20 output, including WETH for native routes.
    /// @param coreGrossCygldIn CYGLD remaining for Core after the Helpers fee.
    /// @param helperFeeCygld CYGLD paid to the current Helpers owner.
    /// @param cygldBalanceBeforeCore Helpers CYGLD baseline immediately before Core settlement.
    /// @param coreOutputBalancesBefore Per-position ERC-20 baselines from the execution preview.
    /// @param projected Complete fresh Core vector used only for route shape and receipt arming.
    struct RedemptionContext {
        address payer;
        address core;
        address outputToken;
        uint256 coreGrossCygldIn;
        uint256 helperFeeCygld;
        uint256 cygldBalanceBeforeCore;
        uint256[] coreOutputBalancesBefore;
        ICoreRedemption.RedemptionQuote projected;
    }

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

    /// @notice Redeem CYGLD to one ERC-20 using its existing allowance.
    /// @param request Recipient, output token, complete Core binding, and aggregate minimum.
    /// @param legs Compact adapter legs in filtered Core output order.
    /// @return result Exact aggregate payout, positive forwarded recovery shares, and fees.
    function redeemToTokenExactIn(AggregatedRedemptionRequest calldata request, RedemptionSwapLeg[] calldata legs)
        external
        whenNotPaused
        nonReentrant
        returns (AggregatedRedemptionResult memory result)
    {
        RedemptionOperation memory operation = _tokenOperation(request);
        RedemptionContext memory ctx = _prepareRedemption(operation, legs);
        _acquireWithAllowance(ctx.payer, IERC20(ctx.core), operation.grossCygldIn);
        return _settleRedemption(operation, legs, ctx);
    }

    /// @notice Redeem CYGLD to one ERC-20 using CYGLD's ERC-2612 authorization.
    /// @param request Recipient, output token, complete Core binding, and aggregate minimum.
    /// @param permit CYGLD ERC-2612 authorization; an already-consumed permit is accepted when allowance suffices.
    /// @param legs Compact adapter legs in filtered Core output order.
    /// @return result Exact aggregate payout, positive forwarded recovery shares, and fees.
    function redeemToTokenExactInWithPermit(
        AggregatedRedemptionRequest calldata request,
        PermitParams calldata permit,
        RedemptionSwapLeg[] calldata legs
    ) external whenNotPaused nonReentrant returns (AggregatedRedemptionResult memory result) {
        RedemptionOperation memory operation = _tokenOperation(request);
        RedemptionContext memory ctx = _prepareRedemption(operation, legs);
        _acquireWithPermit(ctx.payer, IERC20(ctx.core), operation.grossCygldIn, _copyPermit(permit));
        return _settleRedemption(operation, legs, ctx);
    }

    /// @notice Redeem CYGLD to one ERC-20 using Permit2.
    /// @param request Recipient, output token, complete Core binding, and aggregate minimum.
    /// @param permit Permit2 authorization for the exact gross CYGLD input.
    /// @param legs Compact adapter legs in filtered Core output order.
    /// @return result Exact aggregate payout, positive forwarded recovery shares, and fees.
    function redeemToTokenExactInWithPermit2(
        AggregatedRedemptionRequest calldata request,
        Permit2Params calldata permit,
        RedemptionSwapLeg[] calldata legs
    ) external whenNotPaused nonReentrant returns (AggregatedRedemptionResult memory result) {
        RedemptionOperation memory operation = _tokenOperation(request);
        RedemptionContext memory ctx = _prepareRedemption(operation, legs);
        _acquireWithPermit2(ctx.payer, IERC20(ctx.core), operation.grossCygldIn, _copyPermit2(permit));
        return _settleRedemption(operation, legs, ctx);
    }

    /// @notice Redeem CYGLD to native currency using its existing allowance.
    /// @param request Recipient, complete Core binding, and native-output minimum.
    /// @param legs Compact adapter legs in filtered Core output order.
    /// @return result Exact native payout, positive forwarded recovery shares, and fees.
    function redeemToNativeExactIn(
        AggregatedNativeRedemptionRequest calldata request,
        RedemptionSwapLeg[] calldata legs
    ) external whenNotPaused nonReentrant returns (AggregatedRedemptionResult memory result) {
        RedemptionOperation memory operation = _nativeOperation(request);
        RedemptionContext memory ctx = _prepareRedemption(operation, legs);
        _acquireWithAllowance(ctx.payer, IERC20(ctx.core), operation.grossCygldIn);
        return _settleRedemption(operation, legs, ctx);
    }

    /// @notice Redeem CYGLD to native currency using CYGLD's ERC-2612 authorization.
    /// @param request Recipient, complete Core binding, and native-output minimum.
    /// @param permit CYGLD ERC-2612 authorization; an already-consumed permit is accepted when allowance suffices.
    /// @param legs Compact adapter legs in filtered Core output order.
    /// @return result Exact native payout, positive forwarded recovery shares, and fees.
    function redeemToNativeExactInWithPermit(
        AggregatedNativeRedemptionRequest calldata request,
        PermitParams calldata permit,
        RedemptionSwapLeg[] calldata legs
    ) external whenNotPaused nonReentrant returns (AggregatedRedemptionResult memory result) {
        RedemptionOperation memory operation = _nativeOperation(request);
        RedemptionContext memory ctx = _prepareRedemption(operation, legs);
        _acquireWithPermit(ctx.payer, IERC20(ctx.core), operation.grossCygldIn, _copyPermit(permit));
        return _settleRedemption(operation, legs, ctx);
    }

    /// @notice Redeem CYGLD to native currency using Permit2.
    /// @param request Recipient, complete Core binding, and native-output minimum.
    /// @param permit Permit2 authorization for the exact gross CYGLD input.
    /// @param legs Compact adapter legs in filtered Core output order.
    /// @return result Exact native payout, positive forwarded recovery shares, and fees.
    function redeemToNativeExactInWithPermit2(
        AggregatedNativeRedemptionRequest calldata request,
        Permit2Params calldata permit,
        RedemptionSwapLeg[] calldata legs
    ) external whenNotPaused nonReentrant returns (AggregatedRedemptionResult memory result) {
        RedemptionOperation memory operation = _nativeOperation(request);
        RedemptionContext memory ctx = _prepareRedemption(operation, legs);
        _acquireWithPermit2(ctx.payer, IERC20(ctx.core), operation.grossCygldIn, _copyPermit2(permit));
        return _settleRedemption(operation, legs, ctx);
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

    function _prepareRedemption(RedemptionOperation memory operation, RedemptionSwapLeg[] calldata legs)
        internal
        view
        returns (RedemptionContext memory ctx)
    {
        if (operation.recipient == address(0) || operation.recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (!operation.outputIsNative && operation.outputTokenRaw == address(0)) revert ZeroAddress();

        LibAppStorage.RouterStorage storage rs = _routerStorage();
        ctx.payer = msg.sender;
        ctx.core = rs.coreDiamond;
        ctx.outputToken = operation.outputIsNative ? _wrappedNative() : operation.outputTokenRaw;
        (ctx.coreGrossCygldIn, ctx.helperFeeCygld, ctx.projected) =
            _previewCoreRedemption(ctx.core, rs.helperFeePpm, operation.grossCygldIn);

        _validateQuoteMinimums(ctx.projected.outputs, operation.expectedCoreOutputs);
        _validateRoute(rs, ctx.projected.outputs, ctx.outputToken, legs);
        _requireAggregateMinimum(ctx.projected.outputs, operation.minimumAmountOut);
    }

    function _settleRedemption(
        RedemptionOperation memory operation,
        RedemptionSwapLeg[] calldata legs,
        RedemptionContext memory ctx
    ) internal returns (AggregatedRedemptionResult memory result) {
        IERC20 cygld = IERC20(ctx.core);
        if (ctx.helperFeeCygld != 0) {
            _payoutTokenExact(_feeRecipient(), ctx.core, false, ctx.helperFeeCygld);
        }
        ctx.cygldBalanceBeforeCore = cygld.balanceOf(address(this));
        ctx.coreOutputBalancesBefore = _snapshotCoreOutputBalances(ctx.projected.outputs);
        _armRecoveryReceipt(ctx.core, operation.recipient, ctx.projected.outputs);

        ICoreRedemption.RedemptionQuote memory settled =
            ICoreRedemption(ctx.core).safeRedeem(ctx.coreGrossCygldIn, operation.expectedCoreOutputs);
        _requireExactRouterDebit(
            ctx.core, ctx.cygldBalanceBeforeCore, cygld.balanceOf(address(this)), ctx.coreGrossCygldIn
        );
        _validateSettledRedemption(
            ctx.core,
            ctx.coreGrossCygldIn,
            ctx.projected,
            settled,
            operation.expectedCoreOutputs,
            ctx.coreOutputBalancesBefore
        );
        _completeRecoveryReceipt(ctx.projected.outputs);

        // Validate the complete actual route before invoking the first adapter. Any Core drift that
        // changes the compact leg shape therefore reverts the entire Core settlement atomically.
        _validateRoute(_routerStorage(), settled.outputs, ctx.outputToken, legs);
        result.amountOut = _convertCoreOutputs(ctx.outputToken, settled.outputs, legs);
        if (result.amountOut < operation.minimumAmountOut) {
            revert InsufficientOutput(operation.minimumAmountOut, result.amountOut);
        }

        _payoutTokenExact(operation.recipient, ctx.outputToken, operation.outputIsNative, result.amountOut);
        _refundRedeemDust(ctx.payer, ctx.outputToken, settled.outputs, ctx.coreOutputBalancesBefore);

        result.recoveryShareOutputs = _positiveRecoveryOutputs(settled.outputs);
        result.fees.protocolFeeCygld = settled.protocolFeeCygld;
        result.fees.helperFeeCygld = ctx.helperFeeCygld;
        _emitRedeemed(
            ctx.payer,
            operation.recipient,
            operation.outputIsNative ? address(0) : operation.outputTokenRaw,
            operation.grossCygldIn,
            result.amountOut,
            result.recoveryShareOutputs,
            result.fees.protocolFeeCygld,
            result.fees.helperFeeCygld
        );
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

    function _convertCoreOutputs(
        address outputToken,
        ICoreRedemption.TokenAmount[] memory coreOutputs,
        RedemptionSwapLeg[] calldata legs
    ) internal returns (uint256 amountOut) {
        uint256 cursor;
        for (uint256 i; i < coreOutputs.length;) {
            ICoreRedemption.TokenAmount memory output = coreOutputs[i];
            if (output.kind == ICoreRedemption.TokenKind.ERC20 && output.amount != 0) {
                if (output.token == outputToken) {
                    amountOut += output.amount;
                } else {
                    amountOut += _consumeRedemptionLeg(output, outputToken, legs[cursor]);
                    ++cursor;
                }
            }
            unchecked {
                ++i;
            }
        }
        assert(cursor == legs.length);
    }

    function _consumeRedemptionLeg(
        ICoreRedemption.TokenAmount memory inputLot,
        address outputToken,
        RedemptionSwapLeg calldata leg
    ) internal returns (uint256 received) {
        IERC20 input = IERC20(inputLot.token);
        uint256 inputBefore = input.balanceOf(address(this));
        input.forceApprove(leg.adapter, inputLot.amount);
        IERC20 output = IERC20(outputToken);
        uint256 outputBefore = output.balanceOf(address(this));
        uint256 returned = ISwapAdapter(leg.adapter).swap(inputLot.token, outputToken, inputLot.amount, leg.data);
        uint256 outputAfter = output.balanceOf(address(this));
        input.forceApprove(leg.adapter, 0);
        _requireAdapterInputDebitAtMost(
            inputLot.token, leg.adapter, inputBefore, input.balanceOf(address(this)), inputLot.amount
        );
        received = outputAfter >= outputBefore ? outputAfter - outputBefore : 0;
        if (received != returned) revert AdapterOutputMismatch(outputToken, leg.adapter, returned, received);
        if (received < leg.minimumAmountOut) {
            revert InsufficientOutputForMinAmountOut(inputLot.token, leg.minimumAmountOut, received);
        }
    }

    function _requireAggregateMinimum(ICoreRedemption.TokenAmount[] memory outputs, uint256 minimumAmountOut)
        internal
        pure
    {
        if (minimumAmountOut != 0) return;
        for (uint256 i; i < outputs.length;) {
            if (outputs[i].kind == ICoreRedemption.TokenKind.ERC20 && outputs[i].amount != 0) {
                revert ZeroFinalMinimum();
            }
            unchecked {
                ++i;
            }
        }
    }

    function _wrappedNative() internal view returns (address wrappedNative) {
        wrappedNative = _routerStorage().wrappedNative;
        if (wrappedNative == address(0)) revert WrappedNativeNotSet();
    }

    function _tokenOperation(AggregatedRedemptionRequest calldata request)
        internal
        pure
        returns (RedemptionOperation memory operation)
    {
        operation.grossCygldIn = request.grossCygldIn;
        operation.outputTokenRaw = request.outputToken;
        operation.recipient = request.recipient;
        operation.minimumAmountOut = request.minimumAmountOut;
        operation.expectedCoreOutputs = request.expectedCoreOutputs;
    }

    function _nativeOperation(AggregatedNativeRedemptionRequest calldata request)
        internal
        pure
        returns (RedemptionOperation memory operation)
    {
        operation.grossCygldIn = request.grossCygldIn;
        operation.recipient = request.recipient;
        operation.minimumAmountOut = request.minimumAmountOut;
        operation.expectedCoreOutputs = request.expectedCoreOutputs;
        operation.outputIsNative = true;
    }
}
