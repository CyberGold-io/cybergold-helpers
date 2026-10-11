// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";

/// @notice Pausable facet gated by diamond ownership (ERC-173).
contract OwnerPausableFacet is PausableUpgradeable {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.owner.pausable");

    /// @notice Pause.
    function pause() external {
        LibDiamond.enforceIsContractOwner();
        _pause();
    }

    /// @notice Unpause.
    function unpause() external {
        LibDiamond.enforceIsContractOwner();
        _unpause();
    }
}
