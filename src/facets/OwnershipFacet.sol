// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LibOwnershipStorage} from "../diamond/LibOwnershipStorage.sol";

/// @notice Two-step IERC-173 ownership transfer with owner cancellation.
contract OwnershipFacet is IERC173 {
    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.ownership");

    /// @notice The proposed owner is zero or is already the current owner.
    /// @param currentOwner Current diamond owner.
    /// @param proposedOwner Rejected new owner.
    error InvalidOwnershipTransfer(address currentOwner, address proposedOwner);
    /// @notice The caller is not the nominated pending owner.
    /// @param caller Account attempting to accept ownership.
    /// @param pendingOwner Account currently nominated to accept ownership.
    error NotPendingOwner(address caller, address pendingOwner);
    /// @notice No ownership nomination exists to cancel.
    error NoPendingOwnershipTransfer();

    /// @notice Emitted when the current owner nominates a successor.
    /// @param currentOwner Owner that created the nomination.
    /// @param pendingOwner Account nominated to accept ownership.
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    /// @notice Emitted when the current owner cancels a nomination.
    /// @param currentOwner Owner that canceled the nomination.
    /// @param pendingOwner Account whose nomination was canceled.
    event OwnershipTransferCanceled(address indexed currentOwner, address indexed pendingOwner);

    /// @inheritdoc IERC173
    function transferOwnership(address newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        address currentOwner = LibDiamond.contractOwner();
        if (newOwner == address(0) || newOwner == currentOwner) {
            revert InvalidOwnershipTransfer(currentOwner, newOwner);
        }
        LibOwnershipStorage.ownershipStorage().pendingOwner = newOwner;
        emit OwnershipTransferStarted(currentOwner, newOwner);
    }

    /// @notice Accept a pending ownership nomination.
    function acceptOwnership() external {
        LibOwnershipStorage.OwnershipStorage storage s = LibOwnershipStorage.ownershipStorage();
        address nominated = s.pendingOwner;
        if (msg.sender != nominated) revert NotPendingOwner(msg.sender, nominated);
        s.pendingOwner = address(0);
        LibDiamond.setContractOwner(nominated);
    }

    /// @notice Cancel the current pending ownership nomination.
    function cancelOwnershipTransfer() external {
        LibDiamond.enforceIsContractOwner();
        LibOwnershipStorage.OwnershipStorage storage s = LibOwnershipStorage.ownershipStorage();
        address nominated = s.pendingOwner;
        if (nominated == address(0)) revert NoPendingOwnershipTransfer();
        s.pendingOwner = address(0);
        emit OwnershipTransferCanceled(LibDiamond.contractOwner(), nominated);
    }

    /// @notice Return the nominated owner, or zero when no transfer is pending.
    /// @return Account nominated to accept ownership.
    function pendingOwner() external view returns (address) {
        return LibOwnershipStorage.ownershipStorage().pendingOwner;
    }

    /// @inheritdoc IERC173
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}
