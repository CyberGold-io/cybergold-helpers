// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {RouterIssueSettlementBase} from "./RouterIssueSettlementBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @notice Single-token and native acquisition routes for exact-output CYGLD issuance.
contract RouterIssueFacet is RouterIssueSettlementBase {
    using SafeERC20 for IERC20;

    /// @notice Bind this facet implementation to the release-wide immutable Permit2 identity.
    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) RouterIssueSettlementBase(permit2_) {}

    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.issue");

    /// @notice Normalized internal inputs shared by ERC-20 and native exact-output routes.
    struct IssueRouteRequest {
        address inputToken;
        address inputTokenForEvent;
        bool inputIsNative;
        uint256 maximumInputAmount;
        uint256 netCygldOut;
        address recipient;
        address[] expectedOrderedCoreAssets;
    }

    /// @notice Input authorization selected by the public token route.
    enum IssueAuthorizationMode {
        Allowance,
        TokenPermit,
        Permit2
    }

    /// @notice Authorization inputs carried into the common acquisition and settlement path.
    struct IssueAuthorization {
        IssueAuthorizationMode mode;
        PermitParams permit;
        Permit2Params permit2;
    }

    /// @notice Deliver an exact net CYGLD amount from one nonzero ERC-20 input token.
    /// @param params Token identity, caller input ceiling, and desired net CYGLD output.
    /// @param execution Recipient and snapshotted ordered Core-asset binding.
    /// @param legs Compact positional swap legs for non-direct Core inputs.
    /// @return fees Protocol and Helpers fees charged in CYGLD.
    function issueFromTokenExactOut(
        IssueFromTokenExactOutParams calldata params,
        IssueExecutionParams calldata execution,
        IssueSwapLeg[] calldata legs
    ) external whenNotPaused nonReentrant returns (Fees memory fees) {
        if (params.inputToken == address(0)) revert ZeroAddress();
        IssueAuthorization memory authorization;
        return _issueExactOut(_tokenRouteRequest(params, execution), legs, authorization);
    }

    /// @notice Deliver an exact net CYGLD amount from an ERC-20 input authorized by standard ERC-2612.
    /// @param params Token identity, caller input ceiling, and desired net CYGLD output.
    /// @param execution Recipient and snapshotted ordered Core-asset binding.
    /// @param permit Token-native allowance authorization covering the declared input ceiling.
    /// @param legs Compact positional swap legs for non-direct Core inputs.
    /// @return fees Protocol and Helpers fees charged in CYGLD.
    function issueFromTokenExactOutWithPermit(
        IssueFromTokenExactOutParams calldata params,
        IssueExecutionParams calldata execution,
        PermitParams calldata permit,
        IssueSwapLeg[] calldata legs
    ) external whenNotPaused nonReentrant returns (Fees memory fees) {
        if (params.inputToken == address(0)) revert ZeroAddress();
        IssueAuthorization memory authorization;
        authorization.mode = IssueAuthorizationMode.TokenPermit;
        authorization.permit = _copyPermit(permit);
        return _issueExactOut(_tokenRouteRequest(params, execution), legs, authorization);
    }

    /// @notice Deliver an exact net CYGLD amount from one ERC-20 input authorized through Permit2.
    /// @param params Token identity, caller input ceiling, and desired net CYGLD output.
    /// @param execution Recipient and snapshotted ordered Core-asset binding.
    /// @param permit One-time Permit2 transfer authorization for the declared input ceiling.
    /// @param legs Compact positional swap legs for non-direct Core inputs.
    /// @return fees Protocol and Helpers fees charged in CYGLD.
    function issueFromTokenExactOutWithPermit2(
        IssueFromTokenExactOutParams calldata params,
        IssueExecutionParams calldata execution,
        Permit2Params calldata permit,
        IssueSwapLeg[] calldata legs
    ) external whenNotPaused nonReentrant returns (Fees memory fees) {
        if (params.inputToken == address(0)) revert ZeroAddress();
        IssueAuthorization memory authorization;
        authorization.mode = IssueAuthorizationMode.Permit2;
        authorization.permit2 = _copyPermit2(permit);
        return _issueExactOut(_tokenRouteRequest(params, execution), legs, authorization);
    }

    /// @notice Deliver an exact net CYGLD amount from native ETH, wrapping the exact declared budget.
    /// @param params Native input budget and desired net CYGLD output.
    /// @param execution Recipient and snapshotted ordered Core-asset binding.
    /// @param legs Compact positional swap legs for every Core input.
    /// @return fees Protocol and Helpers fees charged in CYGLD.
    function issueFromNativeExactOut(
        IssueFromNativeExactOutParams calldata params,
        IssueExecutionParams calldata execution,
        IssueSwapLeg[] calldata legs
    ) external payable whenNotPaused nonReentrant returns (Fees memory fees) {
        if (msg.value != params.maximumNativeIn) {
            revert NativeValueMismatch(params.maximumNativeIn, msg.value);
        }
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        if (rs.wrappedNative == address(0)) revert WrappedNativeNotSet();

        IssueRouteRequest memory request;
        request.inputToken = rs.wrappedNative;
        request.inputTokenForEvent = address(0);
        request.inputIsNative = true;
        request.maximumInputAmount = params.maximumNativeIn;
        request.netCygldOut = params.netCygldOut;
        request.recipient = execution.recipient;
        request.expectedOrderedCoreAssets = execution.expectedOrderedCoreAssets;

        IssueAuthorization memory authorization;
        return _issueExactOut(request, legs, authorization);
    }

    /// @dev Copy public token-route calldata into the normalized exact-output request.
    function _tokenRouteRequest(IssueFromTokenExactOutParams calldata params, IssueExecutionParams calldata execution)
        internal
        pure
        returns (IssueRouteRequest memory request)
    {
        request.inputToken = params.inputToken;
        request.inputTokenForEvent = params.inputToken;
        request.maximumInputAmount = params.maximumInputAmount;
        request.netCygldOut = params.netCygldOut;
        request.recipient = execution.recipient;
        request.expectedOrderedCoreAssets = execution.expectedOrderedCoreAssets;
    }

    /// @dev Execute one exact-output route from a snapshotted Core preview through `safeIssue`.
    function _issueExactOut(
        IssueRouteRequest memory request,
        IssueSwapLeg[] calldata legs,
        IssueAuthorization memory authorization
    ) internal returns (Fees memory fees) {
        if (request.recipient == address(0) || request.recipient == address(this)) {
            revert InvalidRecipient();
        }
        if (request.netCygldOut == 0 || request.maximumInputAmount == 0) revert ZeroInputAmount();

        LibAppStorage.RouterStorage storage rs = _routerStorage();
        IssueContext memory ctx;
        ctx.payer = msg.sender;
        ctx.recipient = request.recipient;
        ctx.inputToken = IERC20(request.inputToken);
        ctx.inputTokenForEvent = request.inputTokenForEvent;
        ctx.inputIsNative = request.inputIsNative;
        ctx.maximumInputAmount = request.maximumInputAmount;

        (ctx.coreNetCygldOut, ctx.helperFeeCygld) = _grossForNet(request.netCygldOut, rs.helperFeePpm);
        (, ctx.maximumCoreInputs, ctx.coreAssets) = _previewCoreIssueExactOut(rs, ctx.coreNetCygldOut);
        _validateOrderedBasketAssets(request.expectedOrderedCoreAssets, ctx.coreAssets);
        _validateExactOutIssueLegs(
            rs, ctx.coreAssets, ctx.maximumCoreInputs, address(ctx.inputToken), request.maximumInputAmount, legs
        );

        ctx.inputBalanceBefore = ctx.inputToken.balanceOf(address(this));
        if (request.inputIsNative) {
            IWETH(address(ctx.inputToken)).deposit{value: request.maximumInputAmount}();
        } else if (authorization.mode == IssueAuthorizationMode.TokenPermit) {
            _acquireWithPermit(ctx.payer, ctx.inputToken, request.maximumInputAmount, authorization.permit);
        } else if (authorization.mode == IssueAuthorizationMode.Permit2) {
            _acquireWithPermit2(ctx.payer, ctx.inputToken, request.maximumInputAmount, authorization.permit2);
        } else {
            _acquireWithAllowance(ctx.payer, ctx.inputToken, request.maximumInputAmount);
        }
        ctx.assetBalancesBefore = _snapshotRequiredCoreBalances(ctx.coreAssets, ctx.maximumCoreInputs);

        _executeIssueSwaps(rs, ctx, legs);
        _approveCoreInputs(rs, ctx.coreAssets, ctx.maximumCoreInputs);
        IssueSettlementResult memory settlement = _issueToRecipient(rs, ctx);
        _finalizeIssue(ctx, settlement);

        fees.protocolFeeCygld = settlement.protocolFeeCygld;
        fees.helperFeeCygld = ctx.helperFeeCygld;
    }

    /// @dev Acquire every non-direct Core input in canonical compact order.
    function _executeIssueSwaps(
        LibAppStorage.RouterStorage storage rs,
        IssueContext memory ctx,
        IssueSwapLeg[] calldata legs
    ) internal {
        uint256 remainingInput = ctx.maximumInputAmount;
        uint256 cursor;
        uint256 assetCount = ctx.coreAssets.length;
        for (uint256 i; i < assetCount; ++i) {
            address asset = ctx.coreAssets[i];
            uint256 requiredAmount = ctx.maximumCoreInputs[i];
            if (requiredAmount == 0) continue;

            if (asset == address(ctx.inputToken)) {
                remainingInput -= requiredAmount;
                continue;
            }

            IssueSwapLeg calldata leg = legs[cursor++];
            remainingInput -= leg.amountIn;
            _executeIssueSwap(rs, ctx.inputToken, asset, requiredAmount, leg);
        }
    }

    /// @dev Execute and measure one approved ERC-20 adapter leg.
    function _executeIssueSwap(
        LibAppStorage.RouterStorage storage rs,
        IERC20 inputToken,
        address outputAsset,
        uint256 requiredAmount,
        IssueSwapLeg calldata leg
    ) internal {
        if (!_isAdapterApproved(rs, leg.adapter)) revert AdapterNotApproved(leg.adapter);

        uint256 inputBefore = inputToken.balanceOf(address(this));
        inputToken.forceApprove(leg.adapter, leg.amountIn);
        IERC20 outputToken = IERC20(outputAsset);
        uint256 outputBefore = outputToken.balanceOf(address(this));
        uint256 returned = ISwapAdapter(leg.adapter).swap(address(inputToken), outputAsset, leg.amountIn, leg.data);
        uint256 outputAfter = outputToken.balanceOf(address(this));
        uint256 inputAfter = inputToken.balanceOf(address(this));
        inputToken.forceApprove(leg.adapter, 0);

        _requireAdapterInputDebitAtMost(address(inputToken), leg.adapter, inputBefore, inputAfter, leg.amountIn);
        uint256 amountOut = outputAfter >= outputBefore ? outputAfter - outputBefore : 0;
        if (amountOut != returned) {
            revert AdapterOutputMismatch(outputAsset, leg.adapter, returned, amountOut);
        }
        if (amountOut < requiredAmount) {
            revert InsufficientOutputForNeed(outputAsset, requiredAmount, amountOut);
        }
        if (amountOut < leg.minimumAmountOut) {
            revert InsufficientOutputForMinAmountOut(outputAsset, leg.minimumAmountOut, amountOut);
        }
    }
}
