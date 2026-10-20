// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IBasketRouterTypes} from "./IBasketRouterTypes.sol";
import {IUniswapRoutingTypes} from "./IUniswapRoutingTypes.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Typed, atomic exact-input trades. Native currency is address zero.
interface ITradeExactInput is IBasketRouterTypes {
    /// @notice Supported scalar and direct-vector execution intents.
    enum Intent {
        BuyCygld,
        SellCygld,
        IssueBasket,
        RedeemBasket
    }
    /// @notice Primary issuance/redemption or CYGLD-paired AMM execution.
    enum BranchKind {
        Core,
        Market
    }

    /// @notice One exact acquired or realized physical currency lot.
    struct AssetAmount {
        address currency;
        uint256 amount;
    }

    /// @notice One connected path; final route receives the integer allocation remainder.
    struct WeightedRoute {
        uint32 sharePpm;
        IUniswapRoutingTypes.Step[] steps;
    }

    /// @notice Runtime amount is supplied by its owning branch, never the quoted payload.
    struct AmmTemplate {
        address inputCurrency;
        address outputCurrency;
        uint256 minimumOutput;
        WeightedRoute[] routes;
    }

    /// @notice Post-issue actual residual conversion with one final CYGLD Market fee.
    struct Continuation {
        AmmTemplate route;
        uint256 feeCygld;
    }

    /// @notice Literal allocation of a Core purchase payment budget to one basket position.
    struct Acquisition {
        uint256 amountIn;
        AmmTemplate route;
    }

    /// @notice Ordered basket acquisition and mandatory runtime residual conversion templates.
    struct CoreBuyBody {
        address[] basketAssets;
        Acquisition[] acquisitions;
        Continuation[] continuations;
    }

    /// @notice Complete Core output binding and positionally aligned output conversions.
    struct CoreSellBody {
        ICoreRedemption.TokenMinimum[] expectedOutputs;
        AmmTemplate[] conversions;
    }

    /// @notice CYGLD-paired primary Market conversion and its literal CYGLD fee.
    struct MarketBody {
        AmmTemplate route;
        uint256 feeCygld;
    }

    /// @notice data decodes to CoreBuyBody/CoreSellBody/MarketBody according to intent/kind.
    struct TradeBranch {
        BranchKind kind;
        uint256 amountIn;
        bytes data;
    }

    /// @notice Primary Core/Market branches in their execution and rounding order.
    struct ScalarBody {
        TradeBranch[] branches;
    }

    /// @notice Explicitly funded direct basket issuance and ordered residual templates.
    struct BasketIssueBody {
        Continuation[] continuations;
    }

    /// @notice Direct redemption bound to the complete canonical ERC20/ERC1155 vector.
    struct BasketRedeemBody {
        ICoreRedemption.TokenMinimum[] expectedOutputs;
    }

    /// @notice body decodes to ScalarBody, BasketIssueBody or BasketRedeemBody.
    struct ExactInputPlan {
        Intent intent;
        AssetAmount[] inputs;
        address outputCurrency;
        address recipient;
        uint256 deadline;
        uint256 minimumOutput;
        bytes body;
    }

    /// @notice Existing allowance, token permit or batch Permit2 acquisition for one input.
    struct FundingAuthorization {
        BasketInputAuthorization kind;
        PermitParams permit;
    }

    /// @notice Aligned input authorizations and one compact positive-lot Permit2 batch.
    struct FundingBundle {
        FundingAuthorization[] authorizations;
        Permit2BatchParams permit2;
    }

    /// @notice Currency-specific funded, returned, consumed, gained and delivered stage amounts.
    struct StageResult {
        uint256 branch;
        uint256 stage;
        address inputCurrency;
        address outputCurrency;
        uint256 fundedInput;
        uint256 returnedInput;
        uint256 consumedInput;
        uint256 inputGain;
        uint256 amountOut;
    }

    /// @notice Actual protocol-owned input return, kept in Helpers and excluded from spendable lots.
    struct RetainedInputCharge {
        uint256 branch;
        uint256 stage;
        address currency;
        uint256 amount;
    }

    /// @notice Aggregate settlement; retained charges explain gross acquisition and are not added to it.
    struct TradeResult {
        AssetAmount[] acquiredInputs;
        StageResult[] stages;
        ICoreRedemption.TokenAmount[] recipientOutputs;
        ICoreRedemption.TokenAmount[] recoveryShares;
        RetainedInputCharge[] retainedInputs;
        uint256 coreProtocolFeeCygld;
        uint256 coreHelpersFeeCygld;
        uint256 marketFeeCygld;
        address retainedCustodian;
        address feeBeneficiaryAtSettlement;
    }

    /// @notice A template does not spend or deliver its caller-owned currency.
    /// @param actual Currency supplied or delivered by the current owned lot.
    /// @param expected Declared currency to be spent or delivered.
    error RouteCurrencyMismatch(address actual, address expected);
    /// @notice Trade deadline uses the same timestamp contract as adapter execution.
    /// @param deadline Caller-selected last execution timestamp.
    /// @param timestamp Current execution timestamp.
    error TradeExpired(uint256 deadline, uint256 timestamp);

    /// @notice One authoritative aggregate receipt emitted after successful settlement.
    /// @param payer Caller from whom exact original inputs were acquired.
    /// @param recipient Recipient of all favorable net outputs and recovery shares.
    /// @param intent Executed scalar or vector intent.
    /// @param result Acquisitions, stage amounts, fees, retained assets and recipient outputs.
    event ExactInputExecuted(address indexed payer, address indexed recipient, Intent intent, TradeResult result);

    /// @notice Acquire exact original inputs and execute all selected branches atomically.
    /// @param plan Typed caller intent, original acquired amounts, execution bodies and output bounds.
    /// @param funding Existing allowance or signed authorization for each exact acquired token lot.
    /// @return result Actual aggregate settlement, including disclosed protocol-retained input.
    function executeExactInput(ExactInputPlan calldata plan, FundingBundle calldata funding)
        external
        payable
        returns (TradeResult memory result);
}
