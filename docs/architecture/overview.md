---
title: Helpers architecture
doc_type: architecture
status: active
owner: helpers-maintainer
created: 2026-07-11
last_reviewed: 2026-07-23
canonical_for: Helpers implemented architecture
---

# Helpers architecture

`HelpersDiamond` is the single integration address. Its production logic is
partitioned into validated cut, loupe, ownership, pause, admin, issuance
preview, aggregated issuance, direct-basket issuance, aggregated redemption,
direct-basket redemption, and recovery-share receiver facets. Durable product
configuration contains only Core, the Helpers fee, wrapped native, and the
adapter allowlist. Permit2 is constructor-bound in every routed facet rather
than stored in diamond storage.

The diamond remains selected code-partitioning and stable-address
infrastructure. Removed rebalance and recovery-specific wrappers are not
replaced by aliases or hidden modes. The product surface supports both
single-token/native aggregation and complete current-state basket operations.

## Issuance boundary

Exact-output issuance minimally grosses the selected recipient's CYGLD amount
up for the Helpers fee, then asks Core for the exact current input vector needed
to issue that intermediate Core net amount. Helpers takes one Core preview at
route entry, before token acquisition or adapter calls, and carries the ordered
assets and amounts unchanged as `safeIssue` maxima.

`IssueExecutionParams.expectedOrderedCoreAssets` binds the caller to the same
ordered vector. An execution-time requirement increase fails at Core's bounded
settlement. A decrease may consume less than the snapshotted maxima; Helpers
then returns the operation-local input and Core-asset surplus to the payer.
Helpers verifies Core's positive reported inputs against measured debits and
clears every Core allowance it established after settlement.

Core can retain zero-target Exiting members in its canonical issuance vector.
Aggregated exact-input construction filters compact legs by positive target,
while settlement retains the complete canonical vector but does not probe,
pull, approve, debit-check, or refund a zero-required token. Direct-basket
Permit2 authorization likewise retains the signed identity slot with a zero
requested transfer. This lets current positive lots settle even when an
identity-only Exiting token is unreadable.

Exact-input issuance previews are conservative construction helpers. They use
a fixed token or native budget and the caller's adapter-leg minima to construct
a Core input vector, then calculate a `netCygldOut` suitable for a later
exact-output execution. Previews never call an adapter or venue quoter.

Direct-basket issuance has exact-input and exact-output Permit2-batch
executors. The signed ordered permissions supply the caller-bound asset order
and per-asset budgets or ceilings. Helpers previews Core immediately before
acquisition, pulls and approves only the returned fresh exact lots, and passes
those exact values as `safeIssue` maxima. Larger signed capacity and
pre-existing Helpers balances are never exposed to Core. A later requirement
increase reverts; a decrease refunds operation-local surplus.

## Generic mixed redemption boundary

Helpers has one redemption model for every Core state. It deducts the Helpers
fee from the exact gross CYGLD input, asks Core for its complete mixed
`TokenAmount[]`, and accepts the caller's complete ordered
`TokenMinimum[] expectedCoreOutputs`. Helpers passes that array unchanged to
`safeRedeem`; adapter minima and the final aggregate minimum are independent
protections.

The mixed vector contains current ERC-20 reserve outputs followed by any
ERC-1155 recovery-share outputs. For each positive ERC-20 output that differs
from the selected final token, Helpers consumes one compact
`RedemptionSwapLeg` in Core order. A direct output, zero amount, or ERC-1155
entry consumes no adapter leg. Every positive ERC-20 amount is aggregated into
the chosen ERC-20 or WETH result. Every positive ERC-1155 amount is forwarded
unchanged to the same recipient and returned as a typed
`recoveryShareOutputs` entry.

The direct-basket redemption facet shares the same validation and receipt
mechanics but forwards each positive ERC-20 output directly and returns Core's
complete settled vector. Exact-output intent is constructed by
`previewRedeemToBasketExactOut`, which returns the minimum outer gross input
and complete mixed projection; settlement then uses the exact-input executor
family. A projected zero ERC-20 position is not balance-probed and must remain
zero, allowing an unreadable current-state asset to stay structural without
weakening proofs for positive legs.

Helpers validates the fresh preview, caller descriptors, settled descriptors,
per-entry minima, exact CYGLD debit, exact ERC-20 credits, and aggregate output
minimum. There is no healthy/recovery route branch, mode, epoch, historical
guard, or separate share vector in the public request.

## Recovery-share receipt

The ERC-1155 receiver is a settlement mechanism inside generic redemption, not
a separate product route. Immediately before `safeRedeem`, Helpers derives the
positive Core-share batch from the fresh mixed preview and arms one transient
`Idle -> Armed -> Consumed` receipt. Its stored fields are only state,
recipient, and a hash of IDs, amounts, and Helpers pre-credit balances.

The callback accepts only an empty-data batch mint from and operated by the
configured Core. It forwards the exact batch to the selected recipient,
requires Helpers' balances to return to their baselines, and verifies exact
credit for an EOA recipient. A contract recipient may move shares during its
own callback. Completion requires the expected callback state and clears the
receipt back to `Idle`; there is no public getter, nonce, or history.

For every recovery-share descriptor, the ERC-1155 token is Core and the ID is
the impaired asset address cast to `uint256`. Helpers events therefore report
the impaired asset and amount without duplicating Core or the ID.

Recovery-share amounts are native raw asset units, not universally 18-decimal
CYGLD units. Helpers forwards the quoted integer quantity unchanged; it never
rescales or automatically burns shares for impaired tokens. Immediate Core
settlement eligibility therefore does not make a mixed route depend on an
impaired token's transferability. A contract recipient may forward its credited
shares during receipt, while nested Helpers settlement remains blocked by the
outer shared guard. The mixed-redemption tests cover 6/8/18/24-decimal quantities
and the forwarding/reentry combination.

## Authorization, native value, fees, and dust

The payer is always `msg.sender`; a recipient must be nonzero and must not be
the Helpers diamond itself. Helpers has no CYGLD composition callback for its
own issuance payout, so rejecting self-recipient execution prevents user output
from becoming stranded in owner-sweepable custody. Authorization is
deliberately scoped:

- arbitrary ERC-20 issuance input: allowance or Permit2;
- native issuance input: exact `msg.value`, wrapped to WETH;
- direct-basket issuance: one atomic Permit2 batch;
- CYGLD redemption to ERC-20, native, or the direct mixed basket: allowance,
  Permit2, or CYGLD's guaranteed ERC-2612 permit.

Only `issueFromNativeExactOut` is payable. Generic ERC-20 routes are
nonpayable, require nonzero token addresses, and can use WETH as an ordinary
token. Dedicated native-output redemption aggregates to WETH, unwraps the
exact result, and transfers ETH to the recipient.

The configured fee remains in parts per million with a 0.5% cap. Its recipient
is derived from current diamond ownership; no separate fee-recipient storage
exists. Helpers refunds every positive operation-local remainder to the payer
and emits `DustRefunded`. Balance snapshots isolate the operation from older
router funds.

## Adapter boundary

Launch adapters expose one nonpayable ERC-20 `swap` operation. They pull the
declared current lot from Helpers, restrict venue interaction to an immutable
router, measure output and unused input from balance deltas, return both to
Helpers, and protect pre-existing adapter balances. No adapter tuple contains
native value and no swap forwards ETH to a venue.

Every adapter stores the Helpers diamond as immutable recovery authority. Only
that diamond can invoke recovery, and recovered ERC-20 or native balances go
directly to the diamond's current owner. `recoverAdapter` remains owner-only
and works even after the adapter has been removed from the route allowlist.

The launch allowlist contains exactly 1inch and Uniswap Universal Router, and
postflight rejects any different cardinality or identity. Routed facets and the
Uniswap adapter share the exact immutable Permit2 identity. After launch, the
owner may admit and remove adapters under the honest-governance model; no
permanent two-adapter on-chain restriction is imposed. A mistaken adapter can
make routes selecting it revert until removal, an accepted liveness residual.

The 1inch adapter forwards opaque caller-supplied calldata to its immutable
Aggregation Router. Helpers proves outer token debits, measured credits, route
minima, and final settlement, but does not decode the payload or bind its
internal selector, assets, recipient, amount, or expiry. App checks are defense
in depth rather than an on-chain trust boundary.

The retained `ZeroExAdapter` source is frozen and excluded from deployment,
approval, release manifests, generated ABI, fork qualification, and
active-support claims. CI rejects source drift or active-surface re-entry until
the adapter undergoes explicit requalification.

## Deployment topology

Adapters require the final Helpers address in their constructors, so release
deployment uses a three-stage topology:

1. deploy the deterministic Helpers shell with only the bootstrap cut;
2. deploy 1inch and Uniswap adapters with the shell and immutable venue
   dependencies; and
3. finalize the existing shell with production facets, initialization,
   adapter approvals, and final ownership.

The finalizer validates a pristine shell and registers exactly version one for
every installed production facet, including the protocol-owned loupe. Routed
entrypoints share OpenZeppelin's Osaka transient reentrancy guard, so no
persistent guard initializer or storage root exists. One outer initialization
context protects the only stateful facet hook; there is no deployment-only
reentrancy facet or separate pausable reinitializer.

ERC-165 advertises the diamond standards, ERC-173 ownership, and the narrow
ERC-1155 receiver surface. It deliberately does not advertise the generated
`ICyberGoldHelpers` release aggregate: that artifact remains the exact client
ABI and selector manifest, while validated upgrades protect only advertised
stable interfaces. Registered selector manifests are the exclusive ERC-165
advertisement authority; the inherited diamond mapping remains inert. Helpers
therefore returns `false` for Core's four operation-specific protected-account
callback IDs:
`0x8886834b`, `0xc8a81e3b`, `0xc723c768`, and `0x54b02e3b`. A pristine
deterministic shell must not have any of those bits set before finalization.

Helpers is consequently a code-bearing non-advertiser, not a protected-policy
account. Core makes one bounded 30,000-gas ERC-165 probe before each relevant
Helpers outflow without a pre-probe gas threshold.
Non-advertisement preserves ordinary semantics for Helpers' CYGLD recipient and
owner-fee payouts, its CYGLD burn during redemption, and its nested
recovery-share forwarding from the Core receiver callback. Callers budget only
for the complete outer route; exact minimum-caller-gas tests prove successful
execution and atomic failure one gas below that complete-operation minimum.

Postflight must prove the four callback IDs remain false, in addition to
proving that the approved adapter set contains exactly the recorded 1inch and
Uniswap adapters, the diamond and routed facets agree on Permit2, and each
adapter is bound to the diamond. The retained postflight artifact records both
launch adapter addresses, the exact count, and their set hash. Helpers has no
separate Safe trust or identity store: a Safe may be the current ERC-173 owner,
but Helpers persists no Safe singleton, version, or marker.
The retained facets are not merged: ownership, pause, configuration, preview,
stateful issuance, mixed redemption, and receiver callbacks have distinct
authority or external-call boundaries. Under the canonical Osaka/100-run
artifact graph, the largest deployed product facet is the 16,332-byte
aggregated redemption facet, preserving 8,244 bytes of EIP-170 runtime margin;
the direct-basket redemption facet is 13,394 bytes.

See the [execution API](../reference/execution-api.md) for exact public tuple
semantics and the [completed implementation
record](../../../cybergold-ops/docs/work/done/core-helpers-governance-app-smart-contract-simplification-implementation-plan.md)
for the selected simplification authority. Core callback compatibility follows
the active [Governance protected-account invariant implementation
plan](../../../cybergold-ops/docs/work/implemented-awaiting-release/governance-protected-account-invariants.md).
