---
title: Core safe handoff and router deadline removal
doc_type: adr
status: superseded
owner: helpers-maintainer
created: 2026-07-15
last_reviewed: 2026-07-22
canonical_for: historical Core bounded-settlement and Helpers execution-expiry rationale
supersedes_in_part: 2026-02-04-preview-execution-api.md
superseded_by: ../../../cybergold-ops/docs/work/done/core-helpers-governance-app-smart-contract-simplification-implementation-plan.md
---

# Core safe handoff and router deadline removal

> **Superseded on 2026-07-22.** This ADR is preserved as historical rationale.
> The [production smart-contract simplification implementation
> plan](../../../cybergold-ops/docs/work/done/core-helpers-governance-app-smart-contract-simplification-implementation-plan.md)
> and the current [execution API](../reference/execution-api.md) are
> authoritative for the implemented generic route surface, mixed redemption
> binding, tuple shapes, and events. The historical body below is unchanged.

The [current Ops risk
register](../../../cybergold-ops/docs/security/current-risk-register.md#current-accepted-risk-inventory)
tracks the Helpers boundaries as `HLP-L-05` (caller-bound settlement does not
commit the Helpers fee allocation) and `HLP-I-01` (Helpers execution has no
top-level expiry). Core's independently remediable counterparts are
`COR-L-03` and `COR-I-08`. They are new accepted residual findings, not
reopenings of the source-closed CG-M04 immediate-settlement finding.

> **Clean-launch projection revised on 2026-07-21.** The safe-handoff and
> deadline decisions remain accepted. Before launch, result structs were
> minimized to calculated values, recovery identity was reduced to ordered
> assets plus an epoch, and `SwapFromQuote` stopped repeating Core's input lot.
> The current [execution API](../reference/execution-api.md) is authoritative for
> exact struct and event shapes.

## Decision

Helpers issue and redeem routes use Core safe-settlement endpoints:
`safeIssue`, `safeRecoveryIssue`, `safeRedeem`, or `safeRecoveryRedeem` as the
current route requires. Healthy basket calculations return
`orderedBasketAssets`; recovery redemption returns distinct ordered healthy and
recovery asset lists. Execution receives those lists as expected identities.
Helpers compares the addresses before custody or adapter effects and passes the
same identities and numeric bounds to Core, which repeats the checks against
its fresh calculation immediately before settlement.

The ordered address list is the complete basket-identity commitment for these
routes. Helpers does not expose or accept a basket hash: hashing the same list
would add calldata and computation without protecting any value not already
bound by the explicit addresses and per-asset maxima or minima.

The independent top-level Helpers execution `deadline` is removed from all five
issue, five healthy-redeem, five recovery-redeem, and one rebalance execution
endpoints. The original deadline decision superseded the requirement in
[the 2026-02-04 preview/execution ADR](2026-02-04-preview-execution-api.md)
that every state-changing execution receive a top-level deadline. The later
clean-launch projection revision also superseded that record's embedded quote
copies and gross-output projection while retaining its amount direction, fee
basis, and typed calculated results.

Expiry fields that authorize or constrain another mechanism remain mandatory:

- the ERC-2612 permit deadline;
- the Permit2 single or batch signature deadline; and
- any venue-specific deadline encoded in adapter data.

These expiries are not router-level transaction deadlines and are not removed
or rewritten by Helpers.

## Lean public data model

Helpers result structs return calculated values and do not echo the quote
inputs already held by the caller. Exact-output issue previews therefore omit
the requested `netCygldOut`; exact-input redemption previews omit the supplied
`grossCygldIn`; and no result embeds a reusable `quoteParams` copy. Computed
outputs remain where they are needed, and `Fees` reports
`protocolFeeCygld` plus `helperFeeCygld`.

The clean-launch ABI standardizes these fields:

| Meaning | Current field |
| --- | --- |
| Exact-in basket issue budgets | `maxAmountsIn` |
| Exact-out basket redemption floors | `minAmountsOut` |
| Previewed basket input vector | `amountsInExact` |
| Previewed basket output vector | `amountsOutExact` |
| Previewed recovery healthy/share vectors | `healthyAmountsOutExact` / `recoverySharesOutExact` |
| Previewed final-token output | `amountOutExact` |
| Realized basket input/output vectors | `amountsIn` / `amountsOut` |
| Realized recovery healthy/share vectors | `healthyAmountsOut` / `recoverySharesOut` |
| Realized final-token output | `amountOut` |
| Protocol and Helpers fees | `protocolFeeCygld` / `helperFeeCygld` |

Healthy execution parameter structs carry `expectedOrderedBasketAssets` where
positional basket terms are used. Issue execution also carries a scalar
`expectedRecoveryEpoch`. Recovery-redemption structs carry expected healthy and
recovery asset lists, share minima, and that same scalar epoch. No nested Core
protection struct, recovery configuration hash, or parallel share-ID array is
added.

Token redemption derives each Core minimum and adapter input from the fresh
Core amount. `SwapFromQuote` binds the input asset, adapter, output minimum,
call value, and venue data but does not duplicate `inputAmount`. Direct basket
redemption passes caller-provided `minAmountsOut` directly.

## Rationale

The exact CYGLD principal, complete ordered asset list, per-asset maxima or
minima, adapter-leg bounds, and final output minimums define the economic terms
of a route. A separate router timestamp does not strengthen those terms: an old
transaction can execute only while every bound still passes. The sender retains
normal nonce replacement or cancellation when temporal preference matters.

The Core safe handoff closes the callback window between Helpers' preparation
and Core settlement. Helpers performs an execution-time Core preview, validates
the caller's expected list before acquiring assets, and later calls Core safe
settlement with that same list and operation bounds. A callback-time change can
execute only if Core's fresh calculation still satisfies those bounds.

## Consequences

- Consumers must migrate to the deadline-free execution selectors and provide
  the expected ordered asset lists and recovery epoch required by their route.
- Consumers must treat `orderedBasketAssets[i]` as the identity of every
  positional `amountsInExact[i]`, `amountsOutExact[i]`, maximum, or minimum.
- A pending transaction may be mined later than the sender expected when all
  economic bounds and any permit or venue expiry still pass; this temporal
  residual is accepted.
- Every production Helpers facet starts at version 1 for the clean launch. The
  first post-launch replacement of a replaceable facet must use version 2.
- Consumers must retain quote inputs locally; preview results no longer echo
  them. Recovery consumers use recovery asset addresses as the share identity
  and must not expect collection/configuration getters or share-ID vectors.
