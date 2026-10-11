// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Exact payload shared by both calls of Helpers's optional-initializer coordinator migration.
interface IHelpersOptionalInitializerMigration {
    /// @notice Runtime identities and the retained ordered selector topology approved for the migration.
    struct Payload {
        address oldCoordinator;
        bytes32 oldCoordinatorCodeHash;
        address newCoordinator;
        bytes32 newCoordinatorCodeHash;
        address migrationFacet;
        bytes32 migrationFacetCodeHash;
        bytes32 baselineTopologyHash;
    }

    /// @notice Bind the exact second call to the current Diamond, caller, chain and transaction.
    /// @dev Used only as the first cut's initializer; this selector must not be installed.
    /// @param payloadData ABI-encoded Payload passed unchanged to the migration call.
    function armHelpersOptionalInitializerMigration(bytes calldata payloadData) external;

    /// @notice Replace only the coordinator and remove this temporary selector atomically.
    /// @param payloadData ABI-encoded Payload previously committed by the first call.
    function executeHelpersOptionalInitializerMigration(bytes calldata payloadData) external;
}
