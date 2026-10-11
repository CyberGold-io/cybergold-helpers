---
title: Uniswap quote staticcall incident
doc_type: incident
status: completed
owner: helpers-maintainer
created: 2026-02-04
last_reviewed: 2026-07-11
canonical_for: Uniswap quote failure rationale
---

# Uniswap quote staticcall incident

Token-route previews failed when the Helpers adapter attempted to call
QuoterV2 through `staticcall`; some simulated swap paths perform state writes
and therefore revert in a static call tree. The durable resolution is to build
quotes off chain (or call the appropriate quoter directly from the integration
layer), pass conservative minima/payloads to Helpers, and keep adapters
execution-only. Current balance-delta settlement tests cover adapter output and
refund integrity.

