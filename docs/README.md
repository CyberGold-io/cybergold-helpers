---
title: CyberGold Helpers documentation
doc_type: portal
status: active
owner: helpers-maintainer
created: 2026-07-11
last_reviewed: 2026-10-11
canonical_for: Helpers documentation navigation
---

# CyberGold Helpers documentation

| Document | Status | Owner | Last reviewed |
| --- | --- | --- | --- |
| [Root README](../README.md) | active | Helpers maintainer | 2026-07-23 |
| [Portfolio security model](../../cybergold-ops/docs/security/security-model.md) | active | Ops maintainer | 2026-07-13 |
| [Production smart-contract simplification implementation plan](../../cybergold-ops/docs/work/done/core-helpers-governance-app-smart-contract-simplification-implementation-plan.md) | completed source authority | Ops maintainer | 2026-07-22 |
| [Governance protected-account invariant implementation plan](../../cybergold-ops/docs/work/implemented-awaiting-release/governance-protected-account-invariants.md) | implemented, awaiting release evidence | Protocol maintainer | 2026-07-23 |
| [Architecture](architecture/overview.md) | active | Helpers maintainer | 2026-07-23 |
| [Market swaps](reference/market-swaps.md) | active; candidate extension | Helpers maintainer | 2026-10-10 |
| [Execution API](reference/execution-api.md) | active | Helpers maintainer | 2026-07-22 |
| [Optional-initializer coordinator migration](reference/optional-initializer-migration.md) | active | Helpers maintainer | 2026-10-10 |
| [ABI usage matrix](abi-usage-matrix.md) | active | Helpers maintainer | 2026-07-22 |
| [Testing](development/testing.md) | active | Helpers maintainer | 2026-07-23 |
| [Branch workflow](development/branch-workflow.md) | active | Helpers maintainer | 2026-10-11 |
| [Owned future work](future-work.md) | active | Helpers maintainer | 2026-07-23 |
| [Core safe-handoff and router-deadline ADR](adr/2026-07-15-core-safe-handoff-and-router-deadline-removal.md) | superseded historical decision | Helpers maintainer | 2026-07-22 |
| [Preview/execution ADR](adr/2026-02-04-preview-execution-api.md) | historical; superseded in relevant parts | Helpers maintainer | 2026-07-21 |
| [Uniswap quote incident](incidents/2026-02-uniswap-quote-staticcall.md) | completed historical evidence | Helpers maintainer | 2026-07-11 |

The current Ops implementation plan is the authority for the simplified
single-token/native aggregation and direct-basket products, generic mixed
redemption, retained authorization variants, immutable dependency topology,
launch adapter set, and Core protected-account callback compatibility. The
active architecture, execution API, and ABI matrix describe the landed Helpers
implementation.

Older ADRs and incident records are preserved as history. They explain earlier
amount, deadline, and adapter-quotation decisions but are not an authority for
current route names, tuple shapes, mode/epoch binding, direct wrappers,
deployment composition, or outcome events.

Phase 1 release operations and the trusted-but-fallible operator security model
live in Ops. Helpers treats callers, swap payloads, routers, tokens, and public
chain state as untrusted. Product-wide economic claims live in Protocol
documentation. Explicitly deferred Helpers engineering is owned in the
[future-work register](future-work.md).

Public contributor and licensing entry points:

- [Contributor guide](../CONTRIBUTING.md).
- [Project licensing scope](../LICENSING.md).
