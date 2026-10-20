// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TradeExactInputBase} from "./TradeExactInputBase.sol";
import {CoreIssueExecution} from "../libraries/CoreIssueExecution.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Core operations leave scalar proceeds owned by the current trade until aggregate payout.
abstract contract TradeExactInputCoreBase is TradeExactInputBase {
    /// @notice Bind inherited exact-input funding and routing modules.
    /// @param permit2_ Release-wide Permit2 identity.
    /// @param adapter_ No-hook successor adapter.
    constructor(address permit2_, address adapter_) TradeExactInputBase(permit2_, adapter_) {}

    /// @notice One Core redemption preview, custody baselines and fee basis.
    struct CoreSaleWork {
        address core;
        uint256 gross;
        uint256 helperFee;
        uint256 cygldBefore;
        ICoreRedemption.RedemptionQuote projected;
        uint256[] balances;
    }

    function _buyCore(address payment, uint256 amount, CoreBuyBody memory body, Execution memory ex) internal {
        address[] memory assets = _loadBasketAssets();
        _validateOrderedBasketAssets(body.basketAssets, assets);
        if (body.acquisitions.length != assets.length) {
            revert QuoteLengthMismatch(body.acquisitions.length, assets.length);
        }
        uint256[] memory lots = new uint256[](assets.length);
        uint256 remaining = amount;
        for (uint256 i; i < assets.length; ++i) {
            Acquisition memory acquisition = body.acquisitions[i];
            remaining -= acquisition.amountIn;
            lots[i] = _convert(payment, acquisition.amountIn, acquisition.route, assets[i], ex);
        }
        _retain(ex, payment, remaining);
        _issueLots(assets, lots, body.continuations, ex);
    }

    function _issueLots(
        address[] memory assets,
        uint256[] memory lots,
        Continuation[] memory continuations,
        Execution memory ex
    ) internal {
        if (continuations.length != assets.length) {
            revert QuoteLengthMismatch(continuations.length, assets.length);
        }
        address core = _routerStorage().coreDiamond;
        (uint256 target, uint256 previewFee, uint256[] memory maxima, address[] memory ordered) =
            ICyberGoldCore(core).previewIssueFromBasketExactIn(lots);
        _validateCoreBasketAmounts(ordered, maxima);
        _validateOrderedBasketAssets(assets, ordered);
        uint256[] memory actual = new uint256[](assets.length);
        if (target != 0) {
            uint256 protocolFee;
            (protocolFee, actual) = CoreIssueExecution.settle(core, ordered, maxima, target);
            if (protocolFee != previewFee) revert CoreIssuanceResultMismatch();
            ex.result.coreProtocolFeeCygld += protocolFee;
            uint256 fee = Math.mulDiv(target, _routerStorage().helperFeePpm, PPM_DENOMINATOR);
            ex.result.coreHelpersFeeCygld += fee;
            ex.netOutput += target - fee;
        }
        for (uint256 i; i < assets.length; ++i) {
            uint256 residual = lots[i] - actual[i];
            _appendStage(ex, StageResult(0, 0, assets[i], core, lots[i], residual, actual[i], 0, i == 0 ? target : 0));
            if (residual == 0) continue;
            Continuation memory continuation = continuations[i];
            uint256 gross = _convert(assets[i], residual, continuation.route, core, ex);
            // The stage funds its own fee; sibling CYGLD cannot subsidize a tiny continuation.
            if (gross < continuation.feeCygld) revert InsufficientOutput(continuation.feeCygld, gross);
            ex.result.marketFeeCygld += continuation.feeCygld;
            ex.netOutput += gross - continuation.feeCygld;
        }
    }

    function _sellCore(
        uint256 amount,
        CoreSellBody memory body,
        address recipient,
        address desired,
        bool vector,
        Execution memory ex
    ) internal {
        CoreSaleWork memory w;
        w.core = _routerStorage().coreDiamond;
        (w.gross, w.helperFee, w.projected) = _previewCoreRedemption(w.core, _routerStorage().helperFeePpm, amount);
        _validateQuoteMinimums(w.projected.outputs, body.expectedOutputs);
        if (!vector) _requireAggregateMinimum(w.projected.outputs, ex.minimumOutput);
        w.balances = _snapshotCoreOutputBalances(w.projected.outputs);
        w.cygldBefore = IERC20(w.core).balanceOf(address(this));
        _armRecoveryReceipt(w.core, recipient, w.projected.outputs);
        ICoreRedemption.RedemptionQuote memory settled =
            ICoreRedemption(w.core).safeRedeem(w.gross, body.expectedOutputs);
        _requireExactRouterDebit(w.core, w.cygldBefore, IERC20(w.core).balanceOf(address(this)), w.gross);
        _validateSettledRedemption(w.core, w.gross, w.projected, settled, body.expectedOutputs, w.balances);
        _completeRecoveryReceipt(w.projected.outputs);
        ex.result.coreProtocolFeeCygld += settled.protocolFeeCygld;
        ex.result.coreHelpersFeeCygld += w.helperFee;
        _appendRecovery(ex, settled.outputs);
        if (vector) {
            ex.result.recipientOutputs = settled.outputs;
            for (uint256 i; i < settled.outputs.length; ++i) {
                ICoreRedemption.TokenAmount memory output = settled.outputs[i];
                if (output.kind == ICoreRedemption.TokenKind.ERC20) {
                    _payCurrency(recipient, output.token, output.amount);
                }
            }
        } else {
            if (body.conversions.length != settled.outputs.length) {
                revert QuoteLengthMismatch(body.conversions.length, settled.outputs.length);
            }
            for (uint256 i; i < settled.outputs.length; ++i) {
                ICoreRedemption.TokenAmount memory output = settled.outputs[i];
                if (output.kind == ICoreRedemption.TokenKind.ERC20) {
                    ex.netOutput += _convert(output.token, output.amount, body.conversions[i], desired, ex);
                }
            }
        }
    }
}
