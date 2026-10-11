---
title: Helpers market swaps
doc_type: reference
status: active
owner: helpers-maintainer
created: 2026-10-10
last_reviewed: 2026-10-10
canonical_for: Scoped market extension funding execution and release semantics
---

# Helpers market swaps

The market extension trades existing ERC-20 tokens through
`MarketSwapFacet → UniswapMultiProtocolAdapter → Universal Router 2.2.0`.
The existing Core issue/redeem operations and historical 54-selector release
remain separate. The supplemental `generated/abi/HelpersMarket.json` is not a
claim that its selectors are installed; consumers observe the actual Diamond.

Both `swapExactInput` and `swapExactOutput` accept `IMarketSwap.MarketSwapParams`
and one funding authorization. Side 0 buys CYGLD, side 1 sells CYGLD. The
configured Core token provides the CYGLD endpoint; `msg.sender` funds and
receives refunds, while `recipient` receives user output. Existing allowance,
ERC-2612 native permit and Permit2 SignatureTransfer are available. Native
permit funds the complete inclusive budget/maximum inside the swap transaction.
An already sufficient allowance handles a previously submitted permit.

The Backend's replaceable pricing function initially returns 1,000 ppm (0.1%).
It freezes a quoted CYGLD fee `F` in calldata. A buy deducts F from newly received
CYGLD; a sale retains F from the acquired CYGLD budget. The facet resolves the
existing Diamond owner as actual beneficiary. This is first-party application
pricing; the facet does not authenticate a Backend rate or require a positive F.
Independent callers can choose their own F, including zero. Adapter and router
commands collect no second application fee.

For exact-input sales, `amount` is total inclusive budget B, `routedInput` is
explicit S, and `bound` is the counter-token output floor. With M=1,000,000 and
rate r, S=floor(B*M/(M+r)), F=ceil(S*r/M). For B=1002 and r=1000, S=1000, F=1,
with one unit refunded. Never route B−F. Exact-output purchases quote gross
target G=ceil(N*M/(M−r)) and F=G−N. Sale exact-output maxima include the fixed
quoted fee; unused acquired CYGLD is refunded. Measured custody preserves old
balances and returns current output improvement/surplus according to the ABI.

Adapter `SwapPlan` encodes exactIn, aggregate limit, deadline, and ordered
branches of literal inputs and typed V2/V3/V4 hops. V2=0, V3=1, V4=2. All three
support homogeneous input/output. Mixed and split routes support exact input;
complex mixed exact output is deferred. Each input hop uses its measured new
output as successor funding. Exceptional nonendpoint current-operation
remainders revert atomically under the owner's accepted OQ-4 invariant.
Historical balances never become current funding; zero lots never become V2's
already-paid sentinel. The retained V3 payload is supported by the new adapter
for existing Core consumers.

The selected Mainnet router is `0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB`.
`config/market-deploy-config.json` and the `uniswapMarket` reviewed dependency
lock hold the scoped release facts. The old immutable 2.1.1 adapter is not
retargetable. A new adapter deployment and approval/configuration transition
perform the upgrade; historical deployment configuration/evidence is retained.

`MarketSwapDeployment` deploys just the facet and new adapter. Its additive cut
installs two selectors through the existing validated Diamond coordinator,
which records the new market namespace generation. No initializer is needed.
`script/DeployMarketSwap.s.sol` prints the separate owner cut and adapter approval
calldata. The owner performs creation/cut/approval signatures with a Ledger,
following the existing reviewed Ops deployment procedure; do not broadcast
from an agent session. Before deployment, qualify the actual dependencies,
constructor identities, compiled artifacts and scoped rehearsal. Record the
installed adapter/selector identities before enabling the App market flow.

Regenerate the supplement after `forge build` with
`python3 script/generate-market-abi.py`; `ci/check-release-abi.sh` verifies it
alongside the unchanged historical release. The scoped coordinator test is
`test/MarketSwapDeployment.t.sol`. Actual router/funded-pool scenarios are in
`qualification/UniswapMarketFork.t.sol`; they use a local Mainnet fork and synthetic
holder balances, with real token permits/router/pool code. They do not establish
owner Ledger or production installation acceptance.
