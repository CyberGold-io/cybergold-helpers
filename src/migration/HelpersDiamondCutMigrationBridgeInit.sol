// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {IHelpersDiamondCutMigration} from "../interfaces/IHelpersDiamondCutMigration.sol";
import {LibHelpersDiamondCutMigration} from "./LibHelpersDiamondCutMigration.sol";

/// @notice Stage-A initializer consumed by Helpers' installed legacy coordinator.
/// @dev The migration commitment is transient and therefore usable only by Stage B in the same transaction.
contract HelpersDiamondCutMigrationBridgeInit is FacetVersionRegistry {
    /// @notice Reverts when Stage A is not executed by the Safe committed in the migration payload.
    /// @param expected Safe address authorized by the migration payload.
    /// @param actual Account that invoked the Stage-A initializer.
    error HelpersMigrationUnauthorizedSafe(address expected, address actual);
    /// @notice Reverts when the committed Safe is not the Diamond's current owner.
    /// @param expectedOwner Current owner required by the deployed Helpers authority model.
    /// @param actualCaller Account executing the Stage-A initializer.
    error HelpersMigrationUnauthorizedOwner(address expectedOwner, address actualCaller);
    /// @notice Reverts when a migration dependency has missing or unexpected runtime code.
    /// @param target Dependency address whose runtime was inspected.
    /// @param expected Runtime code hash committed in the migration payload.
    /// @param actual Runtime code hash observed at `target`.
    error HelpersMigrationInvalidRuntime(address target, bytes32 expected, bytes32 actual);
    /// @notice Reverts when an old or new coordinator does not use the required coordinator namespace.
    /// @param target Coordinator address whose namespace was inspected.
    /// @param namespace Namespace reported by `target`.
    error HelpersMigrationInvalidCoordinator(address target, bytes32 namespace);
    /// @notice Reverts when the installed temporary migration facet differs from the committed facet.
    /// @param facet Temporary migration facet address that failed validation.
    error HelpersMigrationInvalidTemporaryFacet(address facet);
    /// @notice Reverts when Helpers' pre-migration selector topology differs from the committed baseline.
    /// @param expected Baseline topology hash committed in the migration payload.
    /// @param actual Topology hash derived from current Diamond storage.
    error HelpersMigrationInvalidBaselineTopology(bytes32 expected, bytes32 actual);
    /// @notice Reverts when a namespace's installed generation differs from the migration requirement.
    /// @param namespace Facet namespace whose generation was inspected.
    /// @param expected Generation required by the migration.
    /// @param actual Generation read from the legacy registry.
    error HelpersMigrationInvalidRegistryGeneration(bytes32 namespace, uint64 expected, uint64 actual);
    /// @notice Reverts when the namespace and generation manifests have invalid cardinality.
    /// @param namespaces Number of namespace entries supplied.
    /// @param generations Number of generation entries supplied.
    error HelpersMigrationManifestLengthMismatch(uint256 namespaces, uint256 generations);

    /// @notice Emitted when Stage A binds the exact Stage-B migration to the current transaction.
    /// @param commitment Transient commitment consumed by the temporary migration facet.
    /// @param oldCoordinator Installed legacy coordinator authenticated by Stage A.
    /// @param newCoordinator Live coordinator committed for Stage B.
    /// @param migrationFacet Temporary one-selector migration facet installed by Stage A.
    event HelpersDiamondCutMigrationArmed(
        bytes32 indexed commitment,
        address indexed oldCoordinator,
        address indexed newCoordinator,
        address migrationFacet
    );

    /// @notice Consume the legacy pending tuple and arm the exact same-transaction Stage B.
    /// @param migrationFacet Temporary migration facet installed by the enclosing legacy cut.
    /// @param payloadData ABI-encoded migration payload shared byte-for-byte with Stage B.
    function armHelpersDiamondCutMigration(address migrationFacet, bytes calldata payloadData) external {
        IHelpersDiamondCutMigration.Payload memory payload =
            abi.decode(payloadData, (IHelpersDiamondCutMigration.Payload));
        if (payload.safe != msg.sender) {
            revert HelpersMigrationUnauthorizedSafe(payload.safe, msg.sender);
        }
        if (LibDiamond.contractOwner() != msg.sender) {
            revert HelpersMigrationUnauthorizedOwner(LibDiamond.contractOwner(), msg.sender);
        }
        if (payload.namespaces.length == 0 || payload.namespaces.length != payload.generations.length) {
            revert HelpersMigrationManifestLengthMismatch(payload.namespaces.length, payload.generations.length);
        }
        if (migrationFacet != payload.migrationFacet) {
            revert HelpersMigrationInvalidTemporaryFacet(migrationFacet);
        }

        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        address oldCoordinator = ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress;
        if (oldCoordinator != payload.oldCoordinator) {
            revert HelpersMigrationInvalidCoordinator(oldCoordinator, bytes32(0));
        }
        _requireRuntime(oldCoordinator, payload.oldCoordinatorCodeHash);
        _requireRuntime(payload.newCoordinator, payload.newCoordinatorCodeHash);
        _requireRuntime(migrationFacet, payload.migrationFacetCodeHash);
        _requireRuntime(payload.retirementInitializer, payload.retirementInitializerCodeHash);

        _requireCoordinatorNamespace(oldCoordinator);
        _requireCoordinatorNamespace(payload.newCoordinator);
        LibHelpersDiamondCutMigration.requireOnlySelector(oldCoordinator, IDiamondCut.diamondCut.selector);
        if (
            ds.facetAddressAndSelectorPosition[LibHelpersDiamondCutMigration.MIGRATION_SELECTOR].facetAddress
                != migrationFacet
        ) {
            revert HelpersMigrationInvalidTemporaryFacet(migrationFacet);
        }
        LibHelpersDiamondCutMigration.requireOnlySelector(
            migrationFacet, LibHelpersDiamondCutMigration.MIGRATION_SELECTOR
        );
        bytes32 migrationNamespace = LibHelpersDiamondCutMigration.facetNamespace(migrationFacet);
        if (migrationNamespace == bytes32(0)) {
            revert HelpersMigrationInvalidTemporaryFacet(migrationFacet);
        }

        uint64 coordinatorRegistryGeneration =
            _facetVersions().versions[LibHelpersDiamondCutMigration.COORDINATOR_NAMESPACE];
        if (coordinatorRegistryGeneration != 1) {
            revert HelpersMigrationInvalidRegistryGeneration(
                LibHelpersDiamondCutMigration.COORDINATOR_NAMESPACE, 1, coordinatorRegistryGeneration
            );
        }
        bytes32 topologyHash =
            LibHelpersDiamondCutMigration.topologyHashWithout(LibHelpersDiamondCutMigration.MIGRATION_SELECTOR);
        if (topologyHash != payload.baselineTopologyHash) {
            revert HelpersMigrationInvalidBaselineTopology(payload.baselineTopologyHash, topologyHash);
        }

        // This is the sole compatibility write performed by the deployed V1 coordinator path.
        _checkAndSetFacetVersion(migrationFacet);
        bytes32 commitment = LibHelpersDiamondCutMigration.migrationCommitment(payloadData);
        LibHelpersDiamondCutMigration.armMigration(commitment);
        emit HelpersDiamondCutMigrationArmed(commitment, oldCoordinator, payload.newCoordinator, migrationFacet);
    }

    function _requireCoordinatorNamespace(address coordinator) private view {
        bytes32 namespace = LibHelpersDiamondCutMigration.facetNamespace(coordinator);
        if (namespace != LibHelpersDiamondCutMigration.COORDINATOR_NAMESPACE) {
            revert HelpersMigrationInvalidCoordinator(coordinator, namespace);
        }
    }

    function _requireRuntime(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (target.code.length == 0 || expected == bytes32(0) || actual != expected) {
            revert HelpersMigrationInvalidRuntime(target, expected, actual);
        }
    }
}
