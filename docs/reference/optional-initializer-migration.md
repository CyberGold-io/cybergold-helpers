---
title: Helpers optional-initializer coordinator migration
doc_type: reference
status: active
owner: helpers-maintainer
created: 2026-10-10
last_reviewed: 2026-10-10
canonical_for: Helpers live coordinator migration to optional initialization
---

# Helpers optional-initializer coordinator migration

The updated `DiamondCutOwnerLiveFacet` reuses Protocol's adopted live upgrade
policy. Add, Replace and Remove cuts may pass `address(0)` and empty initializer
calldata when they need no state initialization. A nonzero initializer still
requires selector-bearing calldata; calldata without an initializer remains
invalid. Owner authority, protected coordinator selectors, live runtime and
namespace comparisons, generation accounting, recovery interfaces and topology
checks retain their existing behavior.

The Helpers coordinator installed before the 2026-10-10 upgrade had a
mandatory-initializer policy and protected its own selectors from ordinary
replacement. The dedicated
`HelpersOptionalInitializerMigrationFacet` ports Core's accepted atomic
migration to the Helpers owner authority. Its historical baseline is runtime
hash `0x444259d415cc05ad1cf101cd6601ea387aad01629e0b109f7de6431e2c6a998c`
and coordinator generation one. It advances that generation to two, preserves
the persistent layout and other generation entries, and clears the temporary
migration generation to zero. This migration leaves the existing advertised
interfaces and all other ordered selector owners unchanged.

The owner executed both stages in one outer transaction on 2026-10-10; the
active implementations and receipt-bound generations are recorded in the
[Mainnet registry](../../README.md#ethereum-mainnet-helpers-deployment). The
migration sequence is:

1. Call the existing `diamondCut` to Add only
   `executeHelpersOptionalInitializerMigration(bytes)` (`0x7527543b`). Use the
   same migration implementation as this cut's initializer, with
   `armHelpersOptionalInitializerMigration(bytes)` (`0xc412c9b0`) and the encoded
   payload. Arming writes only a transient commitment bound to the chain,
   Helpers address, caller and exact payload bytes.
2. Call `executeHelpersOptionalInitializerMigration(bytes)` with identical
   payload bytes. It consumes the commitment, replaces `diamondCut`
   (`0x1f931c1c`) and `facetGeneration(bytes32)` (`0x0d11c635`) with the approved
   coordinator, then removes its own temporary selector. The arm selector and
   migration metadata/getter selectors are never installed.

The commitment disappears at transaction completion. Separate transactions
cannot perform the two stages. Failure of either stage, or a later call in the
same atomic bundle, rolls back the coordinator change and temporary installation.
An ordinary issuance upgrade can follow the migration with a zero initializer
and empty calldata. Helpers launch initialization still uses `DiamondLiveInit`
to establish actual deployment state.

`IHelpersOptionalInitializerMigration.Payload` is encoded as a single tuple:

| Field | Type | Purpose |
| --- | --- | --- |
| `oldCoordinator` | `address` | Existing owner coordinator implementation |
| `oldCoordinatorCodeHash` | `bytes32` | Frozen installed baseline runtime hash |
| `newCoordinator` | `address` | Reviewed optional-initializer coordinator |
| `newCoordinatorCodeHash` | `bytes32` | Exact replacement runtime hash |
| `migrationFacet` | `address` | Temporary migration implementation |
| `migrationFacetCodeHash` | `bytes32` | Exact temporary runtime hash |
| `baselineTopologyHash` | `bytes32` | Hash of ABI-encoded ordered selector and owner arrays |

The migration ABI is an auxiliary implementation artifact. It is omitted from
the permanent aggregate Helpers interface and launch selector inventory.

Focused regression coverage is in
`test/HelpersOptionalInitializerMigration.t.sol` and
`test/ValidatedUpgradeCoordinator.t.sol`. Frozen coordinator runtime fixtures
preserve the deployed policy and the older legacy migration target independently
of the updated shared source. Disposable installed-target fork qualification
and owner handoff remain recorded in the Ops implementation workplan.
