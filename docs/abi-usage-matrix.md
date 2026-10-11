# Helpers public execution ABI usage matrix

This inventory explains every retained product variant. Variants select a real
authorization or native-value path; they are not compatibility aliases.
Rebalance, recovery-basket, and recovery-token wrappers are
absent. Direct-basket operations use the same generic Core issue/redeem
semantics as aggregated routes.

## Execution variants

| Flow | Allowance | ERC-2612 | Permit2 | Core handoff |
| --- | --- | --- | --- | --- |
| Issue exact CYGLD from one ERC-20 | `issueFromTokenExactOut` | `issueFromTokenExactOutWithPermit` | `issueFromTokenExactOutWithPermit2` | one snapshotted `safeIssue` maximum vector |
| Issue exact CYGLD from native ETH | exact-value `issueFromNativeExactOut` | — | — | one snapshotted `safeIssue` maximum vector |
| Issue from the complete Core basket, exact input | — | — | `issueFromBasketExactInWithPermit2` | fresh exact lot inside signed ordered budgets |
| Issue from the complete Core basket, exact output | — | — | `issueFromBasketExactOutWithPermit2` | fresh exact lot inside signed ordered ceilings |
| Redeem CYGLD to one ERC-20 | `redeemToTokenExactIn` | `redeemToTokenExactInWithPermit` | `redeemToTokenExactInWithPermit2` | caller's complete mixed minima passed to `safeRedeem` |
| Redeem CYGLD to native ETH | `redeemToNativeExactIn` | `redeemToNativeExactInWithPermit` | `redeemToNativeExactInWithPermit2` | caller's complete mixed minima passed to `safeRedeem` |
| Redeem CYGLD to the complete mixed basket | `redeemToBasketExactIn` | `redeemToBasketExactInWithPermit` | `redeemToBasketExactInWithPermit2` | caller's complete mixed minima passed to `safeRedeem` |

Standard ERC-2612 supports selected-token issuance and CYGLD-funded redemption.
Issuance accepts any compatible standard ERC-2612 input through the same selector;
Helpers does not probe or require catalog membership. A caller can retain
allowance or Permit2 for tokens without usable native permits. Sign the input
ceiling as the permit value for exact purchase allowance: Helpers pulls that
ceiling once, consuming the allowance, then refunds any unused input. The
native-permit issuance selector requires an updated shared issuance facet on
each target; exporting its candidate ABI does not install it. The native issuance
route requires `msg.value == maximumNativeIn` and is the only payable product
selector. Native-output redemption still acquires CYGLD, so it retains all
three CYGLD authorization paths while remaining nonpayable.

Direct-basket issuance intentionally has no allowance variant: one Permit2
batch atomically binds and authorizes every current Core asset. Signed batch
amounts are budgets or ceilings. Helpers pulls and approves only Core's fresh
exact lots, never the larger signed values.

## Preview variants

| Flow | Public calculator | Purpose |
| --- | --- | --- |
| Token issuance, exact output | `previewIssueFromTokenExactOut` | fees and current ordered Core assets for the exact-net target |
| Token issuance, exact input | `previewIssueFromTokenExactIn` | conservative exact-output construction from a fixed token budget |
| Native issuance, exact output | `previewIssueFromNativeExactOut` | fees and current ordered Core assets after WETH normalization |
| Native issuance, exact input | `previewIssueFromNativeExactIn` | conservative exact-output construction from a fixed native budget |
| Basket issuance, exact input | `previewIssueFromBasketExactIn` | supported recipient net, fees, fresh exact lots, and ordered assets for per-asset budgets |
| Basket issuance, exact output | `previewIssueFromBasketExactOut` | fees, fresh exact lots, and ordered assets for the exact recipient net |
| Token redemption, exact input | `previewRedeemToTokenExactIn` | complete mixed Core projection, constructed aggregate floor, and fees |
| Native redemption, exact input | `previewRedeemToNativeExactIn` | the same calculation with WETH as normalized output |
| Basket redemption, exact input | `previewRedeemToBasketExactIn` | complete mixed Core projection and fees for one outer gross input |
| Basket redemption, exact output | `previewRedeemToBasketExactOut` | minimum outer gross, complete mixed projection, and fees satisfying a complete floor vector |

All public operation calculators use `preview*`. A preview is a read-only
current-state calculation, not a promise of a same-direction execution
selector. In particular, exact-input issuance previews do not add exact-input
executors for the aggregated token/native families and do not call adapters or
venue quoters. Direct-basket issuance is the explicit exception: it has an
exact-input executor. Basket redemption exact-out remains construction only;
its output feeds an exact-input executor.

## Binding and result rules

Issuance execution carries `expectedOrderedCoreAssets`. Helpers performs the
Core exact-output preview once before acquisition or adapter effects, validates
that list, and passes the snapshotted amount vector unchanged as `safeIssue`
maxima. Core may consume less; a requirement increase fails. Every positive
operation-local remainder is refunded to the payer. Aggregated exact-input
preview legs cover positive-target, non-direct Core members only. Zero-target
canonical members retain their positional slot at zero and are not touched by
issuance settlement.

Direct-basket issuance obtains order and amounts from a fresh Core preview and
binds them positionally to the signed Permit2 batch. The signed values only cap
the operation: Permit2 pulls and Core approvals use the fresh exact amounts.

Redemption execution carries a complete `expectedCoreOutputs` array of Core
`TokenMinimum` descriptors, including ERC-20 and ERC-1155 positions and zero
minimums. Helpers passes that exact array to `safeRedeem`. The independent
adapter-leg minima and aggregate `minimumAmountOut` remain enforced by Helpers.

`AggregatedRedemptionPreview.projectedCoreOutputs` is the complete current
mixed vector. `AggregatedRedemptionResult.recoveryShareOutputs` is a
positive-only subset of validated ERC-1155 outputs that Helpers forwarded to
the selected recipient. All positive ERC-20 outputs are aggregated into
`amountOut`. A share-only result may use a zero aggregate minimum; a route with
positive ERC-20 output requires a positive final minimum.

`BasketRedemptionResult.outputs` is the complete settled vector rather than a
positive-only subset. Projected zero ERC-20 legs remain structural and consume
no balance probe; they must remain zero at settlement. Positive outputs are
still proven by exact balance deltas and delivered without aggregation.

`Fees` contains only `protocolFeeCygld` and `helperFeeCygld`. The latter is
paid to the current Helpers owner. There is no separate fee recipient or dust
donation mode.

## Compact swap tuples

`IssueSwapLeg` carries `adapter`, source-token `amountIn`,
`minimumAmountOut`, and venue `data`. It needs an explicit amount because the
caller allocates one input budget across multiple Core inputs.

`RedemptionSwapLeg` carries only `adapter`, `minimumAmountOut`, and venue
`data`. Its input amount comes from Core's settled ERC-20 output. Neither tuple
repeats asset identity or carries native value. Compact positions follow the
filtered Core order; direct, zero, and ERC-1155 entries consume no tuple.

Adapter swaps are nonpayable ERC-20 operations. Native user routes wrap or
unwrap at Helpers and do not forward ETH to a venue. The launch deployment
supports exactly 1inch and Uniswap. The 1inch payload remains opaque:
balance-delta and minimum-output enforcement proves outer accounting, not the
payload's internal intent. App-side validation is defense in depth. The
retained `ZeroExAdapter` source is frozen and does not belong to the deployment
or release ABI; CI rejects re-entry pending explicit requalification.

## Shared dependencies and outcomes

Permit2 is an immutable dependency shared by routed facets and the Uniswap
adapter. Each adapter is also constructed with the immutable Helpers diamond
as recovery authority. Neither dependency has a post-deployment binding
setter.

`Issued`, `IssuedFromBasket`, `Redeemed`, and `RedeemedToBasket` are the four
product-specific economic outcomes, one per successful route execution.
Native ETH is identified by `address(0)` only in the aggregated event token
field. `Redeemed`
reports aligned impaired-asset and positive recovery-share amount arrays
without duplicating Core or asset-derived ERC-1155 IDs. The direct events carry
complete ordered issuance or mixed redemption vectors. `DustRefunded` may
additionally report operation-local surplus returned to the payer.

Execution has no router-level deadline. ERC-2612 deadlines, Permit2 signed
deadlines/nonces, and venue-specific expiry encoded in adapter data remain in
force.
