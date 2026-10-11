// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice One-shot recovery-share receipt context for Helpers-mediated Core redemptions.
library LibRecoveryShareReceiverStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("cybergold.helpers.recovery-share-receiver.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_LOCATION = 0xb3f97b180a0a1d02be9ed9a6d933995b7bfe2281ea5507835729da1cc2e9a300;

    /// @notice State of the one-shot Core recovery-share receipt.
    enum ReceiptState {
        Idle,
        Armed,
        Consumed
    }

    /// @notice Minimal one-shot commitment for one pending Core batch mint.
    struct Layout {
        ReceiptState state;
        address recipient;
        bytes32 expectedBatchHash;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 location = STORAGE_LOCATION;
        assembly {
            s.slot := location
        }
    }

    function storageLocation() internal pure returns (bytes32) {
        return STORAGE_LOCATION;
    }
}
