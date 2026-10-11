// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Transaction-scoped commitment for Helpers's live-to-live coordinator migration.
library LibHelpersOptionalInitializerMigration {
    bytes32 internal constant COMMITMENT_SLOT =
        keccak256("cybergold.helpers.optional-initializer-migration.transient.commitment");
    bytes32 private constant COMMITMENT_DOMAIN = keccak256("CYBERGOLD_HELPERS_OPTIONAL_INITIALIZER_MIGRATION_V1");

    /// @notice Reverts when the migration was not armed with these exact bytes by this caller.
    /// @param expected Commitment derived from the second call.
    /// @param actual Commitment retained by the first call in transient storage.
    error HelpersOptionalInitializerCommitmentMismatch(bytes32 expected, bytes32 actual);

    /// @dev Bind the exact payload to the executing Diamond and authority.
    function commitment(bytes calldata payloadData) internal view returns (bytes32) {
        return
            keccak256(abi.encode(COMMITMENT_DOMAIN, block.chainid, address(this), msg.sender, keccak256(payloadData)));
    }

    /// @dev Arm the second call without modifying persistent product or generation storage.
    function arm(bytes32 value) internal {
        bytes32 slot = COMMITMENT_SLOT;
        assembly {
            tstore(slot, value)
        }
    }

    /// @dev Consume the exact commitment once; EIP-1153 also clears it at transaction completion.
    function consume(bytes32 expected) internal {
        bytes32 slot = COMMITMENT_SLOT;
        bytes32 actual;
        assembly {
            actual := tload(slot)
        }
        if (actual != expected || actual == bytes32(0)) {
            revert HelpersOptionalInitializerCommitmentMismatch(expected, actual);
        }
        assembly {
            tstore(slot, 0)
        }
    }
}
