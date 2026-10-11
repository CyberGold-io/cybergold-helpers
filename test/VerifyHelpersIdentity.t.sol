// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";

import {VerifyHelpers} from "../script/VerifyHelpers.s.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeployParams} from "../src/deploy/DeployParams.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";

contract IdentityRuntimeTarget {}

contract IdentityExtraFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.test.identity-extra");
    uint64 public constant FACET_VERSION = 1;

    function extraSelector() external pure returns (uint256) {
        return 1;
    }
}

contract IdentityUpgradeInit {
    function noop() external pure {}
}

contract VerifyHelpersHarness is VerifyHelpers {
    function verifyExternalIdentity(address target, string calldata label) external view {
        _verifyExternalIdentity(target, label);
    }

    function verifyHelpersDiamondIdentity(address actualDiamond) external view {
        HelperArtifacts memory art;
        art.diamond = actualDiamond;
        DeployParams.Params memory params;
        _verifyIdentityPolicy(art, params);
    }

    function verifyLocalDeployment(DeploymentTypes.DeployArtifacts memory deployed, address permit2_) external view {
        HelperArtifacts memory art;
        art.diamond = address(deployed.diamond);
        art.cutFacet = address(deployed.facets.cut);
        art.loupeFacet = address(deployed.facets.loupe);
        art.ownershipFacet = address(deployed.facets.ownership);
        art.pauseFacet = address(deployed.facets.pause);
        art.adminFacet = address(deployed.facets.admin);
        art.issuePreviewFacet = address(deployed.facets.issuePreview);
        art.issueFacet = address(deployed.facets.issue);
        art.issueBasketFacet = address(deployed.facets.issueBasket);
        art.redeemFacet = address(deployed.facets.redeem);
        art.redeemBasketFacet = address(deployed.facets.redeemBasket);
        art.recoveryShareReceiverFacet = address(deployed.facets.recoveryShareReceiver);
        art.diamondInit = address(deployed.diamondInit);
        _verifyLocalDeployment(art, permit2_);
    }

    function verifyInitializerState(DeploymentTypes.DeployArtifacts memory deployed) external view {
        HelperArtifacts memory art;
        art.diamond = address(deployed.diamond);
        art.cutFacet = address(deployed.facets.cut);
        art.loupeFacet = address(deployed.facets.loupe);
        art.ownershipFacet = address(deployed.facets.ownership);
        art.pauseFacet = address(deployed.facets.pause);
        art.adminFacet = address(deployed.facets.admin);
        art.issuePreviewFacet = address(deployed.facets.issuePreview);
        art.issueFacet = address(deployed.facets.issue);
        art.issueBasketFacet = address(deployed.facets.issueBasket);
        art.redeemFacet = address(deployed.facets.redeem);
        art.redeemBasketFacet = address(deployed.facets.redeemBasket);
        art.recoveryShareReceiverFacet = address(deployed.facets.recoveryShareReceiver);
        _verifyInitializerState(art);
    }

    function verifyExactAdapterSet(address[] memory approved, address oneInch, address uniswap) external pure {
        _verifyExactAdapterSet(approved, oneInch, uniswap);
    }

    function loadArtifactAddresses()
        external
        view
        returns (address diamond, address issueFacet, address redeemFacet, address recoveryShareReceiverFacet)
    {
        HelperArtifacts memory art = _loadArtifacts();
        return (art.diamond, art.issueFacet, art.redeemFacet, art.recoveryShareReceiverFacet);
    }
}

contract VerifyHelpersIdentityTest is Test {
    bytes32 private constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 private constant RETIRED_REENTRANCY_GUARD_STORAGE_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    VerifyHelpersHarness private verifier;

    function setUp() public {
        verifier = new VerifyHelpersHarness();
    }

    function testRuntimeIdentityRequiresExactCodehashAndNoProxySlot() public {
        IdentityRuntimeTarget target = new IdentityRuntimeTarget();
        _setRuntimeIdentity("RUNTIME", address(target));

        verifier.verifyExternalIdentity(address(target), "RUNTIME");

        // Environment mutations are required to exercise identity verification failures.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_RUNTIME_CODEHASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert("VerifyHelpers: RUNTIME codehash mismatch");
        verifier.verifyExternalIdentity(address(target), "RUNTIME");

        _setRuntimeIdentity("RUNTIME", address(target));
        vm.store(address(target), EIP1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(0xBEEF)))));
        vm.expectRevert("VerifyHelpers: RUNTIME undeclared proxy");
        verifier.verifyExternalIdentity(address(target), "RUNTIME");
    }

    function testEip1967ProxyRequiresExactImplementationAndImplementationCodehash() public {
        IdentityRuntimeTarget proxy = new IdentityRuntimeTarget();
        IdentityRuntimeTarget implementation = new IdentityRuntimeTarget();
        vm.store(address(proxy), EIP1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(address(implementation)))));
        _setProxyIdentity("PROXY", address(proxy), address(implementation));

        verifier.verifyExternalIdentity(address(proxy), "PROXY");

        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_PROXY_IMPLEMENTATION", vm.toString(address(0xBEEF)));
        vm.expectRevert("VerifyHelpers: PROXY implementation mismatch");
        verifier.verifyExternalIdentity(address(proxy), "PROXY");

        _setProxyIdentity("PROXY", address(proxy), address(implementation));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_PROXY_IMPLEMENTATION_CODEHASH", vm.toString(bytes32(uint256(1))));
        vm.expectRevert("VerifyHelpers: PROXY implementation codehash mismatch");
        verifier.verifyExternalIdentity(address(proxy), "PROXY");
    }

    function testUnsupportedIdentityKindFailsClosed() public {
        IdentityRuntimeTarget target = new IdentityRuntimeTarget();
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_UNSUPPORTED_KIND", "custom-proxy");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_UNSUPPORTED_CODEHASH", vm.toString(address(target).codehash));

        vm.expectRevert("VerifyHelpers: UNSUPPORTED unsupported identity kind");
        verifier.verifyExternalIdentity(address(target), "UNSUPPORTED");
    }

    function testStrictIdentityRejectsHelpersDiamondOutsideCandidate() public {
        // Environment mutations are required to exercise strict identity policy.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("HELPERS_IDENTITY_POLICY", "strict-proxy-codehash-v1");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("EXPECTED_HELPERS_DIAMOND", vm.toString(address(0xA11CE)));

        vm.expectRevert("VerifyHelpers: Helpers diamond differs from candidate");
        verifier.verifyHelpersDiamondIdentity(address(0xB0B));
    }

    function testLocalDeploymentRequiresCanonicalRuntimeAndExactTopology() public {
        DeploymentTypes.DeployArtifacts memory deployed = _deployHelpers();
        verifier.verifyLocalDeployment(deployed, address(0x2222));

        IdentityExtraFacet extra = new IdentityExtraFacet();
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IdentityExtraFacet.extraSelector.selector;
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(extra), action: IDiamond.FacetCutAction.Add, functionSelectors: selectors
        });
        IdentityUpgradeInit upgradeInit = new IdentityUpgradeInit();
        IDiamondCut(address(deployed.diamond))
            .diamondCut(cut, address(upgradeInit), abi.encodeCall(IdentityUpgradeInit.noop, ()));

        vm.expectRevert("VerifyHelpers: unexpected facet count");
        verifier.verifyLocalDeployment(deployed, address(0x2222));
    }

    function testLocalDeploymentRejectsFacetPermit2Mismatch() public {
        DeploymentTypes.DeployArtifacts memory deployed = _deployHelpers();

        vm.expectRevert("VerifyHelpers: admin immutable missing");
        verifier.verifyLocalDeployment(deployed, address(0x3333));
    }

    function testInitializerVerificationRequiresRetiredRuntimeHashSlotToStayZero() public {
        DeploymentTypes.DeployArtifacts memory deployed = _deployHelpers();
        verifier.verifyInitializerState(deployed);

        bytes32 namespace = keccak256("cybergold.helpers.issue");
        bytes32 runtimeCodeHashSlot =
            keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + 1)));
        vm.store(address(deployed.diamond), runtimeCodeHashSlot, bytes32(uint256(1)));

        vm.expectRevert("VerifyHelpers: retired registry entry used");
        verifier.verifyInitializerState(deployed);
    }

    function testInitializerVerificationRejectsRetiredPersistentReentrancyStorage() public {
        DeploymentTypes.DeployArtifacts memory deployed = _deployHelpers();
        vm.store(address(deployed.diamond), RETIRED_REENTRANCY_GUARD_STORAGE_SLOT, bytes32(uint256(1)));

        vm.expectRevert("VerifyHelpers: retired reentrancy storage used");
        verifier.verifyInitializerState(deployed);
    }

    function testAdapterVerificationRejectsAnyExtraApprovedAdapter() public {
        address[] memory exact = new address[](2);
        exact[0] = address(0x1);
        exact[1] = address(0x3);
        verifier.verifyExactAdapterSet(exact, exact[0], exact[1]);

        address[] memory extra = new address[](3);
        extra[0] = exact[0];
        extra[1] = exact[1];
        extra[2] = address(0x4);
        vm.expectRevert("VerifyHelpers: unexpected approved adapter count");
        verifier.verifyExactAdapterSet(extra, exact[0], exact[1]);
    }

    function testArtifactLoaderReadsLiteralDottedFacetKeys() public {
        DeploymentTypes.DeployArtifacts memory deployed = _deployHelpers();
        string memory label = "verifyHelpersArtifact";
        string memory json = vm.serializeAddress(label, "diamond", address(deployed.diamond));
        json = vm.serializeAddress(label, "oneInchAdapter", address(0x1));
        json = vm.serializeAddress(label, "uniswapAdapter", address(0x2));
        json = vm.serializeAddress(label, "facet.cut", address(deployed.facets.cut));
        json = vm.serializeAddress(label, "facet.loupe", address(deployed.facets.loupe));
        json = vm.serializeAddress(label, "facet.ownership", address(deployed.facets.ownership));
        json = vm.serializeAddress(label, "facet.pause", address(deployed.facets.pause));
        json = vm.serializeAddress(label, "facet.admin", address(deployed.facets.admin));
        json = vm.serializeAddress(label, "facet.issuePreview", address(deployed.facets.issuePreview));
        json = vm.serializeAddress(label, "facet.issue", address(deployed.facets.issue));
        json = vm.serializeAddress(label, "facet.issueBasket", address(deployed.facets.issueBasket));
        json = vm.serializeAddress(label, "facet.redeem", address(deployed.facets.redeem));
        json = vm.serializeAddress(label, "facet.redeemBasket", address(deployed.facets.redeemBasket));
        json = vm.serializeAddress(label, "facet.recoveryShareReceiver", address(deployed.facets.recoveryShareReceiver));
        json = vm.serializeAddress(label, "diamondInit", address(deployed.diamondInit));
        string memory path = string.concat(vm.projectRoot(), "/out/test-verify-helpers-artifact.json");
        vm.writeJson(json, path);
        // Environment mutation redirects the verifier to the focused test artifact.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv("DEPLOY_HELPERS_PATH", path);

        (address diamond, address issueFacet, address redeemFacet, address recoveryShareReceiverFacet) =
            verifier.loadArtifactAddresses();
        assertEq(diamond, address(deployed.diamond));
        assertEq(issueFacet, address(deployed.facets.issue));
        assertEq(redeemFacet, address(deployed.facets.redeem));
        assertEq(recoveryShareReceiverFacet, address(deployed.facets.recoveryShareReceiver));
    }

    function _deployHelpers() private returns (DeploymentTypes.DeployArtifacts memory deployed) {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = address(0xC0DE);
        cfg.permit2 = address(0x2222);
        cfg.wrappedNative = address(0x3333);
        cfg.approvedAdapters = new address[](0);
        deployed = DeploymentHelper.deploy(cfg);
    }

    function _setRuntimeIdentity(string memory label, address target) private {
        // Environment mutations are required to construct the verifier's expected identity.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_KIND"), "runtime");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_CODEHASH"), vm.toString(target.codehash));
    }

    function _setProxyIdentity(string memory label, address proxy, address implementation) private {
        // Environment mutations are required to construct the verifier's expected proxy identity.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_KIND"), "eip1967-proxy");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_CODEHASH"), vm.toString(proxy.codehash));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_IMPLEMENTATION"), vm.toString(implementation));
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.setEnv(string.concat("EXPECTED_", label, "_IMPLEMENTATION_CODEHASH"), vm.toString(implementation.codehash));
    }
}
