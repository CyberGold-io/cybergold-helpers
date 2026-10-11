---
title: Helpers execution API
doc_type: reference
status: active
owner: helpers-maintainer
created: 2026-07-11
last_reviewed: 2026-10-10
canonical_for: Helpers public execution semantics
---

# Helpers execution API

Helpers is an aggregation and direct-basket convenience layer. It does not
expose rebalance or recovery-named wrapper operations. The retained API issues
CYGLD either from one ERC-20/native-ETH input or from Core's complete current
basket, and redeems CYGLD either into one aggregated ERC-20/native-ETH output
or directly into Core's complete mixed ERC-20/ERC-1155 vector.

Every read-only operation calculator is named `preview*`. A preview reads
current Core and Helpers state and validates the supplied compact route shape;
it never calls an adapter or venue quoter and is not an executable commitment.
Aggregated token/native exact-input issuance previews construct parameters for
their exact-output executors. Direct-basket exact-input issuance has a matching
Permit2-batch executor. Direct-basket exact-output redemption is deliberately a
preview-to-exact-input construction, not a second state-changing endpoint.

## Public route matrix

| Operation | Authorization | Payable | Return |
| --- | --- | --- | --- |
| `previewIssueFromTokenExactOut` | none | no | `IssueExactOutPreview` |
| `previewIssueFromTokenExactIn` | none | no | `IssueExactInPreview` |
| `issueFromTokenExactOut` | ERC-20 allowance | no | `Fees` |
| `issueFromTokenExactOutWithPermit` | selected-token standard ERC-2612 | no | `Fees` |
| `issueFromTokenExactOutWithPermit2` | Permit2 | no | `Fees` |
| `previewIssueFromNativeExactOut` | none | no | `IssueExactOutPreview` |
| `previewIssueFromNativeExactIn` | none | no | `IssueExactInPreview` |
| `issueFromNativeExactOut` | exact native value | yes | `Fees` |
| `previewIssueFromBasketExactIn` | none | no | `BasketIssueExactInPreview` |
| `issueFromBasketExactInWithPermit2` | Permit2 batch | no | `BasketIssueResult` |
| `previewIssueFromBasketExactOut` | none | no | `BasketIssueExactOutPreview` |
| `issueFromBasketExactOutWithPermit2` | Permit2 batch | no | `BasketIssueResult` |
| `previewRedeemToTokenExactIn` | none | no | `AggregatedRedemptionPreview` |
| `redeemToTokenExactIn` | CYGLD allowance | no | `AggregatedRedemptionResult` |
| `redeemToTokenExactInWithPermit` | CYGLD ERC-2612 | no | `AggregatedRedemptionResult` |
| `redeemToTokenExactInWithPermit2` | Permit2 | no | `AggregatedRedemptionResult` |
| `previewRedeemToNativeExactIn` | none | no | `AggregatedRedemptionPreview` |
| `redeemToNativeExactIn` | CYGLD allowance | no | `AggregatedRedemptionResult` |
| `redeemToNativeExactInWithPermit` | CYGLD ERC-2612 | no | `AggregatedRedemptionResult` |
| `redeemToNativeExactInWithPermit2` | Permit2 | no | `AggregatedRedemptionResult` |
| `previewRedeemToBasketExactIn` | none | no | `BasketRedemptionExactInPreview` |
| `previewRedeemToBasketExactOut` | none | no | `BasketRedemptionExactOutPreview` |
| `redeemToBasketExactIn` | CYGLD allowance | no | `BasketRedemptionResult` |
| `redeemToBasketExactInWithPermit` | CYGLD ERC-2612 | no | `BasketRedemptionResult` |
| `redeemToBasketExactInWithPermit2` | Permit2 | no | `BasketRedemptionResult` |

The payer is always `msg.sender`. Execution selects an explicit recipient.
Every executor rejects both the zero address and the Helpers diamond itself;
Helpers has no composition callback for its own CYGLD payout, and
self-recipient output would otherwise remain in owner-sweepable custody. Token
endpoints reject a zero token address, including the generic token routes that
can use WETH as an ordinary ERC-20. Dedicated native routes perform wrapping
or unwrapping. Only event fields use `address(0)` as the native-ETH marker.

## Public types

The principal route types are:

```solidity
struct Fees {
    uint256 protocolFeeCygld;
    uint256 helperFeeCygld;
}

struct IssueFromTokenExactOutParams {
    address inputToken;
    uint256 maximumInputAmount;
    uint256 netCygldOut;
}

struct IssueFromTokenExactInParams {
    address inputToken;
    uint256 inputAmount;
}

struct IssueFromNativeExactOutParams {
    uint256 maximumNativeIn;
    uint256 netCygldOut;
}

struct IssueExecutionParams {
    address recipient;
    address[] expectedOrderedCoreAssets;
}

struct IssueSwapLeg {
    address adapter;
    uint256 amountIn;
    uint256 minimumAmountOut;
    bytes data;
}

struct PermitParams {
    uint256 value;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

struct RedemptionSwapLeg {
    address adapter;
    uint256 minimumAmountOut;
    bytes data;
}

struct IssueExactOutPreview {
    Fees fees;
    address[] orderedCoreAssets;
}

struct IssueExactInPreview {
    uint256 netCygldOut;
    Fees fees;
    address[] orderedCoreAssets;
}

struct BasketIssueExactOutRequest {
    uint256 netCygldOut;
    address recipient;
}

struct BasketIssueExactInRequest {
    address recipient;
    uint256 minimumNetCygldOut;
}

struct BasketIssueExactInPreview {
    uint256 netCygldOut;
    Fees fees;
    uint256[] amountsInExact;
    address[] orderedCoreAssets;
}

struct BasketIssueExactOutPreview {
    Fees fees;
    uint256[] amountsInExact;
    address[] orderedCoreAssets;
}

struct BasketIssueResult {
    uint256 netCygldOut;
    Fees fees;
    uint256[] actualAmountsIn;
}

struct Permit2BatchParams {
    ISignatureTransfer.PermitBatchTransferFrom permit;
    bytes signature;
}
```

Redemption uses Core's typed union directly:

```solidity
struct RedeemToTokenExactInParams {
    uint256 grossCygldIn;
    address outputToken;
}

struct AggregatedRedemptionPreview {
    uint256 minimumAmountOut;
    ICoreRedemption.TokenAmount[] projectedCoreOutputs;
    Fees fees;
}

struct AggregatedRedemptionRequest {
    uint256 grossCygldIn;
    address outputToken;
    address recipient;
    uint256 minimumAmountOut;
    ICoreRedemption.TokenMinimum[] expectedCoreOutputs;
}

struct AggregatedNativeRedemptionRequest {
    uint256 grossCygldIn;
    address recipient;
    uint256 minimumAmountOut;
    ICoreRedemption.TokenMinimum[] expectedCoreOutputs;
}

struct AggregatedRedemptionResult {
    uint256 amountOut;
    ICoreRedemption.TokenAmount[] recoveryShareOutputs;
    Fees fees;
}

struct BasketRedemptionRequest {
    uint256 grossCygldIn;
    address recipient;
    ICoreRedemption.TokenMinimum[] expectedCoreOutputs;
}

struct BasketRedemptionExactInPreview {
    ICoreRedemption.TokenAmount[] projectedCoreOutputs;
    Fees fees;
}

struct BasketRedemptionExactOutPreview {
    uint256 grossCygldIn;
    ICoreRedemption.TokenAmount[] projectedCoreOutputs;
    Fees fees;
}

struct BasketRedemptionResult {
    ICoreRedemption.TokenAmount[] outputs;
    Fees fees;
}
```

`TokenAmount` and `TokenMinimum` each carry `kind`, `token`, `id`, and an
amount or minimum. A reserve output has kind `ERC20`, its reserve token, and ID
zero. A recovery-share output has kind `ERC1155`, Core as its token, and the
impaired asset address cast to `uint256` as its ID. Structural zero-amount legs
remain in Core's complete mixed vector.

## Compact adapter-leg order

Neither swap-leg type repeats the Core asset identity. Its position derives the
asset from the canonical filtered Core order.

For exact-output issuance, normalize native input to WETH and include one
`IssueSwapLeg` for every positive required Core input that differs from the
normalized route input. A direct input or zero requirement consumes no leg.
Each leg's `amountIn` allocates the caller's input budget and
`minimumAmountOut` must cover Core's snapshotted requirement.

For exact-input issuance preview, include one leg for every positive-target
Core input other than the normalized route input, in canonical Core order. A
zero-target Exiting member remains in Core's returned identity vector but
consumes no compact leg and is constructed with a zero input budget. Each
positive `amountIn` consumes part of the fixed route budget, and
`minimumAmountOut` is the conservative Core input credited to that position.
The unallocated remainder becomes a direct position only when the normalized
route input is itself a positive-target Core input; otherwise that remainder
does not contribute to the previewed output.

For redemption, normalize native output to WETH and include one
`RedemptionSwapLeg` for every positive ERC-20 Core output that differs from the
normalized final output. Positive direct-output ERC-20 legs, zero legs, and
all ERC-1155 legs consume no tuple. Redemption legs omit `amountIn` because
Core's settled output is the authoritative adapter input lot.

Every route rejects a short, long, zero-minimum, unapproved, or positionally
invalid compact leg list. Adapter payload construction and price discovery
remain off chain or venue-specific. In particular, the 1inch adapter forwards
opaque Aggregation Router calldata and does not semantically bind its selector,
assets, recipient, amount, or expiry. Helpers' measured balance deltas and
minimums constrain the outer accounting, not the payload's internal intent.
App-side inspection is defense in depth only.

## Issuance semantics

Exact-output issuance names the exact CYGLD credit to the selected recipient:

```text
netCygldOut + Helpers fee = Core net
Core net + protocol fee   = protocol gross
```

Helpers minimally grosses up for its floor-rounded fee, and Core independently
calculates its fee and required inputs. `IssueExactOutPreview` returns only
calculated fees and `orderedCoreAssets`; the caller already retains its desired
net output, input maximum, and adapter legs.

Execution performs the Core exact-output preview once at route entry. Before
acquiring funds or calling an adapter, it compares
`expectedOrderedCoreAssets` with that preview. It then:

1. acquires the exact maximum token budget, or wraps exactly
   `maximumNativeIn` after requiring `msg.value` equality;
2. executes the compact legs and proves adapter input/output balance deltas;
3. approves Core for the positive snapshotted per-asset maxima;
4. calls `safeIssue` with the same ordered assets and maxima;
5. verifies every positive reported Core input is at or below its maximum and
   equals the measured debit, while zero slots remain structurally bound;
6. clears allowances established for positive lots and pays the exact CYGLD recipient and owner fee
   credits; and
7. returns every operation-local surplus to the payer.

A Core requirement increase therefore makes bounded settlement fail. A
decrease can settle with smaller actual inputs, whose surplus is refunded.
Helpers never re-previews after an adapter call.

Zero-required canonical slots are never balance-probed, approved, pulled,
debit-checked, or dust-settled. This keeps an unreadable Exiting token from
blocking issuance while preserving Core's complete positional identity. Dust
accounting remains operation-local to the input token and positive lots the
route can actually touch.

`IssueExactInPreview` is an advisory solver. From a fixed input budget and
conservative adapter minima it constructs Core inputs, asks Core for the
supported output, deducts the Helpers fee once, and returns the resulting
`netCygldOut`. A caller can use that amount to build a later exact-output
execution with freshly selected maxima and bounds.

### Direct-basket issuance

Direct-basket issuance is atomic through Helpers in both amount directions and
uses Permit2 batch authorization only:

- `previewIssueFromBasketExactIn(maximumAmountsIn)` treats the ordered vector
  as per-asset budgets and returns the supported recipient net, fees, fresh
  exact input lots, and current Core asset order.
- `previewIssueFromBasketExactOut(netCygldOut)` returns fees, fresh exact input
  lots, and current Core asset order without echoing the requested net.
- the matching executors take the recipient/final minimum or exact net plus a
  signed Permit2 batch. The signed permission array is the sole caller-bound
  asset order and per-asset ceiling vector.

Signed amounts are authorization capacity, not settlement instructions. At
execution, Helpers asks Core for the fresh exact lot, requires every asset to
match the signed position and every fresh amount to fit its signed ceiling,
then asks Permit2 to transfer only the fresh exact amounts. A zero-required
canonical permission remains identity-bound but has a zero requested transfer
and no token balance probe. Helpers approves Core only for positive fresh
amounts and passes the complete vector as `safeIssue` maxima. A requirement
increase after Permit2 therefore reverts; it cannot consume pre-existing
Helpers balances or unused signed capacity. A decrease may settle with smaller
actual inputs, and the operation-local positive-lot remainder is refunded while
older Helpers balances remain isolated.

`BasketIssueResult.actualAmountsIn` is Core's measured realized input vector.
One `IssuedFromBasket` event reports the same complete ordered vector and fee
split.

## Redemption semantics

Redemption is exact gross CYGLD input. Helpers calculates its fee from
`grossCygldIn`, pays that fee to the current Helpers owner, and passes the
remaining exact gross principal to Core. Core's preview and settled result each
report the protocol fee and complete mixed output vector.

`AggregatedRedemptionPreview` returns:

- `projectedCoreOutputs`: Core's complete current `TokenAmount[]`;
- `minimumAmountOut`: the constructed aggregate of direct projected ERC-20
  amounts plus each supplied adapter minimum; and
- separate Protocol and Helpers CYGLD fees.

The caller derives a complete ordered `TokenMinimum[]` from the projection,
chooses each Core minimum, and supplies that list as `expectedCoreOutputs`.
Execution passes the list unchanged to `safeRedeem`; Helpers does not rebuild
it from its fresh preview. The fresh preview still arms the exact ERC-1155
receipt and validates route shape. After Core settlement, Helpers requires the
actual descriptors to equal both the fresh projection and caller descriptors,
enforces every Core minimum, and proves exact Core debits and credits.

All positive ERC-20 outputs are then aggregated into the selected output token.
Direct output is added without an adapter; every other positive ERC-20 output
uses its compact leg and independent minimum. `minimumAmountOut` is enforced on
the aggregate exact recipient credit. It may be zero only for a share-only
redemption with no positive ERC-20 result.

Every positive ERC-1155 output is forwarded unchanged to the same recipient.
`recoveryShareOutputs` contains only those positive typed outputs in Core order;
it is empty for an all-ERC-20 settlement. The complete mixed Core event remains
the authority for structural zero entries.

Core redemption previews are caller-sensitive because Core evaluates fee
policy for the immediate caller. Integrators routing through Helpers must use
the Helpers preview surface; an end user's direct Core preview is not a valid
Helpers projection.

### Direct-basket redemption

`previewRedeemToBasketExactIn(grossCygldIn)` returns Core's complete current
mixed projection and both fee amounts. `redeemToBasketExactIn` and its
ERC-2612/Permit2 authorization variants deliver every positive ERC-20 and
ERC-1155 entry directly to one recipient and return the complete settled vector
in Core order. The request carries the complete `TokenMinimum[]`, including
structural zero entries; Helpers binds every descriptor and minimum before
CYGLD acquisition and passes that same vector to `safeRedeem`.

`previewRedeemToBasketExactOut(minimumOutputs)` is the exact-output
construction endpoint. It returns the minimum outer `grossCygldIn`, complete
projected mixed vector, and fees needed to satisfy the supplied complete floor
vector. The consumer then submits that gross and the returned descriptors and
chosen minima to an exact-input executor. There is no state-changing
`redeemToBasketExactOut`: this preview-to-exact-input flow preserves one
settlement implementation while giving the App an exact-output construction.

A projected zero ERC-20 descriptor consumes no adapter leg and is not probed
for `balanceOf`; this permits current-state vectors to retain an unreadable or
unavailable asset at zero while another leg settles positively. Its minimum
must remain zero, and settlement must also leave it zero. A zero-to-positive
drift is rejected because Helpers intentionally has no trusted pre-settlement
balance baseline for that token. Positive ERC-20 outputs remain subject to
exact readable balance-delta proofs.

## ERC-1155 receipt authentication

Immediately before Core settlement, Helpers commits to positive recovery-share
IDs, amounts, recipient, and its pre-credit balances. The receiver accepts
exactly one empty-data batch mint from and operated by the configured Core,
forwards it, and transitions `Idle -> Armed -> Consumed`. Completion requires
the expected state, verifies Helpers returned to each baseline, and clears the
receipt to `Idle`.

Single-ID receipts and unsolicited or mismatched batches revert. Exact
recipient credit is verified for EOAs; a contract recipient may move shares
during its own receiver callback. No public receipt getter, nonce, historical
record, or recovery configuration identity exists.

## Authorization and expiry

Arbitrary single-token issuance inputs support allowance, standard token-native
ERC-2612, and Permit2. `issueFromTokenExactOutWithPermit(params, execution,
permit, legs)` shares the existing Core preview, route validation, acquisition,
swap and settlement path. Its signature authorizes `msg.sender`'s selected
input token allowance to Helpers, covering `maximumInputAmount`; it does not
replace the purchase transaction's intent. Helpers does not probe ERC-2612
support or require token catalog membership. Direct-basket
issuance uses one Permit2 batch so all current Core assets are authorized and
pulled atomically. CYGLD redemption, including direct-basket redemption,
additionally supports ERC-2612 because CYGLD's implementation is
protocol-controlled. A previously consumed permit is accepted when the
resulting existing allowance already covers the exact pull. Existing sufficient
allowance also skips any new permit application. If allowance is insufficient,
the permit value must cover the complete input ceiling, since ERC-2612 replaces
allowance rather than adding to it. Signing exactly that ceiling consumes all
purchase allowance when Helpers acquires it; subsequent unused-input refunds
return tokens without restoring allowance. A later purchase failure rolls back
the permit's nonce/allowance effects together with settlement. A permit
submitted externally before the purchase remains externally applied.

This native-permit issuance selector is a source candidate. Each deployed target
requires the corresponding shared issuance-facet cut before clients use it;
older targets retain their existing allowance and Permit2 entry points.

Execution endpoints have no independent router-level deadline. The following
specialized expiries remain effective:

- `PermitParams.deadline` on selected-token and CYGLD ERC-2612 authorization;
- the deadline and nonce in a Permit2 signed transfer; and
- a venue-specific deadline encoded in adapter data, such as Uniswap's
  Universal Router deadline.

## Fees, dust, and events

`Fees` reports `protocolFeeCygld` and `helperFeeCygld`. The Helpers fee can be
changed within its compiled cap, and its recipient is always the current
Helpers owner. There is no separate fee-recipient setting.

Positive operation-local token or wrapped-native surplus is always refunded to
the payer and emits `DustRefunded`. Native-route WETH surplus is unwrapped for
the refund. No caller can claim a pre-existing router balance, and no surplus
is donated to the owner.

Exactly one route-family economic outcome is emitted per execution. Aggregated
token/native routes emit:

```solidity
event Issued(
    address indexed payer,
    address indexed recipient,
    address indexed inputToken,
    uint256 inputUsed,
    uint256 netCygldOut,
    uint256 protocolFeeCygld,
    uint256 helperFeeCygld
);

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
```

Direct-basket routes emit complete aligned vectors:

```solidity
event IssuedFromBasket(
    address indexed payer,
    address indexed recipient,
    address[] orderedCoreAssets,
    uint256[] amountsIn,
    uint256 netCygldOut,
    uint256 protocolFeeCygld,
    uint256 helperFeeCygld
);

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
```

`inputUsed`, `netCygldOut`, and `amountOut` are measured realized values.
Native input/output uses the event-only zero-address marker. Recovery arrays
have equal length, contain only positive forwarded shares, and preserve Core
order. `recoveryAssets[i]` is the impaired asset represented by
`recoveryShareAmounts[i]`; Core and the derived ERC-1155 ID are not duplicated.
`IssuedFromBasket` preserves Core's complete issuance order.
`RedeemedToBasket` preserves every mixed output position, including structural
zeros, by emitting aligned kind, token, ID, and amount arrays.

## Administrative and adapter surface

`setHelperFeePpm(current, next)` and
`setAdapterApproval(adapter, current, next)` are owner-only
optimistic-concurrency updates: a stale expected value or a no-op transition
reverts. Permit2 is immutable and has no setter. Ownership retains its separate
two-step transfer lifecycle.

`recoverAdapter(adapter, token)` can be called by the Helpers owner regardless
of current route approval. The adapter accepts recovery only from its immutable
Helpers diamond and transfers the balance directly to that diamond's current
owner. Adapter swaps are nonpayable and receive no native-value field.

The launch deployment and postflight require exactly the recorded 1inch and
Uniswap Universal Router adapters. The honest owner may add or remove adapters
after launch without an on-chain cardinality cap; a mistaken adapter can make a
route revert until removal. `ZeroExAdapter` is frozen dormant source and is not
part of deployment, manifests, generated ABI, fork qualification, or active
launch support. CI requires explicit requalification before it can change or
re-enter any active surface.

See the [ABI usage matrix](../abi-usage-matrix.md) for the authorization-focused
inventory and the [completed implementation
record](../../../cybergold-ops/docs/work/done/core-helpers-governance-app-smart-contract-simplification-implementation-plan.md)
for the frozen simplification decision.
