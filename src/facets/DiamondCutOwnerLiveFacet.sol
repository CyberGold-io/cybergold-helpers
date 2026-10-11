// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LiveValidatedDiamondCut} from "diamond-infra/helpers/LiveValidatedDiamondCut.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice Owner-controlled upgrade coordinator comparing candidates with live installed facets.
/// @dev This is additive to the deployed legacy `DiamondCutOwnerFacet`. Candidate identity and
/// runtime codehashes exist only in coordinator memory; persistent state records generations only.
contract DiamondCutOwnerLiveFacet is LiveValidatedDiamondCut {
    /// @notice Stable namespace shared by owner-controlled upgrade coordinators.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.upgrade.coordinator.owner");

    /// @inheritdoc IDiamondCut
    function diamondCut(FacetCut[] calldata diamondCut_, address init, bytes calldata initCalldata) external override {
        LibDiamond.enforceIsContractOwner();
        _validatedDiamondCut(diamondCut_, init, initCalldata);
    }

    /// @dev Preserve the complete two-step owner recovery surface after every cut.
    function _validateUpgradeAuthority() internal view override {
        _requireInstalled(IERC173.owner.selector);
        _requireInstalled(IERC173.transferOwnership.selector);
        _requireInstalled(bytes4(keccak256("pendingOwner()")));
        _requireInstalled(bytes4(keccak256("acceptOwnership()")));
        _requireInstalled(bytes4(keccak256("cancelOwnershipTransfer()")));

        if (LibDiamond.contractOwner() == address(0) || !LibInterfaceInvariant.isAdvertised(type(IERC173).interfaceId))
        {
            revert DiamondCutRecoveryInvariantFailed(IERC173.owner.selector);
        }
    }
}
