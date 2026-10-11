// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {DiamondCutOwnerLiveFacet} from "../src/facets/DiamondCutOwnerLiveFacet.sol";
import {IHelpersDiamondCutMigration} from "../src/interfaces/IHelpersDiamondCutMigration.sol";
import {HelpersDiamondCutMigrationBridgeInit} from "../src/migration/HelpersDiamondCutMigrationBridgeInit.sol";
import {HelpersDiamondCutMigrationFacet} from "../src/migration/HelpersDiamondCutMigrationFacet.sol";
import {HelpersFacetRegistryRetirementInit} from "../src/migration/HelpersFacetRegistryRetirementInit.sol";
import {LibHelpersDiamondCutMigration} from "../src/migration/LibHelpersDiamondCutMigration.sol";

contract HelpersMigrationCoverageFacet {
    bytes32 public immutable FACET_NAMESPACE;
    uint64 public constant FACET_VERSION = 1;

    constructor(bytes32 namespace) {
        FACET_NAMESPACE = namespace;
    }

    function diamondCut(IDiamond.FacetCut[] calldata, address, bytes calldata) external {}
    function executeHelpersDiamondCutMigration(bytes calldata) external {}
    function arbitrarySelector() external pure {}
}

contract HelpersMigrationBridgeCoverageHarness is HelpersDiamondCutMigrationBridgeInit {
    function setContractOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function seedSelector(bytes4 selector, address owner) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.facetAddressAndSelectorPosition[selector].facetAddress = owner;
        ds.facetAddressAndSelectorPosition[selector].selectorPosition = uint16(ds.selectors.length);
        ds.selectors.push(selector);
    }

    function setSelectorOwner(bytes4 selector, address owner) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = owner;
    }

    function seedGeneration(bytes32 namespace, uint64 generation) external {
        _facetVersions().versions[namespace] = generation;
    }
}

contract HelpersMigrationFacetCoverageHarness is HelpersDiamondCutMigrationFacet {
    uint64 private _getterGeneration;

    function facetGeneration(bytes32) external view returns (uint64) {
        return _getterGeneration;
    }

    function setContractOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setGetterGeneration(uint64 generation) external {
        _getterGeneration = generation;
    }

    function setActive(bool active) external {
        _upgradeState().active = active;
    }

    function seedSelector(bytes4 selector, address owner, uint16 position) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.facetAddressAndSelectorPosition[selector].facetAddress = owner;
        ds.facetAddressAndSelectorPosition[selector].selectorPosition = position;
        ds.selectors.push(selector);
    }

    function setSelectorAt(uint256 index, bytes4 selector) external {
        LibDiamond.diamondStorage().selectors[index] = selector;
    }

    function setSelectorOwner(bytes4 selector, address owner) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = owner;
    }

    function setSelectorPosition(bytes4 selector, uint16 position) external {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].selectorPosition = position;
    }

    function seedGeneration(bytes32 namespace, uint64 generation) external {
        _facetVersions().versions[namespace] = generation;
    }

    function seedLegacy(bytes32 namespace, uint256 offset, bytes32 value) external {
        FacetVersionStore storage registry = _facetVersions();
        if (offset == 1) registry.runtimeCodeHashes[namespace] = value;
        else if (offset == 2) registry.pendingFacets[namespace] = address(uint160(uint256(value)));
        else if (offset == 3) registry.pendingVersions[namespace] = uint64(uint256(value));
        else registry.pendingRuntimeCodeHashes[namespace] = value;
    }

    function requireAuthority(address safe) external view {
        _requireAuthority(safe);
    }

    function requireCoordinator(address coordinator) external view {
        _requireCoordinator(coordinator);
    }

    function requireRuntime(address target, bytes32 expected) external view {
        _requireRuntime(target, expected);
    }

    function requireTemporarySelectorLast() external view {
        _requireTemporarySelectorLast(LibDiamond.diamondStorage());
    }

    function requireCompleteManifest(bytes32[] calldata namespaces, uint64[] calldata generations) external view {
        IHelpersDiamondCutMigration.Payload memory payload;
        payload.namespaces = namespaces;
        payload.generations = generations;
        _requireCompleteManifest(payload, LibDiamond.diamondStorage());
    }

    function requirePostflightTopology(
        bytes4[] calldata selectorsBefore,
        address[] calldata ownersBefore,
        address coordinator
    ) external view {
        _requirePostflightTopology(LibDiamond.diamondStorage(), selectorsBefore, ownersBefore, coordinator);
    }

    function requireGenerationGetter(bytes32 namespace, uint64 expected) external view {
        _requireGenerationGetter(namespace, expected);
    }

    function requireRetiredRegistry(
        bytes32[] calldata namespaces,
        uint64[] calldata generations,
        bool coordinatorCommitted
    ) external view {
        IHelpersDiamondCutMigration.Payload memory payload;
        payload.namespaces = namespaces;
        payload.generations = generations;
        _requireRetiredRegistry(payload, coordinatorCommitted);
    }

    function armMigrationFor(bytes calldata payloadData, address caller) external {
        bytes32 commitment = keccak256(
            abi.encode(
                keccak256("CYBERGOLD_HELPERS_DIAMOND_CUT_MIGRATION_V1"),
                block.chainid,
                address(this),
                caller,
                keccak256(payloadData)
            )
        );
        bytes32 slot = keccak256("cybergold.helpers.diamond-cut-migration.transient.commitment");
        assembly {
            tstore(slot, commitment)
        }
    }
}

contract HelpersMigrationRetirementCoverageHarness is HelpersFacetRegistryRetirementInit {
    function seedGeneration(bytes32 namespace, uint64 generation) external {
        _facetVersions().versions[namespace] = generation;
    }

    function seedLegacy(bytes32 namespace, uint256 offset, bytes32 value) external {
        FacetVersionStore storage registry = _facetVersions();
        if (offset == 1) registry.runtimeCodeHashes[namespace] = value;
        else if (offset == 2) registry.pendingFacets[namespace] = address(uint160(uint256(value)));
        else if (offset == 3) registry.pendingVersions[namespace] = uint64(uint256(value));
        else registry.pendingRuntimeCodeHashes[namespace] = value;
    }

    function requireRetiredEntries(bytes32[] calldata namespaces, uint64[] calldata generations) external view {
        _requireRetiredEntries(namespaces, generations);
    }

    function requireLegacyRootsZero() external view {
        _requireLegacyRootsZero();
    }
}

contract HelpersMigrationRetirementCallHarness is FacetVersionRegistry {
    function seedGeneration(bytes32 namespace, uint64 generation) external {
        _facetVersions().versions[namespace] = generation;
    }

    function execute(address initializer, bytes calldata data) external {
        LibHelpersDiamondCutMigration.armRetirement(LibHelpersDiamondCutMigration.retirementCommitment(data));
        (bool ok, bytes memory reason) = initializer.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}

contract HelpersMigrationLibraryCoverageHarness {
    function seedSelector(bytes4 selector, address owner) external {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.facetAddressAndSelectorPosition[selector].facetAddress = owner;
        ds.facetAddressAndSelectorPosition[selector].selectorPosition = uint16(ds.selectors.length);
        ds.selectors.push(selector);
    }

    function topologyHashWithout(bytes4 selector) external view returns (bytes32) {
        return LibHelpersDiamondCutMigration.topologyHashWithout(selector);
    }

    function facetNamespace(address facet) external view returns (bytes32) {
        return LibHelpersDiamondCutMigration.facetNamespace(facet);
    }

    function requireOnlySelector(address facet, bytes4 selector) external view {
        LibHelpersDiamondCutMigration.requireOnlySelector(facet, selector);
    }

    function requireLiveCoordinatorSelectors(address facet) external view {
        LibHelpersDiamondCutMigration.requireLiveCoordinatorSelectors(facet);
    }

    function consumeRetirement(bytes32 commitment) external {
        LibHelpersDiamondCutMigration.consumeRetirement(commitment);
    }
}

contract HelpersDiamondCutMigrationCoverageTest is Test {
    bytes32 private constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.owner");
    bytes32 private constant MIGRATION_NAMESPACE = keccak256("cybergold.helpers.diamond-cut-migration");
    bytes4 private constant MIGRATION_SELECTOR = bytes4(keccak256("executeHelpersDiamondCutMigration(bytes)"));
    bytes4 private constant GENERATION_SELECTOR = bytes4(keccak256("facetGeneration(bytes32)"));
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");
    bytes32 private constant CANONICAL_LIVE_COORDINATOR_CODE_HASH =
        0x3879803540004ef762c8e7398c0824f87b8c6340862dce07e1ccf72af36e9bec;

    function testBridgeRejectsEveryAuthenticatedInputMismatch() public {
        (
            HelpersMigrationBridgeCoverageHarness harness,
            HelpersMigrationCoverageFacet oldCoordinator,
            HelpersMigrationCoverageFacet newCoordinator,
            HelpersMigrationCoverageFacet migration,
            HelpersMigrationCoverageFacet retirement,
            IHelpersDiamondCutMigration.Payload memory payload
        ) = _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);

        payload.safe = address(0xBEEF);
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        harness.setContractOwner(address(0xBEEF));
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        payload.namespaces = new bytes32[](0);
        payload.generations = new uint64[](0);
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(retirement), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        payload.oldCoordinator = address(newCoordinator);
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        payload.newCoordinatorCodeHash = bytes32(0);
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(keccak256("wrong.coordinator"), MIGRATION_NAMESPACE);
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        harness.setSelectorOwner(MIGRATION_SELECTOR, address(retirement));
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, bytes32(0));
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        harness.seedGeneration(COORDINATOR_NAMESPACE, 2);
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));

        (harness, oldCoordinator, newCoordinator, migration, retirement, payload) =
            _bridgeFixture(COORDINATOR_NAMESPACE, MIGRATION_NAMESPACE);
        payload.baselineTopologyHash = bytes32(uint256(payload.baselineTopologyHash) ^ 1);
        vm.expectRevert();
        harness.armHelpersDiamondCutMigration(address(migration), abi.encode(payload));
    }

    function testMigrationPrimitiveGuardsAndTopLevelEarlyBranches() public {
        HelpersMigrationFacetCoverageHarness harness = new HelpersMigrationFacetCoverageHarness();
        vm.expectRevert();
        harness.requireAuthority(address(0xBEEF));

        vm.expectRevert();
        harness.requireAuthority(address(this));

        HelpersMigrationCoverageFacet wrongNamespace = new HelpersMigrationCoverageFacet(keccak256("wrong.namespace"));
        vm.expectRevert();
        harness.requireCoordinator(address(wrongNamespace));

        vm.expectRevert();
        harness.requireRuntime(address(0), bytes32(0));

        harness.setContractOwner(address(this));
        IHelpersDiamondCutMigration.Payload memory payload;
        payload.safe = address(this);
        bytes memory payloadData = abi.encode(payload);
        harness.armMigrationFor(payloadData, address(this));
        harness.setActive(true);
        vm.expectRevert();
        harness.executeHelpersDiamondCutMigration(payloadData);

        harness = new HelpersMigrationFacetCoverageHarness();
        harness.setContractOwner(address(this));
        payload.safe = address(this);
        payload.migrationFacet = address(0xCAFE);
        payloadData = abi.encode(payload);
        harness.armMigrationFor(payloadData, address(this));
        vm.expectRevert();
        harness.executeHelpersDiamondCutMigration(payloadData);
    }

    function testTopLevelRejectsChangedCoordinatorOwnerAndTopology() public {
        (HelpersMigrationFacetCoverageHarness harness, bytes memory payloadData) = _topLevelFixture(true, false);
        vm.expectRevert();
        harness.executeHelpersDiamondCutMigration(payloadData);

        (harness, payloadData) = _topLevelFixture(false, true);
        vm.expectRevert();
        harness.executeHelpersDiamondCutMigration(payloadData);
    }

    function testManifestValidationRejectsEveryDefensiveStateMismatch() public {
        HelpersMigrationFacetCoverageHarness harness = new HelpersMigrationFacetCoverageHarness();
        vm.expectRevert();
        harness.requireCompleteManifest(new bytes32[](0), new uint64[](0));

        bytes32[] memory namespaces = new bytes32[](1);
        uint64[] memory generations = new uint64[](0);
        namespaces[0] = bytes32(uint256(1));
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new HelpersMigrationFacetCoverageHarness();
        namespaces = new bytes32[](2);
        generations = new uint64[](2);
        namespaces[0] = bytes32(uint256(2));
        namespaces[1] = bytes32(uint256(1));
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new HelpersMigrationFacetCoverageHarness();
        HelpersMigrationCoverageFacet zeroNamespace = new HelpersMigrationCoverageFacet(bytes32(0));
        harness.seedSelector(bytes4(0x11111111), address(zeroNamespace), 0);
        namespaces = new bytes32[](1);
        generations = new uint64[](1);
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new HelpersMigrationFacetCoverageHarness();
        bytes32 duplicateNamespace = bytes32(uint256(3));
        HelpersMigrationCoverageFacet first = new HelpersMigrationCoverageFacet(duplicateNamespace);
        HelpersMigrationCoverageFacet second = new HelpersMigrationCoverageFacet(duplicateNamespace);
        harness.seedSelector(bytes4(0x11111111), address(first), 0);
        harness.seedSelector(bytes4(0x22222222), address(second), 1);
        harness.seedGeneration(duplicateNamespace, 1);
        namespaces[0] = duplicateNamespace;
        generations[0] = 1;
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new HelpersMigrationFacetCoverageHarness();
        bytes32 generationNamespace = bytes32(uint256(4));
        HelpersMigrationCoverageFacet generationFacet = new HelpersMigrationCoverageFacet(generationNamespace);
        harness.seedSelector(bytes4(0x11111111), address(generationFacet), 0);
        harness.seedGeneration(generationNamespace, 2);
        namespaces[0] = generationNamespace;
        generations[0] = 1;
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new HelpersMigrationFacetCoverageHarness();
        bytes32 installedNamespace = bytes32(uint256(5));
        HelpersMigrationCoverageFacet installed = new HelpersMigrationCoverageFacet(installedNamespace);
        harness.seedSelector(bytes4(0x11111111), address(installed), 0);
        harness.seedGeneration(installedNamespace, 1);
        namespaces = new bytes32[](2);
        generations = new uint64[](2);
        namespaces[0] = installedNamespace;
        namespaces[1] = bytes32(uint256(6));
        generations[0] = 1;
        generations[1] = 1;
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);

        harness = new HelpersMigrationFacetCoverageHarness();
        installedNamespace = bytes32(uint256(7));
        installed = new HelpersMigrationCoverageFacet(installedNamespace);
        harness.seedSelector(bytes4(0x11111111), address(installed), 0);
        namespaces = new bytes32[](1);
        generations = new uint64[](1);
        namespaces[0] = bytes32(uint256(8));
        generations[0] = 1;
        vm.expectRevert();
        harness.requireCompleteManifest(namespaces, generations);
    }

    function testTemporarySelectorAndEveryPostflightTopologyGuard() public {
        HelpersMigrationFacetCoverageHarness harness = new HelpersMigrationFacetCoverageHarness();
        harness.seedSelector(MIGRATION_SELECTOR, address(harness), 1);
        vm.expectRevert();
        harness.requireTemporarySelectorLast();

        bytes4 baselineSelector = bytes4(0x11111111);
        address baselineOwner = address(0xA11CE);
        address coordinator = address(0xC001);
        bytes4[] memory beforeSelectors = new bytes4[](1);
        address[] memory beforeOwners = new address[](1);
        beforeSelectors[0] = MIGRATION_SELECTOR;
        beforeOwners[0] = address(harness);
        harness = new HelpersMigrationFacetCoverageHarness();
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        beforeSelectors = new bytes4[](2);
        beforeOwners = new address[](2);
        beforeSelectors[0] = baselineSelector;
        beforeSelectors[1] = MIGRATION_SELECTOR;
        beforeOwners[0] = baselineOwner;
        beforeOwners[1] = address(harness);

        harness = _postflightHarness(bytes4(0x22222222), baselineOwner, coordinator);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = _postflightHarness(baselineSelector, address(0xBAD), coordinator);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = _postflightHarness(baselineSelector, baselineOwner, coordinator);
        harness.setSelectorPosition(baselineSelector, 1);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        beforeSelectors = new bytes4[](1);
        beforeOwners = new address[](1);
        beforeSelectors[0] = MIGRATION_SELECTOR;
        beforeOwners[0] = address(harness);
        harness = new HelpersMigrationFacetCoverageHarness();
        harness.seedSelector(baselineSelector, coordinator, 0);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = new HelpersMigrationFacetCoverageHarness();
        harness.seedSelector(GENERATION_SELECTOR, address(0xBAD), 0);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = new HelpersMigrationFacetCoverageHarness();
        harness.seedSelector(GENERATION_SELECTOR, coordinator, 1);
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);

        harness = new HelpersMigrationFacetCoverageHarness();
        harness.seedSelector(GENERATION_SELECTOR, coordinator, 0);
        harness.setSelectorOwner(MIGRATION_SELECTOR, address(0xBAD));
        vm.expectRevert();
        harness.requirePostflightTopology(beforeSelectors, beforeOwners, coordinator);
    }

    function testGenerationGetterAndRetiredRegistryDefensiveGuards() public {
        HelpersMigrationFacetCoverageHarness harness = new HelpersMigrationFacetCoverageHarness();
        harness.setGetterGeneration(1);
        vm.expectRevert();
        harness.requireGenerationGetter(bytes32(uint256(1)), 2);

        bytes32[] memory namespaces = new bytes32[](1);
        uint64[] memory generations = new uint64[](1);
        bytes32 namespace = bytes32(uint256(11));
        namespaces[0] = namespace;
        generations[0] = 1;

        harness = new HelpersMigrationFacetCoverageHarness();
        vm.expectRevert();
        harness.requireRetiredRegistry(namespaces, generations, false);

        for (uint256 offset = 1; offset <= 4; ++offset) {
            harness = new HelpersMigrationFacetCoverageHarness();
            harness.seedGeneration(namespace, 1);
            harness.seedLegacy(namespace, offset, bytes32(uint256(1)));
            vm.expectRevert();
            harness.requireRetiredRegistry(namespaces, generations, false);
        }

        harness = new HelpersMigrationFacetCoverageHarness();
        harness.seedGeneration(namespace, 1);
        vm.store(address(harness), bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1), bytes32(uint256(1)));
        vm.expectRevert();
        harness.requireRetiredRegistry(namespaces, generations, false);

        harness = new HelpersMigrationFacetCoverageHarness();
        harness.seedGeneration(namespace, 1);
        bytes32 temporarySelectorSlot = keccak256(abi.encode(MIGRATION_SELECTOR, DIAMOND_STORAGE_POSITION));
        vm.store(address(harness), temporarySelectorSlot, bytes32(uint256(1)));
        vm.expectRevert();
        harness.requireRetiredRegistry(namespaces, generations, false);
    }

    function testRetirementInitializerAndVerificationRejectEveryMismatch() public {
        HelpersFacetRegistryRetirementInit initializer = new HelpersFacetRegistryRetirementInit();
        HelpersMigrationRetirementCallHarness caller = new HelpersMigrationRetirementCallHarness();
        bytes32[] memory namespaces = new bytes32[](0);
        uint64[] memory generations = new uint64[](0);
        bytes memory data = abi.encodeCall(
            HelpersFacetRegistryRetirementInit.retireHelpersLegacyFacetRegistry, (namespaces, generations)
        );
        vm.expectRevert();
        caller.execute(address(initializer), data);

        caller = new HelpersMigrationRetirementCallHarness();
        namespaces = new bytes32[](2);
        generations = new uint64[](2);
        namespaces[0] = bytes32(uint256(2));
        namespaces[1] = bytes32(uint256(1));
        generations[0] = 1;
        generations[1] = 1;
        caller.seedGeneration(namespaces[0], 1);
        caller.seedGeneration(namespaces[1], 1);
        data = abi.encodeCall(
            HelpersFacetRegistryRetirementInit.retireHelpersLegacyFacetRegistry, (namespaces, generations)
        );
        vm.expectRevert();
        caller.execute(address(initializer), data);

        caller = new HelpersMigrationRetirementCallHarness();
        namespaces = new bytes32[](1);
        generations = new uint64[](1);
        namespaces[0] = bytes32(uint256(3));
        generations[0] = 1;
        caller.seedGeneration(namespaces[0], 2);
        data = abi.encodeCall(
            HelpersFacetRegistryRetirementInit.retireHelpersLegacyFacetRegistry, (namespaces, generations)
        );
        vm.expectRevert();
        caller.execute(address(initializer), data);

        HelpersMigrationRetirementCoverageHarness verifier = new HelpersMigrationRetirementCoverageHarness();
        namespaces[0] = bytes32(uint256(4));
        verifier.seedGeneration(namespaces[0], 2);
        vm.expectRevert();
        verifier.requireRetiredEntries(namespaces, generations);

        for (uint256 offset = 1; offset <= 4; ++offset) {
            verifier = new HelpersMigrationRetirementCoverageHarness();
            verifier.seedGeneration(namespaces[0], 1);
            verifier.seedLegacy(namespaces[0], offset, bytes32(uint256(1)));
            vm.expectRevert();
            verifier.requireRetiredEntries(namespaces, generations);
        }

        verifier = new HelpersMigrationRetirementCoverageHarness();
        vm.store(address(verifier), bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1), bytes32(uint256(1)));
        vm.expectRevert();
        verifier.requireLegacyRootsZero();
    }

    function testLibraryRejectsEveryMalformedTopologyAndCommitment() public {
        HelpersMigrationLibraryCoverageHarness harness = new HelpersMigrationLibraryCoverageHarness();
        vm.expectRevert();
        harness.consumeRetirement(bytes32(uint256(1)));

        bytes4 selector = bytes4(0x11111111);
        harness = new HelpersMigrationLibraryCoverageHarness();
        harness.seedSelector(selector, address(0xA11CE));
        harness.seedSelector(selector, address(0xA11CE));
        vm.expectRevert();
        harness.topologyHashWithout(selector);

        harness = new HelpersMigrationLibraryCoverageHarness();
        vm.expectRevert();
        harness.facetNamespace(address(0xBEEF));

        HelpersMigrationCoverageFacet facet = new HelpersMigrationCoverageFacet(bytes32(uint256(1)));
        harness = new HelpersMigrationLibraryCoverageHarness();
        harness.seedSelector(bytes4(0x22222222), address(facet));
        vm.expectRevert();
        harness.requireOnlySelector(address(facet), selector);

        harness = new HelpersMigrationLibraryCoverageHarness();
        vm.expectRevert();
        harness.requireOnlySelector(address(facet), selector);

        harness = new HelpersMigrationLibraryCoverageHarness();
        harness.seedSelector(IDiamondCut.diamondCut.selector, address(facet));
        harness.seedSelector(GENERATION_SELECTOR, address(facet));
        harness.seedSelector(bytes4(0x33333333), address(facet));
        vm.expectRevert();
        harness.requireLiveCoordinatorSelectors(address(facet));

        harness = new HelpersMigrationLibraryCoverageHarness();
        harness.seedSelector(IDiamondCut.diamondCut.selector, address(facet));
        vm.expectRevert();
        harness.requireLiveCoordinatorSelectors(address(facet));
    }

    function _bridgeFixture(bytes32 newCoordinatorNamespace, bytes32 migrationNamespace)
        private
        returns (
            HelpersMigrationBridgeCoverageHarness harness,
            HelpersMigrationCoverageFacet oldCoordinator,
            HelpersMigrationCoverageFacet newCoordinator,
            HelpersMigrationCoverageFacet migration,
            HelpersMigrationCoverageFacet retirement,
            IHelpersDiamondCutMigration.Payload memory payload
        )
    {
        harness = new HelpersMigrationBridgeCoverageHarness();
        harness.setContractOwner(address(this));
        oldCoordinator = new HelpersMigrationCoverageFacet(COORDINATOR_NAMESPACE);
        newCoordinator = new HelpersMigrationCoverageFacet(newCoordinatorNamespace);
        migration = new HelpersMigrationCoverageFacet(migrationNamespace);
        retirement = new HelpersMigrationCoverageFacet(bytes32(uint256(99)));
        harness.seedSelector(IDiamondCut.diamondCut.selector, address(oldCoordinator));
        harness.seedSelector(MIGRATION_SELECTOR, address(migration));
        harness.seedGeneration(COORDINATOR_NAMESPACE, 1);

        bytes4[] memory baselineSelectors = new bytes4[](1);
        address[] memory baselineOwners = new address[](1);
        baselineSelectors[0] = IDiamondCut.diamondCut.selector;
        baselineOwners[0] = address(oldCoordinator);
        bytes32[] memory namespaces = new bytes32[](2);
        uint64[] memory generations = new uint64[](2);
        namespaces[0] = COORDINATOR_NAMESPACE < migrationNamespace ? COORDINATOR_NAMESPACE : migrationNamespace;
        namespaces[1] = COORDINATOR_NAMESPACE < migrationNamespace ? migrationNamespace : COORDINATOR_NAMESPACE;
        generations[0] = 1;
        generations[1] = 1;
        payload = IHelpersDiamondCutMigration.Payload({
            safe: address(this),
            oldCoordinator: address(oldCoordinator),
            oldCoordinatorCodeHash: address(oldCoordinator).codehash,
            newCoordinator: address(newCoordinator),
            newCoordinatorCodeHash: address(newCoordinator).codehash,
            migrationFacet: address(migration),
            migrationFacetCodeHash: address(migration).codehash,
            retirementInitializer: address(retirement),
            retirementInitializerCodeHash: address(retirement).codehash,
            baselineTopologyHash: keccak256(abi.encode(baselineSelectors, baselineOwners)),
            namespaces: namespaces,
            generations: generations
        });
    }

    function _postflightHarness(bytes4 baselineSelector, address baselineOwner, address coordinator)
        private
        returns (HelpersMigrationFacetCoverageHarness harness)
    {
        harness = new HelpersMigrationFacetCoverageHarness();
        harness.setContractOwner(address(this));
        harness.seedSelector(baselineSelector, baselineOwner, 0);
        harness.seedSelector(GENERATION_SELECTOR, coordinator, 1);
    }

    function _topLevelFixture(bool wrongOwner, bool wrongTopology)
        private
        returns (HelpersMigrationFacetCoverageHarness harness, bytes memory payloadData)
    {
        harness = new HelpersMigrationFacetCoverageHarness();
        harness.setContractOwner(address(this));
        HelpersMigrationCoverageFacet oldCoordinator = new HelpersMigrationCoverageFacet(COORDINATOR_NAMESPACE);
        HelpersMigrationCoverageFacet migration = new HelpersMigrationCoverageFacet(MIGRATION_NAMESPACE);
        HelpersMigrationCoverageFacet retirement = new HelpersMigrationCoverageFacet(bytes32(uint256(99)));
        DiamondCutOwnerLiveFacet newCoordinator = _deployCanonicalCoordinator();

        harness.seedSelector(
            IDiamondCut.diamondCut.selector, wrongOwner ? address(retirement) : address(oldCoordinator), 0
        );
        harness.seedSelector(MIGRATION_SELECTOR, address(migration), 1);
        harness.seedGeneration(COORDINATOR_NAMESPACE, 1);
        harness.seedGeneration(MIGRATION_NAMESPACE, 1);

        bytes4[] memory baselineSelectors = new bytes4[](1);
        address[] memory baselineOwners = new address[](1);
        baselineSelectors[0] = IDiamondCut.diamondCut.selector;
        baselineOwners[0] = address(oldCoordinator);
        bytes32 topologyHash = keccak256(abi.encode(baselineSelectors, baselineOwners));
        if (wrongTopology) topologyHash = bytes32(uint256(topologyHash) ^ 1);

        bytes32[] memory namespaces = new bytes32[](2);
        uint64[] memory generations = new uint64[](2);
        namespaces[0] = COORDINATOR_NAMESPACE < MIGRATION_NAMESPACE ? COORDINATOR_NAMESPACE : MIGRATION_NAMESPACE;
        namespaces[1] = COORDINATOR_NAMESPACE < MIGRATION_NAMESPACE ? MIGRATION_NAMESPACE : COORDINATOR_NAMESPACE;
        generations[0] = 1;
        generations[1] = 1;
        IHelpersDiamondCutMigration.Payload memory payload = IHelpersDiamondCutMigration.Payload({
            safe: address(this),
            oldCoordinator: address(oldCoordinator),
            oldCoordinatorCodeHash: address(oldCoordinator).codehash,
            newCoordinator: address(newCoordinator),
            newCoordinatorCodeHash: address(newCoordinator).codehash,
            migrationFacet: address(migration),
            migrationFacetCodeHash: address(migration).codehash,
            retirementInitializer: address(retirement),
            retirementInitializerCodeHash: address(retirement).codehash,
            baselineTopologyHash: topologyHash,
            namespaces: namespaces,
            generations: generations
        });
        payloadData = abi.encode(payload);
        harness.armMigrationFor(payloadData, address(this));
    }

    function _deployCanonicalCoordinator() private returns (DiamondCutOwnerLiveFacet coordinator) {
        coordinator = new DiamondCutOwnerLiveFacet();
        bytes memory runtime = vm.parseBytes(
            vm.trim(vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/legacy-helpers-live-coordinator.hex")))
        );
        vm.etch(address(coordinator), runtime);
        assertEq(address(coordinator).codehash, CANONICAL_LIVE_COORDINATOR_CODE_HASH);
    }
}
