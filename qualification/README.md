---
title: Native token permit fork qualification
doc_type: reference
status: active
owner: helpers-maintainer
created: 2026-10-10
last_reviewed: 2026-10-20
canonical_for: Candidate token-native permit purchase fork test scope
---

# Native token permit fork qualification

`TokenNativePermitFork.t.sol` exercises actual deployed PAXG, XAUt and USDC
permits through a full candidate Helpers diamond on a disposable mainnet fork.
The first-use cases start without Helpers or Permit2 allowance, sign exactly
the purchase ceiling, acquire it atomically, refund unused input and deliver
exact CYGLD. A USDC failure after acquisition checks that nonce, allowance and
economic balances roll back together. Core and adapter accounting use local
test doubles.

`TokenNativePermitLiveCoreFork.t.sol` adds two PAXG cases using deployed Core
`0x601da021cAF3DB5AA63e700D239b5935C370601d`, the real PAXG/XAUt Uniswap V3 pool
`0xc756BBA710d45647715079cE50aa16aab36deD42`, and Universal Router
`0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA`. Each case deploys a fresh
candidate Helpers diamond and an adapter bound to it inside the disposable
fork. Existing Core and Helpers configuration is untouched. The successful
case signs the exact PAXG ceiling, trades for the required XAUt, and settles
through actual Core. It checks exact CYGLD delivery, protocol fees, reserve
and pool movements, a positive input refund, the consumed permit nonce,
zero remaining payer allowance, and cleared ERC20 approvals and temporary
custody. The failure case uses an expired actual Universal Router command
and verifies that the permit, allowances and all observed economic balances
roll back together. The adapter's existing Permit2 internal allowance behavior
is unchanged; the cleanup assertions concern ERC20 approvals.

This separately invoked qualification uses the October 7 domain-evidence block
`26142051`. It preserves the existing historical four-suite/nine-test release
fork inventory at block `25609006`. Run the complete historical qualification
through `ci/check-fork-tests.sh` as before, and run these native-permit cases
separately:

```sh
FOUNDRY_TEST=qualification ../cybergold-ops/scripts/with-authenticated-rpc.sh \
  --cwd "$PWD" -- bash -c \
  'forge test --match-contract "(TokenNativePermitForkTest|TokenNativePermitLiveCoreForkTest)" --fork-url "$MAINNET_RPC_URL" --fork-block-number 26142051 -vv'
```

The existing RPC wrapper obtains its transport credentials from the local Ops
tooling environment. Tests create fresh disposable signing accounts in memory;
they broadcast no transaction and create no wallet prompts. A fixed, publicly
known test private key can already have code on mainnet, which USDC correctly
handles through ERC1271 rather than an EOA signature. Fresh accounts keep this
qualification focused on the EOA standard-permit path.

The ordinary unit suite contains the imported standard-token route, domain,
nonce, payer, reentrancy, exact-transfer, allowance and failure regressions,
including 256-case ceiling/refund fuzz coverage. These six fork cases establish
real token permit behavior and one PAXG purchase route through deployed Core
and Uniswap. Other token-to-Core/venue routes, Backend and App qualification,
physical-wallet behavior and shared target installation remain separately
recorded in the Ops implementation workplan.

`TokenNativePermitInstalledHelpersFork.t.sol` is invoked separately by the
Ops optional-initializer workflow after its owned Anvil has migrated the
existing Helpers coordinator and installed the candidate issuance facet. It
forks that Anvil's latest post-cut state. It deploys no substitute Helpers,
adapter, Core or venue and changes no installed configuration. Three cases
exercise native PAXG permit purchase, exact ordinary PAXG allowance purchase,
and actual venue failure/permit-economic rollback. They preserve pre-existing
Helpers/adapter custody and assert actual Core/Uniswap economics and retained
coordinator/issuance routing. The payer is a fresh locally funded test account;
this is not a physical-wallet or shared Sandbox test. The ordinary PAXG case
tests the allowance executor independently of native signing, not a live USDT
liquidity route. Its operator command is the scoped Ops rehearsal; running
against an unmodified upstream correctly fails because the selector and new
coordinator are not installed there.

`BasketMixedPermitsInstalledHelpersFork.t.sol` adds eight cases invoked after
the separate owned-Anvil basket facet cut. It uses the actual installed
Helpers, Core, PAXG, XAUt and Permit2 without deploying replacements or changing
their configuration. Direct basket settlement invokes no swap venue. The cases
cover first and repeat all-native purchases, a native PAXG/Permit2 XAUt subset,
cold token-to-Permit2 setup and warm repeat batches, exact ordinary Helpers
allowances, invalid real Permit2 and native signatures, real Permit2 nonce
replay, and native exact-input budgets. XAUt is native-qualified; selecting
Permit2 for it exercises the contract acquisition mechanism, while client
routing uses native permits for qualified tokens. A non-permit unit token
separately covers the unsupported-capability path.

Success assertions bind payer debits, Core reserve increments, net output,
protocol fees and supply to the returned full input vector. They preserve
existing Helpers custody and unrelated pool balances, clear Helpers-to-Core
approvals, and verify native nonce/allowance or Permit2 nonce bitmap effects.
Failure assertions compare the complete economic and permission snapshot,
including rollback of an earlier native permit. Exact-output native signatures
use each fresh Core lot and leave zero allowance; exact-input signatures may
leave finite unused trade-budget allowance because only the fresh lot is
pulled. Unlimited ERC20 token-to-Permit2 setup is tested as the sole exception
to finite per-trade permissions.

Run against the owned Anvil's latest state after the basket cut:

```sh
FOUNDRY_TEST=qualification forge test \
  --match-contract BasketMixedPermitsInstalledHelpersForkTest \
  --fork-url "$OWNED_ANVIL_URL" -vv
```

This development rehearsal is separate from the unchanged historical
four-suite/nine-test inventory and the earlier six token-native cases. The
candidate is not published to Mainnet, and physical-wallet signing and shared
deployment remain on hold.

## Universal Router 2.2 market qualification

`UniswapMarketFork.t.sol` separately qualifies Router 2.2 at
`0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB`, using block `26164733` and the
funded PAXG/CYGLD V4 pool. Twelve cases cover four native-permit market modes,
V2/V3, legacy V3 payloads, both directions of the mixed V2/V3/V4 route, ordered
splits reusing the same pools and atomic aggregate-floor failure after price
movement. The split matches two ordered executions exactly and its second
branch receives less than a quote against the initial state. Intermediate
donations and router balances remain intact. Ten cases use unmodified existing
pool implementations with synthetic holder funding. One creates and funds a
fork-only CYGLD/USDC pair through the actual canonical V2 factory to qualify
V3 -> V4 -> V2; no CYGLD V2 pool exists at the recorded snapshot. Another
explicitly mocks a partial PoolManager delta to exercise actual Router 2.2's
underfill behavior. Reported test gas includes fixture/Quoter/assertion work
and is not a whole-transaction gas benchmark.
The historical four-suite/nine-test inventory remains unchanged.

```sh
FOUNDRY_TEST=qualification ../cybergold-ops/scripts/with-authenticated-rpc.sh \
  --cwd "$PWD" -- bash -c \
  'forge test --match-contract "^UniswapMarketForkTest$" -vv'
```

The suite selects the recorded block itself; `UNISWAP_MARKET_FORK_BLOCK` is an
explicit later qualification override. These tests never broadcast. Owner
Ledger and installed-facet/adapter acceptance remain separate release work.

## Universal exact-input qualification

`UniswapRoutingFork.t.sol` exercises the successor `UniswapRoutingAdapter`
against actual Universal Router 2.2.0 at
`0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB`, Permit2 and PoolManager at
Mainnet block `26164733`, hash
`0x841450fad8ae713daeeadf60e0e360554053c81d0341729d394c602154aff453`.
Nine cases passed on the local implementation candidate:

- V2/V3 exact-input and retained homogeneous exact-output payloads;
- canonical PAXG/CYGLD V4 execution and mixed V2/V3/V4 custody;
- grouped V4 `PathKey[]`, native input/output, native intermediate currencies,
  ordered split branches and explicit ETH/WETH connections;
- actual bounded-liquidity V3 and V4 input underconsumption;
- native mixed Core/Market purchase and sale, including actual Core supply
  changes and final output settlement.

Native V4 and bounded-liquidity cases create explicitly fork-only pools/tokens
using actual deployed factory/PoolManager code. Other cases use existing
Mainnet liquidity and Core. Synthetic payer funding is local to each fork.
Historical balances remain outside current-operation custody. These tests do
not broadcast or authorize a production cut.

```sh
../cybergold-ops/scripts/with-authenticated-rpc.sh --cwd "$PWD" -- \
  env FOUNDRY_TEST=qualification FOUNDRY_OUT=out-qualification \
  FOUNDRY_CACHE_PATH=cache-qualification \
  forge test --match-contract UniswapRoutingForkTest
```

The Ops universal exact-input rehearsal separately upgrades an owned Anvil's
actual Helpers target and compares six Backend SDK quotes with execution
before and after retirement of old selectors. Its runbook and retained
candidate evidence describe that wider consumer/release qualification. The
historical qualification suites above retain their own scopes; archived
exact-input interfaces used by those tests are test fixtures only.
