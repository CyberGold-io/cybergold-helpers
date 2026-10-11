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
- trade existing ERC-20 tokens through approved Uniswap V2/V3/V4 routes, with
  exact-input or homogeneous exact-output swaps and native-permit funding.

There is no rebalance or recovery-named wrapper route in the launch surface.
Healthy and impaired settlement share the same generic mixed-output model.

## Status

- Development: active. The installed owner coordinator and token-issuance facet
  were compiled from
  [`b4c70410dfb2a0478a76d4d68b9687c37c043f0e`](https://github.com/CyberGold-io/cybergold-helpers/tree/b4c70410dfb2a0478a76d4d68b9687c37c043f0e).
  The basket-issuance facet was compiled from
  [`26e2ff281d0ce653968711614554c5ea152b6c79`](https://github.com/CyberGold-io/cybergold-helpers/tree/26e2ff281d0ce653968711614554c5ea152b6c79).
  These builds use Protocol dependency
  [`ae8479d5885164c70cc7ff3afc37514d3c74b5ff`](https://github.com/CyberGold-io/cybergold-protocol/tree/ae8479d5885164c70cc7ff3afc37514d3c74b5ff)
  and Solidity `0.8.37`. The retained shell, adapters and other facets keep
  their exact launch-source links below. Later documentation commits and
  release tags do not change these compiled-source identities.
- Source-only recovery compatibility update:
  [`4de31c5d849837c568b1f713e89a4ebaaee5e827`](https://github.com/CyberGold-io/cybergold-helpers/tree/4de31c5d849837c568b1f713e89a4ebaaee5e827)
  pins Protocol
  [`b84209ed5d398e01b6b622fd0fe1a8233a955a98`](https://github.com/CyberGold-io/cybergold-protocol/tree/b84209ed5d398e01b6b622fd0fe1a8233a955a98)
  and extends compatibility tests. It does **not** identify a new Helpers
  deployment: the Helpers `src/` tree is unchanged from `3cfe2b9`.
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
  All 54 historical selectors and previous adapter approvals are preserved.
  Backend/App rollout and installed wallet/performance acceptance remain pending.
- Authority and identity: Helpers is owned by the new 2-of-3 Safe
  [`0xfe203ffc4d734e32f24529496c4e647bb163d4b3`](https://etherscan.io/address/0xfe203ffc4d734e32f24529496c4e647bb163d4b3).
  The active primary ENS names are `helpers.cybergold.eth` for Helpers and
  `multisig.cybergold.eth` for the Safe.
- Versioning: `facetGeneration(FACET_NAMESPACE)` is the diamond-local installed
  generation. The owner coordinator, token-issuance and basket-issuance
  namespaces are at generation `2`; the other eight installed namespaces
  and the new market namespace remain at generation `1`. The temporary
  optional-initializer migration namespace is cleared to `0`.
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

The contracts below are the current replacement inventory. Their complete
runtime bytes and installed topology were validated by the canonical Helpers
postflight at block **25,986,545**; source publication subsequently authenticated
finalized Mainnet creation identities. Source links identify the actual
compiled commits, not the latest repository branch.
The Core upgrade's receipt-bound postflight at block **26,030,290** confirmed
this Helpers inventory was unchanged. The 2026-10-10 coordinator migration at
block **26,162,093** and issuance cut at block **26,162,105**
replaced only the coordinator and token-issuance implementations. Receipt-bound
postflight confirmed 11 installed namespaces and 52 selectors, coordinator and issuance
generations `2`, and no installed temporary migration selector. The later
mixed-permit basket cut at block **26,164,272** replaced only the basket facet
and added its two mixed-permit selectors. Its receipt-bound postflight confirmed
11 installed namespaces and 54 selectors, basket generation `2`, and unchanged
coordinator, token-issuance and other installed generations.
The 2026-10-11 market cut and approval postflight at block **26,168,059**
confirmed 12 installed namespaces and 56 selectors, market generation `1`,
unchanged historical selector owners/generations and three approved adapters.
The new contracts were compiled from published main
[`96c2437`](https://github.com/CyberGold-io/cybergold-helpers/tree/96c2437ba416f1ddc92de855d5b788b7cb578374).

#### Shell

Only the current shell is listed here. The retired deployment and its
coordinator migration remain historical Ops receipts.

| Contract | Address | Role | Verified source |
| --- | --- | --- | --- |
| HelpersDiamond | [`0x30e9afd21a30b2629be33508a131ac890368f534`](https://etherscan.io/address/0x30e9afd21a30b2629be33508a131ac890368f534) | Diamond shell and live entry point; `helpers.cybergold.eth` | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/diamond/HelpersDiamond.sol) · [Etherscan](https://etherscan.io/address/0x30e9afd21a30b2629be33508a131ac890368f534#code) · [Sourcify](https://repo.sourcify.dev/1/0x30e9afd21a30b2629be33508a131ac890368f534) |

#### Facets

These are the 12 currently installed facets. The replacement
[finalization transaction](https://etherscan.io/tx/0xb7ebb9057426d752ca8054e1889b9461a6c1e2d2623eb372ceca6eb1d5b81553)
installed the original set; the 2026-10-10 cuts replaced only the owner
coordinator, token-issuance and basket-issuance implementations. The 2026-10-11
market cut added its two selectors without replacing a historical facet.
The bootstrap facet and deployment-only initializers are not installed facets.
`Installed generation` is the postflight-validated
`facetGeneration(FACET_NAMESPACE)` value. `Deployed bytecode` is the
`keccak256` and byte length of the complete runtime, including metadata.

| Facet | Address | Installed generation | Deployed bytecode (`keccak256` / bytes) | Source / explorer |
| --- | --- | ---: | --- | --- |
| MarketSwapFacet | [`0x56a7ce70982f1893669c6d1c87e633185d096771`](https://etherscan.io/address/0x56a7ce70982f1893669c6d1c87e633185d096771) | 1 | `0x7de93c0745701cceb106dd87573ad689e5461fa3fac7cf5d079617b89a25a163` / 8,375 | [`96c2437`](https://github.com/CyberGold-io/cybergold-helpers/blob/96c2437ba416f1ddc92de855d5b788b7cb578374/src/facets/MarketSwapFacet.sol) · [Etherscan](https://etherscan.io/address/0x56a7ce70982f1893669c6d1c87e633185d096771#code) · [Sourcify](https://repo.sourcify.dev/1/0x56a7ce70982f1893669c6d1c87e633185d096771) |
| DiamondCutOwnerLiveFacet | [`0xcf2e33993e16bb8d85f5403603241c0d10406646`](https://etherscan.io/address/0xcf2e33993e16bb8d85f5403603241c0d10406646) | 2 | `0x3b67b3f8385b8d0fb0ea8961b3c3835ff5b3ac2c051ce40ddd471e79c7aa61a9` / 14,375 | [`b4c7041`](https://github.com/CyberGold-io/cybergold-helpers/blob/b4c70410dfb2a0478a76d4d68b9687c37c043f0e/src/facets/DiamondCutOwnerLiveFacet.sol) · [Etherscan](https://etherscan.io/address/0xcf2e33993e16bb8d85f5403603241c0d10406646#code) · [Sourcify](https://repo.sourcify.dev/1/0xcf2e33993e16bb8d85f5403603241c0d10406646) |
| ProtocolDiamondLoupeFacet | [`0xd5a1df09ae83dbbc0e153436adb58a56664d90cd`](https://etherscan.io/address/0xd5a1df09ae83dbbc0e153436adb58a56664d90cd) | 1 | `0xe9b0ce08830ff69f5af02ca9c1c26f921c1c98f2987488e074cc879a06c97011` / 2,837 | [`9e2d88b`](https://github.com/CyberGold-io/cybergold-protocol/blob/9e2d88becb587c259116443d4f0c46e65694825f/packages/0_shared/src/facets/ProtocolDiamondLoupeFacet.sol) · [Etherscan](https://etherscan.io/address/0xd5a1df09ae83dbbc0e153436adb58a56664d90cd#code) · [Sourcify](https://repo.sourcify.dev/1/0xd5a1df09ae83dbbc0e153436adb58a56664d90cd) |
| OwnershipFacet | [`0xb732462bbf4854cf0ef282fd3717bf72a7b472c3`](https://etherscan.io/address/0xb732462bbf4854cf0ef282fd3717bf72a7b472c3) | 1 | `0xc419736b94e8b654c0c4174bd8b81061712831bff7ca05a970860eba10764d05` / 1,139 | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/facets/OwnershipFacet.sol) · [Etherscan](https://etherscan.io/address/0xb732462bbf4854cf0ef282fd3717bf72a7b472c3#code) · [Sourcify](https://repo.sourcify.dev/1/0xb732462bbf4854cf0ef282fd3717bf72a7b472c3) |
| OwnerPausableFacet | [`0x73c3ba0ab596abce64e2074011086e2adc9975f5`](https://etherscan.io/address/0x73c3ba0ab596abce64e2074011086e2adc9975f5) | 1 | `0xea36b4f4c6383e87a8d0b2974eb6e7dabad89e7388b542a4d557f0155d85d419` / 739 | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/facets/OwnerPausableFacet.sol) · [Etherscan](https://etherscan.io/address/0x73c3ba0ab596abce64e2074011086e2adc9975f5#code) · [Sourcify](https://repo.sourcify.dev/1/0x73c3ba0ab596abce64e2074011086e2adc9975f5) |
| RouterAdminFacet | [`0x5cba6d9a9bffc35a2e49c7406e90bf64479ad8d4`](https://etherscan.io/address/0x5cba6d9a9bffc35a2e49c7406e90bf64479ad8d4) | 1 | `0x6c7eab3bf656735f4393ceb262da2fdc3bd8849806a53c6a6131fec681b8361b` / 3,283 | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/facets/RouterAdminFacet.sol) · [Etherscan](https://etherscan.io/address/0x5cba6d9a9bffc35a2e49c7406e90bf64479ad8d4#code) · [Sourcify](https://repo.sourcify.dev/1/0x5cba6d9a9bffc35a2e49c7406e90bf64479ad8d4) |
| RouterIssuePreviewFacet | [`0xcde21a9ca1c447e8689e975fd444dae15c3e85bd`](https://etherscan.io/address/0xcde21a9ca1c447e8689e975fd444dae15c3e85bd) | 1 | `0x2020e808e81a10a453f5cb830faf16b1449d4296cf72c215598442e9e9eca86b` / 6,106 | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/facets/RouterIssuePreviewFacet.sol) · [Etherscan](https://etherscan.io/address/0xcde21a9ca1c447e8689e975fd444dae15c3e85bd#code) · [Sourcify](https://repo.sourcify.dev/1/0xcde21a9ca1c447e8689e975fd444dae15c3e85bd) |
| RouterIssueFacet | [`0xcf4f3d73650cce5dcd1a49288110a4eb258fa8c4`](https://etherscan.io/address/0xcf4f3d73650cce5dcd1a49288110a4eb258fa8c4) | 2 | `0x1dd22dbb241a4720cfbe8d7156ea59a4d757847a91d561f772e484994589b135` / 13,707 | [`b4c7041`](https://github.com/CyberGold-io/cybergold-helpers/blob/b4c70410dfb2a0478a76d4d68b9687c37c043f0e/src/facets/RouterIssueFacet.sol) · [Etherscan](https://etherscan.io/address/0xcf4f3d73650cce5dcd1a49288110a4eb258fa8c4#code) · [Sourcify](https://repo.sourcify.dev/1/0xcf4f3d73650cce5dcd1a49288110a4eb258fa8c4) |
| RouterIssueBasketFacet | [`0xdd4e687b31c0b2d07905057a2df1bc7faf8e93b7`](https://etherscan.io/address/0xdd4e687b31c0b2d07905057a2df1bc7faf8e93b7) | 2 | `0xc9fc4bf2d159ebdd05aaca67f345303a0b7f6aa325188d0244c9082e1f79952d` / 13,975 | [`26e2ff2`](https://github.com/CyberGold-io/cybergold-helpers/blob/26e2ff281d0ce653968711614554c5ea152b6c79/src/facets/RouterIssueBasketFacet.sol) · [Etherscan](https://etherscan.io/address/0xdd4e687b31c0b2d07905057a2df1bc7faf8e93b7#code) · [Sourcify](https://repo.sourcify.dev/1/0xdd4e687b31c0b2d07905057a2df1bc7faf8e93b7) |
| RouterRedeemFacet | [`0x3c2461cec650d4d0e77765a1f08edee2647d7878`](https://etherscan.io/address/0x3c2461cec650d4d0e77765a1f08edee2647d7878) | 1 | `0x3009becb9272eb5b350552a6cabb0835c23ae65037cf4a3d71a1507beebfc80f` / 16,345 | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/facets/RouterRedeemFacet.sol) · [Etherscan](https://etherscan.io/address/0x3c2461cec650d4d0e77765a1f08edee2647d7878#code) · [Sourcify](https://repo.sourcify.dev/1/0x3c2461cec650d4d0e77765a1f08edee2647d7878) |
| RouterRedeemBasketFacet | [`0x92ba2309f4543fc4c805585600350eaee4c03759`](https://etherscan.io/address/0x92ba2309f4543fc4c805585600350eaee4c03759) | 1 | `0xd65edb1ba6950652178ad274fa7ddbea577df3214cd5b71755cc68d54e60566e` / 13,407 | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/facets/RouterRedeemBasketFacet.sol) · [Etherscan](https://etherscan.io/address/0x92ba2309f4543fc4c805585600350eaee4c03759#code) · [Sourcify](https://repo.sourcify.dev/1/0x92ba2309f4543fc4c805585600350eaee4c03759) |
| RecoveryShareReceiverFacet | [`0x89b04f15e8c0ca0805828af3ce2bb8770bcec39c`](https://etherscan.io/address/0x89b04f15e8c0ca0805828af3ce2bb8770bcec39c) | 1 | `0x5b7249585e7de1cb4a5a6f69fa983f2530b6696a9a7eb2ebf1efdf560a150cc1` / 3,194 | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/facets/RecoveryShareReceiverFacet.sol) · [Etherscan](https://etherscan.io/address/0x89b04f15e8c0ca0805828af3ce2bb8770bcec39c#code) · [Sourcify](https://repo.sourcify.dev/1/0x89b04f15e8c0ca0805828af3ce2bb8770bcec39c) |

#### Adapters

Adapters are separate deployed contracts approved by Helpers, not facets.
All three approved adapters bind their recovery authority to the current
Helpers address.

| Adapter | Address | Verified source |
| --- | --- | --- |
| OneInchAdapter | [`0xe8e87763768125ba02dd30d932b86bbdd1af082c`](https://etherscan.io/address/0xe8e87763768125ba02dd30d932b86bbdd1af082c) | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/adapters/OneInchAdapter.sol) · [Etherscan](https://etherscan.io/address/0xe8e87763768125ba02dd30d932b86bbdd1af082c#code) · [Sourcify](https://repo.sourcify.dev/1/0xe8e87763768125ba02dd30d932b86bbdd1af082c) |
| UniswapUniversalAdapter | [`0x4edb8190232a47e45d861003672938eb7ee84a15`](https://etherscan.io/address/0x4edb8190232a47e45d861003672938eb7ee84a15) | [`3cfe2b9`](https://github.com/CyberGold-io/cybergold-helpers/blob/3cfe2b9cf0ab4928f14c6a2a9d14ce17c7b40592/src/adapters/UniswapUniversalAdapter.sol) · [Etherscan](https://etherscan.io/address/0x4edb8190232a47e45d861003672938eb7ee84a15#code) · [Sourcify](https://repo.sourcify.dev/1/0x4edb8190232a47e45d861003672938eb7ee84a15) |
| UniswapMultiProtocolAdapter | [`0xc2c210979674db1349f812ea116f2f6d131ab839`](https://etherscan.io/address/0xc2c210979674db1349f812ea116f2f6d131ab839) | [`96c2437`](https://github.com/CyberGold-io/cybergold-helpers/blob/96c2437ba416f1ddc92de855d5b788b7cb578374/src/adapters/UniswapMultiProtocolAdapter.sol) · [Etherscan](https://etherscan.io/address/0xc2c210979674db1349f812ea116f2f6d131ab839#code) · [Sourcify](https://repo.sourcify.dev/1/0xc2c210979674db1349f812ea116f2f6d131ab839) |

The new multi-protocol adapter's complete runtime hash is
`0xfa44748bff7b0d48a075587cd516f8fc690cc87ad7a9ad18b49033dd2bb380c2`
(12,797 bytes). The old V3 adapter remains approved; approval-list order does
not designate a preferred adapter or its calldata encoding.

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

Historical source references for the retired deployment remain available:
the original [Phase 1b launch tag](https://github.com/CyberGold-io/cybergold-helpers/releases/tag/mainnet-phase-1b-helpers-20260727)
identifies commit
[`7e2f31bdbb6c7462244d95debdf9fcb626932b7b`](https://github.com/CyberGold-io/cybergold-helpers/tree/7e2f31bdbb6c7462244d95debdf9fcb626932b7b),
and its later coordinator migration used commit
[`b5353c04ce736aa11026f8a1a47675e044ec1b04`](https://github.com/CyberGold-io/cybergold-helpers/tree/b5353c04ce736aa11026f8a1a47675e044ec1b04)
in [transaction `0x70828ad4…9304`](https://etherscan.io/tx/0x70828ad42e625ebf9006662fffd66b0e1ba20518c3da0176afe058ab6ddd9304).
These are historical identities, not the current replacement source or target.

Release phases are defined in the Ops [release-phase
authority](../cybergold-ops/docs/architecture/release-phases.md), and
cross-repository reviews apply the Ops [trusted-but-fallible operator security
model](../cybergold-ops/docs/security/security-model.md). Operator trust does
not extend to callers, swap payloads, routers, tokens, or public chain state.

## Retained route model

All public calculators use the `preview*` prefix. Aggregated token/native
exact-input issuance previews are advisory constructors for their exact-output
executors. Direct-basket issuance supports both exact input and exact output;
direct-basket redemption supports exact-input execution plus an exact-output
preview that constructs the gross input and complete mixed minimum vector for
that executor.

Token issuance accepts ordinary ERC-20 allowance, standard token-native ERC-2612,
or Permit2. Ethereum Mainnet Helpers installs the native-permit selector
`0x462835d6`. When an exact-ceiling token-native permit is applied, the upfront
ceiling transfer consumes its allowance; unused input is refunded without
restoring allowance. Native
issuance has one dedicated payable endpoint and wraps exactly the declared ETH
budget. CYGLD-funded redemption retains allowance, Permit2, and ERC-2612
variants for both ERC-20 and native output. Generic token routes accept a
nonzero ERC-20 address, including WETH, and are nonpayable; `address(0)` is
used only in `Issued` and `Redeemed` events to identify native ETH.

The retained direct-basket issuance routes use one Permit2 batch. Ethereum
Mainnet also installs `issueFromBasketExactInWithMixedPermits` (`0x705b2d0b`) and
`issueFromBasketExactOutWithMixedPermits` (`0xac7fbf2f`). Each input selects
ordinary Helpers allowance, token-native ERC-2612, or Permit2; the compact
Permit2 batch includes only its selected inputs in the same relative Core
order.
The signed permissions are finite per-trade budgets or ceilings: Helpers asks
Core for the fresh exact lot and pulls and approves only that lot. A larger
native budget leaves its finite unused allowance; a consumed Permit2 nonce
cannot be replayed. The client uses native signing for qualified tokens and
Permit2 for other tokens. Unlimited token-to-Permit2 setup is the sole allowance
exception. Direct-basket redemption retains allowance, CYGLD ERC-2612, and
Permit2 authorization variants.

Issuance preserves Core's full canonical asset order, including zero-target
Exiting members, but only positive targets consume exact-input preview legs and
only positive required lots are probed, pulled, approved, or dust-settled.
Direct-basket inputs keep zero slots for identity binding. Permit2-authorized
zero members remain in their signed batch with a zero requested transfer;
native permits and ordinary transfers are skipped for zero required amounts.

Every issuance and redemption executor rejects the Helpers diamond itself as
recipient. Helpers has no composition callback for its own CYGLD payout, so a
self-recipient issuance would strand the user's output in custody reachable by
the owner sweep.

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

The Helpers fee recipient is always the current Helpers owner. Every positive
operation-local surplus is refunded to the payer; it is never donated as fee
revenue. Pre-operation balance baselines prevent one caller from receiving an
older balance.

See the [execution API](docs/reference/execution-api.md) and [ABI usage
matrix](docs/abi-usage-matrix.md) for exact signatures and tuple meanings.

## Adapters and deployment

The launch deployment includes exactly two approved adapters: 1inch and
Uniswap Universal Router.
Each adapter is nonpayable for swaps, accepts ERC-20 inputs only, protects
pre-existing balances, and is constructed with the Helpers diamond as its
immutable recovery authority. The Uniswap adapter and routed facets use the
same immutable Permit2 address. The owner may admit or remove adapters after
launch under the honest-governance model; there is deliberately no permanent
on-chain two-adapter cardinality restriction. A mistaken adapter can make
routes selecting it revert until the owner removes it, which is an accepted
post-launch liveness residual.

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
