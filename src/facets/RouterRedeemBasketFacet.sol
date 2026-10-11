// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RouterRedemptionCoreBase} from "./RouterRedemptionCoreBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Direct delivery of Core's complete current-state ERC-20/ERC-1155 redemption vector.
contract RouterRedeemBasketFacet is RouterRedemptionCoreBase {
    /// @notice One direct-basket redemption's snapshotted parties, fees, and Core preview.
    struct BasketRedemptionContext {
        address payer;
        address core;
        uint256 coreGrossCygldIn;
        uint256 helperFeeCygld;
        uint256 cygldBalanceBeforeCore;
        uint256[] coreOutputBalancesBefore;
        ICoreRedemption.RedemptionQuote projected;
    }

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

    /// @notice Redeem CYGLD directly to the complete mixed basket using existing allowance.
    /// @param request Outer gross input, recipient, and complete caller-bound Core output vector.
    /// @return result Complete realized output vector and fee split.
    function redeemToBasketExactIn(BasketRedemptionRequest calldata request)
        external
        whenNotPaused
        nonReentrant
        returns (BasketRedemptionResult memory result)
    {
        BasketRedemptionContext memory ctx = _prepareBasketRedemption(request);
        _acquireWithAllowance(ctx.payer, IERC20(ctx.core), request.grossCygldIn);
        return _settleBasketRedemption(request, ctx);
    }

    /// @notice Redeem CYGLD directly to the complete mixed basket using CYGLD's ERC-2612 permit.
    /// @param request Outer gross input, recipient, and complete caller-bound Core output vector.
    /// @param permit CYGLD ERC-2612 authorization.
    /// @return result Complete realized output vector and fee split.
    function redeemToBasketExactInWithPermit(BasketRedemptionRequest calldata request, PermitParams calldata permit)
        external
        whenNotPaused
        nonReentrant
        returns (BasketRedemptionResult memory result)
    {
        BasketRedemptionContext memory ctx = _prepareBasketRedemption(request);
        _acquireWithPermit(ctx.payer, IERC20(ctx.core), request.grossCygldIn, _copyPermit(permit));
        return _settleBasketRedemption(request, ctx);
    }

    /// @notice Redeem CYGLD directly to the complete mixed basket using Permit2.
    /// @param request Outer gross input, recipient, and complete caller-bound Core output vector.
    /// @param permit One-time Permit2 authorization for the exact outer gross input.
    /// @return result Complete realized output vector and fee split.
    function redeemToBasketExactInWithPermit2(BasketRedemptionRequest calldata request, Permit2Params calldata permit)
        external
        whenNotPaused
        nonReentrant
        returns (BasketRedemptionResult memory result)
    {
        BasketRedemptionContext memory ctx = _prepareBasketRedemption(request);
        _acquireWithPermit2(ctx.payer, IERC20(ctx.core), request.grossCygldIn, _copyPermit2(permit));
        return _settleBasketRedemption(request, ctx);
    }

    /// @dev Snapshot one direct-basket redemption before the selected authorization mechanism runs.
    function _prepareBasketRedemption(BasketRedemptionRequest calldata request)
        internal
        view
        returns (BasketRedemptionContext memory ctx)
    {
        if (request.recipient == address(0) || request.recipient == address(this)) {
            revert InvalidRecipient();
        }
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        ctx.payer = msg.sender;
        ctx.core = rs.coreDiamond;
        (ctx.coreGrossCygldIn, ctx.helperFeeCygld, ctx.projected) =
            _previewCoreRedemption(ctx.core, rs.helperFeePpm, request.grossCygldIn);
        _validateQuoteMinimums(ctx.projected.outputs, request.expectedCoreOutputs);
    }

    /// @dev Settle once, deliver every ERC-20 directly, and rely on the armed callback for ERC-1155 delivery.
    function _settleBasketRedemption(BasketRedemptionRequest calldata request, BasketRedemptionContext memory ctx)
        internal
        returns (BasketRedemptionResult memory result)
    {
        IERC20 cygld = IERC20(ctx.core);
        if (ctx.helperFeeCygld != 0) {
            _payoutTokenExact(_feeRecipient(), ctx.core, false, ctx.helperFeeCygld);
        }
        ctx.cygldBalanceBeforeCore = cygld.balanceOf(address(this));
        ctx.coreOutputBalancesBefore = _snapshotCoreOutputBalances(ctx.projected.outputs);
        _armRecoveryReceipt(ctx.core, request.recipient, ctx.projected.outputs);

        ICoreRedemption.RedemptionQuote memory settled =
            ICoreRedemption(ctx.core).safeRedeem(ctx.coreGrossCygldIn, request.expectedCoreOutputs);
        _requireExactRouterDebit(
            ctx.core, ctx.cygldBalanceBeforeCore, cygld.balanceOf(address(this)), ctx.coreGrossCygldIn
        );
        _validateSettledRedemption(
            ctx.core,
            ctx.coreGrossCygldIn,
            ctx.projected,
            settled,
            request.expectedCoreOutputs,
            ctx.coreOutputBalancesBefore
        );
        _completeRecoveryReceipt(ctx.projected.outputs);

        _payoutDirectErc20Outputs(request.recipient, settled.outputs);
        result.outputs = settled.outputs;
        result.fees.protocolFeeCygld = settled.protocolFeeCygld;
        result.fees.helperFeeCygld = ctx.helperFeeCygld;
        _emitRedeemedToBasket(ctx.payer, request.recipient, request.grossCygldIn, result);
    }

    /// @dev Deliver each positive ERC-20 output exactly; ERC-1155 outputs were forwarded in the callback.
    function _payoutDirectErc20Outputs(address recipient, ICoreRedemption.TokenAmount[] memory outputs) internal {
        for (uint256 i; i < outputs.length;) {
            ICoreRedemption.TokenAmount memory output = outputs[i];
            if (output.kind == ICoreRedemption.TokenKind.ERC20 && output.amount != 0) {
                _payoutTokenExact(recipient, output.token, false, output.amount);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Render one complete realized mixed-output result without recovery-specific aliases.
    function _emitRedeemedToBasket(
        address payer,
        address recipient,
        uint256 grossCygldIn,
        BasketRedemptionResult memory result
    ) internal {
        uint256 outputCount = result.outputs.length;
        ICoreRedemption.TokenKind[] memory kinds = new ICoreRedemption.TokenKind[](outputCount);
        address[] memory tokens = new address[](outputCount);
        uint256[] memory ids = new uint256[](outputCount);
        uint256[] memory amounts = new uint256[](outputCount);
        for (uint256 i; i < outputCount;) {
            ICoreRedemption.TokenAmount memory output = result.outputs[i];
            kinds[i] = output.kind;
            tokens[i] = output.token;
            ids[i] = output.id;
            amounts[i] = output.amount;
            unchecked {
                ++i;
            }
        }
        emit RedeemedToBasket(
            payer,
            recipient,
            grossCygldIn,
            kinds,
            tokens,
            ids,
            amounts,
            result.fees.protocolFeeCygld,
            result.fees.helperFeeCygld
        );
    }
}
