// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {OneInchAdapter} from "../src/adapters/OneInchAdapter.sol";
import {UniswapUniversalAdapter} from "../src/adapters/UniswapUniversalAdapter.sol";
import {AdapterDeployer} from "../src/deploy/AdapterDeployer.sol";
import {DeployOutput} from "../src/deploy/DeployOutput.sol";
import {DeployParams} from "../src/deploy/DeployParams.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {HelpersDiamond} from "../src/diamond/HelpersDiamond.sol";
import {DiamondArgs} from "diamond-1/Diamond.sol";
import {LibRecoveryShareReceiverStorage} from "../src/diamond/LibRecoveryShareReceiverStorage.sol";
import {DiamondInit} from "../src/deploy/DiamondInit.sol";
import {DiamondLiveInit} from "../src/deploy/DiamondLiveInit.sol";
import {DiamondCutOwnerFacet} from "../src/facets/DiamondCutOwnerFacet.sol";
import {DiamondCutOwnerLiveFacet} from "../src/facets/DiamondCutOwnerLiveFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {DiamondCutFacet as BootstrapDiamondCutFacet} from "diamond-1/facets/DiamondCutFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {OwnerPausableFacet} from "../src/facets/OwnerPausableFacet.sol";
import {RouterAdminFacet} from "../src/facets/RouterAdminFacet.sol";
import {RouterIssuePreviewFacet} from "../src/facets/RouterIssuePreviewFacet.sol";
import {RouterIssueFacet} from "../src/facets/RouterIssueFacet.sol";
import {RouterIssueBasketFacet} from "../src/facets/RouterIssueBasketFacet.sol";
import {RouterRedeemFacet} from "../src/facets/RouterRedeemFacet.sol";
import {RouterRedeemBasketFacet} from "../src/facets/RouterRedeemBasketFacet.sol";
import {RecoveryShareReceiverFacet} from "../src/facets/RecoveryShareReceiverFacet.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {BaseDiamondHelper} from "diamond-infra/deploy/BaseDiamondHelper.sol";
import {FacetVersionRegistry} from "diamond-infra/helpers/FacetVersionRegistry.sol";
import {LiveFacetVersionRegistry} from "diamond-infra/helpers/LiveFacetVersionRegistry.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LibInterfaceInvariant} from "diamond-infra/libraries/LibInterfaceInvariant.sol";

contract NoDataRevertInitTarget {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.test.no-data-revert");
    uint64 public constant FACET_VERSION = 1;

    fallback() external payable {
        assembly {
            revert(0, 0)
        }
    }

    receive() external payable {
        assembly {
            revert(0, 0)
        }
    }
}

contract ConfigurableLaunchFacetMetadata {
    bytes32 public immutable FACET_NAMESPACE;
    uint64 public immutable FACET_VERSION;

    constructor(bytes32 namespace, uint64 version) {
        FACET_NAMESPACE = namespace;
        FACET_VERSION = version;
    }
}

contract DiamondInitHarness is DiamondInit {
    function assertSelectorManifestCount(uint256 expectedSelectorCount) external view {
        _assertSelectorManifestCount(expectedSelectorCount);
    }

    function validateLaunchFacetMetadata(address[11] calldata suppliedFacets) external view {
        address[11] memory facets = suppliedFacets;
        _validateRequiredLaunchFacets(facets);
        _validateLaunchFacetMetadata(facets);
    }

    function initRouter(address target, address[] calldata approvedAdapters) external {
        bytes4 installedSelector = 0x0ac68a1e;
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.facetAddressAndSelectorPosition[installedSelector].facetAddress = target;
        ds.selectors.push(installedSelector);
        _enterInitContext();
        _initRouter(address(0), address(0), 0, approvedAdapters);
        _exitInitContext();
    }

    function validateConfiguredFacet(uint256 facetIndex, address configured, bytes4 selector, address installed)
        external
        returns (address)
    {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = installed;
        return _configuredFacet(LibDiamond.diamondStorage(), facetIndex, configured, selector);
    }

    function validateLaunchFacetTopology(address[11] calldata suppliedFacets, bytes4 selector, address installed)
        external
    {
        address[11] memory facets = suppliedFacets;
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (selector != bytes4(0)) {
            ds.selectors.push(selector);
            ds.facetAddressAndSelectorPosition[selector].facetAddress = installed;
        }
        _validateLaunchFacetTopology(ds, facets);
    }
}

contract DiamondLiveInitHarness is DiamondLiveInit {
    function assertSelectorManifestCount(uint256 expectedSelectorCount) external view {
        _assertSelectorManifestCount(expectedSelectorCount);
    }

    function validateLaunchFacetMetadata(address[11] calldata suppliedFacets) external view {
        address[11] memory facets = suppliedFacets;
        _validateRequiredLaunchFacets(facets);
        _validateLaunchFacetMetadata(facets);
    }

    function initRouter(address target, address[] calldata approvedAdapters) external {
        bytes4 installedSelector = 0x0ac68a1e;
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.facetAddressAndSelectorPosition[installedSelector].facetAddress = target;
        ds.selectors.push(installedSelector);
        _enterInitContext();
        _initRouter(address(0), address(0), 0, approvedAdapters);
        _exitInitContext();
    }

    function validateConfiguredFacet(uint256 facetIndex, address configured, bytes4 selector, address installed)
        external
        returns (address)
    {
        LibDiamond.diamondStorage().facetAddressAndSelectorPosition[selector].facetAddress = installed;
        return _configuredFacet(LibDiamond.diamondStorage(), facetIndex, configured, selector);
    }

    function validateLaunchFacetTopology(address[11] calldata suppliedFacets, bytes4 selector, address installed)
        external
    {
        address[11] memory facets = suppliedFacets;
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        if (selector != bytes4(0)) {
            ds.selectors.push(selector);
            ds.facetAddressAndSelectorPosition[selector].facetAddress = installed;
        }
        _validateLaunchFacetTopology(ds, facets);
    }
}

contract UnexpectedShellFacet {
    function unexpectedShellSelector() external pure returns (bytes4) {
        return this.unexpectedShellSelector.selector;
    }
}

contract ShellStateTainter {
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;

    function taintPendingOwner(address pendingOwner) external {
        bytes32 slot = keccak256("cybergold.helpers.ownership.storage");
        assembly {
            sstore(slot, pendingOwner)
        }
    }

    function taintRouterCore(address coreDiamond) external {
        bytes32 slot = keccak256("cybergold.helpers.app.storage");
        assembly {
            sstore(slot, coreDiamond)
        }
    }

    function taintPause() external {
        bytes32 slot = 0xcd5ed15c6e187e77e9aee88184c21f4f2182ab5827cb3b7e07fbedcd63f03300;
        assembly {
            sstore(slot, 1)
        }
    }

    function taintFacetVersion(bytes32 namespace, uint64 version) external {
        bytes32 slot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        assembly {
            sstore(slot, version)
        }
    }

    function taintRawSlot(bytes32 slot, uint256 value) external {
        assembly {
            sstore(slot, value)
        }
    }

    function taintInterface(bytes4 interfaceId) external {
        LibDiamond.diamondStorage().supportedInterfaces[interfaceId] = true;
    }

    function taintInterfaceManifest(bytes4 interfaceId, bytes4 selector) external {
        bytes4[][] memory groups = new bytes4[][](1);
        groups[0] = new bytes4[](1);
        groups[0][0] = selector;
        LibInterfaceInvariant.registerInterface(interfaceId, groups);
    }
}

contract FinalizationSafeHarness {
    function execute(address target, bytes calldata data) external {
        (bool succeeded, bytes memory returndata) = target.call(data);
        if (!succeeded) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }
}

contract DeployLibrariesTest is Test {
    bytes32 private constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant RETIRED_REENTRANCY_GUARD_STORAGE_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    function loadDeployParamsFromEnvExternal() external view {
        DeployParams.fromEnv(vm);
    }

    function validateDeployParamsExternal(DeployParams.Params memory params) external pure {
        DeployParams.validate(params);
    }

    function deployHelpersExternal(DeploymentTypes.DeployConfig memory cfg) external {
        DeploymentHelper.deploy(cfg);
    }

    function deployHelpersShellExternal(address bootstrapOwner) external {
        DeploymentHelper.deployHelpersShell(bootstrapOwner, keccak256("helpers-shell-guard"));
    }

    function deployHelpersShellFromExternal(address bootstrapOwner, bytes32 salt, address create2Deployer)
        external
        returns (HelpersDiamond diamond, address bootstrapDiamondCutFacet)
    {
        return DeploymentHelper.deployHelpersShellFrom(bootstrapOwner, salt, create2Deployer);
    }

    function finalizeExistingExternal(HelpersDiamond diamond, DeploymentTypes.DeployConfig memory cfg) external {
        DeploymentHelper.finalizeExisting(diamond, cfg);
    }

    function prepareExistingFinalizationExternal(HelpersDiamond diamond, DeploymentTypes.DeployConfig memory cfg)
        external
        returns (bytes memory finalizationCalldata)
    {
        (, finalizationCalldata) = DeploymentHelper.prepareExistingFinalization(diamond, cfg);
    }

    function executeFinalizationExternal(address diamond, bytes calldata finalizationCalldata) external {
        (bool succeeded, bytes memory returndata) = diamond.call(finalizationCalldata);
        if (!succeeded) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

    function deployAdaptersExternal(DeployParams.Params memory params, address helpersDiamond) external {
        AdapterDeployer.deploy(params, helpersDiamond);
    }

    function testAdapterDeployerDeploysConfiguredRoutersAndAppliesConfig() public {
        DeployParams.Params memory params;
        params.permit2 = address(0x2222);
        params.oneInchRouter = address(0x1111);
        params.uniswapRouter = address(0x3333);

        AdapterDeployer.AdapterDeployment memory adapters = AdapterDeployer.deploy(params, address(this));
        assertEq(OneInchAdapter(payable(adapters.oneInchAdapter)).AGGREGATION_ROUTER(), params.oneInchRouter);
        assertEq(UniswapUniversalAdapter(payable(adapters.uniswapAdapter)).UNIVERSAL_ROUTER(), params.uniswapRouter);
        assertEq(UniswapUniversalAdapter(payable(adapters.uniswapAdapter)).PERMIT2(), params.permit2);

        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(0xABCD);
        cfg = AdapterDeployer.applyToConfig(cfg, adapters);

        assertEq(cfg.admin, address(0xABCD));
        assertEq(cfg.approvedAdapters.length, 2);
        assertEq(cfg.approvedAdapters[0], adapters.oneInchAdapter);
        assertEq(cfg.approvedAdapters[1], adapters.uniswapAdapter);
        assertEq(OneInchAdapter(payable(adapters.oneInchAdapter)).helpersDiamond(), address(this));
        assertEq(UniswapUniversalAdapter(payable(adapters.uniswapAdapter)).helpersDiamond(), address(this));
    }

    function testShellAdaptersFinalizeInImmutableAuthorityOrder() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-adapter-order"));

        DeployParams.Params memory params;
        params.permit2 = address(0x2222);
        params.oneInchRouter = address(0x1111);
        params.uniswapRouter = address(0x3333);
        AdapterDeployer.AdapterDeployment memory adapters = AdapterDeployer.deploy(params, address(shell));

        DeploymentTypes.DeployConfig memory cfg = _shellConfig();
        cfg = AdapterDeployer.applyToConfig(cfg, adapters);
        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.finalizeExisting(shell, cfg);

        assertEq(address(deployed.diamond), address(shell));
        assertEq(OneInchAdapter(payable(adapters.oneInchAdapter)).helpersDiamond(), address(shell));
        assertEq(UniswapUniversalAdapter(payable(adapters.uniswapAdapter)).helpersDiamond(), address(shell));
        assertEq(UniswapUniversalAdapter(payable(adapters.uniswapAdapter)).PERMIT2(), cfg.permit2);
        assertTrue(RouterAdminFacet(address(shell)).isAdapterApproved(adapters.oneInchAdapter));
        assertTrue(RouterAdminFacet(address(shell)).isAdapterApproved(adapters.uniswapAdapter));
    }

    function testFinalizeExistingReusesAnExactAuditedFacetRuntime() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-reuse-exact-runtime"));
        ProtocolDiamondLoupeFacet retainedLoupe = new ProtocolDiamondLoupeFacet();
        DeploymentTypes.DeployConfig memory cfg = _shellConfig();
        cfg.facetOverrides.loupe = DeploymentTypes.FacetOverride({
            facet: address(retainedLoupe), runtimeCodeHash: address(retainedLoupe).codehash
        });

        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.finalizeExisting(shell, cfg);

        assertEq(address(deployed.facets.loupe), address(retainedLoupe));
        assertEq(IDiamondLoupe(address(shell)).facetAddress(IDiamondLoupe.facets.selector), address(retainedLoupe));
    }

    function testFinalizeExistingReusesAnExactImmutableBoundRouterFacet() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-reuse-immutable-router"));
        DeploymentTypes.DeployConfig memory cfg = _shellConfig();
        RouterAdminFacet retainedAdmin = new RouterAdminFacet(cfg.permit2);
        cfg.facetOverrides.admin = DeploymentTypes.FacetOverride({
            facet: address(retainedAdmin), runtimeCodeHash: address(retainedAdmin).codehash
        });

        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.finalizeExisting(shell, cfg);

        assertEq(address(deployed.facets.admin), address(retainedAdmin));
        assertEq(RouterAdminFacet(address(shell)).permit2(), cfg.permit2);
    }

    function testFinalizeExistingRejectsMismatchedReusedFacetRuntime() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-reuse-runtime-mismatch"));
        DeploymentTypes.DeployConfig memory cfg = _shellConfig();
        cfg.facetOverrides.loupe = DeploymentTypes.FacetOverride({
            facet: address(new ProtocolDiamondLoupeFacet()), runtimeCodeHash: bytes32(uint256(1))
        });

        vm.expectRevert(bytes("DeploymentHelper: loupe runtime mismatch"));
        this.finalizeExistingExternal(shell, cfg);
    }

    function testFinalizeExistingRejectsFacetOverrideWithoutCodehash() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-reuse-missing-codehash"));
        DeploymentTypes.DeployConfig memory cfg = _shellConfig();
        cfg.facetOverrides.loupe = DeploymentTypes.FacetOverride({
            facet: address(new ProtocolDiamondLoupeFacet()), runtimeCodeHash: bytes32(0)
        });

        vm.expectRevert(bytes("DeploymentHelper: override codehash missing"));
        this.finalizeExistingExternal(shell, cfg);
    }

    function testFinalizeExistingRejectsCodehashWithoutFacetOverride() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-reuse-empty-override"));
        DeploymentTypes.DeployConfig memory cfg = _shellConfig();
        cfg.facetOverrides.loupe.runtimeCodeHash = bytes32(uint256(1));

        vm.expectRevert(bytes("DeploymentHelper: unused override has codehash"));
        this.finalizeExistingExternal(shell, cfg);
    }

    function _assertDeployParamsFacetReuseEvidence() private {
        _resetDeployParamsEnvironment();
        ProtocolDiamondLoupeFacet retainedLoupe = new ProtocolDiamondLoupeFacet();
        string memory evidence = string.concat(
            '{"schemaVersion":"1.0","kind":"cybergold-facet-reuse-evidence","execution":"not-performed","scope":"helpers","chainId":',
            vm.toString(block.chainid),
            ',"releaseManifest":{"id":"helpers-test-release","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"overrides":{"loupe":{"address":"',
            vm.toString(address(retainedLoupe)),
            '","runtimeCodehash":"',
            vm.toString(address(retainedLoupe).codehash),
            '"}}}'
        );
        string memory path = string.concat(vm.projectRoot(), "/out/test-facet-reuse-evidence.json");
        vm.writeFile(path, evidence);
        vm.setEnv("HELPERS_FACET_REUSE_EVIDENCE_PATH", path);

        DeployParams.Params memory params = DeployParams.fromEnv(vm);
        assertEq(params.facetOverrides.loupe.facet, address(retainedLoupe));
        assertEq(params.facetOverrides.loupe.runtimeCodeHash, address(retainedLoupe).codehash);
        assertEq(params.facetOverrides.cut.facet, address(0));
        _setStrictRuntimeIdentityEnvironment();
        vm.setEnv("RELEASE_MANIFEST_ID", "different-release");
        vm.expectRevert(bytes("DeployParams: facet reuse release ID mismatch"));
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        vm.setEnv(
            "HELPERS_FACET_REUSE_EVIDENCE_PATH",
            _writeFacetReuseEvidence(
                "facet-reuse-invalid-kind",
                "wrong-kind",
                "helpers",
                block.chainid,
                "helpers-test-release",
                _testReleaseHash(),
                address(retainedLoupe),
                address(retainedLoupe).codehash
            )
        );
        vm.expectRevert(bytes("DeployParams: invalid facet reuse evidence"));
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        vm.setEnv(
            "HELPERS_FACET_REUSE_EVIDENCE_PATH",
            _writeFacetReuseEvidence(
                "facet-reuse-invalid-scope",
                "cybergold-facet-reuse-evidence",
                "core",
                block.chainid,
                "helpers-test-release",
                _testReleaseHash(),
                address(retainedLoupe),
                address(retainedLoupe).codehash
            )
        );
        vm.expectRevert(bytes("DeployParams: facet reuse scope mismatch"));
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        vm.setEnv(
            "HELPERS_FACET_REUSE_EVIDENCE_PATH",
            _writeFacetReuseEvidence(
                "facet-reuse-invalid-chain",
                "cybergold-facet-reuse-evidence",
                "helpers",
                block.chainid + 1,
                "helpers-test-release",
                _testReleaseHash(),
                address(retainedLoupe),
                address(retainedLoupe).codehash
            )
        );
        vm.expectRevert(bytes("DeployParams: facet reuse chain mismatch"));
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        vm.setEnv(
            "HELPERS_FACET_REUSE_EVIDENCE_PATH",
            _writeFacetReuseEvidence(
                "facet-reuse-strict-ok",
                "cybergold-facet-reuse-evidence",
                "helpers",
                block.chainid,
                "helpers-test-release",
                _testReleaseHash(),
                address(retainedLoupe),
                address(retainedLoupe).codehash
            )
        );
        DeployParams.fromEnv(vm);

        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        vm.setEnv(
            "HELPERS_FACET_REUSE_EVIDENCE_PATH",
            _writeFacetReuseEvidence(
                "facet-reuse-invalid-release-hash",
                "cybergold-facet-reuse-evidence",
                "helpers",
                block.chainid,
                "helpers-test-release",
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                address(retainedLoupe),
                address(retainedLoupe).codehash
            )
        );
        vm.expectRevert(bytes("DeployParams: facet reuse release hash mismatch"));
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        vm.setEnv(
            "HELPERS_FACET_REUSE_EVIDENCE_PATH",
            _writeFacetReuseEvidence(
                "facet-reuse-zero-address",
                "cybergold-facet-reuse-evidence",
                "helpers",
                block.chainid,
                "helpers-test-release",
                _testReleaseHash(),
                address(0),
                address(retainedLoupe).codehash
            )
        );
        vm.expectRevert(bytes("DeployParams: facet reuse address missing"));
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        vm.setEnv(
            "HELPERS_FACET_REUSE_EVIDENCE_PATH",
            _writeFacetReuseEvidence(
                "facet-reuse-zero-codehash",
                "cybergold-facet-reuse-evidence",
                "helpers",
                block.chainid,
                "helpers-test-release",
                _testReleaseHash(),
                address(retainedLoupe),
                bytes32(0)
            )
        );
        vm.expectRevert(bytes("DeployParams: facet reuse codehash missing"));
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
    }

    function testAdapterDeployerRejectsMissingHelpersShell() public {
        DeployParams.Params memory params;
        params.permit2 = address(0x2222);
        params.oneInchRouter = address(0x1111);
        params.uniswapRouter = address(0x3333);

        vm.expectRevert(bytes("AdapterDeployer: Helpers diamond missing"));
        this.deployAdaptersExternal(params, address(0));
    }

    function testDeployParamsFromEnvPreflightsDependenciesAndIdentity() public {
        _assertDeployParamsHappyPath();
        _assertDeployParamsPolicyAndManifestFailures();
        _assertDeployParamsRuntimeIdentityFailures();
        _assertDeployParamsProxyIdentityFailures();
        _assertDeployParamsFacetReuseEvidence();
    }

    function testDeployParamsRejectsZeroRequiredAddress() public {
        DeployParams.Params memory params;
        params.admin = address(0xA11CE);
        params.coreDiamond = address(0xC1);
        params.oneInchRouter = address(0x11);
        params.uniswapRouter = address(0x33);
        params.wrappedNative = address(0xE1);

        vm.expectRevert(bytes("PERMIT2_ADDR must be provided"));
        this.validateDeployParamsExternal(params);
    }

    function _assertDeployParamsHappyPath() private {
        _resetDeployParamsEnvironment();
        DeployParams.Params memory params = DeployParams.fromEnv(vm);
        assertEq(params.admin, address(0xA1));
        assertEq(params.helperFeePpm, 250);
        assertEq(params.coreDiamond, address(0xC1));
        assertEq(params.permit2, address(0xC2));
        assertEq(params.oneInchRouter, address(0x1111));
        assertEq(params.uniswapRouter, address(0x3333));
        assertEq(params.wrappedNative, address(0xE1));

        DeploymentTypes.DeployConfig memory cfg = DeployParams.toConfig(params);
        assertEq(cfg.admin, params.admin);
        assertEq(cfg.coreDiamond, params.coreDiamond);
        assertEq(cfg.permit2, params.permit2);
        assertEq(cfg.wrappedNative, params.wrappedNative);
        assertEq(cfg.helperFeePpm, params.helperFeePpm);

        // Local rehearsals may explicitly select the current-chain default.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CHAIN_ID", "0");
        DeployParams.fromEnv(vm);

        _resetDeployParamsEnvironment();
        // This removes only Core code so the first dependency check fails deterministically.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.etch(address(0xC1), hex"");
        vm.expectRevert("DeployParams: CORE has no bytecode");
        this.loadDeployParamsFromEnvExternal();
    }

    function _assertDeployParamsPolicyAndManifestFailures() private {
        _resetDeployParamsEnvironment();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HELPERS_IDENTITY_POLICY", "unreviewed-policy");
        vm.expectRevert("DeployParams: unsupported identity policy");
        this.loadDeployParamsFromEnvExternal();

        uint256 originalChainId = block.chainid;
        // Mainnet deployment must consume the sealed dependency-identity policy.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.chainId(1);
        _resetDeployParamsEnvironment();
        vm.expectRevert("DeployParams: strict identity policy required on mainnet");
        this.loadDeployParamsFromEnvExternal();
        _setStrictRuntimeIdentityEnvironment();
        DeployParams.fromEnv(vm);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.chainId(originalChainId);

        _resetDeployParamsEnvironment();
        // Zero is the explicit missing-value sentinel for a sealed identity manifest.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HELPERS_IDENTITY_POLICY", "strict-proxy-codehash-v1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CHAIN_ID", "0");
        vm.expectRevert("DeployParams: expected chain ID missing");
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        DeployParams.fromEnv(vm);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid + 1));
        vm.expectRevert("DeployParams: chain ID mismatch");
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("RELEASE_MANIFEST_ID", "");
        vm.expectRevert("DeployParams: release manifest ID missing");
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("RELEASE_MANIFEST_SHA256", "abc");
        vm.expectRevert("DeployParams: release manifest SHA-256 missing");
        this.loadDeployParamsFromEnvExternal();
    }

    function _assertDeployParamsRuntimeIdentityFailures() private {
        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CORE_CODEHASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert("DeployParams: CORE codehash mismatch");
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        // The Core identity manifest may classify the diamond separately from plain runtime code.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CORE_KIND", "diamond");
        DeployParams.fromEnv(vm);

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CORE_KIND", "unsupported");
        vm.expectRevert("DeployParams: CORE unsupported identity kind");
        this.loadDeployParamsFromEnvExternal();

        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.store(address(0xC1), EIP1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(0x4444)))));
        vm.expectRevert("DeployParams: CORE undeclared proxy");
        this.loadDeployParamsFromEnvExternal();
    }

    function _assertDeployParamsProxyIdentityFailures() private {
        address implementation = address(0x4444);
        _resetDeployParamsEnvironment();
        _setStrictRuntimeIdentityEnvironment();
        // Test-only runtime and storage model an EIP-1967 dependency.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.etch(implementation, hex"00");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.store(address(0xC1), EIP1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(implementation))));
        _setProxyIdentity("CORE", address(0xC1), implementation);
        DeployParams.fromEnv(vm);

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CORE_IMPLEMENTATION", vm.toString(address(0x5555)));
        vm.expectRevert("DeployParams: CORE implementation mismatch");
        this.loadDeployParamsFromEnvExternal();

        _setProxyIdentity("CORE", address(0xC1), implementation);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CORE_IMPLEMENTATION_CODEHASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert("DeployParams: CORE implementation codehash mismatch");
        this.loadDeployParamsFromEnvExternal();

        address missingImplementation = address(0x5555);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.store(address(0xC1), EIP1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(missingImplementation))));
        _setProxyIdentity("CORE", address(0xC1), missingImplementation);
        vm.expectRevert("DeployParams: CORE implementation has no bytecode");
        this.loadDeployParamsFromEnvExternal();

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.store(
            address(0xC1), EIP1967_IMPLEMENTATION_SLOT, bytes32((uint256(1) << 200) | uint256(uint160(implementation)))
        );
        _setProxyIdentity("CORE", address(0xC1), implementation);
        vm.expectRevert("DeployParams: CORE malformed implementation slot");
        this.loadDeployParamsFromEnvExternal();
    }

    function _resetDeployParamsEnvironment() private {
        _setDeployParamValues();
        _installConfiguredDependencyCode();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.store(address(0xC1), EIP1967_IMPLEMENTATION_SLOT, bytes32(0));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HELPERS_IDENTITY_POLICY", "local-unsealed");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("RELEASE_MANIFEST_ID", "helpers-test-release");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("RELEASE_MANIFEST_SHA256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        // A missing reuse-evidence path is the fresh-facet default; do not let
        // a preceding evidence-negative test influence another test case.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HELPERS_FACET_REUSE_EVIDENCE_PATH", "");
        _setRuntimeIdentity("CORE", address(0xC1));
        _setRuntimeIdentity("PERMIT2", address(0xC2));
        _setRuntimeIdentity("WETH", address(0xE1));
        _setRuntimeIdentity("ONEINCH_ROUTER", address(0x1111));
        _setRuntimeIdentity("UNISWAP_ROUTER", address(0x3333));
    }

    function _testReleaseHash() private pure returns (string memory) {
        return "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    }

    function _writeFacetReuseEvidence(
        string memory name,
        string memory kind,
        string memory scope,
        uint256 chainId,
        string memory releaseId,
        string memory releaseHash,
        address facet,
        bytes32 runtimeCodeHash
    ) private returns (string memory path) {
        string memory evidence = string.concat(
            '{"schemaVersion":"1.0","kind":"',
            kind,
            '","scope":"',
            scope,
            '","chainId":',
            vm.toString(chainId),
            ',"releaseManifest":{"id":"',
            releaseId,
            '","sha256":"',
            releaseHash,
            '"},"overrides":{"loupe":{"address":"',
            vm.toString(facet),
            '","runtimeCodehash":"',
            vm.toString(runtimeCodeHash),
            '"}}}'
        );
        path = string.concat(vm.projectRoot(), "/out/test-", name, ".json");
        vm.writeFile(path, evidence);
    }

    function _setDeployParamValues() private {
        // Environment mutations are required to exercise deployment parameter parsing.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HELPER_ADMIN", "0x00000000000000000000000000000000000000a1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HELPER_FEE_PPM", "250");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("CORE_DIAMOND_ADDRESS", "0x00000000000000000000000000000000000000c1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("PERMIT2_ADDR", "0x00000000000000000000000000000000000000c2");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("ONEINCH_ROUTER", "0x0000000000000000000000000000000000001111");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("UNISWAP_ROUTER", "0x0000000000000000000000000000000000003333");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("WETH_ADDR", "0x00000000000000000000000000000000000000e1");
    }

    function _installConfiguredDependencyCode() private {
        // Test-only bytecode stands in for live dependencies during read-only preflight.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.etch(address(0xC1), hex"00");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.etch(address(0xC2), hex"00");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.etch(address(0xE1), hex"00");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.etch(address(0x1111), hex"00");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.etch(address(0x3333), hex"00");
    }

    function _setRuntimeIdentity(string memory label, address target) private {
        // Environment mutations construct the strict release identity expected by the preflight.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_KIND"), "runtime");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_CODEHASH"), vm.toString(target.codehash));
    }

    function _setStrictRuntimeIdentityEnvironment() private {
        // Environment mutations model the sealed release identity manifest consumed before broadcast.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HELPERS_IDENTITY_POLICY", "strict-proxy-codehash-v1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("RELEASE_MANIFEST_ID", "helpers-test-release");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("RELEASE_MANIFEST_SHA256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        _setRuntimeIdentity("CORE", address(0xC1));
        _setRuntimeIdentity("PERMIT2", address(0xC2));
        _setRuntimeIdentity("WETH", address(0xE1));
        _setRuntimeIdentity("ONEINCH_ROUTER", address(0x1111));
        _setRuntimeIdentity("UNISWAP_ROUTER", address(0x3333));
    }

    function _setProxyIdentity(string memory label, address proxy, address implementation) private {
        // Environment mutations construct an expected EIP-1967 identity.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_KIND"), "eip1967-proxy");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_CODEHASH"), vm.toString(proxy.codehash));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_IMPLEMENTATION"), vm.toString(implementation));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_IMPLEMENTATION_CODEHASH"), vm.toString(implementation.codehash));
    }

    function testDeployParamsWriteJsonSerializesArtifactsAdaptersAndFacets() public {
        DeployParams.Params memory params;
        params.admin = address(0xA11CE);
        params.helperFeePpm = 321;
        params.coreDiamond = address(0xC0FFEE);
        params.permit2 = address(0x2222);
        params.wrappedNative = address(0xE7);
        params.oneInchRouter = address(0x1111);
        params.uniswapRouter = address(0x3333);

        DeploymentTypes.DeployConfig memory cfg = DeployParams.toConfig(params);
        DeploymentTypes.DeployArtifacts memory art;
        art.diamond = HelpersDiamond(payable(address(0xD1A)));
        art.diamondInit = DiamondLiveInit(address(0xD17));
        art.facets.cut = DiamondCutOwnerLiveFacet(address(0xC07));
        art.facets.loupe = ProtocolDiamondLoupeFacet(address(0x10A));
        art.facets.ownership = OwnershipFacet(address(0x0A11));
        art.facets.pause = OwnerPausableFacet(address(0x0AA5E));
        art.facets.admin = RouterAdminFacet(address(0xAD));
        art.facets.issuePreview = RouterIssuePreviewFacet(address(0x15EE));
        art.facets.issue = RouterIssueFacet(address(0x155E));
        art.facets.issueBasket = RouterIssueBasketFacet(address(0x155EB));
        art.facets.redeem = RouterRedeemFacet(address(0x0EDE));
        art.facets.redeemBasket = RouterRedeemBasketFacet(address(0x0EDEB));
        art.facets.recoveryShareReceiver = RecoveryShareReceiverFacet(address(0x0EC2));

        string memory path = string.concat(vm.projectRoot(), "/out/test-deploy-helpers-write-json.json");
        DeployParams.writeJson(vm, cfg, art, params, address(0x1A), address(0x3C), path);
        // Reading the generated deployment artifact is the behavior under test.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory written = vm.readFile(path);

        assertEq(vm.parseJsonAddress(written, ".diamond"), address(0xD1A));
        assertEq(vm.parseJsonAddress(written, ".diamondInit"), address(0xD17));
        assertEq(vm.parseJsonAddress(written, ".coreDiamond"), params.coreDiamond);
        assertEq(vm.parseJsonUint(written, ".helperFeePpm"), params.helperFeePpm);
        assertEq(vm.parseJsonAddress(written, ".oneInchAdapter"), address(0x1A));
        assertEq(vm.parseJsonAddress(written, ".uniswapAdapter"), address(0x3C));
        assertEq(vm.parseJsonUint(written, ".approvedAdapterCount"), 2);
        assertEq(
            vm.parseJsonBytes32(written, ".approvedAdapterSetHash"), keccak256(abi.encode(address(0x1A), address(0x3C)))
        );
        assertEq(vm.parseJsonAddress(written, ".[\"facet.recoveryShareReceiver\"]"), address(0x0EC2));
        assertFalse(vm.keyExistsJson(written, ".[\"facet.reentrancy\"]"));
    }

    function testDeploymentFacetSpecsAreCanonicalForCutAndArtifacts() public pure {
        DeploymentTypes.DeployArtifacts memory art;
        art.facets.cut = DiamondCutOwnerLiveFacet(address(0xC07));
        art.facets.loupe = ProtocolDiamondLoupeFacet(address(0x10A));
        art.facets.ownership = OwnershipFacet(address(0x0A11));
        art.facets.pause = OwnerPausableFacet(address(0x0AA5E));
        art.facets.admin = RouterAdminFacet(address(0xAD));
        art.facets.issuePreview = RouterIssuePreviewFacet(address(0x15EE));
        art.facets.issue = RouterIssueFacet(address(0x155E));
        art.facets.issueBasket = RouterIssueBasketFacet(address(0x155EB));
        art.facets.redeem = RouterRedeemFacet(address(0x0EDE));
        art.facets.redeemBasket = RouterRedeemBasketFacet(address(0x0EDEB));
        art.facets.recoveryShareReceiver = RecoveryShareReceiverFacet(address(0x0EC2));

        FacetSpec.Entry[] memory specs = DeploymentHelper.facetSpecs(art);

        assertEq(specs.length, 11);
        assertEq(specs[0].name, "cut");
        assertEq(specs[0].facet, address(art.facets.cut));
        assertEq(specs[3].name, "pause");
        assertEq(specs[3].facet, address(art.facets.pause));
        assertEq(specs[4].name, "admin");
        assertEq(specs[4].facet, address(art.facets.admin));
        assertEq(specs[5].name, "issuePreview");
        assertEq(specs[5].facet, address(art.facets.issuePreview));
        assertEq(specs[6].name, "issue");
        assertEq(specs[6].facet, address(art.facets.issue));
        assertEq(specs[7].name, "issueBasket");
        assertEq(specs[7].facet, address(art.facets.issueBasket));
        assertEq(specs[8].name, "redeem");
        assertEq(specs[8].facet, address(art.facets.redeem));
        assertEq(specs[9].name, "redeemBasket");
        assertEq(specs[9].facet, address(art.facets.redeemBasket));
        assertEq(specs[10].name, "recoveryShareReceiver");
        assertEq(specs[10].facet, address(art.facets.recoveryShareReceiver));
    }

    function testRetainedProductSelectorsAreOwnedByCanonicalFacets() public {
        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(_shellConfig());
        IDiamondLoupe loupe = IDiamondLoupe(address(deployed.diamond));
        assertEq(loupe.facetFunctionSelectors(address(deployed.facets.issuePreview)).length, 6);
        assertEq(loupe.facetFunctionSelectors(address(deployed.facets.issue)).length, 4);
        assertEq(loupe.facetFunctionSelectors(address(deployed.facets.issueBasket)).length, 4);
        assertEq(loupe.facetFunctionSelectors(address(deployed.facets.redeem)).length, 8);
        assertEq(loupe.facetFunctionSelectors(address(deployed.facets.redeemBasket)).length, 5);
        assertEq(loupe.facetFunctionSelectors(address(deployed.facets.recoveryShareReceiver)).length, 2);

        _assertSelectorOwner(
            loupe, RouterIssueFacet.issueFromTokenExactOut.selector, 0x00a7f551, address(deployed.facets.issue)
        );
        _assertSelectorOwner(
            loupe, RouterRedeemFacet.redeemToTokenExactIn.selector, 0x3b25a19c, address(deployed.facets.redeem)
        );
        _assertSelectorOwner(
            loupe,
            RouterIssueBasketFacet.issueFromBasketExactOutWithPermit2.selector,
            0xabf4c20e,
            address(deployed.facets.issueBasket)
        );
        _assertSelectorOwner(
            loupe,
            RouterRedeemBasketFacet.redeemToBasketExactIn.selector,
            0xc2f2261c,
            address(deployed.facets.redeemBasket)
        );
        assertEq(
            loupe.facetAddress(RecoveryShareReceiverFacet.onERC1155BatchReceived.selector),
            address(deployed.facets.recoveryShareReceiver)
        );
    }

    function _assertSelectorOwner(IDiamondLoupe loupe, bytes4 actual, bytes4 expected, address owner) private view {
        assertEq(actual, expected);
        assertEq(loupe.facetAddress(actual), owner);
    }

    function testDeployHelpersShellIdempotentlyAdoptsExactCanonicalDeployment() public {
        bytes32 salt = keccak256("helpers-shell-idempotent");
        (HelpersDiamond first, address firstBootstrap) = DeploymentHelper.deployHelpersShell(address(this), salt);
        (HelpersDiamond adopted, address adoptedBootstrap) = DeploymentHelper.deployHelpersShell(address(this), salt);

        assertEq(address(adopted), address(first));
        assertEq(adoptedBootstrap, firstBootstrap);
    }

    function testDeployHelpersShellFromRequiresConfiguredDeployerAndAdoptsCanonicalDeployment() public {
        bytes32 salt = keccak256("helpers-shell-explicit-deployer");

        vm.expectRevert(bytes("DeploymentHelper: CREATE2 deployer missing"));
        this.deployHelpersShellFromExternal(address(this), salt, address(0));

        (HelpersDiamond first, address firstBootstrap) =
            this.deployHelpersShellFromExternal(address(this), salt, address(this));
        (HelpersDiamond adopted, address adoptedBootstrap) =
            this.deployHelpersShellFromExternal(address(this), salt, address(this));

        assertEq(address(adopted), address(first));
        assertEq(adoptedBootstrap, firstBootstrap);
    }

    function testDeployHelpersShellFromRejectsConfiguredBootstrapAddressMismatch() public {
        vm.expectRevert(bytes("DeploymentHelper: bootstrap address mismatch"));
        this.deployHelpersShellFromExternal(
            address(this), keccak256("helpers-shell-bootstrap-address-mismatch"), address(0xDEAD)
        );
    }

    function testDeployHelpersShellFromRejectsAdoptedBootstrapRuntimeMismatch() public {
        bytes32 salt = keccak256("helpers-shell-bootstrap-runtime-mismatch");
        (, address bootstrap) = this.deployHelpersShellFromExternal(address(this), salt, address(this));
        vm.etch(bootstrap, hex"00");

        vm.expectRevert(bytes("DeploymentHelper: bootstrap runtime mismatch"));
        this.deployHelpersShellFromExternal(address(this), salt, address(this));
    }

    function testDeployHelpersShellFromRejectsConfiguredDiamondAddressMismatch() public {
        bytes32 salt = keccak256("helpers-shell-diamond-address-mismatch");
        address configuredDeployer = address(0xDEAD);
        bytes32 bootstrapSalt = keccak256(abi.encodePacked("cybergold.helpers.bootstrapCut", salt));
        address configuredBootstrap =
            _create2Address(configuredDeployer, bootstrapSalt, keccak256(type(BootstrapDiamondCutFacet).creationCode));
        vm.etch(configuredBootstrap, type(BootstrapDiamondCutFacet).runtimeCode);

        vm.expectRevert(bytes("DeploymentHelper: diamond address mismatch"));
        this.deployHelpersShellFromExternal(address(this), salt, configuredDeployer);
    }

    function testDeployHelpersShellFromRejectsAdoptedDiamondRuntimeMismatch() public {
        bytes32 salt = keccak256("helpers-shell-diamond-runtime-mismatch");
        (HelpersDiamond shell,) = this.deployHelpersShellFromExternal(address(this), salt, address(this));
        vm.etch(address(shell), hex"00");

        vm.expectRevert(bytes("DeploymentHelper: diamond runtime mismatch"));
        this.deployHelpersShellFromExternal(address(this), salt, address(this));
    }

    function testDeployShellFinalizeSetsFinalOwnerAndRemovesBootstrapAuthority() public {
        address bootstrapOwner = address(this);
        address finalOwner = address(0xA11CE);
        (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(bootstrapOwner, keccak256("helpers-shell-test"));

        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = finalOwner;
        cfg.coreDiamond = address(0xC0DE);
        cfg.permit2 = address(0x2222);
        cfg.wrappedNative = address(0x3333);
        cfg.approvedAdapters = new address[](0);

        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.finalizeExisting(shell, cfg);

        assertEq(address(deployed.diamond), address(shell));
        assertEq(IERC173(address(shell)).owner(), finalOwner);
        assertEq(OwnershipFacet(address(shell)).pendingOwner(), address(0));
        vm.expectRevert();
        vm.prank(bootstrapOwner);
        IDiamondCut(address(shell)).diamondCut(new IDiamond.FacetCut[](0), address(0), "");
    }

    function testSafeOwnedShellRequiresSafeToExecutePreparedFinalization() public {
        FinalizationSafeHarness safeOwner = new FinalizationSafeHarness();
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(safeOwner), keccak256("helpers-safe-owned-finalization"));
        bytes memory finalizationCalldata = this.prepareExistingFinalizationExternal(shell, _shellConfig());

        vm.expectRevert();
        this.executeFinalizationExternal(address(shell), finalizationCalldata);

        safeOwner.execute(address(shell), finalizationCalldata);
        assertEq(IERC173(address(shell)).owner(), _shellConfig().admin);
    }

    function testFinalizeExistingRejectsShellWithUnexpectedSelector() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-selector"));
        UnexpectedShellFacet unexpected = new UnexpectedShellFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = UnexpectedShellFacet.unexpectedShellSelector.selector;
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(unexpected), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });
        IDiamondCut(address(shell)).diamondCut(cut, address(0), "");

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellSelectorManifestMismatch.selector, 54, 55));
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testFinalizeExistingRejectsShellWithPendingOwnerState() public {
        (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-owner"));
        ShellStateTainter tainter = new ShellStateTainter();
        IDiamondCut(address(shell))
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(tainter),
                abi.encodeCall(ShellStateTainter.taintPendingOwner, (address(0xBAD)))
            );

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellPendingOwnerNotPristine.selector, address(0xBAD)));
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testFinalizeExistingRejectsShellWithRouterState() public {
        (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-router"));
        ShellStateTainter tainter = new ShellStateTainter();
        IDiamondCut(address(shell))
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(tainter),
                abi.encodeCall(ShellStateTainter.taintRouterCore, (address(0xBAD)))
            );

        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondLiveInit.ShellRouterStorageNotPristine.selector, address(0xBAD), 0, address(0), 0
            )
        );
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testFinalizeExistingRejectsShellWithPausedState() public {
        (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-pause"));
        ShellStateTainter tainter = new ShellStateTainter();
        IDiamondCut(address(shell))
            .diamondCut(new IDiamond.FacetCut[](0), address(tainter), abi.encodeCall(ShellStateTainter.taintPause, ()));

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellPauseStorageNotPristine.selector, 1));
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testFinalizeExistingRejectsShellWithFacetVersionState() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-facet-version"));
        ShellStateTainter tainter = new ShellStateTainter();
        bytes32 namespace = keccak256("cybergold.helpers.issue");
        IDiamondCut(address(shell))
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(tainter),
                abi.encodeCall(ShellStateTainter.taintFacetVersion, (namespace, uint64(1)))
            );

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellFacetGenerationNotPristine.selector, namespace, 1));
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testFinalizeExistingRejectsEveryRetiredFacetRegistryDerivedEntry() public {
        bytes32 namespace = keccak256("cybergold.helpers.issue");
        for (uint256 offset = 1; offset <= 4; ++offset) {
            (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(
                address(this), keccak256(abi.encode("helpers-shell-facet-registry-derived", offset))
            );
            ShellStateTainter tainter = new ShellStateTainter();
            bytes32 derivedEntry =
                keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + offset)));
            IDiamondCut(address(shell))
                .diamondCut(
                    new IDiamond.FacetCut[](0),
                    address(tainter),
                    abi.encodeCall(ShellStateTainter.taintRawSlot, (derivedEntry, uint256(offset)))
                );

            vm.expectRevert(
                abi.encodeWithSelector(
                    DiamondLiveInit.ShellInfrastructureStorageNotPristine.selector, derivedEntry, offset
                )
            );
            this.finalizeExistingExternal(shell, _shellConfig());
        }
    }

    function testFinalizeExistingRejectsRetiredFacetRegistryRootWords() public {
        for (uint256 offset = 1; offset <= 4; ++offset) {
            (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(
                address(this), keccak256(abi.encode("helpers-shell-facet-registry-root", offset))
            );
            ShellStateTainter tainter = new ShellStateTainter();
            bytes32 retiredRoot = bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + offset);
            IDiamondCut(address(shell))
                .diamondCut(
                    new IDiamond.FacetCut[](0),
                    address(tainter),
                    abi.encodeCall(ShellStateTainter.taintRawSlot, (retiredRoot, uint256(offset)))
                );

            vm.expectRevert(
                abi.encodeWithSelector(
                    DiamondLiveInit.ShellInfrastructureStorageNotPristine.selector, retiredRoot, offset
                )
            );
            this.finalizeExistingExternal(shell, _shellConfig());
        }
    }

    function testFinalizeExistingRejectsRetiredPersistentReentrancyStorage() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-retired-guard"));
        ShellStateTainter tainter = new ShellStateTainter();
        IDiamondCut(address(shell))
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(tainter),
                abi.encodeCall(ShellStateTainter.taintRawSlot, (RETIRED_REENTRANCY_GUARD_STORAGE_SLOT, uint256(1)))
            );

        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondLiveInit.ShellInfrastructureStorageNotPristine.selector, RETIRED_REENTRANCY_GUARD_STORAGE_SLOT, 1
            )
        );
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testFinalizeExistingRejectsShellWithRecoveryReceiptState() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-recovery-receipt"));
        ShellStateTainter tainter = new ShellStateTainter();
        bytes32 receiptBatchHashSlot = bytes32(uint256(LibRecoveryShareReceiverStorage.storageLocation()) + 1);
        IDiamondCut(address(shell))
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(tainter),
                abi.encodeCall(ShellStateTainter.taintRawSlot, (receiptBatchHashSlot, uint256(1)))
            );

        vm.expectRevert(
            abi.encodeWithSelector(
                DiamondLiveInit.ShellInfrastructureStorageNotPristine.selector, receiptBatchHashSlot, 1
            )
        );
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testFinalizeExistingRejectsShellWithInterfaceState() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-interface"));
        ShellStateTainter tainter = new ShellStateTainter();
        bytes4 interfaceId = type(IERC165).interfaceId;
        IDiamondCut(address(shell))
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(tainter),
                abi.encodeCall(ShellStateTainter.taintInterface, (interfaceId))
            );

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellInterfaceNotPristine.selector, interfaceId));
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testFinalizeExistingRejectsShellAdvertisingAnyProtectedAccountCallback() public {
        bytes4[4] memory callbackInterfaceIds = [
            type(ICygldOutflowCallback).interfaceId,
            type(ICygldApprovalCallback).interfaceId,
            type(IRecoveryShareOutflowCallback).interfaceId,
            type(IRecoveryShareRedemptionCallback).interfaceId
        ];
        for (uint256 i; i < callbackInterfaceIds.length; ++i) {
            (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(
                address(this), keccak256(abi.encode("helpers-shell-protected-account-callback", i))
            );
            ShellStateTainter tainter = new ShellStateTainter();
            bytes4 interfaceId = callbackInterfaceIds[i];
            IDiamondCut(address(shell))
                .diamondCut(
                    new IDiamond.FacetCut[](0),
                    address(tainter),
                    abi.encodeCall(ShellStateTainter.taintInterface, (interfaceId))
                );

            vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellInterfaceNotPristine.selector, interfaceId));
            this.finalizeExistingExternal(shell, _shellConfig());
        }
    }

    function testHelpersExplicitlyRemainNonAdvertisersForProtectedAccountCallbacks() public {
        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(_shellConfig());
        IERC165 interfaceView = IERC165(address(deployed.diamond));

        assertFalse(interfaceView.supportsInterface(type(ICygldOutflowCallback).interfaceId));
        assertFalse(interfaceView.supportsInterface(type(ICygldApprovalCallback).interfaceId));
        assertFalse(interfaceView.supportsInterface(type(IRecoveryShareOutflowCallback).interfaceId));
        assertFalse(interfaceView.supportsInterface(type(IRecoveryShareRedemptionCallback).interfaceId));
    }

    function testFinalizeExistingRejectsShellWithInterfaceManifestState() public {
        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-interface-manifest"));
        ShellStateTainter tainter = new ShellStateTainter();
        IDiamondCut(address(shell))
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(tainter),
                abi.encodeCall(ShellStateTainter.taintInterfaceManifest, (bytes4(0x12345678), bytes4(0x87654321)))
            );

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellInterfaceManifestNotPristine.selector, 1));
        this.finalizeExistingExternal(shell, _shellConfig());
    }

    function testDeploymentHelperGuardBranches() public {
        vm.expectRevert(bytes("DeploymentHelper: bootstrap owner missing"));
        this.deployHelpersShellExternal(address(0));

        DeploymentTypes.DeployConfig memory cfg;
        vm.expectRevert(bytes("DeploymentHelper: admin missing"));
        this.deployHelpersExternal(cfg);

        cfg.admin = address(0xA11CE);
        vm.expectRevert(bytes("DeploymentHelper: Permit2 missing"));
        this.deployHelpersExternal(cfg);

        vm.expectRevert(bytes("DeploymentHelper: diamond missing"));
        this.finalizeExistingExternal(HelpersDiamond(payable(address(0))), cfg);

        vm.expectRevert(bytes("DeploymentHelper: diamond has no code"));
        this.finalizeExistingExternal(HelpersDiamond(payable(address(0xBAD))), cfg);

        (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers-shell-admin"));
        cfg.admin = address(0);
        vm.expectRevert(bytes("DeploymentHelper: admin missing"));
        this.finalizeExistingExternal(shell, cfg);
    }

    function _shellConfig() private pure returns (DeploymentTypes.DeployConfig memory cfg) {
        cfg.admin = address(0xA11CE);
        cfg.coreDiamond = address(0xC0DE);
        cfg.permit2 = address(0x2222);
        cfg.wrappedNative = address(0x3333);
        cfg.approvedAdapters = new address[](0);
    }

    function testDeployOutputPathSelection() public {
        // Environment mutations are required to test output-path selection.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_OUTPUT_DIR", "/tmp/cybergold-helper-out");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_HELPERS_PATH", "/tmp/explicit-deploy-helpers.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_HELPERS_SHELL_PATH", "/tmp/explicit-deploy-helpers-shell.json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("VERIFY_HELPERS_PATH", "/tmp/explicit-verify-helpers.json");

        assertEq(DeployOutput.outPath(vm, "deploy-helpers.json"), "/tmp/explicit-deploy-helpers.json");
        assertEq(DeployOutput.outPath(vm, "deploy-helpers-shell.json"), "/tmp/explicit-deploy-helpers-shell.json");
        assertEq(DeployOutput.outPath(vm, "verify-helpers.json"), "/tmp/explicit-verify-helpers.json");
        assertEq(DeployOutput.outPath(vm, "other.json"), "/tmp/cybergold-helper-out/other.json");
    }

    function testDiamondInitRejectsMissingOwner() public {
        DiamondInit init = new DiamondInit();
        DiamondInit.InitConfig memory cfg;

        vm.expectRevert(bytes("DiamondInit: owner missing"));
        init.init(cfg);
    }

    function testDiamondInitRejectsSelectorCountMismatch() public {
        DiamondInitHarness init = new DiamondInitHarness();

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.ShellSelectorManifestMismatch.selector, 1, 0));
        init.assertSelectorManifestCount(1);
    }

    function testDiamondLiveInitRejectsMissingOwnerAndSelectorCountMismatch() public {
        DiamondLiveInit init = new DiamondLiveInit();
        DiamondLiveInit.InitConfig memory cfg;
        vm.expectRevert(bytes("DiamondLiveInit: owner missing"));
        init.init(cfg);

        DiamondLiveInitHarness harness = new DiamondLiveInitHarness();
        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellSelectorManifestMismatch.selector, 1, 0));
        harness.assertSelectorManifestCount(1);
    }

    function testDirectDeploymentRejectsExtraAndMissingSelectorCardinality() public {
        DeploymentTypes.DeployConfig memory cfg = _shellConfig();
        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(cfg);
        DiamondLiveInit.InitConfig memory initCfg = _diamondLiveInitConfig(deployed, cfg);
        DiamondArgs memory args = BaseDiamondHelper.buildArgs(
            cfg.admin, address(deployed.diamondInit), abi.encodeWithSelector(DiamondLiveInit.init.selector, initCfg)
        );

        IDiamond.FacetCut[] memory extraCut = FacetSpec.buildCut(DeploymentHelper.facetSpecs(deployed));
        bytes4[] memory originalAdminSelectors = extraCut[4].functionSelectors;
        bytes4[] memory extraAdminSelectors = new bytes4[](originalAdminSelectors.length + 1);
        for (uint256 i; i < originalAdminSelectors.length; ++i) {
            extraAdminSelectors[i] = originalAdminSelectors[i];
        }
        extraAdminSelectors[originalAdminSelectors.length] = UnexpectedShellFacet.unexpectedShellSelector.selector;
        extraCut[4].functionSelectors = extraAdminSelectors;

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellSelectorManifestMismatch.selector, 54, 55));
        new HelpersDiamond(extraCut, args);

        IDiamond.FacetCut[] memory missingCut = FacetSpec.buildCut(DeploymentHelper.facetSpecs(deployed));
        bytes4[] memory originalPauseSelectors = missingCut[3].functionSelectors;
        bytes4[] memory missingPauseSelector = new bytes4[](originalPauseSelectors.length - 1);
        for (uint256 i; i < missingPauseSelector.length; ++i) {
            missingPauseSelector[i] = originalPauseSelectors[i];
        }
        missingCut[3].functionSelectors = missingPauseSelector;

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.ShellSelectorManifestMismatch.selector, 54, 53));
        new HelpersDiamond(missingCut, args);
    }

    function testLaunchFacetMetadataRequiresEveryFacetAndRuntimeCode() public {
        DiamondLiveInitHarness init = new DiamondLiveInitHarness();
        address[11] memory facets = _validLaunchMetadataFacets();
        facets[4] = address(0);
        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.LaunchFacetMissing.selector, 4));
        init.validateLaunchFacetMetadata(facets);

        facets = _validLaunchMetadataFacets();
        facets[4] = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.LaunchFacetCodeMissing.selector, 4, address(0xBEEF)));
        init.validateLaunchFacetMetadata(facets);
    }

    function testLaunchConfiguredFacetMustBePresentInstalledAndExact() public {
        DiamondLiveInitHarness init = new DiamondLiveInitHarness();
        bytes4 selector = bytes4(keccak256("configuredFacetProbe()"));
        address configured = address(0xCAFE);
        address installed = address(0xBEEF);

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.LaunchFacetMissing.selector, 4));
        init.validateConfiguredFacet(4, address(0), selector, installed);

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.LaunchFacetMissing.selector, 4));
        init.validateConfiguredFacet(4, configured, selector, address(0));

        vm.expectRevert(
            abi.encodeWithSelector(DiamondLiveInit.LaunchFacetAddressMismatch.selector, 4, configured, installed)
        );
        init.validateConfiguredFacet(4, configured, selector, installed);

        assertEq(init.validateConfiguredFacet(4, configured, selector, configured), configured);
    }

    function testLaunchTopologyRequiresDistinctFacetsAndRejectsUnexpectedSelectorOwners() public {
        DiamondLiveInitHarness init = new DiamondLiveInitHarness();
        address[11] memory facets = _validLaunchMetadataFacets();
        facets[8] = facets[7];
        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.LaunchFacetAddressDuplicate.selector, facets[7], 7, 8));
        init.validateLaunchFacetTopology(facets, bytes4(0), address(0));

        facets = _validLaunchMetadataFacets();
        bytes4 expectedSelector = bytes4(keccak256("expectedOwner()"));
        init.validateLaunchFacetTopology(facets, expectedSelector, facets[4]);

        bytes4 unexpectedSelector = bytes4(keccak256("unexpectedOwner()"));
        address unexpected = address(new UnexpectedShellFacet());
        vm.expectRevert(
            abi.encodeWithSelector(DiamondLiveInit.LaunchUnexpectedFacet.selector, unexpectedSelector, unexpected)
        );
        init.validateLaunchFacetTopology(facets, unexpectedSelector, unexpected);
    }

    function testLiveLaunchFacetMetadataRejectsMissingZeroAndDuplicateNamespaces() public {
        DiamondLiveInitHarness init = new DiamondLiveInitHarness();
        address[11] memory facets = _validLaunchMetadataFacets();
        UnexpectedShellFacet missing = new UnexpectedShellFacet();
        facets[4] = address(missing);
        vm.expectRevert(
            abi.encodeWithSelector(LiveFacetVersionRegistry.FacetNamespaceProbeFailed.selector, address(missing))
        );
        init.validateLaunchFacetMetadata(facets);

        facets = _validLaunchMetadataFacets();
        ConfigurableLaunchFacetMetadata zeroNamespace = new ConfigurableLaunchFacetMetadata(bytes32(0), 1);
        facets[4] = address(zeroNamespace);
        vm.expectRevert(
            abi.encodeWithSelector(DiamondLiveInit.LaunchFacetNamespaceInvalid.selector, 4, address(zeroNamespace))
        );
        init.validateLaunchFacetMetadata(facets);

        facets = _validLaunchMetadataFacets();
        bytes32 namespace = ConfigurableLaunchFacetMetadata(facets[7]).FACET_NAMESPACE();
        facets[8] = address(new ConfigurableLaunchFacetMetadata(namespace, 1));
        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.LaunchFacetNamespaceDuplicate.selector, namespace, 7, 8));
        init.validateLaunchFacetMetadata(facets);
    }

    function testLaunchFacetMetadataRejectsMissingZeroAndNonV1Metadata() public {
        DiamondInitHarness init = new DiamondInitHarness();
        address[11] memory facets = _validLaunchMetadataFacets();
        UnexpectedShellFacet missing = new UnexpectedShellFacet();
        facets[4] = address(missing);
        vm.expectRevert(abi.encodeWithSelector(FacetVersionRegistry.FacetVersionProbeFailed.selector, address(missing)));
        init.validateLaunchFacetMetadata(facets);

        facets = _validLaunchMetadataFacets();
        ConfigurableLaunchFacetMetadata zeroNamespace = new ConfigurableLaunchFacetMetadata(bytes32(0), 1);
        facets[4] = address(zeroNamespace);
        vm.expectRevert(
            abi.encodeWithSelector(DiamondInit.LaunchFacetNamespaceInvalid.selector, 4, address(zeroNamespace))
        );
        init.validateLaunchFacetMetadata(facets);

        facets = _validLaunchMetadataFacets();
        ConfigurableLaunchFacetMetadata versionZero =
            new ConfigurableLaunchFacetMetadata(keccak256("helpers.test.v0"), 0);
        facets[4] = address(versionZero);
        vm.expectRevert(
            abi.encodeWithSelector(DiamondInit.LaunchFacetVersionInvalid.selector, 4, address(versionZero), uint64(0))
        );
        init.validateLaunchFacetMetadata(facets);

        facets = _validLaunchMetadataFacets();
        ConfigurableLaunchFacetMetadata versionTwo =
            new ConfigurableLaunchFacetMetadata(keccak256("helpers.test.v2"), 2);
        facets[4] = address(versionTwo);
        vm.expectRevert(
            abi.encodeWithSelector(DiamondInit.LaunchFacetVersionInvalid.selector, 4, address(versionTwo), uint64(2))
        );
        init.validateLaunchFacetMetadata(facets);
    }

    function testLaunchFacetMetadataRejectsDuplicateNamespaces() public {
        DiamondInitHarness init = new DiamondInitHarness();
        address[11] memory facets = _validLaunchMetadataFacets();
        bytes32 namespace = ConfigurableLaunchFacetMetadata(facets[7]).FACET_NAMESPACE();
        facets[8] = address(new ConfigurableLaunchFacetMetadata(namespace, 1));

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.LaunchFacetNamespaceDuplicate.selector, namespace, 7, 8));
        init.validateLaunchFacetMetadata(facets);
    }

    function testDiamondLiveInitOuterReplayIsRejectedByInstalledGeneration() public {
        DeploymentTypes.DeployConfig memory cfg = _shellConfig();
        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(cfg);
        DiamondLiveInit.InitConfig memory initCfg = _diamondLiveInitConfig(deployed, cfg);
        bytes32 namespace = keccak256("cybergold.upgrade.coordinator.owner");

        vm.prank(cfg.admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveFacetVersionRegistry.FacetGenerationAlreadyInitialized.selector, namespace, uint64(1)
            )
        );
        IDiamondCut(address(deployed.diamond))
            .diamondCut(
                new IDiamond.FacetCut[](0),
                address(deployed.diamondInit),
                abi.encodeWithSelector(DiamondLiveInit.init.selector, initCfg)
            );
    }

    function testDiamondInitWrapsNoDataDelegateRevert() public {
        DiamondInitHarness init = new DiamondInitHarness();
        NoDataRevertInitTarget target = new NoDataRevertInitTarget();
        bytes memory data = abi.encodeWithSelector(
            RouterAdminFacet.initRouter.selector, address(0), address(0), uint256(0), new address[](0)
        );

        vm.expectRevert(abi.encodeWithSelector(DiamondInit.FacetInitFailed.selector, address(target), data));
        init.initRouter(address(target), new address[](0));

        bytes32 initContextSlot = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
        bytes32 facetVersionRegistrySlot = 0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
        bytes32 versionSlot = keccak256(abi.encode(target.FACET_NAMESPACE(), facetVersionRegistrySlot));
        assertEq(vm.load(address(init), initContextSlot), bytes32(0));
        assertEq(vm.load(address(init), versionSlot), bytes32(0));
    }

    function testDiamondLiveInitWrapsNoDataDelegateRevert() public {
        DiamondLiveInitHarness init = new DiamondLiveInitHarness();
        NoDataRevertInitTarget target = new NoDataRevertInitTarget();
        bytes memory data = abi.encodeWithSelector(
            RouterAdminFacet.initRouter.selector, address(0), address(0), uint256(0), new address[](0)
        );

        vm.expectRevert(abi.encodeWithSelector(DiamondLiveInit.FacetInitFailed.selector, address(target), data));
        init.initRouter(address(target), new address[](0));

        bytes32 initContextSlot = 0xcbb2ce56a049a64c9c08535426fc3e60a12a71c4d714a6454bc239b37e97e32d;
        bytes32 facetVersionRegistrySlot = 0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
        bytes32 generationSlot = keccak256(abi.encode(target.FACET_NAMESPACE(), facetVersionRegistrySlot));
        assertEq(vm.load(address(init), initContextSlot), bytes32(0));
        assertEq(vm.load(address(init), generationSlot), bytes32(0));
    }

    function _validLaunchMetadataFacets() private returns (address[11] memory facets) {
        for (uint256 i; i < facets.length; ++i) {
            facets[i] = address(new ConfigurableLaunchFacetMetadata(keccak256(abi.encode("facet", i)), 1));
        }
    }

    function _diamondLiveInitConfig(
        DeploymentTypes.DeployArtifacts memory deployed,
        DeploymentTypes.DeployConfig memory cfg
    ) private pure returns (DiamondLiveInit.InitConfig memory initCfg) {
        initCfg = DiamondLiveInit.InitConfig({
            owner: cfg.admin,
            requirePristineShell: false,
            expectedSelectorCount: 54,
            loupeFacet: address(deployed.facets.loupe),
            pausableFacet: address(deployed.facets.pause),
            ownershipFacet: address(deployed.facets.ownership),
            adminFacet: address(deployed.facets.admin),
            issuePreviewFacet: address(deployed.facets.issuePreview),
            issueFacet: address(deployed.facets.issue),
            issueBasketFacet: address(deployed.facets.issueBasket),
            redeemFacet: address(deployed.facets.redeem),
            redeemBasketFacet: address(deployed.facets.redeemBasket),
            recoveryShareReceiverFacet: address(deployed.facets.recoveryShareReceiver),
            coreDiamond: cfg.coreDiamond,
            wrappedNative: cfg.wrappedNative,
            helperFeePpm: cfg.helperFeePpm,
            approvedAdapters: cfg.approvedAdapters
        });
    }

    function _create2Address(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
