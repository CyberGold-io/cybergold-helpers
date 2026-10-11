// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {LiveInitCoordinator} from "diamond-infra/helpers/LiveInitCoordinator.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";
import {StandardInterfaceManifests} from "diamond-infra/libraries/StandardInterfaceManifests.sol";
import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";
import {RouterAdminFacet} from "../facets/RouterAdminFacet.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibOwnershipStorage} from "../diamond/LibOwnershipStorage.sol";
import {ICyberGoldHelpers} from "../interfaces/ICyberGoldHelpers.sol";
import {FacetSelectors} from "./FacetSelectors.sol";

/// @notice Generation-only initializer for new Helpers diamond deployments.
/// @dev The deployed legacy `DiamondInit` remains unchanged for reproducibility. This live
/// initializer records generation one at registry offset `+0` and never writes offsets `+1..+4`.
contract DiamondLiveInit is LiveInitCoordinator {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ERC-7201 slot used by OpenZeppelin PausableUpgradeable.
    bytes32 private constant PAUSABLE_STORAGE_LOCATION =
        0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300;
    bytes32 private constant INIT_CONTEXT_STORAGE_LOCATION =
        0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
    bytes32 private constant RECOVERY_SHARE_RECEIVER_STORAGE_LOCATION =
        0xb3f97b180a0a1d02be9ed9a6d933995b7bfe2281ea5507835729da1cc2e9a300;
    bytes32 private constant FACET_VERSION_REGISTRY_STORAGE_LOCATION =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant RETIRED_REENTRANCY_GUARD_STORAGE_LOCATION =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    /// @notice Reverts when facet init failed.
    /// @param target Contract address called or initialized by the operation.
    /// @param data Opaque calldata passed to the sleeve, adapter, initializer, or timelock operation.
    error FacetInitFailed(address target, bytes data);
    /// @notice A launch cut installed an unexpected selector cardinality.
    /// @param expected Exact post-cut selector count for the canonical Helpers manifest.
    /// @param actual Selector count observed after applying the finalization cut.
    error ShellSelectorManifestMismatch(uint256 expected, uint256 actual);
    /// @notice A deterministic shell retained a pending two-step ownership nomination.
    /// @param pendingOwner Unexpected pending ownership nominee retained by the shell.
    error ShellPendingOwnerNotPristine(address pendingOwner);
    /// @notice A deterministic shell retained Helpers router configuration.
    /// @param coreDiamond Unexpected configured Core diamond.
    /// @param helperFeePpm Unexpected configured Helpers fee in parts per million.
    /// @param wrappedNative Unexpected configured wrapped-native token.
    /// @param approvedAdapterCount Number of unexpected approved adapters.
    error ShellRouterStorageNotPristine(
        address coreDiamond, uint256 helperFeePpm, address wrappedNative, uint256 approvedAdapterCount
    );
    /// @notice A deterministic shell retained non-default pause storage.
    /// @param rawPausedState Raw nonzero OpenZeppelin pause-storage word retained by the shell.
    error ShellPauseStorageNotPristine(uint256 rawPausedState);
    /// @notice A deterministic shell retained non-default initialization infrastructure storage.
    /// @param slot Known infrastructure storage slot that was unexpectedly nonzero.
    /// @param rawValue Raw nonzero word retained in the slot.
    error ShellInfrastructureStorageNotPristine(bytes32 slot, uint256 rawValue);
    /// @notice A deterministic shell retained a canonical supported-interface entry.
    /// @param interfaceId Canonical interface identifier unexpectedly registered before finalization.
    error ShellInterfaceNotPristine(bytes4 interfaceId);
    /// @notice A deterministic shell retained a known facet-generation entry.
    /// @param namespace Facet namespace whose registry entry was unexpectedly initialized.
    /// @param generation Unexpected installed generation.
    error ShellFacetGenerationNotPristine(bytes32 namespace, uint64 generation);
    /// @notice A deterministic shell retained advertised-interface selector manifests.
    /// @param count Unexpected number of pre-registered interface manifests.
    error ShellInterfaceManifestNotPristine(uint256 count);
    /// @notice A required production facet was omitted from the launch configuration.
    /// @param facetIndex Canonical launch-facet index (cut, loupe, ownership, pause, admin,
    /// issue-preview, issue, issue-basket, redeem, redeem-basket, recovery-share receiver).
    error LaunchFacetMissing(uint256 facetIndex);
    /// @notice A required production facet address has no runtime code.
    /// @param facetIndex Canonical launch-facet index.
    /// @param facet Address without runtime code.
    error LaunchFacetCodeMissing(uint256 facetIndex, address facet);
    /// @notice A Helpers-owned launch facet reported the zero namespace.
    /// @param facetIndex Canonical launch-facet index.
    /// @param facet Facet reporting invalid metadata.
    error LaunchFacetNamespaceInvalid(uint256 facetIndex, address facet);
    /// @notice Two Helpers-owned launch facets reported the same namespace.
    /// @param namespace Duplicate namespace.
    /// @param firstIndex First canonical launch-facet index using the namespace.
    /// @param duplicateIndex Later canonical launch-facet index using the namespace.
    error LaunchFacetNamespaceDuplicate(bytes32 namespace, uint256 firstIndex, uint256 duplicateIndex);
    /// @notice A configured facet differs from the implementation owning its canonical selector.
    /// @param facetIndex Canonical launch-facet index.
    /// @param configured Facet address supplied to the initializer.
    /// @param installed Facet address resolved from diamond selector storage.
    error LaunchFacetAddressMismatch(uint256 facetIndex, address configured, address installed);
    /// @notice Two canonical launch-facet entries resolve to the same implementation.
    /// @param facet Duplicate facet address.
    /// @param firstIndex First canonical launch-facet index using the address.
    /// @param duplicateIndex Later canonical launch-facet index using the address.
    error LaunchFacetAddressDuplicate(address facet, uint256 firstIndex, uint256 duplicateIndex);
    /// @notice An installed selector belongs to an implementation outside the canonical launch inventory.
    /// @param selector Selector owned by the unexpected implementation.
    /// @param facet Unexpected selector owner.
    error LaunchUnexpectedFacet(bytes4 selector, address facet);

    /// @notice Initializer payload for wiring diamond facets and package-specific state.
    struct InitConfig {
        address owner;
        bool requirePristineShell;
        uint256 expectedSelectorCount;
        address loupeFacet;
        address pausableFacet;
        address ownershipFacet;
        address adminFacet;
        address issuePreviewFacet;
        address issueFacet;
        address issueBasketFacet;
        address redeemFacet;
        address redeemBasketFacet;
        address recoveryShareReceiverFacet;
        address coreDiamond;
        address wrappedNative;
        uint256 helperFeePpm;
        address[] approvedAdapters;
    }

    /// @notice Initialize helpers diamond state.
    /// @param cfg Initializer or deployment config consumed by this function.
    function init(InitConfig calldata cfg) external {
        require(cfg.owner != address(0), "DiamondLiveInit: owner missing");
        _assertSelectorManifestCount(cfg.expectedSelectorCount);
        (address cutFacet, address loupeFacet) = _validateLaunchFacets(cfg);
        if (cfg.requirePristineShell) _assertPristineShell(cfg, cutFacet, loupeFacet);
        if (LibDiamond.contractOwner() != cfg.owner) {
            LibDiamond.setContractOwner(cfg.owner);
        }
        _enterInitContext();
        _registerFacetGeneration(cutFacet);
        _registerFacetGeneration(loupeFacet);
        _registerFacetGeneration(cfg.pausableFacet);
        _registerFacetGeneration(cfg.ownershipFacet);
        _initRouter(cfg.coreDiamond, cfg.wrappedNative, cfg.helperFeePpm, cfg.approvedAdapters);
        _registerFacetGeneration(cfg.issuePreviewFacet);
        _registerFacetGeneration(cfg.issueFacet);
        _registerFacetGeneration(cfg.issueBasketFacet);
        _registerFacetGeneration(cfg.redeemFacet);
        _registerFacetGeneration(cfg.redeemBasketFacet);
        _registerFacetGeneration(cfg.recoveryShareReceiverFacet);
        _registerInterfaces();
        _exitInitContext();
    }

    /// @dev Prove that deterministic-shell finalization started from default known state.
    function _assertPristineShell(InitConfig calldata cfg, address cutFacet, address loupeFacet) internal view {
        address pendingOwner = LibOwnershipStorage.ownershipStorage().pendingOwner;
        if (pendingOwner != address(0)) revert ShellPendingOwnerNotPristine(pendingOwner);

        LibAppStorage.RouterStorage storage rs = LibAppStorage.routerStorage();
        uint256 approvedAdapterCount = rs.approvedAdapters.length();
        if (
            rs.coreDiamond != address(0) || rs.helperFeePpm != 0 || rs.wrappedNative != address(0)
                || approvedAdapterCount != 0
        ) {
            revert ShellRouterStorageNotPristine(
                rs.coreDiamond, rs.helperFeePpm, rs.wrappedNative, approvedAdapterCount
            );
        }

        uint256 rawPausedState;
        bytes32 pauseSlot = PAUSABLE_STORAGE_LOCATION;
        assembly {
            rawPausedState := sload(pauseSlot)
        }
        if (rawPausedState != 0) revert ShellPauseStorageNotPristine(rawPausedState);

        _assertRawSlotUnset(RETIRED_REENTRANCY_GUARD_STORAGE_LOCATION);
        _assertRawSlotUnset(INIT_CONTEXT_STORAGE_LOCATION);
        _assertRawSlotUnset(RECOVERY_SHARE_RECEIVER_STORAGE_LOCATION);
        _assertRawSlotUnset(bytes32(uint256(RECOVERY_SHARE_RECEIVER_STORAGE_LOCATION) + 1));
        for (uint256 offset = 1; offset <= 4; ++offset) {
            _assertRawSlotUnset(bytes32(uint256(FACET_VERSION_REGISTRY_STORAGE_LOCATION) + offset));
        }
        uint256 interfaceManifestCount = LibInterfaceInvariant.registeredInterfaceCount();
        if (interfaceManifestCount != 0) revert ShellInterfaceManifestNotPristine(interfaceManifestCount);

        _assertInterfaceUnset(type(IERC165).interfaceId);
        _assertInterfaceUnset(type(IDiamondCut).interfaceId);
        _assertInterfaceUnset(type(IDiamondLoupe).interfaceId);
        _assertInterfaceUnset(type(IERC173).interfaceId);
        _assertInterfaceUnset(type(ICyberGoldHelpers).interfaceId);
        _assertInterfaceUnset(type(IERC1155Receiver).interfaceId);
        _assertInterfaceUnset(type(ICygldOutflowCallback).interfaceId);
        _assertInterfaceUnset(type(ICygldApprovalCallback).interfaceId);
        _assertInterfaceUnset(type(IRecoveryShareOutflowCallback).interfaceId);
        _assertInterfaceUnset(type(IRecoveryShareRedemptionCallback).interfaceId);

        _assertFacetGenerationUnset(cutFacet);
        _assertFacetGenerationUnset(loupeFacet);
        _assertFacetGenerationUnset(cfg.ownershipFacet);
        _assertFacetGenerationUnset(cfg.pausableFacet);
        _assertFacetGenerationUnset(cfg.adminFacet);
        _assertFacetGenerationUnset(cfg.issuePreviewFacet);
        _assertFacetGenerationUnset(cfg.issueFacet);
        _assertFacetGenerationUnset(cfg.issueBasketFacet);
        _assertFacetGenerationUnset(cfg.redeemFacet);
        _assertFacetGenerationUnset(cfg.redeemBasketFacet);
        _assertFacetGenerationUnset(cfg.recoveryShareReceiverFacet);
    }

    /// @dev Enforce the canonical selector count after every launch cut, including direct deployment.
    function _assertSelectorManifestCount(uint256 expectedSelectorCount) internal view {
        uint256 actualSelectorCount = LibDiamond.diamondStorage().selectors.length;
        if (actualSelectorCount != expectedSelectorCount) {
            revert ShellSelectorManifestMismatch(expectedSelectorCount, actualSelectorCount);
        }
    }

    function _assertRawSlotUnset(bytes32 slot) internal view {
        uint256 rawValue;
        assembly {
            rawValue := sload(slot)
        }
        if (rawValue != 0) revert ShellInfrastructureStorageNotPristine(slot, rawValue);
    }

    function _assertInterfaceUnset(bytes4 interfaceId) internal view {
        if (LibDiamond.diamondStorage().supportedInterfaces[interfaceId]) {
            revert ShellInterfaceNotPristine(interfaceId);
        }
    }

    function _assertFacetGenerationUnset(address facet) internal view {
        bytes32 namespace = _facetNamespace(facet);
        uint64 generation = _facetVersions().versions[namespace];
        if (generation != 0) revert ShellFacetGenerationNotPristine(namespace, generation);
        for (uint256 offset = 1; offset < 5; ++offset) {
            _assertRawSlotUnset(
                keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_STORAGE_LOCATION) + offset)))
            );
        }
    }

    /// @dev Require every production facet and a unique nonzero namespace for every implementation.
    function _validateLaunchFacets(InitConfig calldata cfg)
        internal
        view
        returns (address cutFacet, address loupeFacet)
    {
        address[11] memory facets;
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facets[0] = ds.facetAddressAndSelectorPosition[IDiamondCut.diamondCut.selector].facetAddress;
        facets[1] = _configuredFacet(ds, 1, cfg.loupeFacet, IDiamondLoupe.facets.selector);
        facets[2] = _configuredFacet(ds, 2, cfg.ownershipFacet, IERC173.owner.selector);
        facets[3] = _configuredFacet(ds, 3, cfg.pausableFacet, bytes4(keccak256("pause()")));
        facets[4] = _configuredFacet(ds, 4, cfg.adminFacet, FacetSelectors.adminSelectors()[0]);
        facets[5] = _configuredFacet(ds, 5, cfg.issuePreviewFacet, FacetSelectors.issuePreviewSelectors()[0]);
        facets[6] = _configuredFacet(ds, 6, cfg.issueFacet, FacetSelectors.issueSelectors()[0]);
        facets[7] = _configuredFacet(ds, 7, cfg.issueBasketFacet, FacetSelectors.issueBasketSelectors()[0]);
        facets[8] = _configuredFacet(ds, 8, cfg.redeemFacet, FacetSelectors.redeemSelectors()[0]);
        facets[9] = _configuredFacet(ds, 9, cfg.redeemBasketFacet, FacetSelectors.redeemBasketSelectors()[0]);
        facets[10] = _configuredFacet(
            ds, 10, cfg.recoveryShareReceiverFacet, FacetSelectors.recoveryShareReceiverSelectors()[0]
        );

        _validateRequiredLaunchFacets(facets);
        _validateLaunchFacetTopology(ds, facets);
        _validateLaunchFacetMetadata(facets);
        cutFacet = facets[0];
        loupeFacet = facets[1];
    }

    function _configuredFacet(
        LibDiamond.DiamondStorage storage ds,
        uint256 facetIndex,
        address configured,
        bytes4 representativeSelector
    ) internal view returns (address installed) {
        if (configured == address(0)) revert LaunchFacetMissing(facetIndex);
        installed = ds.facetAddressAndSelectorPosition[representativeSelector].facetAddress;
        if (installed == address(0)) revert LaunchFacetMissing(facetIndex);
        if (configured != installed) revert LaunchFacetAddressMismatch(facetIndex, configured, installed);
    }

    function _validateRequiredLaunchFacets(address[11] memory facets) internal view {
        for (uint256 i; i < facets.length; ++i) {
            address facet = facets[i];
            if (facet == address(0)) revert LaunchFacetMissing(i);
            if (facet.code.length == 0) revert LaunchFacetCodeMissing(i, facet);
        }
    }

    function _validateLaunchFacetTopology(LibDiamond.DiamondStorage storage ds, address[11] memory facets)
        internal
        view
    {
        for (uint256 i; i < facets.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (facets[i] == facets[j]) revert LaunchFacetAddressDuplicate(facets[i], j, i);
            }
        }

        for (uint256 i; i < ds.selectors.length; ++i) {
            bytes4 selector = ds.selectors[i];
            address owner = ds.facetAddressAndSelectorPosition[selector].facetAddress;
            uint256 j;
            while (j < facets.length && owner != facets[j]) ++j;
            if (j == facets.length) revert LaunchUnexpectedFacet(selector, owner);
        }
    }

    function _validateLaunchFacetMetadata(address[11] memory facets) internal view {
        bytes32[11] memory namespaces;
        uint256[11] memory namespaceFacetIndexes;
        uint256 namespaceCount;
        for (uint256 i; i < facets.length; ++i) {
            address facet = facets[i];

            bytes32 namespace = _facetNamespace(facet);
            if (namespace == bytes32(0)) revert LaunchFacetNamespaceInvalid(i, facet);
            for (uint256 j; j < namespaceCount; ++j) {
                if (namespaces[j] == namespace) {
                    revert LaunchFacetNamespaceDuplicate(namespace, namespaceFacetIndexes[j], i);
                }
            }
            namespaces[namespaceCount] = namespace;
            namespaceFacetIndexes[namespaceCount] = i;
            ++namespaceCount;
        }
    }

    /// @dev Register standards and narrow stable interfaces. The release-wide aggregate ABI is
    /// intentionally not an ERC-165 claim because routine upgrades may change product selectors.
    function _registerInterfaces() internal {
        StandardInterfaceManifests.registerErc165();
        StandardInterfaceManifests.registerDiamondCut();
        StandardInterfaceManifests.registerDiamondLoupe();
        _registerOwnershipInterfaceManifest();
        StandardInterfaceManifests.registerErc1155Receiver();
    }

    function _registerOwnershipInterfaceManifest() private {
        bytes4[][] memory groups = new bytes4[][](1);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IERC173.owner.selector;
        selectors[1] = IERC173.transferOwnership.selector;
        groups[0] = selectors;
        LibInterfaceInvariant.registerInterface(type(IERC173).interfaceId, groups);
    }

    /// @dev Internal helper for init router.
    /// @param coreDiamond Core CYGLD controller configured for the helpers router.
    /// @param wrappedNative Wrapped native token address used for ETH routes.
    /// @param helperFeePpm Helper fee rate in parts per million.
    /// @param approvedAdapters Adapter addresses approved during helper initialization.
    function _initRouter(
        address coreDiamond,
        address wrappedNative,
        uint256 helperFeePpm,
        address[] calldata approvedAdapters
    ) internal {
        address adminFacet =
            LibDiamond.diamondStorage().facetAddressAndSelectorPosition[FacetSelectors.adminSelectors()[0]].facetAddress;
        _checkAndSetLiveLaunchFacetGeneration(adminFacet);
        bytes memory data =
            abi.encodeCall(RouterAdminFacet.initRouter, (coreDiamond, wrappedNative, helperFeePpm, approvedAdapters));
        (bool ok, bytes memory err) = adminFacet.delegatecall(data);
        if (ok) return;
        if (err.length > 0) {
            assembly {
                revert(add(err, 0x20), mload(err))
            }
        }
        revert FacetInitFailed(adminFacet, data);
    }

    /// @dev Register clean-launch facet generation one.
    /// @param facet Facet address probed or initialized by the helper.
    function _registerFacetGeneration(address facet) internal {
        _checkAndSetLiveLaunchFacetGeneration(facet);
    }
}
