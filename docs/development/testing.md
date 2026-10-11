---
title: Helpers testing
doc_type: development-guide
status: active
owner: helpers-maintainer
created: 2026-07-11
last_reviewed: 2026-10-10
canonical_for: Helpers supported test commands
---

# Helpers testing

Run the complete repository entry point with:

```bash
./script/test.sh
```

For local iteration, build and run non-fork suites directly:

```bash
forge build
forge test --no-match-path 'test/*Fork*.t.sol'
forge test --match-path test/BasketRouterIssue.t.sol
forge test --match-path test/RouterIssueBasketMixedPermits.t.sol
forge test --match-path test/BasketRouterRedeem.t.sol
forge test --match-path test/BasketRouterAdmin.t.sol
forge test --match-path test/CoreHelpersFeeIntegration.t.sol
forge test --match-path test/DeployLibraries.t.sol
forge test --match-path test/ReleaseAbiConformance.t.sol
forge test --match-path test/HelpersOptionalInitializerMigration.t.sol
forge test --match-path test/ValidatedUpgradeCoordinator.t.sol
forge test --match-path test/OneInchAdapter.t.sol
forge test --match-path test/UniswapUniversalAdapter.t.sol
```

The focused release-surface gates are:

```bash
./ci/check-build-test.sh
./ci/check-facet-selectors.sh
./ci/check-selector-snapshots.sh
./ci/check-release-abi.sh
./ci/check-storage-inventory.sh
./ci/check-sizes.sh
./ci/check-gas-budgets.sh
python3 ./ci/check-build-policy.py
python3 ./ci/check-dormant-zeroex.py
python3 ./ci/check-fork-evidence-policy.py
./ci/check-natspec.sh
./ci/check-coverage.sh
python3 lib/cybergold-protocol/ci/check-solidity-known-bugs.py --project-root .
python3 lib/cybergold-protocol/ci/check-docs.py .
python3 lib/cybergold-protocol/ci/check-terminology.py --project-root .
```

`check-release-abi.sh` regenerates the canonical aggregate client interface in
check mode and runs the Helpers-specific ABI semantics validator. The generated
aggregate freezes the release ABI but is deliberately not advertised through
ERC-165; ERC-165 is reserved for diamond standards, ERC-173, and the narrow
ERC-1155 receiver interface. The selector gates freeze the installed facet
mapping and reject stale removed routes. Coverage requires 100% of active
Helpers source; dormant `ZeroExAdapter` source is explicitly excluded because
it is not deployed, launch-qualified, or actively supported.
`check-dormant-zeroex.py` also freezes its reviewed source hash and rejects any
deployment, release, generated-ABI, or qualification re-entry pending explicit
requalification.

`check-build-policy.py` makes `foundry.toml` the single first-party compiler
authority and rejects per-command EVM or optimizer overrides. Every build and
analysis therefore uses Solidity 0.8.37, EVM `osaka`, optimizer enabled, and
100 optimizer runs.

## Required route evidence

Issuance tests must cover:

- allowance and Permit2 token acquisition plus exact-value native acquisition;
- token/native exact-in previews used to construct exact-output execution;
- direct-basket exact-in and exact-out previews plus their atomic Permit2 batch
  executions;
- mixed basket acquisition with full Core-order budgets, native permit and
  compact Permit2 subsets, ordinary allowance fallback, unsupported native
  capability, real signature/nonce replay rollback, and cross-asset callback
  conservation;
- signed basket order, length, deadlines, ceilings, fresh exact pulls and Core
  approvals, post-Permit2 requirement drift, and stale-balance isolation;
- one Core snapshot before any adapter effect and no post-swap Core preview;
- ordered-asset drift, requirement increases, accepted decreases, exact Core
  debit bounds, and allowance cleanup;
- compact direct/converted/zero-target leg ordering, including production-Core
  one-asset and unreadable Exiting-member regressions, adapter input/output
  mismatch, and independent minima; and
- exact `Issued` fields, native event marker, fee payout, and operation-local
  refund isolation; and
- one complete `IssuedFromBasket` vector event per direct-basket success.

Redemption tests must cover:

- allowance, Permit2, and CYGLD ERC-2612 for both token and native output,
  including fresh-wallet and already-consumed-permit behavior;
- caller `expectedCoreOutputs` passed unchanged to `safeRedeem`;
- complete mixed descriptor validation, zero structural legs, state drift, and
  maximum vectors;
- direct-basket exact-input execution plus exact-output preview construction,
  all three CYGLD authorization paths, and complete mixed direct delivery;
- unreadable zero ERC-20 legs that remain structural without blocking positive
  settlement, alongside fail-closed zero-to-positive drift;
- ERC-20 aggregation, share-only output, native unwrap, per-adapter minima,
  aggregate minimum, and exact recipient credit;
- the `Idle -> Armed -> Consumed -> Idle` ERC-1155 receipt, exact batch
  authentication, forwarding, rollback, and callback/reentrancy behavior; and
- exact `Redeemed` fields, positive-only typed recovery result, one economic
  outcome, fee payout, and operation-local refund isolation; and
- one complete `RedeemedToBasket` vector event per direct-basket success.

Admin, deployment, and ABI tests must additionally prove immutable Permit2
identity across routed facets and Uniswap, immutable adapter recovery authority,
recovery after allowlist removal, expected-current/no-op setter guards, direct
shared reentrancy initialization, and the shell-to-adapters-to-finalization
deployment topology. They must prove that removed recovery/rebalance wrappers,
public `quote*` operations, mutable Permit2, adapter native-value fields, and
launch ZeroEx entries cannot reappear in generated surfaces.

The production-Core integration also proves Helpers remains a code-bearing
non-advertiser for the four protected-account callback IDs. It expects Core to
request at most 30,000 gas during both CYGLD issuance payouts, the redemption
fee payout and burn, and nested recovery-share forwarding. There is no
pre-probe threshold. Calibrated cases prove the exact minimum caller gas
completes for CYGLD and recovery-share outflows, while one less gas fails
atomically. Deployment, release ABI, and verification tests assert all four IDs
remain false, while tainted-shell tests reject any preexisting positive
registration.

## Fork tests

Set `MAINNET_RPC_URL` to run canonical 1inch and Uniswap fork suites through the
CI helper:

```bash
MAINNET_RPC_URL="$MAINNET_RPC_URL" ./ci/check-fork-tests.sh
```

The default fork block is pinned by the script and may be overridden with
`MAINNET_FORK_BLOCK`. When `MAINNET_RPC_URL` is absent, the gate emits an
unmistakable local warning and a GitHub Actions warning annotation: the fork
tests were not run and the result is not a pass. The warning behavior has its
own regression test.

Production/release acceptance does not use that nonblocking development path.
Manually dispatch the `Helpers release fork evidence` workflow at the approved
ref and enter the same exact 40-character commit as `expected_commit`.

Select one release authority explicitly:

- `pinned-history` (the default) requires the protected archive RPC to report
  Ethereum mainnet chain ID `1` and serve block `25609006`. The gate resolves
  and records that block's exact hash before Forge, then verifies the same
  chain/number/hash identity after Forge.
- `live-latest-snapshot` is the owner-authorized fallback when that historical
  state is unavailable. It starts Anvil on a private `127.0.0.1` endpoint with
  an unpinned upstream fork, reads that local fork head once, records its exact
  block number and hash, requires Ethereum mainnet chain ID `1`, and then pins
  Forge and any test-created nested forks to that exact private local block for
  the whole run. It re-verifies the recorded number/hash before shutting down
  Anvil. The retained authority is the resolved number/hash pair, never the
  mutable label `latest`.

Both modes fail closed unless the commit and clean checkout match both before
and after execution, and exactly the four expected suites / nine tests pass
with their exact per-suite counts (`1 + 2 + 2 + 4`). Extra, duplicate, or
partial suites fail. The artifact records the commit, selected mode, resolved
block identity, suite completeness, Forge exit code, and SHA-256 digest of the
sanitized log. The shared sanitizer removes the complete upstream URL plus
decoded username, password, path-token, query-token, and fragment credentials
from retained diagnostics. The live runner gives Forge only its private
loopback URL and exact resolved block; it terminates the complete private Anvil
and Forge process groups on success, failure, or interruption. Only a `passed`
artifact with `suiteCompleteness: true` is release evidence.

There is deliberately no automatic fallback: a partial or failed
`pinned-history` run remains failed. Dispatch `live-latest-snapshot` as a new,
explicit evidence run if archive capability is unavailable.

For a local rehearsal of pinned-history semantics, use the credential-safe Ops
URL + bearer wrapper (`../cybergold-ops/scripts/with-authenticated-rpc.sh`):

```bash
../cybergold-ops/scripts/with-authenticated-rpc.sh -- env \
  EXPECTED_HELPERS_COMMIT="$(git rev-parse HEAD)" \
  bash ci/check-fork-tests.sh --release-evidence
```

For the explicit live snapshot fallback, keep `MAINNET_FORK_BLOCK` unset:

```bash
../cybergold-ops/scripts/with-authenticated-rpc.sh -- env \
  EXPECTED_HELPERS_COMMIT="$(git rev-parse HEAD)" \
  HELPERS_RELEASE_FORK_MODE=live-latest-snapshot \
  bash ci/check-fork-tests.sh --release-evidence
```

Release mode deliberately rejects a moved commit or dirty checkout before or
after execution. `pinned-history` rejects
any `MAINNET_FORK_BLOCK` other than `25609006`; `live-latest-snapshot` rejects
the variable entirely so no caller-supplied block can be confused with the
resolved snapshot authority. An ordinary missing RPC remains `NOT RUN` /
`NOT A PASS`, and release mode exits nonzero. There is no active ZeroEx fork
suite.

The Protocol gitlink and `foundry.lock` revision are one release input and must
move together. The same lock and exact-worktree check covers Permit2.

`check-storage-inventory.sh` builds the current compiler graph and applies the
Protocol-pinned shared storage inventory engine to the Helpers diamond. The
tracked inventory includes every runtime or delegatecall-reachable storage
root in the release topology, its full compiler schema, and every exact
reviewed alias. Import-only roots pulled in by deployment selector helpers
remain visible as exact, reasoned exclusions. Collisions, missing roots,
invalid aliases, stale exclusions, and unreviewed layout drift fail the gate.
After reviewing an intentional storage change, refresh the snapshot with:

```bash
./ci/check-storage-inventory.sh --update
```

## Critical-route gas evidence

`./ci/check-gas-budgets.sh` measures representative administration, allowance,
Permit2, direct-basket, aggregated recovery-share, and maximum-cardinality
routes. Every route must stay below the absolute ceiling in
`ci/gas-budgets.json` and may not regress by more than 5% from the tracked
`.gas-snapshot` baseline. Intentional gas changes are reviewed first and then
recorded with:

```bash
./ci/check-gas-budgets.sh --update
```

The 100-run optimizer policy must be re-evaluated when a product facet leaves
less than the enforced 4 KiB EIP-170 runtime margin or a representative route
breaches its tracked 5% relative ceiling or absolute gas budget. Any new
optimizer choice requires a fresh cross-product size, deployment-gas, and
runtime-gas benchmark before the single build authority changes.
