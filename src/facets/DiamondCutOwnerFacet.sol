// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {ValidatedDiamondCut} from "diamond-infra/helpers/ValidatedDiamondCut.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

/// @notice Sole validated runtime upgrade coordinator for the owner-gated Helpers diamond.
contract DiamondCutOwnerFacet is ValidatedDiamondCut {
    /// @notice Facet version used by source/off-chain compatibility checks.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace reserved for the immutable Helpers upgrade coordinator.
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
