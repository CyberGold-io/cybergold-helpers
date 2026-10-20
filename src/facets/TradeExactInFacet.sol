// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ITradeExactInput} from "../interfaces/ITradeExactInput.sol";
import {TradeExactInputCoreBase} from "./TradeExactInputCoreBase.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Universal atomic exact-input dispatch with disclosed protocol retention.
contract TradeExactInFacet is TradeExactInputCoreBase {
    /// @notice Documentary facet implementation version.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Diamond-local namespace for exact-input execution generation.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.trade.exact-input");

    /// @notice Bind release-wide funding and successor routing identities.
    /// @param permit2_ Existing Permit2 SignatureTransfer identity.
    /// @param adapter_ Immutable approved no-hook successor adapter.
    constructor(address permit2_, address adapter_) TradeExactInputCoreBase(permit2_, adapter_) {}

    /// @inheritdoc ITradeExactInput
    function executeExactInput(ExactInputPlan calldata plan, FundingBundle calldata funding)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (TradeResult memory result)
    {
        if (plan.recipient == address(0) || plan.recipient == address(this)) revert InvalidRecipient();
        // forge-lint: disable-next-line(block-timestamp)
        if (plan.deadline != 0 && plan.deadline < block.timestamp) revert TradeExpired(plan.deadline, block.timestamp);
        _validateIntentInputs(plan);
        Execution memory ex;
        ex.deadline = plan.deadline;
        ex.minimumOutput = plan.minimumOutput;
        ex.result.acquiredInputs = plan.inputs;
        ex.result.retainedCustodian = address(this);
        _acquireInputs(plan, funding);
        if (plan.intent == Intent.IssueBasket) {
            _issueBasket(plan, ex);
        } else if (plan.intent == Intent.RedeemBasket) {
            BasketRedeemBody memory body = abi.decode(plan.body, (BasketRedeemBody));
            CoreSellBody memory sell = CoreSellBody(body.expectedOutputs, new AmmTemplate[](0));
            _sellCore(plan.inputs[0].amount, sell, plan.recipient, address(0), true, ex);
        } else {
            _executeScalar(plan, ex);
        }
        ex.result.feeBeneficiaryAtSettlement = _feeRecipient();
        uint256 totalFee = ex.result.coreHelpersFeeCygld + ex.result.marketFeeCygld;
        _payCurrency(ex.result.feeBeneficiaryAtSettlement, _routerStorage().coreDiamond, totalFee);
        if (plan.intent != Intent.RedeemBasket) {
            if (ex.netOutput < plan.minimumOutput) revert InsufficientOutput(plan.minimumOutput, ex.netOutput);
            _payCurrency(plan.recipient, plan.outputCurrency, ex.netOutput);
            ex.result.recipientOutputs = new ICoreRedemption.TokenAmount[](1);
            ex.result.recipientOutputs[0] =
                ICoreRedemption.TokenAmount(ICoreRedemption.TokenKind.ERC20, plan.outputCurrency, 0, ex.netOutput);
        }
        emit ExactInputExecuted(msg.sender, plan.recipient, plan.intent, ex.result);
        return ex.result;
    }

    function _validateIntentInputs(ExactInputPlan calldata plan) private view {
        address core = _routerStorage().coreDiamond;
        if (plan.intent == Intent.IssueBasket) {
            address[] memory provided = new address[](plan.inputs.length);
            for (uint256 i; i < provided.length; ++i) {
                provided[i] = plan.inputs[i].currency;
            }
            _validateOrderedBasketAssets(provided, _loadBasketAssets());
        } else {
            if (plan.inputs.length != 1) revert CoreAssetAmountsLengthMismatch(1, plan.inputs.length);
            if (plan.inputs[0].amount == 0) revert ZeroInputAmount();
            if (plan.intent != Intent.BuyCygld && plan.inputs[0].currency != core) {
                revert RouteCurrencyMismatch(plan.inputs[0].currency, core);
            }
        }
        if (plan.intent == Intent.BuyCygld || plan.intent == Intent.IssueBasket) {
            if (plan.outputCurrency != core) revert RouteCurrencyMismatch(plan.outputCurrency, core);
        }
        if ((plan.intent == Intent.BuyCygld || plan.intent == Intent.IssueBasket) && plan.minimumOutput == 0) {
            revert ZeroFinalMinimum();
        }
    }

    function _issueBasket(ExactInputPlan calldata plan, Execution memory ex) private {
        uint256 count = plan.inputs.length;
        address[] memory assets = new address[](count);
        uint256[] memory lots = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = plan.inputs[i].currency;
            lots[i] = plan.inputs[i].amount;
        }
        BasketIssueBody memory body = abi.decode(plan.body, (BasketIssueBody));
        _issueLots(assets, lots, body.continuations, ex);
    }

    function _executeScalar(ExactInputPlan calldata plan, Execution memory ex) private {
        ScalarBody memory body = abi.decode(plan.body, (ScalarBody));
        uint256 remaining = plan.inputs[0].amount;
        for (uint256 i; i < body.branches.length; ++i) {
            TradeBranch memory branch = body.branches[i];
            remaining -= branch.amountIn;
            ex.branch = i;
            if (branch.amountIn == 0) continue;
            if (branch.kind == BranchKind.Market) {
                _marketBranch(plan.inputs[0].currency, plan.outputCurrency, branch, plan.intent == Intent.BuyCygld, ex);
            } else if (plan.intent == Intent.BuyCygld) {
                _buyCore(plan.inputs[0].currency, branch.amountIn, abi.decode(branch.data, (CoreBuyBody)), ex);
            } else {
                _sellCore(
                    branch.amountIn,
                    abi.decode(branch.data, (CoreSellBody)),
                    plan.recipient,
                    plan.outputCurrency,
                    false,
                    ex
                );
            }
        }
        ex.branch = body.branches.length;
        _retain(ex, plan.inputs[0].currency, remaining);
    }

    function _marketBranch(address input, address output, TradeBranch memory branch, bool buy, Execution memory ex)
        private
    {
        if (ex.minimumOutput == 0) revert ZeroFinalMinimum();
        MarketBody memory market = abi.decode(branch.data, (MarketBody));
        uint256 routed = buy ? branch.amountIn : branch.amountIn - market.feeCygld;
        if (routed == 0) {
            _retain(ex, input, branch.amountIn);
            return;
        }
        uint256 received = _convert(input, routed, market.route, output, ex);
        if (buy) {
            if (received < market.feeCygld) revert InsufficientOutput(market.feeCygld, received);
            received -= market.feeCygld;
        }
        ex.result.marketFeeCygld += market.feeCygld;
        ex.netOutput += received;
    }
}
