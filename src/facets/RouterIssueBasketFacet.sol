// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {RouterIssueSettlementBase} from "./RouterIssueSettlementBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";

/// @notice Atomic direct-basket Core issuance using Permit2 or mixed token authorizations.
contract RouterIssueBasketFacet is RouterIssueSettlementBase {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.issue.basket");

    /// @notice Bind this facet implementation to the release-wide immutable Permit2 identity.
    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) RouterIssueSettlementBase(permit2_) {}

    /// @notice One Core preview and fee split preserved through basket acquisition and settlement.
    struct BasketIssueContext {
        address recipient;
        address[] assets;
        uint256[] maximumCoreInputs;
        uint256 coreNetCygldOut;
        uint256 helperFeeCygld;
        uint256 protocolFeeCygld;
    }

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

    /// @notice Issue one exact recipient net amount with mixed per-asset acquisition authorizations.
    /// @param request Exact recipient net CYGLD output and recipient.
    /// @param inputs Caller ceilings and authorizations in complete Core order, including zero-required members.
    /// @param permit2 Compact signed Permit2 batch for only the Permit2-authorized inputs in Core order.
    /// @return result Realized recipient output, fee split, and actual Core input debits.
    function issueFromBasketExactOutWithMixedPermits(
        BasketIssueExactOutRequest calldata request,
        BasketIssueInput[] calldata inputs,
        Permit2BatchParams calldata permit2
    ) external whenNotPaused nonReentrant returns (BasketIssueResult memory result) {
        if (request.recipient == address(0) || request.recipient == address(this)) revert InvalidRecipient();

        LibAppStorage.RouterStorage storage rs = _routerStorage();
        BasketIssueContext memory ctx;
        ctx.recipient = request.recipient;
        (ctx.coreNetCygldOut, ctx.helperFeeCygld) = _grossForNet(request.netCygldOut, rs.helperFeePpm);
        (ctx.protocolFeeCygld, ctx.maximumCoreInputs, ctx.assets) = _previewCoreIssueExactOut(rs, ctx.coreNetCygldOut);
        uint256 permit2Count = _validateMixedInputs(inputs, permit2.permit, ctx.assets, ctx.maximumCoreInputs);
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

    /// @notice Issue one exact recipient net amount against signed per-asset ceilings.
    /// @dev The signed Permit2 permissions are the sole caller-bound asset order and input ceilings.
    /// @param request Exact recipient net CYGLD output and recipient.
    /// @param permit Atomic ordered basket authorization and signature.
    /// @return result Realized recipient output, fee split, and actual Core input debits.
    function issueFromBasketExactOutWithPermit2(
        BasketIssueExactOutRequest calldata request,
        Permit2BatchParams calldata permit
    ) external whenNotPaused nonReentrant returns (BasketIssueResult memory result) {
        if (request.recipient == address(0) || request.recipient == address(this)) revert InvalidRecipient();

        LibAppStorage.RouterStorage storage rs = _routerStorage();
        uint256 coreNetCygldOut;
        uint256 helperFeeCygld;
        (coreNetCygldOut, helperFeeCygld) = _grossForNet(request.netCygldOut, rs.helperFeePpm);

        uint256 protocolFeeCygld;
        uint256[] memory amountsInExact;
        address[] memory orderedCoreAssets;
        (protocolFeeCygld, amountsInExact, orderedCoreAssets) = _previewCoreIssueExactOut(rs, coreNetCygldOut);
        _validatePermitBatch(permit.permit, orderedCoreAssets, amountsInExact);

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

    /// @dev Pull only fresh exact lots, settle within signed ceilings, refund surplus, and emit once.
    function _executeBasketIssue(
        LibAppStorage.RouterStorage storage rs,
        address recipient,
        Permit2BatchParams calldata permit,
        address[] memory orderedCoreAssets,
        uint256[] memory amountsInExact,
        uint256 coreNetCygldOut,
        uint256 helperFeeCygld,
        uint256 previewProtocolFeeCygld
    ) internal returns (BasketIssueResult memory result) {
        uint256[] memory balancesBefore = _snapshotRequiredCoreBalances(orderedCoreAssets, amountsInExact);
        _pullBasketWithPermit2(msg.sender, orderedCoreAssets, amountsInExact, balancesBefore, permit);
        BasketIssueContext memory ctx;
        ctx.recipient = recipient;
        ctx.assets = orderedCoreAssets;
        ctx.maximumCoreInputs = amountsInExact;
        ctx.coreNetCygldOut = coreNetCygldOut;
        ctx.helperFeeCygld = helperFeeCygld;
        ctx.protocolFeeCygld = previewProtocolFeeCygld;
        return _settleBasketIssue(rs, ctx, balancesBefore);
    }

    /// @dev Share unchanged Core settlement, exact debits, refunds, fees, and the sole vector event.
    function _settleBasketIssue(
        LibAppStorage.RouterStorage storage rs,
        BasketIssueContext memory ctx,
        uint256[] memory balancesBefore
    ) internal returns (BasketIssueResult memory result) {
        _approveCoreInputs(rs, ctx.assets, ctx.maximumCoreInputs);

        IssueSettlementResult memory settlement = _settleCoreIssue(
            rs, ctx.recipient, ctx.assets, ctx.maximumCoreInputs, ctx.coreNetCygldOut, ctx.helperFeeCygld
        );
        // Core's protocol fee is part of the caller-visible preview. The current Core safe endpoint
        // returns that same fee for the fixed target or reverts atomically.
        if (settlement.protocolFeeCygld != ctx.protocolFeeCygld) revert CoreIssuanceResultMismatch();

        _settleRemainingRequiredCoreAssets(msg.sender, ctx.assets, ctx.maximumCoreInputs, balancesBefore, address(0));

        result.netCygldOut = settlement.netCygldOut;
        result.fees.protocolFeeCygld = settlement.protocolFeeCygld;
        result.fees.helperFeeCygld = ctx.helperFeeCygld;
        result.actualAmountsIn = settlement.actualAmountsIn;
        emit IssuedFromBasket(
            msg.sender,
            ctx.recipient,
            ctx.assets,
            settlement.actualAmountsIn,
            result.netCygldOut,
            result.fees.protocolFeeCygld,
            result.fees.helperFeeCygld
        );
    }

    /// @dev Reuse Core order/length, caller ceiling, and signed Permit2 subset invariants before acquisition.
    function _validateMixedInputs(
        BasketIssueInput[] calldata inputs,
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        address[] memory assets,
        uint256[] memory amounts
    ) internal view returns (uint256 permit2Count) {
        uint256 count = assets.length;
        if (inputs.length != count) revert CoreAssetAmountsLengthMismatch(count, inputs.length);
        for (uint256 i; i < count; ++i) {
            if (inputs[i].token != assets[i]) revert CoreAssetMismatch(i, inputs[i].token, assets[i]);
            if (inputs[i].maximumInputAmount < amounts[i]) revert InsufficientInput();
            if (inputs[i].authorization == BasketInputAuthorization.Permit2) ++permit2Count;
        }
        if (permit2Count == 0) return 0;
        if (permit.permitted.length != permit2Count) {
            revert Permit2BatchLengthMismatch(permit.permitted.length, permit2Count);
        }
        // Permit2 defines its signed deadline against the block timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        if (permit.deadline == 0 || permit.deadline < block.timestamp) {
            revert PermitExpired(permit.deadline, block.timestamp);
        }
        uint256 cursor;
        for (uint256 i; i < count; ++i) {
            if (inputs[i].authorization != BasketInputAuthorization.Permit2) continue;
            ISignatureTransfer.TokenPermissions calldata permission = permit.permitted[cursor++];
            if (permission.token != assets[i]) revert InvalidPermit2Token(permission.token, assets[i]);
            if (permission.amount < amounts[i]) revert Permit2AmountTooLow(permission.amount, amounts[i]);
        }
    }

    /// @dev Acquire only the fresh exact Core lots, then run the retained settlement once.
    function _executeMixedBasketIssue(
        LibAppStorage.RouterStorage storage rs,
        BasketIssueContext memory ctx,
        BasketIssueInput[] calldata inputs,
        Permit2BatchParams calldata permit,
        uint256 permit2Count
    ) internal returns (BasketIssueResult memory result) {
        uint256 count = ctx.assets.length;
        uint256[] memory balancesBefore = _snapshotRequiredCoreBalances(ctx.assets, ctx.maximumCoreInputs);
        uint256[] memory payerBalancesBefore = new uint256[](count);
        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](permit2Count);
        uint256 cursor;
        for (uint256 i; i < count; ++i) {
            uint256 amount = ctx.maximumCoreInputs[i];
            if (amount != 0) payerBalancesBefore[i] = IERC20(ctx.assets[i]).balanceOf(msg.sender);
            if (inputs[i].authorization == BasketInputAuthorization.Permit2) {
                details[cursor++] =
                    ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amount});
            }
        }
        _pullBasketTokenInputs(inputs, ctx.assets, ctx.maximumCoreInputs);
        if (permit2Count != 0) _permit2().permitTransferFrom(permit.permit, details, msg.sender, permit.signature);
        _requireExactBasketPull(msg.sender, ctx.assets, ctx.maximumCoreInputs, balancesBefore, payerBalancesBefore);
        return _settleBasketIssue(rs, ctx, balancesBefore);
    }

    /// @dev Native permits and ordinary allowances reuse exact acquisition and skip zero-required members.
    function _pullBasketTokenInputs(
        BasketIssueInput[] calldata inputs,
        address[] memory assets,
        uint256[] memory amounts
    ) internal {
        for (uint256 i; i < assets.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            if (inputs[i].authorization == BasketInputAuthorization.TokenPermit) {
                _acquireWithPermit(msg.sender, IERC20(assets[i]), amount, _copyPermit(inputs[i].permit));
            } else if (inputs[i].authorization == BasketInputAuthorization.Allowance) {
                _acquireWithAllowance(msg.sender, IERC20(assets[i]), amount);
            }
        }
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

    /// @dev Bind signed permissions exactly to Core's fresh order and require every fresh lot to fit.
    function _validatePermitBatch(
        ISignatureTransfer.PermitBatchTransferFrom calldata permit,
        address[] memory orderedCoreAssets,
        uint256[] memory amountsInExact
    ) internal view {
        uint256 assetCount = orderedCoreAssets.length;
        if (permit.permitted.length != assetCount) {
            revert Permit2BatchLengthMismatch(permit.permitted.length, assetCount);
        }
        // Permit2 defines its signed deadline against the block timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        if (permit.deadline == 0 || permit.deadline < block.timestamp) {
            revert PermitExpired(permit.deadline, block.timestamp);
        }
        for (uint256 i; i < assetCount;) {
            ISignatureTransfer.TokenPermissions calldata permission = permit.permitted[i];
            address expectedAsset = orderedCoreAssets[i];
            if (permission.token != expectedAsset) revert InvalidPermit2Token(permission.token, expectedAsset);
            if (permission.amount < amountsInExact[i]) {
                revert Permit2AmountTooLow(permission.amount, amountsInExact[i]);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Execute one Permit2 batch and prove exact payer debits and Helpers credits per asset.
    function _pullBasketWithPermit2(
        address payer,
        address[] memory orderedCoreAssets,
        uint256[] memory amountsInExact,
        uint256[] memory balancesBefore,
        Permit2BatchParams calldata permit
    ) internal {
        uint256 assetCount = orderedCoreAssets.length;
        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](assetCount);
        uint256[] memory payerBalancesBefore = new uint256[](assetCount);
        for (uint256 i; i < assetCount;) {
            uint256 requestedAmount = amountsInExact[i];
            details[i] =
                ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: requestedAmount});
            if (requestedAmount != 0) payerBalancesBefore[i] = IERC20(orderedCoreAssets[i]).balanceOf(payer);
            unchecked {
                ++i;
            }
        }

        _permit2().permitTransferFrom(permit.permit, details, payer, permit.signature);

        _requireExactBasketPull(payer, orderedCoreAssets, amountsInExact, balancesBefore, payerBalancesBefore);
    }

    /// @dev Prove exact payer debits and exact Helpers credits after one Permit2 batch pull.
    function _requireExactBasketPull(
        address payer,
        address[] memory orderedCoreAssets,
        uint256[] memory amountsInExact,
        uint256[] memory balancesBefore,
        uint256[] memory payerBalancesBefore
    ) internal view {
        uint256 assetCount = orderedCoreAssets.length;
        for (uint256 i; i < assetCount;) {
            address asset = orderedCoreAssets[i];
            uint256 expected = amountsInExact[i];
            if (expected == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }
            _requireExactPayerDebit(asset, payer, payerBalancesBefore[i], IERC20(asset).balanceOf(payer), expected);
            _requireExactTokenCredit(asset, balancesBefore[i], IERC20(asset).balanceOf(address(this)), expected);
            unchecked {
                ++i;
            }
        }
    }
}
