# CyberGold Helpers

Phase 1 convenience layer above the Core diamond. `HelpersDiamond` exposes one
address for five product operations:

- aggregate one ERC-20 or native-ETH input into the current Core inputs needed
  to issue CYGLD; and
- atomically issue CYGLD from Core's complete current ERC-20 basket with
  ordinary allowance, native ERC-2612 or one compact Permit2 batch;
- redeem CYGLD through Core, aggregate every ERC-20 output into one chosen
  ERC-20 or native-ETH output, and forward every positive ERC-1155 recovery
  share unchanged to the same recipient; and
- redeem CYGLD directly into Core's complete current mixed ERC-20/ERC-1155
  output vector; and
- trade ERC-20 or native ETH through approved Uniswap V2/V3/V4 routes with
  universal exact input, or homogeneous ERC-20 exact output with retained
  funding modes.

The single universal `executeExactInput` entrypoint composes Core and Market
branches for scalar purchases/sales and complete basket issuance/redemption.
Its disclosed protocol retention differs from the retained true exact-output
executors, which preserve refunds.

There is no rebalance or recovery-named wrapper route in the launch surface.
Healthy and impaired settlement share the same generic mixed-output model.

## Status

- Development: active. The nine universal-exact-input implementations were
  compiled from published Helpers `9ed3a0e74588ec05f02e5189d2db9542a248a1de`,
  with Protocol dependency `16a66bd1276f3029888f03be144df632046ad93e`
  and Solidity `0.8.37+commit.f401782d`. The retained shell and unchanged
  facets keep their original verified deployed-source links below. Later
  documentation commits and release tags do not change compiled-source identity.
- Release: the non-vanity Helpers replacement was deployed on Ethereum Mainnet
  on 2026-09-16 and all 17 source-publication targets are verified on Etherscan
  and exact-match verified on Sourcify. The Helpers fee is 0 ppm and the owner
  may later set a positive rate up to the compiled 0.5% cap. At launch, Core
  remained paused pending separate activation; Helpers' own pause flag is
  independent.
- On 2026-10-10, the owner migrated the coordinator to optional initialization
  in [transaction `0x6b76001c…f7e29`](https://etherscan.io/tx/0x6b76001c70e6c007689b7f391a3941bdb575489b6dc55dc043c2d5df97df7e29),
  then installed token-native ERC-2612 issuance with a zero-initializer cut in
  [transaction `0xf327468b…cdee`](https://etherscan.io/tx/0xf327468b09947296519ac7849a2a8979dc00cb6ee154ef4edb6ba0c61174cdee).
  Both retained implementations are verified on Etherscan and exact-match
  verified on Sourcify; the temporary migration facet is no longer installed.
- Later on 2026-10-10, the mixed-permit basket facet was deployed in
  [transaction `0x56283701…857a`](https://etherscan.io/tx/0x56283701ff5148684e4af2487efe5879924e996ec03c747cc76795177343857a)
  at block **26,164,184** and installed by the zero-initializer cut in
  [transaction `0xb88e23cd…cad9`](https://etherscan.io/tx/0xb88e23cd3c14fb984b0cba095456862d8f65d5d4d898d4749ac166a299a6cad9)
  at block **26,164,272**. The basket facet is verified on Etherscan and
  exact-match verified on Sourcify; the ten unrelated facets are preserved.
- Core's [2026-09-22 immediate-recovery upgrade](https://etherscan.io/tx/0x7c18d51432601edcef9fb243a45c1a8269ffc363d6390492c384c8989fbc55de)
  at block **26,030,290** preserved the deployed Helpers shell, owner, Core
  reference, facet runtimes, selectors and installed generations. No Helpers
  cut or redeployment was needed. Core remained paused after the upgrade.
- On 2026-10-11, the market facet and multi-protocol adapter were deployed in
  [transaction `0x6a214fcf…1452`](https://etherscan.io/tx/0x6a214fcfd95a3c0c8a204bd922b38c80e8ad04811e97c24ac058f1b78e901452)
  at block **26,167,957** and
  [transaction `0xba6b9a27…fa7e`](https://etherscan.io/tx/0xba6b9a271efad486961d448291c4c9e2ab5aed6bec5e0bd0f378a471e03bfa7e)
  at block **26,167,960**. Both are verified on Etherscan and exact-match
  verified on Sourcify. The additive zero-initializer cut in
  [transaction `0x3f68266c…e06d`](https://etherscan.io/tx/0x3f68266c2646fe562d2fec588e34bf3a8ed3f495c4bc621aab2926c7cc5ce06d)
  at block **26,168,057** installed the two market selectors; separate
  [transaction `0x513c391a…8e3c`](https://etherscan.io/tx/0x513c391a5f50514eefecaa1253e37421c6731e811992a45edf7aa26d824a8e3c)
  at block **26,168,059** approved the new adapter. It uses the existing
  Universal Router 2.2.0 at `0xab863e752bf67d8dcdd929eaae9be9dc83fb3bbb`.
  That historical cut preserved the 54 prior selectors and approvals.
- On 2026-10-21, nine implementation creations mined in blocks
  **26,236,822–26,236,835**. All nine passed receipt-bound runtime checks,
  Etherscan verification and Sourcify exact verification. The activation cut
  [`0x159e6491…bbe1`](https://etherscan.io/tx/0x159e6491dc1e6d3d93a9374447c476f107eacba1b60a3eeb52a21f848583bbe1) at block **26,238,124**
  installed `TradeExactInFacet`; approval
  [`0x976f6466…0cd6`](https://etherscan.io/tx/0x976f64663507303f026746ef6de4485d5c230128172f1eac1629d0591ae50cd6) at block **26,238,129**
  admitted its immutable successor `UniswapRoutingAdapter`.
- Consumer acceptance completed before retirement. The independent Sandbox
  run `61cb514f-7b83-4925-9ef3-594311433096` confirmed all 24 winner-case
  `executeExactInput` trades plus a separate bootstrap. All 48 winner/alternate
  role resets are recorded; alternate roles did not execute (18 lacked a quote
  observation and six were unsupported). Public reads on 2026-10-21 confirmed
  Mainnet App
  `531ade85185f30b4092648c03eacd9d0b403c187` and Backend
  `0b01e46598395e2aa971a461f4d50fd920f98774`; serving adoption is not a Mainnet
  trade claim.

- On 2026-10-22, retirement cut [`0xfa85a5fc…7f07`](https://etherscan.io/tx/0xfa85a5fcaa08c0306d3e87e637ee7bd2187a52ec9d39e61a52ad6af0464f7f07) at block **26,246,738**
  removed all 12 legacy exact-input execution selectors and replaced five
  retained facets, producing 45 selectors across 13 facets. Revocations
  [`0x036c509e…0231`](https://etherscan.io/tx/0x036c509e782c846faa265be03b2b69ce3266cf18d8f46c62579765c122bc0231) at block **26,250,943** and
  [`0x71dd8476…53e2`](https://etherscan.io/tx/0x71dd8476c9eb5e2bc2f54f4fe3ea4108cb8b600f24bbd3b11b3ef315450953e2) at block **26,250,946**
  removed both legacy Uniswap approvals. Canonical receipt-bound postflight
  at block **26,250,946** (`0xec86b3bfcb2f27fb67677e743ccb1223d335ebf86ad935875a25ad69b152a9fb`)
  confirmed the final inventory, retained successor and OneInch approvals,
  and preserved Core, Permit2, WETH, fees, pause and Safe configuration.
- Authority and identity: Helpers is owned by the new 2-of-3 Safe
  [`0xfe203ffc4d734e32f24529496c4e647bb163d4b3`](https://etherscan.io/address/0xfe203ffc4d734e32f24529496c4e647bb163d4b3).
  The active primary ENS names are `helpers.cybergold.eth` for Helpers and
  `multisig.cybergold.eth` for the Safe.
- Versioning: `facetGeneration(FACET_NAMESPACE)` is the diamond-local installed
  generation. Token issuance and basket issuance are at generation `3`;
  coordinator, redemption, basket redemption and Market are at `2`. The other
  seven installed namespaces, including universal exact input, are at `1`.
  The historical temporary initializer namespace remains cleared to `0`.
  Deployment-record release `v0.1.0` identifies this nine-contract release;
  tags do not replace the compiled-source identities below.
- Token compatibility: transfer-taxed, deflationary, and rebasing ERC-20
  acquisition or payout semantics are unsupported because Helpers requires
  exact measured debits and credits.
- Audit: the final source and Phase 1 deployment-machinery audits are complete;
  the combined Core/Helpers postflight passed while Core remained paused.
- Core protected-account callbacks: Helpers is deliberately a code-bearing
  non-advertiser for all four operation-specific callback interfaces. Current
  Core therefore preserves ordinary Helpers payouts, CYGLD redemption burns,
  and nested recovery-share forwarding after its bounded 30,000-gas ERC-165
  probe. Core applies no pre-probe gas threshold; only canonical `true` opts an
  account in, and every other result is unsupported.
- Adapter reliance: the initial release does not claim on-chain semantic
  verification of opaque 1inch payload intent. App checks remain defense in
  depth, and semantic binding is explicitly deferred future work.

### Ethereum Mainnet Helpers deployment

The current 45-selector facet inventory below was confirmed by the completed
retirement postflight at block **26,250,946** and its approved complete
source/runtime comparison. Six facet rows belong to
this universal-exact-input release: one activation and five retirement
replacements. The shell and seven unchanged facet rows retain their accepted
identities and original compiled-source links. Complete runtime hashes include
metadata and resolved immutables.

The nine creation receipts and both activation receipts remain separate from
retirement. No creation is repeated, and the same accepted source/license
provider records are reused. Etherscan and Sourcify links below identify the
verified deployed sources.

#### Shell

Only the current shell is listed here. The retired deployment and its
coordinator migration remain historical Ops receipts.

| Contract | Address | Role | Verified source |
| --- | --- | --- | --- |
| HelpersDiamond | [`0x30e9afd21a30b2629be33508a131ac890368f534`](https://etherscan.io/address/0x30e9afd21a30b2629be33508a131ac890368f534) | Diamond shell and live entry point; `helpers.cybergold.eth` | `3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592` · [Etherscan](https://etherscan.io/address/0x30e9afd21a30b2629be33508a131ac890368f534#code) · [Sourcify](https://repo.sourcify.dev/1/0x30e9afd21a30b2629be33508a131ac890368f534) |

#### Facets

These are the 13 currently installed facets. The universal selector was
installed before consumer cutover; the five retained implementations were
replaced only after acceptance. All six exact-input previews, four exact-output
views and seven true exact-output executors remain installed. The bootstrap
facet, linked libraries and deployment-only initializers are not installed
facets. `Installed generation` is `facetGeneration(FACET_NAMESPACE)`;
`Deployed bytecode` gives the complete runtime's keccak256 and byte length.

| Facet | Address | Installed generation | Deployed bytecode (`keccak256` / bytes) | Original source / verified source |
| --- | --- | ---: | --- | --- |
| TradeExactInFacet | [`0x763c7e752949bbad2a6a55e052146ab23b7236fc`](https://etherscan.io/address/0x763c7e752949bbad2a6a55e052146ab23b7236fc) | 1 | `0xe11b68c98a6336c565d19450d6f91ff182271ebf5e540feb1e133787b44c0c0c` / 23,946 | `9ed3a0e74588ec05f02e5189d2db9542a248a1de` · [Etherscan](https://etherscan.io/address/0x763c7e752949bbad2a6a55e052146ab23b7236fc#code) · [Sourcify](https://repo.sourcify.dev/1/0x763c7e752949bbad2a6a55e052146ab23b7236fc) |
| MarketSwapFacet | [`0xda957edd7456d5d16825a38a871f9e0296254f23`](https://etherscan.io/address/0xda957edd7456d5d16825a38a871f9e0296254f23) | 2 | `0x5437364997d89354ef3801b8adbaeaf46b69bef4d01184adb0a74983a5c3964f` / 8,109 | `9ed3a0e74588ec05f02e5189d2db9542a248a1de` · [Etherscan](https://etherscan.io/address/0xda957edd7456d5d16825a38a871f9e0296254f23#code) · [Sourcify](https://repo.sourcify.dev/1/0xda957edd7456d5d16825a38a871f9e0296254f23) |
| DiamondCutOwnerLiveFacet | [`0xcf2e33993e16bb8d85f5403603241c0d10406646`](https://etherscan.io/address/0xcf2e33993e16bb8d85f5403603241c0d10406646) | 2 | `0x3b67b3f8385b8d0fb0ea8961b3c3835ff5b3ac2c051ce40ddd471e79c7aa61a9` / 14,375 | `b4c70410dfb2a0478a76d4d68b9687c37c043f0e` · [Etherscan](https://etherscan.io/address/0xcf2e33993e16bb8d85f5403603241c0d10406646#code) · [Sourcify](https://repo.sourcify.dev/1/0xcf2e33993e16bb8d85f5403603241c0d10406646) |
| ProtocolDiamondLoupeFacet | [`0xd5a1df09ae83dbbc0e153436adb58a56664d90cd`](https://etherscan.io/address/0xd5a1df09ae83dbbc0e153436adb58a56664d90cd) | 1 | `0xe9b0ce08830ff69f5af02ca9c1c26f921c1c98f2987488e074cc879a06c97011` / 2,837 | `9e2d88becb587c259116443d4f0c46e65694825f` · [Etherscan](https://etherscan.io/address/0xd5a1df09ae83dbbc0e153436adb58a56664d90cd#code) · [Sourcify](https://repo.sourcify.dev/1/0xd5a1df09ae83dbbc0e153436adb58a56664d90cd) |
| OwnershipFacet | [`0xb732462bbf4854cf0ef282fd3717bf72a7b472c3`](https://etherscan.io/address/0xb732462bbf4854cf0ef282fd3717bf72a7b472c3) | 1 | `0xc419736b94e8b654c0c4174bd8b81061712831bff7ca05a970860eba10764d05` / 1,139 | `3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592` · [Etherscan](https://etherscan.io/address/0xb732462bbf4854cf0ef282fd3717bf72a7b472c3#code) · [Sourcify](https://repo.sourcify.dev/1/0xb732462bbf4854cf0ef282fd3717bf72a7b472c3) |
| OwnerPausableFacet | [`0x73c3ba0ab596abce64e2074011086e2adc9975f5`](https://etherscan.io/address/0x73c3ba0ab596abce64e2074011086e2adc9975f5) | 1 | `0xea36b4f4c6383e87a8d0b2974eb6e7dabad89e7388b542a4d557f0155d85d419` / 739 | `3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592` · [Etherscan](https://etherscan.io/address/0x73c3ba0ab596abce64e2074011086e2adc9975f5#code) · [Sourcify](https://repo.sourcify.dev/1/0x73c3ba0ab596abce64e2074011086e2adc9975f5) |
| RouterAdminFacet | [`0x5cba6d9a9bffc35a2e49c7406e90bf64479ad8d4`](https://etherscan.io/address/0x5cba6d9a9bffc35a2e49c7406e90bf64479ad8d4) | 1 | `0x6c7eab3bf656735f4393ceb262da2fdc3bd8849806a53c6a6131fec681b8361b` / 3,283 | `3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592` · [Etherscan](https://etherscan.io/address/0x5cba6d9a9bffc35a2e49c7406e90bf64479ad8d4#code) · [Sourcify](https://repo.sourcify.dev/1/0x5cba6d9a9bffc35a2e49c7406e90bf64479ad8d4) |
| RouterIssuePreviewFacet | [`0xcde21a9ca1c447e8689e975fd444dae15c3e85bd`](https://etherscan.io/address/0xcde21a9ca1c447e8689e975fd444dae15c3e85bd) | 1 | `0x2020e808e81a10a453f5cb830faf16b1449d4296cf72c215598442e9e9eca86b` / 6,106 | `3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592` · [Etherscan](https://etherscan.io/address/0xcde21a9ca1c447e8689e975fd444dae15c3e85bd#code) · [Sourcify](https://repo.sourcify.dev/1/0xcde21a9ca1c447e8689e975fd444dae15c3e85bd) |
| RouterIssueFacet | [`0x5927dea92742aa502f7904d8b51de164af890317`](https://etherscan.io/address/0x5927dea92742aa502f7904d8b51de164af890317) | 3 | `0xe540fa9029075db42c1d5e2caf75fe45e3ac786b6af548f80624ee220e33736f` / 14,259 | `9ed3a0e74588ec05f02e5189d2db9542a248a1de` · [Etherscan](https://etherscan.io/address/0x5927dea92742aa502f7904d8b51de164af890317#code) · [Sourcify](https://repo.sourcify.dev/1/0x5927dea92742aa502f7904d8b51de164af890317) |
| RouterIssueBasketFacet | [`0x1424b149939588cc604ca2a2adc589244adc284d`](https://etherscan.io/address/0x1424b149939588cc604ca2a2adc589244adc284d) | 3 | `0xbe7d5e2220fa96c9465a2fb522c3da6fa1acb3d2b042ce9069a096d14bd0017e` / 12,973 | `9ed3a0e74588ec05f02e5189d2db9542a248a1de` · [Etherscan](https://etherscan.io/address/0x1424b149939588cc604ca2a2adc589244adc284d#code) · [Sourcify](https://repo.sourcify.dev/1/0x1424b149939588cc604ca2a2adc589244adc284d) |
| RouterRedeemFacet | [`0xb16ab04bf9f712553708b1885c4f48d328a29163`](https://etherscan.io/address/0xb16ab04bf9f712553708b1885c4f48d328a29163) | 2 | `0x446cba7919a3aa26023bcbb1d4dcb099bc41623445528f44cce907818a96a3b8` / 3,306 | `9ed3a0e74588ec05f02e5189d2db9542a248a1de` · [Etherscan](https://etherscan.io/address/0xb16ab04bf9f712553708b1885c4f48d328a29163#code) · [Sourcify](https://repo.sourcify.dev/1/0xb16ab04bf9f712553708b1885c4f48d328a29163) |
| RouterRedeemBasketFacet | [`0x64840e05c91ae2581891636435cb783019b05676`](https://etherscan.io/address/0x64840e05c91ae2581891636435cb783019b05676) | 2 | `0xc0789571611d7bcada11109c5a5f31f435264af366a036829c38ada30195b3c5` / 3,812 | `9ed3a0e74588ec05f02e5189d2db9542a248a1de` · [Etherscan](https://etherscan.io/address/0x64840e05c91ae2581891636435cb783019b05676#code) · [Sourcify](https://repo.sourcify.dev/1/0x64840e05c91ae2581891636435cb783019b05676) |
| RecoveryShareReceiverFacet | [`0x89b04f15e8c0ca0805828af3ce2bb8770bcec39c`](https://etherscan.io/address/0x89b04f15e8c0ca0805828af3ce2bb8770bcec39c) | 1 | `0x5b7249585e7de1cb4a5a6f69fa983f2530b6696a9a7eb2ebf1efdf560a150cc1` / 3,194 | `3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592` · [Etherscan](https://etherscan.io/address/0x89b04f15e8c0ca0805828af3ce2bb8770bcec39c#code) · [Sourcify](https://repo.sourcify.dev/1/0x89b04f15e8c0ca0805828af3ce2bb8770bcec39c) |

#### Adapters

Adapters are separate deployed contracts, not facets. The successor and
OneInch approvals are retained. Legacy contracts remain deployed and verified;
revoking their Helpers approval does not delete their code or repoint captured
payloads. Approval-list order does not select an encoding or a default adapter.

| Adapter | Address | Helpers approval | Verified source |
| --- | --- | --- | --- |
| OneInchAdapter | [`0xe8e87763768125ba02dd30d932b86bbdd1af082c`](https://etherscan.io/address/0xe8e87763768125ba02dd30d932b86bbdd1af082c) | approved | `3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592` · [Etherscan](https://etherscan.io/address/0xe8e87763768125ba02dd30d932b86bbdd1af082c#code) · [Sourcify](https://repo.sourcify.dev/1/0xe8e87763768125ba02dd30d932b86bbdd1af082c) |
| UniswapRoutingAdapter | [`0x1b5905175d6a64aba6c170a1cd52e5dd555c35a8`](https://etherscan.io/address/0x1b5905175d6a64aba6c170a1cd52e5dd555c35a8) | approved successor | `9ed3a0e74588ec05f02e5189d2db9542a248a1de` · [Etherscan](https://etherscan.io/address/0x1b5905175d6a64aba6c170a1cd52e5dd555c35a8#code) · [Sourcify](https://repo.sourcify.dev/1/0x1b5905175d6a64aba6c170a1cd52e5dd555c35a8) |
| UniswapUniversalAdapter | [`0x4edb8190232a47e45d861003672938eb7ee84a15`](https://etherscan.io/address/0x4edb8190232a47e45d861003672938eb7ee84a15) | revoked | `3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592` · [Etherscan](https://etherscan.io/address/0x4edb8190232a47e45d861003672938eb7ee84a15#code) · [Sourcify](https://repo.sourcify.dev/1/0x4edb8190232a47e45d861003672938eb7ee84a15) |
| UniswapMultiProtocolAdapter | [`0xc2c210979674db1349f812ea116f2f6d131ab839`](https://etherscan.io/address/0xc2c210979674db1349f812ea116f2f6d131ab839) | revoked | `96c2437ba416f1ddc92de855d5b788b7cb578374` · [Etherscan](https://etherscan.io/address/0xc2c210979674db1349f812ea116f2f6d131ab839#code) · [Sourcify](https://repo.sourcify.dev/1/0xc2c210979674db1349f812ea116f2f6d131ab839) |

The successor's complete runtime hash is `0xf60586463c4c171e5ed4028be1b4aafe02ee86ac8b0531a5b97c2025b6252df4`
(13,465 bytes). Its immutable Helpers and Permit2 bindings
are unchanged by retirement.

#### Nine implementation creations

All nine contracts below were created on 2026-10-21 from Helpers
`9ed3a0e74588ec05f02e5189d2db9542a248a1de`. Six are installed facets, one is
an approved adapter and two are externally linked libraries. Libraries are
implementation dependencies and own no diamond selectors.

| Contract | Role | Creation receipt / block |
| --- | --- | --- |
| CoreIssueExecution [`0x8428202335320ccc09f50c18c9da0c66ed791628`](https://etherscan.io/address/0x8428202335320ccc09f50c18c9da0c66ed791628) | linked library | [`0x615a3ab1…343c`](https://etherscan.io/tx/0x615a3ab1aa88925e559ba07979ae2cd805619974a53d2c855a3df80f9770343c) / 26,236,822 |
| TradeRouteEncoding [`0x622d9776fc6b38eaecf63d123ad5dccb9f6f2214`](https://etherscan.io/address/0x622d9776fc6b38eaecf63d123ad5dccb9f6f2214) | linked library | [`0x381b5194…e2b7`](https://etherscan.io/tx/0x381b519418420752585a6cab4e6b51d9597e4e59cd62d1d639a9be606c61e2b7) / 26,236,826 |
| UniswapRoutingAdapter [`0x1b5905175d6a64aba6c170a1cd52e5dd555c35a8`](https://etherscan.io/address/0x1b5905175d6a64aba6c170a1cd52e5dd555c35a8) | adapter | [`0x813f98a0…a882`](https://etherscan.io/tx/0x813f98a09b963fcad251d0fa3fbe564b6dd359930e918af226c7e413a044a882) / 26,236,828 |
| TradeExactInFacet [`0x763c7e752949bbad2a6a55e052146ab23b7236fc`](https://etherscan.io/address/0x763c7e752949bbad2a6a55e052146ab23b7236fc) | facet | [`0xd50c6511…2f1d`](https://etherscan.io/tx/0xd50c6511382ede9582819426c774e69f94fb4f4f637d99dcd47b5e4e99422f1d) / 26,236,830 |
| RouterIssueFacet [`0x5927dea92742aa502f7904d8b51de164af890317`](https://etherscan.io/address/0x5927dea92742aa502f7904d8b51de164af890317) | facet | [`0x516d14c3…a3cb`](https://etherscan.io/tx/0x516d14c3c1b8152a28ac2118841d3cfb7c53db29e094f1ea4e4e9c6e8ee3a3cb) / 26,236,831 |
| RouterIssueBasketFacet [`0x1424b149939588cc604ca2a2adc589244adc284d`](https://etherscan.io/address/0x1424b149939588cc604ca2a2adc589244adc284d) | facet | [`0x5c03e7d1…a501`](https://etherscan.io/tx/0x5c03e7d1f1ce9b73ec25a966495a87e2bbad2d68b86ca4fab44351c06890a501) / 26,236,832 |
| RouterRedeemFacet [`0xb16ab04bf9f712553708b1885c4f48d328a29163`](https://etherscan.io/address/0xb16ab04bf9f712553708b1885c4f48d328a29163) | facet | [`0xc293513c…0ee3`](https://etherscan.io/tx/0xc293513c20fb11b89fe3006870c19fbdf756baaf9316287015fc1132d27b0ee3) / 26,236,833 |
| RouterRedeemBasketFacet [`0x64840e05c91ae2581891636435cb783019b05676`](https://etherscan.io/address/0x64840e05c91ae2581891636435cb783019b05676) | facet | [`0x981dab62…f818`](https://etherscan.io/tx/0x981dab62e3ddd164e37e39e8407909eb5f03beac7babd344d76b01685cf9f818) / 26,236,834 |
| MarketSwapFacet [`0xda957edd7456d5d16825a38a871f9e0296254f23`](https://etherscan.io/address/0xda957edd7456d5d16825a38a871f9e0296254f23) | facet | [`0x0bb0b718…7042`](https://etherscan.io/tx/0x0bb0b718c605df14181269514e48274377a201d715c324028815957e94d37042) / 26,236,835 |

- `CoreIssueExecution` runtime: `0xd308ca3d353e71fe54eb7067f898f1618bdf4dcdf9cf21db5f00c1e6a3b9950a` / 2,368 bytes.
- `TradeRouteEncoding` runtime: `0x384061ae95741c66628ad1dd64a51574c96d1f4e3e65ae78ea380514bd2ffbba` / 1,557 bytes.

The initial replacement publication inventory also includes the bootstrap facet, `DiamondLiveInit`
and `HelpersEnsPrimaryNameInit`. Fifteen targets use AGPLv3 / Etherscan type
`13`; the external bootstrap facet and the owner-exempted
`ProtocolDiamondLoupeFacet` retain MIT / type `3`. The loupe remains MIT for
future builds as well.

The former Helpers `0x601d51e5883547237e030a3688c8a98bf1f6601d` is retired
and paused. The former Safe `0x601dbc67eab2822a3c44bdb6bbab4147ad1f601d`
is retired from active project authority and ENS identity. Do not select either
for new operations. Core remains at its unchanged address
`0x601da021caf3db5aa63e700d239b5935c370601d`; no user-fund migration or key
destruction is part of retirement. Security reports go to
`security@cybergold.io`.

Release phases are defined in the Ops [release-phase
authority](../cybergold-ops/docs/architecture/release-phases.md), and
cross-repository reviews apply the Ops [trusted-but-fallible operator security
model](../cybergold-ops/docs/security/security-model.md). Operator trust does
not extend to callers, swap payloads, routers, tokens, or public chain state.

## Retained route model

`executeExactInput(ExactInputPlan, FundingBundle)` is the single payable
exact-input executor. Its four intents are `BuyCygld`, `SellCygld`,
`IssueBasket` and `RedeemBasket`. Scalar plans may compose ordered Core and
Market branches and split V2/V3/V4 paths. Native input is the exact declared
`msg.value`; native output and native V4 currencies use `address(0)`, while
WETH remains a separate ERC-20.

Original ERC-20 funding uses a declared exact allowance, native ERC-2612 permit
or compact Permit2 batch; an already sufficient allowance remains usable.
Measured unused AMM input is disclosed protocol retention in its physical
currency at Helpers and cannot fund later branches. Successful Core issuance
residuals follow the declared Market continuation. Favorable recipient output
is paid out; Core fees, Helpers fees, Market fees and retained input are reported
separately in `TradeResult` and `ExactInputExecuted`.

The seven true exact-output executors preserve their existing ABI and refund
economics: token/native routed issuance, complete-basket issuance and
homogeneous ERC-20 Market exact output. All six exact-input previews and four
exact-output views remain; a retained preview does not keep its former legacy
execution selector installed. Captured legacy payloads must be refreshed through
ordinary quotation rather than relabeled with the new encoding or economics.

Helpers exact-output issuance uses final-recipient exact-net semantics:

```text
recipient net + Helpers fee = Core net
Core net + protocol fee      = realized protocol gross
```

Issuance snapshots Core's ordered input vector once before acquisition or
adapter execution and passes it as the maxima to `safeIssue`. Direct-basket
issuance additionally binds that order to the Permit2 batch. Redemption passes
the caller's complete ordered `TokenMinimum[]` unchanged to `safeRedeem`.
Core's mixed `TokenAmount[]` result is the common healthy/impaired settlement
model: ERC-20 legs are aggregated and positive ERC-1155 legs are forwarded.
With Core's immediate-recovery model, each ERC-1155 quantity uses the underlying
asset's native raw units and retained decimals, not CYGLD units. Helpers forwards
those IDs and quantities unchanged: it neither rescales them nor converts them
to ERC-20 during CYGLD redemption. A later recovery-share burn is a separate Core
operation, using Core's current capped payout quote.
There is no Helpers mode, recovery epoch, configuration hash, or historical
recovery identity.

The Helpers fee recipient is always the current Helpers owner. The retained
true exact-output executors refund their unused operation-local input to the
payer. Universal exact input instead discloses measured retained input as its
protocol charge. Pre-operation balance baselines prevent one caller from
receiving an older balance.

See the [execution API](docs/reference/execution-api.md) and [ABI usage
matrix](docs/abi-usage-matrix.md) for exact signatures and tuple meanings.

## Adapters and deployment

The original launch admitted 1inch and the previous Uniswap adapter. The
current approval set is listed above. Adapters protect pre-operation balances
and bind recovery authority to Helpers. The successor supports declared ERC-20
and native exact input; retained homogeneous ERC-20 exact output preserves its
existing refund semantics. Its Permit2 identity matches the routed facets.
The owner may admit or remove adapters under the honest-governance model;
there is no permanent two-adapter cardinality restriction. A mistaken approved
adapter can make routes selecting it revert until the owner removes it, an
accepted post-launch liveness residual.

The 1inch adapter does not decode or semantically bind its opaque Aggregation
Router payload. Its balance-delta, allowance, and minimum-output checks protect
outer accounting, not caller intent. App-side payload checks are defense in
depth only. `ZeroExAdapter` remains frozen dormant source: it is not deployed,
approved, included in release manifests, fork-qualified, or claimed as
launch-supported. CI rejects any source change or active-surface re-entry until
an explicit requalification.

Deployment is intentionally ordered:

1. deploy or locate the deterministic Helpers shell;
2. preflight the selected chain and require live code at Core, Permit2, WETH,
   1inch, and Uniswap; sealed releases additionally bind every target to the
   approved runtime/proxy identity manifest;
3. deploy adapters bound to that shell; and
4. finalize the shell with production facets, immutable dependencies, initial
   adapter approvals, and final ownership.

Mainnet requires `HELPERS_IDENTITY_POLICY=strict-proxy-codehash-v1`,
`EXPECTED_CHAIN_ID`, `RELEASE_MANIFEST_ID`, `RELEASE_MANIFEST_SHA256`, and an
`EXPECTED_<LABEL>_KIND`/`EXPECTED_<LABEL>_CODEHASH` pair for each dependency.
An `eip1967-proxy` entry also requires its expected implementation address and
code hash. Local rehearsals may use the explicit `local-unsealed` policy.

All build, analysis, ABI, gas, size, and storage evidence consumes Solidity
0.8.37, EVM `osaka`, optimizer enabled, and 100 optimizer runs from the single
`foundry.toml` authority.

## Quick start

Requirements: Foundry 1.7.1, Solidity 0.8.37 targeting EVM `osaka`, and the
exact Protocol submodule pin.

```bash
git submodule update --init --recursive
forge build
./script/test.sh
```

For authenticated HTTPS, configure `MAINNET_RPC_URL` and the separate
`MAINNET_RPC_BEARER` in protected local configuration or CI secrets. The
pinned Protocol helper keeps the bearer in a local adapter and gives Forge,
identity probes and snapshot Anvil a credential-free URL for their full
lifetime. URL-only endpoints remain supported. Do not put a bearer in a URL,
repository variable, shell argument or retained log.

Fork suites run only when `MAINNET_RPC_URL` is set. Without it, the gate emits
an unmistakable local/GitHub warning that the fork tests were not run and the
result is not a pass. Production/release evidence is a distinct fail-closed
path: manually dispatch `Helpers release fork evidence` for the exact approved
commit. `pinned-history` remains the default and requires the protected archive
RPC to identify Ethereum mainnet and serve block `25609006`; the exact block
hash is checked before and after the suites. When that archive state is
unavailable, the operator may explicitly select `live-latest-snapshot`: the gate starts a
private loopback Anvil fork without a historical block request, resolves its
head once, records the exact block number and hash, and pins all four suites /
nine tests to that local snapshot, then verifies the same identity again.
A failed historical run never falls back automatically. Both modes require
the same clean exact checkout before and after execution, reject any unexpected
fork suite, and retain a credential-fragment-sanitized,
commit/mode/block-bound artifact; only complete passing evidence is accepted.
Local release evidence uses the credential-safe Ops authenticated RPC wrapper;
release checkouts must never use `git submodule update --remote`.

See the [Helpers documentation index](docs/README.md) for architecture,
execution ABI, testing, decisions, and incident evidence. Integrated fork and
mainnet orchestration belongs to Ops.

## Branch workflow

Create `feature/<slug>` from CyberGold's `dev`, in your fork or, with Write
access, in this repository. Propose it through a PR targeting `dev`. The owner
and `core-team` can merge accepted changes after existing CI passes. Only the
owner can merge a promotion from this repository's exact `dev` into `main`.
Use GitHub merge commits for both stages; direct protected-branch updates,
feature-to-`main` PRs, and squash/rebase merges are outside the selected flow.
Source merges build and test contracts; qualification and on-chain release are
separate operations. See [the branch workflow](docs/development/branch-workflow.md).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for public fork setup, local validation
and the feature-to-`dev` contribution path. The project license is
**AGPL-3.0-only**; [LICENCE](LICENCE) contains the full text.
[Licensing scope](LICENSING.md) preserves existing MIT and other third-party
notices and explains corresponding-source obligations.

## Dependency security

The [dependency security policy](DEPENDENCY_SECURITY.md) blocks new unaccepted
vulnerabilities relative to the PR target. Existing findings may remain or be
resolved and stay visible for manual review. Production, development and
transitive inventories are compared; remediation follows CyberGold-maintained
parents. Daily full scans report the backlog without requiring it to be empty.
