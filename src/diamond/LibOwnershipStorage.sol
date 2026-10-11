// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Namespaced storage for two-step Helpers ownership transfer.
library LibOwnershipStorage {
    bytes32 internal constant OWNERSHIP_STORAGE_POSITION = keccak256("cybergold.helpers.ownership.storage");

    /// @notice Pending two-step ownership nomination.
    struct OwnershipStorage {
        address pendingOwner;
    }

    function ownershipStorage() internal pure returns (OwnershipStorage storage s) {
        bytes32 position = OWNERSHIP_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }
}
