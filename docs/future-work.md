---
title: Helpers owned future work
doc_type: backlog
status: active
owner: helpers-maintainer
created: 2026-07-23
last_reviewed: 2026-07-23
canonical_for: Helpers explicitly deferred engineering work
---

# Helpers owned future work

This register owns work that was deliberately deferred from the Phase 1
candidate. An entry is not a release claim, a completed control, or permission
to weaken the current fail-closed boundaries.

## BP-HELP-009 — Bind opaque 1inch payload intent

- **Owner:** Helpers maintainer, with App maintainer input.
- **Trigger:** before a release depends on 1inch payload intent being verified
  on chain, or before expanding the supported adapter trust claim.
- **Work:** select and qualify either a bounded selector/calldata decoder or a
  signed-quote scheme that binds the intended input token, output token,
  amount, recipient, venue target, and expiry.
- **Current boundary:** `OneInchAdapter` forwards opaque caller-provided
  calldata to its immutable Aggregation Router. Helpers proves adapter input
  debit, measured output credit, per-leg minima, Core settlement bounds, and
  final recipient minima, but it does not prove that the payload's internal
  fields express the caller's intended trade.
- **Residual risk:** malformed or mistaken payload intent can execute a
  different semantically valid Aggregation Router operation before the outer
  accounting checks accept or atomically revert it.

App-side decoding, quote comparison, and warnings are encouraged defense in
depth. They do not become an on-chain trust boundary, and release/readiness
material must not describe them as semantic verification by Helpers.

## BP-HELP-011 — Requalify the frozen ZeroEx adapter

- **Owner:** Helpers maintainer, with security review.
- **Trigger:** any proposal to modify `ZeroExAdapter` beyond the narrowly
  approved compiler-pragma synchronization below, deploy or approve it,
  include it in a manifest or ABI, or add it to active test/fork support.
- **Work:** explicitly reopen its implementation review, dependency identity,
  deployment binding, accounting tests, fork qualification, ABI/support
  documentation, and release evidence as one reviewed change.
- **Current boundary:** the source remains bound to the historical hash enforced
  by `ci/check-dormant-zeroex.py`. On 2026-09-15, the owner explicitly approved
  only changing `pragma solidity ^0.8.36;` to `pragma solidity ^0.8.37;` for
  compiler-baseline synchronization. The gate normalizes only that exact directive
  back to its historical value before comparing the complete source hash. Both
  the historical source and this approved pragma-only variant are accepted;
  other pragma versions, body changes, comments, and all other source drift are
  rejected. This exception is not production requalification and grants no
  deployment, approval, generated-ABI, test/fork-support, or other active re-entry.

Updating only the frozen hash or bypassing the gate is not requalification.

## BP-REPO-002 — Complete dependency-adoption policy

- **Owner:** Helpers maintainer, coordinated with the Ops maintainer.
- **Trigger:** post-launch policy work or any request to replace exact reviewed
  candidate pins with mutable upstream discovery.
- **Work:** define review cadence, acceptable lag, blocking thresholds,
  unavailable-upstream handling, urgent-update ownership, runner-image policy,
  exception expiry, and retained adoption evidence across all ecosystems.
- **Current boundary:** candidate validation consumes exact reviewed and
  immutable pins. Network-backed latest-version discovery remains advisory and
  cannot mutate or authorize a candidate.

## BP-REPO-007 — Re-evaluate optimizer policy

- **Owner:** Helpers maintainer, coordinated with Protocol and Ops maintainers.
- **Trigger:** a product facet leaves less than the enforced 4 KiB EIP-170
  runtime margin, or a representative route breaches its tracked 5% relative
  gas ceiling or absolute gas budget.
- **Work:** benchmark candidate optimizer settings across runtime size,
  deployment gas, and representative execution gas, then obtain an explicit
  cross-product decision before changing the shared value.
- **Current boundary:** every Helpers build and analysis consumes the single
  `foundry.toml` graph with optimizer enabled at 100 runs and EVM `osaka`.
