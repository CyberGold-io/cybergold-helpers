// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Shared public structs, errors, and events for the Helpers router.
interface IBasketRouterTypes {
    // -------- Types --------
    /// @notice Breakdown of CYGLD-denominated protocol and Helpers fees.
    struct Fees {
        uint256 protocolFeeCygld;
        uint256 helperFeeCygld;
    }

    /// @notice Inputs for issuing an exact net CYGLD amount from one ERC-20.
    struct IssueFromTokenExactOutParams {
        address inputToken;
        uint256 maximumInputAmount;
        uint256 netCygldOut;
    }

    /// @notice Inputs for previewing issuance from one fixed ERC-20 amount.
    struct IssueFromTokenExactInParams {
        address inputToken;
        uint256 inputAmount;
    }

    /// @notice Inputs for issuing an exact net CYGLD amount from native currency.
    struct IssueFromNativeExactOutParams {
        uint256 maximumNativeIn;
        uint256 netCygldOut;
    }

    /// @notice Caller-bound issuance settlement identity.
    struct IssueExecutionParams {
        address recipient;
        address[] expectedOrderedCoreAssets;
    }

    /// @notice One compact canonical issuance swap leg.
    struct IssueSwapLeg {
        address adapter;
        uint256 amountIn;
        uint256 minimumAmountOut;
        bytes data;
    }

    /// @notice One compact canonical redemption swap leg.
    struct RedemptionSwapLeg {
        address adapter;
        uint256 minimumAmountOut;
        bytes data;
    }

    /// @notice Exact-output issuance preview.
    struct IssueExactOutPreview {
        Fees fees;
        address[] orderedCoreAssets;
    }

    /// @notice Exact-input issuance construction preview.
    struct IssueExactInPreview {
        uint256 netCygldOut;
        Fees fees;
        address[] orderedCoreAssets;
    }

    /// @notice Exact-output direct-basket issuance execution bound by one signed Permit2 batch.
    /// @dev The Permit2 batch supplies the canonical asset identities and per-asset input ceilings.
    struct BasketIssueExactOutRequest {
        uint256 netCygldOut;
        address recipient;
    }

    /// @notice Exact-input direct-basket issuance execution bound by one signed Permit2 batch.
    /// @dev The Permit2 batch supplies the canonical asset identities and per-asset input budgets.
    struct BasketIssueExactInRequest {
        address recipient;
        uint256 minimumNetCygldOut;
    }

    /// @notice Direct-basket exact-input issuance construction preview.
    struct BasketIssueExactInPreview {
        uint256 netCygldOut;
        Fees fees;
        uint256[] amountsInExact;
        address[] orderedCoreAssets;
    }

    /// @notice Direct-basket exact-output issuance construction preview.
    struct BasketIssueExactOutPreview {
        Fees fees;
        uint256[] amountsInExact;
        address[] orderedCoreAssets;
    }

    /// @notice Realized direct-basket issuance outcome.
    struct BasketIssueResult {
        uint256 netCygldOut;
        Fees fees;
        uint256[] actualAmountsIn;
    }

    /// @notice Inputs for previewing an exact-input redemption into one ERC-20.
    struct RedeemToTokenExactInParams {
        uint256 grossCygldIn;
        address outputToken;
    }

    /// @notice Aggregated redemption preview with Core's complete mixed output vector.
    struct AggregatedRedemptionPreview {
        uint256 minimumAmountOut;
        ICoreRedemption.TokenAmount[] projectedCoreOutputs;
        Fees fees;
    }

    /// @notice Caller-bound exact-input redemption into one ERC-20.
    struct AggregatedRedemptionRequest {
        uint256 grossCygldIn;
        address outputToken;
        address recipient;
        uint256 minimumAmountOut;
        ICoreRedemption.TokenMinimum[] expectedCoreOutputs;
    }

    /// @notice Caller-bound exact-input redemption into native currency.
    struct AggregatedNativeRedemptionRequest {
        uint256 grossCygldIn;
        address recipient;
        uint256 minimumAmountOut;
        ICoreRedemption.TokenMinimum[] expectedCoreOutputs;
    }

    /// @notice Realized aggregated redemption output and forwarded recovery shares.
    struct AggregatedRedemptionResult {
        uint256 amountOut;
        ICoreRedemption.TokenAmount[] recoveryShareOutputs;
        Fees fees;
    }

    /// @notice Caller-bound direct-basket redemption using Core's complete mixed output vector.
    struct BasketRedemptionRequest {
        uint256 grossCygldIn;
        address recipient;
        ICoreRedemption.TokenMinimum[] expectedCoreOutputs;
    }

    /// @notice Direct-basket exact-input redemption construction preview.
    struct BasketRedemptionExactInPreview {
        ICoreRedemption.TokenAmount[] projectedCoreOutputs;
        Fees fees;
    }

    /// @notice Direct-basket exact-output redemption construction preview.
    struct BasketRedemptionExactOutPreview {
        uint256 grossCygldIn;
        ICoreRedemption.TokenAmount[] projectedCoreOutputs;
        Fees fees;
    }

    /// @notice Realized direct-basket redemption outcome in Core's complete canonical order.
    struct BasketRedemptionResult {
        ICoreRedemption.TokenAmount[] outputs;
        Fees fees;
    }

    /// @notice ERC-2612 permit fields used before pulling tokens from the payer.
    /// @param value Token allowance signed by the payer.
    /// @param deadline Last timestamp at which the token permit may be used.
    /// @param v ECDSA recovery identifier.
    /// @param r First 32 bytes of the ECDSA signature.
    /// @param s Second 32 bytes of the ECDSA signature.
    struct PermitParams {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Permit2 transfer authorization and signature used before pulling tokens from the payer.
    /// @param permit Permit2 token permission, nonce, and signature deadline.
    /// @param signature Payer signature authorizing the Permit2 transfer.
    struct Permit2Params {
        ISignatureTransfer.PermitTransferFrom permit;
        bytes signature;
    }

    /// @notice Atomic Permit2 batch authorization used for direct-basket issuance.
    struct Permit2BatchParams {
        ISignatureTransfer.PermitBatchTransferFrom permit;
        bytes signature;
    }

    /// @notice Acquisition selected for one caller-bound direct-basket input.
    enum BasketInputAuthorization {
        Allowance,
        TokenPermit,
        Permit2
    }

    /// @notice One Core-ordered input ceiling and its acquisition authorization.
    /// @param token Asset identity bound to the execution-time Core order.
    /// @param maximumInputAmount Caller input budget or ceiling for this asset.
    /// @param authorization Existing allowance, token-native permit, or compact Permit2 batch membership.
    /// @param permit Standard ERC-2612 authorization used only by TokenPermit acquisition.
    struct BasketIssueInput {
        address token;
        uint256 maximumInputAmount;
        BasketInputAuthorization authorization;
        PermitParams permit;
    }

    // -------- Errors --------
    /// @notice A required address is zero.
    error ZeroAddress();
    /// @notice The requested payout recipient is the zero address or otherwise unsupported.
    error InvalidRecipient();
    /// @notice An exact-input route was requested with no input tokens.
    error ZeroInputAmount();
    /// @notice Protocol and helper fees consume the entire gross amount, leaving no user amount.
    error AmountTooSmallAfterFees();
    /// @notice The requested net amount cannot be grossed up within `uint256` at the active fee rate.
    /// @param netCygldOut Exact CYGLD amount requested after the applicable fee.
    /// @param feePpm Fee rate used for the attempted exact-net gross-up.
    error GrossForNetOverflow(uint256 netCygldOut, uint256 feePpm);
    /// @notice A quote references a swap adapter that governance has not approved.
    /// @param adapter Swap adapter address checked or configured for routed swaps.
    error AdapterNotApproved(address adapter);
    /// @notice An adapter's reported output differs from the output received by the Helpers diamond.
    /// @param asset Output asset measured by the router.
    /// @param adapter Adapter that executed the route leg.
    /// @param returned Amount reported by the adapter.
    /// @param received Amount actually credited to the Helpers diamond.
    error AdapterOutputMismatch(address asset, address adapter, uint256 returned, uint256 received);
    /// @notice An approved adapter consumed more Router input than its quoted maximum lot.
    /// @param asset Input asset whose Router-side debit was measured.
    /// @param adapter Adapter that executed the route leg.
    /// @param maximum Maximum input amount authorized by the quote.
    /// @param actual Router balance decrease observed across the adapter call.
    error AdapterInputDebitExceeded(address asset, address adapter, uint256 maximum, uint256 actual);
    /// @notice Core returned no current issuance assets.
    error CoreAssetsEmpty();
    /// @notice An amount array does not match Core's current issuance-asset length.
    /// @param assetsLength Number of basket asset entries supplied to the validation.
    /// @param amountsLength Number of amount entries supplied to the validation.
    error CoreAssetAmountsLengthMismatch(uint256 assetsLength, uint256 amountsLength);
    /// @notice Core's issuance target vector does not match its current ordered asset length.
    /// @param assetsLength Number of current ordered basket assets returned by Core.
    /// @param targetsLength Number of current target entries returned by Core.
    error CoreBasketTargetsLengthMismatch(uint256 assetsLength, uint256 targetsLength);
    /// @notice A caller-supplied ordered Core-asset list has a different length than Core's preview list.
    /// @param providedLength Number of expected ordered Core assets supplied by the caller.
    /// @param actualLength Number of ordered assets returned by Core's execution-time preview.
    error ExpectedOrderedCoreAssetsLengthMismatch(uint256 providedLength, uint256 actualLength);
    /// @notice A caller-supplied Core asset differs from Core's preview list at an index.
    /// @param index Core-asset index whose identity differs.
    /// @param provided Asset supplied by the caller at the index.
    /// @param actual Asset returned by Core's execution-time preview at the index.
    error CoreAssetMismatch(uint256 index, address provided, address actual);
    /// @notice The available input-token budget cannot satisfy all required basket legs.
    error InsufficientInput();
    /// @notice A swap quote allocates more input than remains in the route budget.
    /// @param quoteAmount Amount requested by the adapter quote.
    /// @param availableInput Input amount still available for route allocation.
    error InvalidQuoteAmount(uint256 quoteAmount, uint256 availableInput);
    /// @notice An adapter leg produced less of a basket asset than Core requires for issuance.
    /// @param asset ERC20 or basket asset address processed by the flow.
    /// @param minExpected Minimum amount required for the operation to remain valid.
    /// @param received Actual token amount received or observed by the contract.
    error InsufficientOutputForNeed(address asset, uint256 minExpected, uint256 received);
    /// @notice An adapter or payout leg produced less than its caller-provided minimum.
    /// @param asset ERC20 or basket asset address processed by the flow.
    /// @param minExpected Minimum amount required for the operation to remain valid.
    /// @param received Actual token amount received or observed by the contract.
    error InsufficientOutputForMinAmountOut(address asset, uint256 minExpected, uint256 received);
    /// @notice Aggregate settlement output is below the transaction-level minimum.
    /// @param minExpected Minimum amount required for the operation to remain valid.
    /// @param received Actual token amount received or observed by the contract.
    error InsufficientOutput(uint256 minExpected, uint256 received);
    /// @notice A proposed Helpers fee exceeds the protocol's configured maximum.
    /// @param requested Caller-requested amount validated against the configured limit.
    error HelperFeeTooHigh(uint256 requested);
    /// @notice A Helpers fee update would leave the stored fee unchanged.
    error HelperFeeChangeNoop();
    /// @notice The stored Helpers fee no longer matches the caller's optimistic-concurrency expectation.
    /// @param expectedHelperFeePpm Expected helper fee rate in parts per million.
    /// @param actualHelperFeePpm Actual helper fee rate in parts per million.
    error HelperFeeCurrentMismatch(uint256 expectedHelperFeePpm, uint256 actualHelperFeePpm);
    /// @notice An adapter approval update would leave the stored approval unchanged.
    error AdapterApprovalChangeNoop();
    /// @notice An adapter approval no longer matches the caller's optimistic-concurrency expectation.
    /// @param expected Approval state the caller expected to replace.
    /// @param actual Current approval state stored by Helpers.
    error AdapterApprovalCurrentMismatch(bool expected, bool actual);
    /// @notice The ERC-2612 authorization deadline is earlier than the current block timestamp.
    /// @param deadline Timestamp after which the permit or request is invalid.
    /// @param currentTime Current block timestamp used for expiry validation.
    error PermitExpired(uint256 deadline, uint256 currentTime);
    /// @notice The signed ERC-2612 allowance is smaller than the maximum token amount the route may pull.
    /// @param permitValue Approved amount encoded in the permit payload.
    /// @param required Required amount or count used to validate the operation.
    error PermitAmountTooLow(uint256 permitValue, uint256 required);
    /// @notice The effective allowance remains smaller than the amount the route must pull after a permit attempt.
    /// @param allowance Effective ERC-20 allowance observed after the permit attempt.
    /// @param required Required amount the route must pull.
    error PermitAllowanceTooLow(uint256 allowance, uint256 required);
    /// @notice The immutable Permit2 dependency is the zero address or otherwise invalid.
    error InvalidPermit2();
    /// @notice The token authorized by Permit2 differs from the token required by the route.
    /// @param provided Caller-provided value observed during validation.
    /// @param expected Expected value required by the invariant or quote check.
    error InvalidPermit2Token(address provided, address expected);
    /// @notice The Permit2 authorization is smaller than the maximum token amount the route may pull.
    /// @param permitValue Approved amount encoded in the permit payload.
    /// @param required Required amount or count used to validate the operation.
    error Permit2AmountTooLow(uint256 permitValue, uint256 required);
    /// @notice A Permit2 batch does not match Core's current canonical asset count.
    /// @param provided Number of signed token permissions.
    /// @param expected Number of current ordered Core assets.
    error Permit2BatchLengthMismatch(uint256 provided, uint256 expected);
    /// @notice `msg.value` differs from the exact native-input budget declared by the caller.
    /// @param expected Exact native value required by the request.
    /// @param actual Native value supplied with the call.
    error NativeValueMismatch(uint256 expected, uint256 actual);
    /// @notice Returning unused native currency to the payer failed.
    error EthRefundFailed();
    /// @notice A native-input or native-output route was selected before wrapped native was configured.
    error WrappedNativeNotSet();
    /// @notice Core reported consuming more of an issuance asset than the snapshotted caller maximum.
    /// @param asset Core issuance asset whose reported input exceeds its maximum.
    /// @param actual Amount Core reported consuming.
    /// @param maximum Snapshotted maximum amount Helpers supplied to `safeIssue`.
    error CoreInputAboveMaximum(address asset, uint256 actual, uint256 maximum);
    /// @notice Helpers received an ERC20 amount different from the amount authorized for the current acquisition.
    /// @param asset ERC20 asset pulled into the Helpers diamond.
    /// @param expected Exact amount Helpers was required to receive.
    /// @param actual Helpers balance increase observed across the transfer.
    error RouterTokenCreditMismatch(address asset, uint256 expected, uint256 actual);
    /// @notice A payer lost more or less than the exact token amount authorized for Router ingress.
    /// @param asset Token pulled from the payer.
    /// @param payer Account whose balance debit was measured.
    /// @param expected Exact debit required by the route.
    /// @param actual Observed payer balance decrease.
    error PayerTokenDebitMismatch(address asset, address payer, uint256 expected, uint256 actual);
    /// @notice An ERC20 payout debited Helpers by an amount different from the promised payout.
    /// @param asset ERC20 asset paid from the Helpers diamond.
    /// @param expected Exact amount that should leave Helpers.
    /// @param actual Helpers balance decrease observed across the transfer.
    error RouterTokenDebitMismatch(address asset, uint256 expected, uint256 actual);
    /// @notice Reverts when a recipient receives a non-exact ERC20 payout.
    /// @param asset ERC20 asset paid to the recipient.
    /// @param recipient Account that should receive the exact payout.
    /// @param actual Recipient balance increase observed across the transfer.
    /// @param expected Nominal amount the router attempted to deliver.
    error RecipientAmountOutMismatch(address asset, address recipient, uint256 actual, uint256 expected);
    /// @notice The number of submitted route quotes does not match the number of required swap legs.
    /// @param provided Caller-provided value observed during validation.
    /// @param expected Expected value required by the invariant or quote check.
    error QuoteLengthMismatch(uint256 provided, uint256 expected);
    /// @notice Reverts when the final user-protection minimum is zero.
    error ZeroFinalMinimum();
    /// @notice Reverts when an active swap or basket-output leg has a zero minimum.
    /// @param index Index of the active leg with no minimum protection.
    error ZeroLegMinimum(uint256 index);
    /// @notice Recovery shares can only be received through the batch-mint route.
    error RecoverySingleShareReceiptRejected();
    /// @notice A recovery-share callback did not originate from the armed Core mint operation.
    /// @param caller ERC-1155 collection that invoked the callback.
    /// @param operator ERC-1155 operator supplied by the callback.
    /// @param from ERC-1155 source supplied by the callback.
    error RecoveryShareReceiptUnauthorized(address caller, address operator, address from);
    /// @notice The one-shot callback context is not in the required state.
    /// @param expected Receipt state required by the current route stage.
    /// @param actual Receipt state observed in storage.
    error RecoveryShareReceiptStateInvalid(uint8 expected, uint8 actual);
    /// @notice The callback batch differs from the exact asset-derived IDs, amounts, and balance baselines armed by the route.
    /// @param expected Expected batch commitment stored when the route was armed.
    /// @param actual Batch commitment recomputed from the authenticated callback.
    error RecoveryShareBatchMismatch(bytes32 expected, bytes32 actual);
    /// @notice Forwarding did not restore Helpers' share balance to its exact pre-route baseline.
    /// @param id Recovery-share identifier whose Helpers debit was checked.
    /// @param expectedBalance Exact pre-route Helpers balance that must be restored.
    /// @param actualBalance Helpers balance observed after forwarding.
    error RecoveryShareDebitMismatch(uint256 id, uint256 expectedBalance, uint256 actualBalance);
    /// @notice An EOA did not retain the exact forwarded recovery-share credit.
    /// @param id Recovery-share identifier whose recipient credit was checked.
    /// @param recipient EOA that must receive the exact recovery-share amount.
    /// @param expectedBalance Exact recipient balance required after forwarding.
    /// @param actualBalance Recipient balance observed after forwarding.
    error RecoveryShareRecipientCreditMismatch(
        uint256 id, address recipient, uint256 expectedBalance, uint256 actualBalance
    );
    /// @notice Core issuance returned a fee or amount vector inconsistent with the bound preview.
    error CoreIssuanceResultMismatch();
    /// @notice Core redemption returned a different structural or numerical vector than its bound preview.
    error CoreRedemptionResultMismatch();

    // -------- Events --------
    /// @notice Emitted when governance authorizes or revokes a swap adapter.
    /// @param adapter Swap adapter address checked or configured for routed swaps.
    /// @param approved Approval flag applied to the operator, adapter, or sleeve.
    event AdapterApprovalUpdated(address indexed adapter, bool approved);
    /// @notice Emitted when the Helpers fee changes.
    /// @param previousHelperFeePpm Previous fee rate in parts per million.
    /// @param newHelperFeePpm New fee rate in parts per million.
    event HelperFeeUpdated(uint256 previousHelperFeePpm, uint256 newHelperFeePpm);
    /// @notice Emitted when an operation returns an unspent token balance to its payer.
    /// @param payer Account whose assets or CYGLD are pulled for the flow.
    /// @param asset ERC20 or basket asset address processed by the flow.
    /// @param amount Token, asset, share, or native amount moved by the operation.
    event DustRefunded(address indexed payer, address indexed asset, uint256 amount);
    /// @notice Emitted after one token/native aggregation route issues CYGLD.
    /// @param payer Account whose assets or CYGLD are pulled for the flow.
    /// @param recipient Account receiving CYGLD, basket assets, or output tokens.
    /// @param inputToken Input token supplied by the payer before routing.
    /// @param inputUsed Input token amount actually consumed by the helper.
    /// @param netCygldOut CYGLD amount delivered after helper fees.
    /// @param protocolFeeCygld CYGLD protocol fee charged by Core.
    /// @param helperFeeCygld CYGLD helper fee retained by the router.
    event Issued(
        address indexed payer,
        address indexed recipient,
        address indexed inputToken,
        uint256 inputUsed,
        uint256 netCygldOut,
        uint256 protocolFeeCygld,
        uint256 helperFeeCygld
    );
    /// @notice Emitted after one direct-basket issuance settles.
    /// @param payer Account supplying the ordered Core assets.
    /// @param recipient Account receiving net CYGLD.
    /// @param orderedCoreAssets Complete current Core issuance-asset order.
    /// @param amountsIn Actual per-asset debits in the same order.
    /// @param netCygldOut CYGLD delivered to the recipient after the Helpers fee.
    /// @param protocolFeeCygld CYGLD protocol fee charged by Core.
    /// @param helperFeeCygld CYGLD Helpers fee paid to the Helpers owner.
    event IssuedFromBasket(
        address indexed payer,
        address indexed recipient,
        address[] orderedCoreAssets,
        uint256[] amountsIn,
        uint256 netCygldOut,
        uint256 protocolFeeCygld,
        uint256 helperFeeCygld
    );
    /// @notice Emitted after one mixed Core redemption is aggregated and delivered.
    /// @param payer Account whose assets or CYGLD are pulled for the flow.
    /// @param recipient Account receiving CYGLD, basket assets, or output tokens.
    /// @param outputToken Output token requested by the redemption recipient.
    /// @param grossCygldIn CYGLD amount supplied before the Helpers and Protocol fee layers.
    /// @param protocolFeeCygld CYGLD protocol fee charged by the core controller.
    /// @param amountOut Output token amount delivered to the redemption recipient.
    /// @param helperFeeCygld CYGLD helper fee retained by the router.
    /// @param recoveryAssets Impaired assets represented by positive forwarded recovery shares in Core order.
    /// @param recoveryShareAmounts Positive recovery-share amounts forwarded to the recipient.
    event Redeemed(
        address indexed payer,
        address indexed recipient,
        address indexed outputToken,
        uint256 grossCygldIn,
        uint256 amountOut,
        address[] recoveryAssets,
        uint256[] recoveryShareAmounts,
        uint256 protocolFeeCygld,
        uint256 helperFeeCygld
    );
    /// @notice Emitted after one complete mixed Core output vector is delivered directly.
    /// @param payer Account supplying gross CYGLD.
    /// @param recipient Account receiving every positive output.
    /// @param grossCygldIn CYGLD supplied before Helpers and Core fee layers.
    /// @param kinds Token standards in complete canonical output order.
    /// @param tokens Token contracts in complete canonical output order.
    /// @param ids Token identifiers in complete canonical output order.
    /// @param amounts Realized amounts in complete canonical output order.
    /// @param protocolFeeCygld CYGLD protocol fee charged by Core.
    /// @param helperFeeCygld CYGLD Helpers fee paid to the Helpers owner.
    event RedeemedToBasket(
        address indexed payer,
        address indexed recipient,
        uint256 grossCygldIn,
        ICoreRedemption.TokenKind[] kinds,
        address[] tokens,
        uint256[] ids,
        uint256[] amounts,
        uint256 protocolFeeCygld,
        uint256 helperFeeCygld
    );
}
