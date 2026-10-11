---
title: Preview and execution API decision
doc_type: adr
status: accepted
owner: helpers-maintainer
created: 2026-02-04
last_reviewed: 2026-07-21
canonical_for: preview execution naming and guard rationale
superseded_in_part_by: 2026-07-15-core-safe-handoff-and-router-deadline-removal.md
---

# Preview and execution API decision

> **Partially superseded before clean launch.** On 2026-07-15, the requirement
> below that every state-changing execution receive a top-level deadline became
> historical. The accepted
> [Core safe-handoff and router-deadline decision](2026-07-15-core-safe-handoff-and-router-deadline-removal.md)
> removes that independent deadline while preserving ERC-2612, Permit2, and
> venue-specific expiries. On 2026-07-21, clean-launch results were further
> minimized so they no longer echo quote parameters or expose a separate gross
> issuance projection. The amount direction, fee basis, and typed calculated
> results remain accepted; the current [execution
> API](../reference/execution-api.md) controls exact shapes.

CyberGold adopted explicit amount direction and fee basis (`gross*`, `net*`,
`*In`, `*Out`) and typed preview results. Slippage minima belong to execution
parameters, not preview intent. The historical design also embedded reusable
quote parameters in results and gave every state-changing execution a
top-level deadline; both choices were removed before launch. The durable
preview/execute relationship remains inspectable without forcing all
mathematically possible preview directions to have an execution endpoint.

This ADR extracts the durable decision from the earlier ignored vNext and
improvement drafts. Current ABI names and shapes remain authoritative.

For exact-output issuance, `netCygldOut` is the exact amount the final
recipient receives after both fee layers. Helpers minimally grosses that
amount up to Core net for the Helpers fee; Core then minimally grosses Core net
up to protocol gross for its own fee. Protocol gross remains an internal
accounting consequence, not a repeated result or event field; the caller's
exact-output intent remains `netCygldOut`.

This H1 convention was selected before first deployment so every issuance
surface uses one end-to-end meaning. Exact-input issuance remains input-budget
driven, and redemption remains exact gross CYGLD input.

Settlement is role-based when addresses alias. Helpers does not reject an
issuance recipient that is also the configured fee recipient. That address
receives the exact final-recipient leg and the separately computed Helpers fee
leg under the same rules used for two distinct addresses. The exact-output
promise applies to the recipient leg, not to the aggregate balance delta of an
address serving multiple settlement roles.
