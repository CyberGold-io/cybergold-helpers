// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {LibRecoveryShareReceiverStorage} from "../src/diamond/LibRecoveryShareReceiverStorage.sol";

contract RouterStorageHarness {
    using EnumerableSet for EnumerableSet.AddressSet;

    function write(address core, uint256 feePpm, address wrappedNative, address adapterA, address adapterB) external {
        LibAppStorage.RouterStorage storage s = LibAppStorage.routerStorage();
        s.coreDiamond = core;
        s.helperFeePpm = feePpm;
        s.wrappedNative = wrappedNative;
        s.approvedAdapters.add(adapterA);
        s.approvedAdapters.add(adapterB);
    }

    function read()
        external
        view
        returns (address core, uint256 feePpm, address wrappedNative, address[] memory adapters)
    {
        LibAppStorage.RouterStorage storage s = LibAppStorage.routerStorage();
        return (s.coreDiamond, s.helperFeePpm, s.wrappedNative, s.approvedAdapters.values());
    }
}

contract RecoveryShareReceiverStorageHarness {
    function storageLocation() external pure returns (bytes32) {
        return LibRecoveryShareReceiverStorage.storageLocation();
    }
}

/// @notice Guards AppStorage slot and ordering for the helpers diamond.
contract AppStorageLayoutTest is Test {
    function testAppStorageSlot() external pure {
        // Hash must stay stable; changing it is a storage migration.
        bytes32 expected = keccak256("cybergold.helpers.app.storage");
        assertEq(LibAppStorage.appStoragePosition(), expected);
    }

    function testRouterStorageNamespaceCoversEveryRetainedField() external {
        RouterStorageHarness harness = new RouterStorageHarness();
        harness.write(address(0xC0), 321, address(0xE7), address(0xA1), address(0xA2));

        (address core, uint256 feePpm, address wrappedNative, address[] memory adapters) = harness.read();
        assertEq(core, address(0xC0));
        assertEq(feePpm, 321);
        assertEq(wrappedNative, address(0xE7));
        assertEq(adapters.length, 2);
        assertEq(adapters[0], address(0xA1));
        assertEq(adapters[1], address(0xA2));
    }

    function testRecoveryShareReceiverStorageNamespaceIsFrozenAndDisjoint() external {
        RecoveryShareReceiverStorageHarness harness = new RecoveryShareReceiverStorageHarness();
        bytes32 root = harness.storageLocation();
        assertEq(root, 0xb3f97b180a0a1d02be9ed9a6d933995b7bfe2281ea5507835729da1cc2e9a300);
        assertEq(
            root,
            keccak256(abi.encode(uint256(keccak256("cybergold.helpers.recovery-share-receiver.storage.v1")) - 1))
                & ~bytes32(uint256(0xff))
        );
        assertTrue(root != LibAppStorage.appStoragePosition());
    }
}
