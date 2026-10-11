// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Helpers router configuration stored directly in one diamond namespace.
library LibAppStorage {
    bytes32 internal constant APP_STORAGE_POSITION = keccak256("cybergold.helpers.app.storage");

    /// @dev Return app storage position.
    /// @return Storage namespace slot used by the Helpers diamond.
    function appStoragePosition() internal pure returns (bytes32) {
        return APP_STORAGE_POSITION;
    }

    /// @notice Persistent Core, fee, wrapped-native, and adapter configuration.
    struct RouterStorage {
        address coreDiamond;
        uint256 helperFeePpm;
        address wrappedNative;
        EnumerableSet.AddressSet approvedAdapters;
    }

    /// @dev Return app storage.
    /// @return s Helpers router storage anchored at the canonical slot.
    function routerStorage() internal pure returns (RouterStorage storage s) {
        bytes32 position = APP_STORAGE_POSITION;
        assembly {
            s.slot := position
        }
    }
}
