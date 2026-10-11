// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LiveFacetVersionRegistry} from "diamond-infra/helpers/LiveFacetVersionRegistry.sol";
import {IHelpersOptionalInitializerMigration} from "../interfaces/IHelpersOptionalInitializerMigration.sol";
import {LibHelpersOptionalInitializerMigration} from "./LibHelpersOptionalInitializerMigration.sol";

/// @notice One-transaction migration from Helpers's deployed live coordinator to optional initialization.
/// @dev Install only executeHelpersOptionalInitializerMigration. The same implementation is the first
/// cut's initializer, which arms the second call without altering persistent storage. The second
/// call changes only the two coordinator selector owners and two active generation entries.
contract HelpersOptionalInitializerMigrationFacet is IHelpersOptionalInitializerMigration, LiveFacetVersionRegistry {
    /// @notice Namespace for the temporary migration implementation, removed before the Safe call completes.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.optional-initializer-migration");
    bytes32 private constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.owner");
    bytes4 private constant GENERATION_SELECTOR = bytes4(keccak256("facetGeneration(bytes32)"));
    bytes32 private constant DEPLOYED_COORDINATOR_CODE_HASH =
        0x444259d415cc05ad1cf101cd6601ea387aad01629e0b109f7de6431e2c6a998c;

    /// @notice Reverts when the caller does not hold Helpers's existing upgrade authority.
    /// @param caller Account attempting the migration.
    error HelpersOptionalInitializerUnauthorized(address caller);
    /// @notice Reverts when a reviewed implementation has different runtime bytes.
    /// @param target Implementation inspected.
    /// @param expected Reviewed runtime hash.
    /// @param actual Observed runtime hash.
    error HelpersOptionalInitializerRuntimeMismatch(address target, bytes32 expected, bytes32 actual);
    /// @notice Reverts when the installed coordinator is not the deployed migration baseline.
    /// @param actual Submitted baseline runtime hash.
    error HelpersOptionalInitializerBaselineMismatch(bytes32 actual);
    /// @notice Reverts when the replacement would retain the same coordinator runtime.
    error HelpersOptionalInitializerRuntimeUnchanged();
    /// @notice Reverts when a candidate uses a different logical coordinator namespace.
    /// @param actual Candidate namespace.
    error HelpersOptionalInitializerNamespaceMismatch(bytes32 actual);
    /// @notice Reverts when a selector is not owned by the exact expected implementation.
    /// @param selector Selector inspected.
    /// @param expected Expected owner.
    /// @param actual Observed owner.
    error HelpersOptionalInitializerSelectorMismatch(bytes4 selector, address expected, address actual);
    /// @notice Reverts when the live ordered selectors and owners differ from the approved topology.
    /// @param expected Reviewed topology digest.
    /// @param actual Observed topology digest.
    error HelpersOptionalInitializerTopologyMismatch(bytes32 expected, bytes32 actual);
    /// @notice Reverts when an affected namespace does not have its expected installed generation.
    /// @param namespace Namespace inspected.
    /// @param expected Expected generation.
    /// @param actual Observed generation.
    error HelpersOptionalInitializerGenerationMismatch(bytes32 namespace, uint64 expected, uint64 actual);

    /// @notice Emitted when the first cut arms the exact same-transaction second call.
    /// @param commitment Domain-separated migration commitment.
    event HelpersOptionalInitializerMigrationArmed(bytes32 indexed commitment);
    /// @notice Emitted after both coordinator selectors move and the temporary selector is removed.
    /// @param commitment Consumed transaction-scoped commitment.
    /// @param oldCoordinator Previous implementation.
    /// @param newCoordinator Replacement implementation.
    /// @param oldRuntimeCodeHash Exact previous runtime hash.
    /// @param newRuntimeCodeHash Exact replacement runtime hash.
    /// @param resultingGeneration Coordinator's resulting installed generation.
    event HelpersOptionalInitializerCoordinatorMigrated(
        bytes32 indexed commitment,
        address indexed oldCoordinator,
        address indexed newCoordinator,
        bytes32 oldRuntimeCodeHash,
        bytes32 newRuntimeCodeHash,
        uint64 resultingGeneration
    );

    /// @inheritdoc IHelpersOptionalInitializerMigration
    function armHelpersOptionalInitializerMigration(bytes calldata payloadData) external {
        _requireAuthority();
        bytes32 value = LibHelpersOptionalInitializerMigration.commitment(payloadData);
        LibHelpersOptionalInitializerMigration.arm(value);
        emit HelpersOptionalInitializerMigrationArmed(value);
    }

    /// @inheritdoc IHelpersOptionalInitializerMigration
    function executeHelpersOptionalInitializerMigration(bytes calldata payloadData) external {
        _requireAuthority();
        bytes32 value = LibHelpersOptionalInitializerMigration.commitment(payloadData);
        LibHelpersOptionalInitializerMigration.consume(value);
        Payload memory payload = abi.decode(payloadData, (Payload));
        if (payload.oldCoordinatorCodeHash != DEPLOYED_COORDINATOR_CODE_HASH) {
            revert HelpersOptionalInitializerBaselineMismatch(payload.oldCoordinatorCodeHash);
        }
        _requireRuntime(payload.oldCoordinator, payload.oldCoordinatorCodeHash);
        _requireRuntime(payload.newCoordinator, payload.newCoordinatorCodeHash);
        _requireRuntime(payload.migrationFacet, payload.migrationFacetCodeHash);
        if (payload.newCoordinatorCodeHash == payload.oldCoordinatorCodeHash) {
            revert HelpersOptionalInitializerRuntimeUnchanged();
        }
        bytes32 candidateNamespace = _facetNamespace(payload.newCoordinator);
        if (candidateNamespace != COORDINATOR_NAMESPACE) {
            revert HelpersOptionalInitializerNamespaceMismatch(candidateNamespace);
        }
        _requireOwner(IDiamondCut.diamondCut.selector, payload.oldCoordinator);
        _requireOwner(GENERATION_SELECTOR, payload.oldCoordinator);
        _requireOwner(this.executeHelpersOptionalInitializerMigration.selector, payload.migrationFacet);
        _requireGeneration(COORDINATOR_NAMESPACE, 1);
        _requireGeneration(FACET_NAMESPACE, 1);

        (bytes4[] memory selectors, address[] memory owners) = _baselineTopology();
        bytes32 actualTopology = keccak256(abi.encode(selectors, owners));
        if (actualTopology != payload.baselineTopologyHash) {
            revert HelpersOptionalInitializerTopologyMismatch(payload.baselineTopologyHash, actualTopology);
        }
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == IDiamondCut.diamondCut.selector || selectors[i] == GENERATION_SELECTOR) {
                owners[i] = payload.newCoordinator;
            }
        }
        bytes32 expectedTopology = keccak256(abi.encode(selectors, owners));

        LibDiamond.diamondCut(_coordinatorCut(payload.newCoordinator), address(0), "");
        _facetVersions().versions[COORDINATOR_NAMESPACE] = 2;
        _facetVersions().versions[FACET_NAMESPACE] = 0;
        (selectors, owners) = _currentTopology();
        actualTopology = keccak256(abi.encode(selectors, owners));
        if (actualTopology != expectedTopology) {
            revert HelpersOptionalInitializerTopologyMismatch(expectedTopology, actualTopology);
        }
        _requireOwner(this.executeHelpersOptionalInitializerMigration.selector, address(0));
        _requireAuthority();
        emit HelpersOptionalInitializerCoordinatorMigrated(
            value,
            payload.oldCoordinator,
            payload.newCoordinator,
            payload.oldCoordinatorCodeHash,
            payload.newCoordinatorCodeHash,
            2
        );
    }

    function _requireAuthority() private view {
        if (LibDiamond.contractOwner() != msg.sender) {
            revert HelpersOptionalInitializerUnauthorized(msg.sender);
        }
    }

    function _requireRuntime(address target, bytes32 expected) private view {
        bytes32 actual = target.codehash;
        if (actual != expected) {
            revert HelpersOptionalInitializerRuntimeMismatch(target, expected, actual);
        }
    }

    function _requireOwner(bytes4 selector, address expected) private view {
        address actual = LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress;
        if (actual != expected) revert HelpersOptionalInitializerSelectorMismatch(selector, expected, actual);
    }

    function _requireGeneration(bytes32 namespace, uint64 expected) private view {
        uint64 actual = _facetVersions().versions[namespace];
        if (actual != expected) revert HelpersOptionalInitializerGenerationMismatch(namespace, expected, actual);
    }

    function _baselineTopology() private view returns (bytes4[] memory selectors, address[] memory owners) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        selectors = new bytes4[](ds.selectors.length - 1);
        owners = new address[](selectors.length);
        uint256 cursor;
        for (uint256 i; i < ds.selectors.length; ++i) {
            bytes4 selector = ds.selectors[i];
            if (selector == this.executeHelpersOptionalInitializerMigration.selector) continue;
            selectors[cursor] = selector;
            owners[cursor++] = ds.facetAddressAndSelectorPosition[selector].facetAddress;
        }
    }

    function _currentTopology() private view returns (bytes4[] memory selectors, address[] memory owners) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        selectors = ds.selectors;
        owners = new address[](selectors.length);
        for (uint256 i; i < selectors.length; ++i) {
            owners[i] = ds.facetAddressAndSelectorPosition[selectors[i]].facetAddress;
        }
    }

    function _coordinatorCut(address candidate) private pure returns (IDiamond.FacetCut[] memory cut) {
        cut = new IDiamond.FacetCut[](2);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IDiamondCut.diamondCut.selector;
        selectors[1] = GENERATION_SELECTOR;
        cut[0] = IDiamond.FacetCut({
            facetAddress: candidate, action: IDiamond.FacetCutAction.Replace, functionSelectors: selectors
        });
        selectors = new bytes4[](1);
        selectors[0] = IHelpersOptionalInitializerMigration.executeHelpersOptionalInitializerMigration.selector;
        cut[1] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: selectors
        });
    }
}
