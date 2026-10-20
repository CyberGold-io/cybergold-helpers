// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeployOutput} from "src/deploy/DeployOutput.sol";
import {DeployParams} from "src/deploy/DeployParams.sol";
import {DeploymentHelper} from "src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "src/deploy/DeploymentTypes.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";
import {ICyberGoldHelpers} from "src/interfaces/ICyberGoldHelpers.sol";
import {HelpersDiamond} from "src/diamond/HelpersDiamond.sol";
import {DiamondCutOwnerLiveFacet} from "../src/facets/DiamondCutOwnerLiveFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {OwnershipFacet} from "src/facets/OwnershipFacet.sol";
import {OwnerPausableFacet} from "src/facets/OwnerPausableFacet.sol";
import {RouterAdminFacet} from "src/facets/RouterAdminFacet.sol";
import {RouterIssuePreviewFacet} from "src/facets/RouterIssuePreviewFacet.sol";
import {RouterIssueFacet} from "src/facets/RouterIssueFacet.sol";
import {RouterIssueBasketFacet} from "src/facets/RouterIssueBasketFacet.sol";
import {RouterRedeemFacet} from "src/facets/RouterRedeemFacet.sol";
import {RouterRedeemBasketFacet} from "src/facets/RouterRedeemBasketFacet.sol";
import {RecoveryShareReceiverFacet} from "src/facets/RecoveryShareReceiverFacet.sol";
import {DiamondLiveInit} from "src/deploy/DiamondLiveInit.sol";
import {IRecoverableSwapAdapter} from "src/interfaces/IRecoverableSwapAdapter.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @notice Minimal pause-state capability used by deployment verification.
interface IPausableView {
    /// @notice Return whether Helpers user flows are paused.
    /// @return Whether the diamond is currently paused.
    function paused() external view returns (bool);
}

interface IOneInchAdapterView {
    function AGGREGATION_ROUTER() external view returns (address);
}

interface IUniswapUniversalAdapterView {
    function UNIVERSAL_ROUTER() external view returns (address);

    function PERMIT2() external view returns (address);
}

contract VerifyHelpers is Script {
    using DeployParams for DeployParams.Params;

    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant STRICT_IDENTITY_POLICY_HASH = keccak256("strict-proxy-codehash-v1");
    bytes32 internal constant RUNTIME_KIND_HASH = keccak256("runtime");
    bytes32 internal constant DIAMOND_KIND_HASH = keccak256("diamond");
    bytes32 internal constant EIP1967_PROXY_KIND_HASH = keccak256("eip1967-proxy");
    bytes32 internal constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;
    bytes32 internal constant RETIRED_REENTRANCY_GUARD_STORAGE_SLOT =
        0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00;

    struct HelperArtifacts {
        address diamond;
        address oneInchAdapter;
        address uniswapAdapter;
        address cutFacet;
        address loupeFacet;
        address ownershipFacet;
        address pauseFacet;
        address adminFacet;
        address issuePreviewFacet;
        address issueFacet;
        address issueBasketFacet;
        address redeemFacet;
        address redeemBasketFacet;
        address recoveryShareReceiverFacet;
        address diamondInit;
    }

    function run() external {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        string memory releaseManifestId = vm.envString("RELEASE_MANIFEST_ID");
        string memory releaseManifestSha256 = vm.envString("RELEASE_MANIFEST_SHA256");
        require(block.chainid == expectedChainId, "VerifyHelpers: chain ID mismatch");
        require(bytes(releaseManifestId).length != 0, "VerifyHelpers: release manifest ID missing");
        require(bytes(releaseManifestSha256).length == 64, "VerifyHelpers: release manifest SHA-256 missing");

        DeployParams.Params memory params = DeployParams.fromEnv(vm);
        require(params.admin != address(0), "VerifyHelpers: admin missing");

        HelperArtifacts memory art = _loadArtifacts();
        ICyberGoldHelpers router = ICyberGoldHelpers(art.diamond);

        require(art.diamond.code.length != 0, "VerifyHelpers: diamond has no bytecode");
        require(art.oneInchAdapter.code.length != 0, "VerifyHelpers: 1inch adapter has no bytecode");
        require(art.uniswapAdapter.code.length != 0, "VerifyHelpers: Uniswap adapter has no bytecode");

        _verifyLocalDeployment(art, params.permit2);
        _verifyIdentityPolicy(art, params);

        require(IERC173(art.diamond).owner() == params.admin, "VerifyHelpers: owner mismatch");
        require(OwnershipFacet(art.diamond).pendingOwner() == address(0), "VerifyHelpers: pending owner must be zero");
        _verifyInitializerState(art);
        require(address(router.coreDiamond()) == params.coreDiamond, "VerifyHelpers: Core diamond mismatch");
        require(router.helperFeePpm() == params.helperFeePpm, "VerifyHelpers: helper fee mismatch");
        require(address(router.permit2()) == params.permit2, "VerifyHelpers: Permit2 mismatch");
        require(router.wrappedNative() == params.wrappedNative, "VerifyHelpers: wrapped native mismatch");
        require(!IPausableView(art.diamond).paused(), "VerifyHelpers: helpers paused");

        _verifyAdapters(router, art, params);
        _writeOutput(art, params, releaseManifestId, releaseManifestSha256);
        _logSummary(art, params);
    }

    function _loadArtifacts() internal view returns (HelperArtifacts memory art) {
        // Deployment verification scripts intentionally read the prior deploy artifact.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(DeployOutput.outPath(vm, "deploy-helpers.json"));
        art.diamond = vm.parseJsonAddress(json, ".diamond");
        art.oneInchAdapter = vm.parseJsonAddress(json, ".oneInchAdapter");
        art.uniswapAdapter = vm.parseJsonAddress(json, ".uniswapAdapter");
        art.cutFacet = vm.parseJsonAddress(json, ".[\"facet.cut\"]");
        art.loupeFacet = vm.parseJsonAddress(json, ".[\"facet.loupe\"]");
        art.ownershipFacet = vm.parseJsonAddress(json, ".[\"facet.ownership\"]");
        art.pauseFacet = vm.parseJsonAddress(json, ".[\"facet.pause\"]");
        art.adminFacet = vm.parseJsonAddress(json, ".[\"facet.admin\"]");
        art.issuePreviewFacet = vm.parseJsonAddress(json, ".[\"facet.issuePreview\"]");
        art.issueFacet = vm.parseJsonAddress(json, ".[\"facet.issue\"]");
        art.issueBasketFacet = vm.parseJsonAddress(json, ".[\"facet.issueBasket\"]");
        art.redeemFacet = vm.parseJsonAddress(json, ".[\"facet.redeem\"]");
        art.redeemBasketFacet = vm.parseJsonAddress(json, ".[\"facet.redeemBasket\"]");
        art.recoveryShareReceiverFacet = vm.parseJsonAddress(json, ".[\"facet.recoveryShareReceiver\"]");
        art.diamondInit = vm.parseJsonAddress(json, ".diamondInit");
    }

    function _verifyIdentityPolicy(HelperArtifacts memory art, DeployParams.Params memory params) internal view {
        string memory policy = vm.envString("HELPERS_IDENTITY_POLICY");
        bool strict = keccak256(bytes(policy)) == STRICT_IDENTITY_POLICY_HASH;
        if (block.chainid == 1) require(strict, "VerifyHelpers: strict identity policy required on mainnet");
        if (!strict) return;

        require(
            art.diamond == vm.envAddress("EXPECTED_HELPERS_DIAMOND"),
            "VerifyHelpers: Helpers diamond differs from candidate"
        );
        _verifyExternalIdentity(params.coreDiamond, "CORE");
        _verifyExternalIdentity(params.permit2, "PERMIT2");
        _verifyExternalIdentity(params.wrappedNative, "WETH");
        _verifyExternalIdentity(params.oneInchRouter, "ONEINCH_ROUTER");
        _verifyExternalIdentity(params.uniswapRouter, "UNISWAP_ROUTER");
        _verifyExternalIdentity(art.oneInchAdapter, "ONEINCH_ADAPTER");
        _verifyExternalIdentity(art.uniswapAdapter, "UNISWAP_ADAPTER");
    }

    function _verifyExternalIdentity(address target, string memory label) internal view {
        require(target.code.length != 0, string.concat("VerifyHelpers: ", label, " has no bytecode"));
        bytes32 kind = keccak256(bytes(vm.envString(string.concat("EXPECTED_", label, "_KIND"))));
        bytes32 expectedCodehash = vm.envBytes32(string.concat("EXPECTED_", label, "_CODEHASH"));
        require(target.codehash == expectedCodehash, string.concat("VerifyHelpers: ", label, " codehash mismatch"));

        bytes32 implementationWord = vm.load(target, EIP1967_IMPLEMENTATION_SLOT);
        if (kind == EIP1967_PROXY_KIND_HASH) {
            address expectedImplementation = vm.envAddress(string.concat("EXPECTED_", label, "_IMPLEMENTATION"));
            bytes32 expectedImplementationCodehash =
                vm.envBytes32(string.concat("EXPECTED_", label, "_IMPLEMENTATION_CODEHASH"));
            address actualImplementation = address(uint160(uint256(implementationWord)));
            require(
                implementationWord == bytes32(uint256(uint160(actualImplementation))),
                string.concat("VerifyHelpers: ", label, " malformed implementation slot")
            );
            require(
                actualImplementation == expectedImplementation,
                string.concat("VerifyHelpers: ", label, " implementation mismatch")
            );
            require(
                actualImplementation.code.length != 0,
                string.concat("VerifyHelpers: ", label, " implementation has no bytecode")
            );
            require(
                actualImplementation.codehash == expectedImplementationCodehash,
                string.concat("VerifyHelpers: ", label, " implementation codehash mismatch")
            );
            return;
        }

        require(
            kind == RUNTIME_KIND_HASH || kind == DIAMOND_KIND_HASH,
            string.concat("VerifyHelpers: ", label, " unsupported identity kind")
        );
        require(implementationWord == bytes32(0), string.concat("VerifyHelpers: ", label, " undeclared proxy"));
    }

    function _verifyLocalDeployment(HelperArtifacts memory art, address permit2_) internal view {
        require(
            art.diamond.codehash == keccak256(type(HelpersDiamond).runtimeCode),
            "VerifyHelpers: diamond runtime mismatch"
        );
        _verifyFacetCode(art.cutFacet, keccak256(type(DiamondCutOwnerLiveFacet).runtimeCode), "cut");
        _verifyFacetCode(art.loupeFacet, keccak256(type(ProtocolDiamondLoupeFacet).runtimeCode), "loupe");
        _verifyFacetCode(art.ownershipFacet, keccak256(type(OwnershipFacet).runtimeCode), "ownership");
        _verifyFacetCode(art.pauseFacet, keccak256(type(OwnerPausableFacet).runtimeCode), "pause");
        _verifyImmutableFacetCode(art.adminFacet, "src/facets/RouterAdminFacet.sol:RouterAdminFacet", permit2_, "admin");
        // The preview facet inherits the common constructor for a uniform deployment surface,
        // but none of its view-only routes consume Permit2, so solc emits no immutable reference.
        _verifyFacetCode(
            art.issuePreviewFacet,
            keccak256(vm.getDeployedCode("src/facets/RouterIssuePreviewFacet.sol:RouterIssuePreviewFacet")),
            "issue preview"
        );
        _verifyImmutableFacetCode(art.issueFacet, "src/facets/RouterIssueFacet.sol:RouterIssueFacet", permit2_, "issue");
        _verifyImmutableFacetCode(
            art.issueBasketFacet,
            "src/facets/RouterIssueBasketFacet.sol:RouterIssueBasketFacet",
            permit2_,
            "issue basket"
        );
        // Consolidated redemption facets retain only views and no longer consume Permit2.
        _verifyFacetCode(
            art.redeemFacet,
            keccak256(vm.getDeployedCode("src/facets/RouterRedeemFacet.sol:RouterRedeemFacet")),
            "redeem"
        );
        _verifyFacetCode(
            art.redeemBasketFacet,
            keccak256(vm.getDeployedCode("src/facets/RouterRedeemBasketFacet.sol:RouterRedeemBasketFacet")),
            "redeem basket"
        );
        _verifyFacetCode(
            art.recoveryShareReceiverFacet,
            keccak256(type(RecoveryShareReceiverFacet).runtimeCode),
            "recovery share receiver"
        );
        require(
            art.diamondInit.codehash == keccak256(type(DiamondLiveInit).runtimeCode),
            "VerifyHelpers: init runtime mismatch"
        );

        DeploymentTypes.DeployArtifacts memory deployed;
        deployed.facets.cut = DiamondCutOwnerLiveFacet(art.cutFacet);
        deployed.facets.loupe = ProtocolDiamondLoupeFacet(art.loupeFacet);
        deployed.facets.ownership = OwnershipFacet(art.ownershipFacet);
        deployed.facets.pause = OwnerPausableFacet(art.pauseFacet);
        deployed.facets.admin = RouterAdminFacet(art.adminFacet);
        deployed.facets.issuePreview = RouterIssuePreviewFacet(art.issuePreviewFacet);
        deployed.facets.issue = RouterIssueFacet(art.issueFacet);
        deployed.facets.issueBasket = RouterIssueBasketFacet(art.issueBasketFacet);
        deployed.facets.redeem = RouterRedeemFacet(art.redeemFacet);
        deployed.facets.redeemBasket = RouterRedeemBasketFacet(art.redeemBasketFacet);
        deployed.facets.recoveryShareReceiver = RecoveryShareReceiverFacet(art.recoveryShareReceiverFacet);
        FacetSpec.Entry[] memory specs = DeploymentHelper.facetSpecs(deployed);
        IDiamondLoupe loupe = IDiamondLoupe(art.diamond);
        require(loupe.facetAddresses().length == specs.length, "VerifyHelpers: unexpected facet count");
        for (uint256 i; i < specs.length; ++i) {
            bytes4[] memory actualSelectors = loupe.facetFunctionSelectors(specs[i].facet);
            require(actualSelectors.length == specs[i].selectors.length, "VerifyHelpers: facet selector count mismatch");
            for (uint256 j; j < specs[i].selectors.length; ++j) {
                require(
                    loupe.facetAddress(specs[i].selectors[j]) == specs[i].facet,
                    "VerifyHelpers: facet selector mapping mismatch"
                );
            }
        }
    }

    function _verifyInitializerState(HelperArtifacts memory art) internal view {
        IERC165 interfaceView = IERC165(art.diamond);
        require(interfaceView.supportsInterface(type(IERC165).interfaceId), "VerifyHelpers: IERC165 missing");
        require(interfaceView.supportsInterface(type(IDiamondCut).interfaceId), "VerifyHelpers: IDiamondCut missing");
        require(
            interfaceView.supportsInterface(type(IDiamondLoupe).interfaceId), "VerifyHelpers: IDiamondLoupe missing"
        );
        require(interfaceView.supportsInterface(type(IERC173).interfaceId), "VerifyHelpers: IERC173 missing");
        require(
            !interfaceView.supportsInterface(type(ICyberGoldHelpers).interfaceId),
            "VerifyHelpers: aggregate Helpers interface advertised"
        );
        require(
            !interfaceView.supportsInterface(type(ICygldOutflowCallback).interfaceId),
            "VerifyHelpers: CYGLD outflow callback advertised"
        );
        require(
            !interfaceView.supportsInterface(type(ICygldApprovalCallback).interfaceId),
            "VerifyHelpers: CYGLD approval callback advertised"
        );
        require(
            !interfaceView.supportsInterface(type(IRecoveryShareOutflowCallback).interfaceId),
            "VerifyHelpers: recovery-share outflow callback advertised"
        );
        require(
            !interfaceView.supportsInterface(type(IRecoveryShareRedemptionCallback).interfaceId),
            "VerifyHelpers: recovery-share redemption callback advertised"
        );
        require(
            interfaceView.supportsInterface(type(IERC1155Receiver).interfaceId),
            "VerifyHelpers: ERC1155 receiver interface missing"
        );
        require(
            vm.load(art.diamond, RETIRED_REENTRANCY_GUARD_STORAGE_SLOT) == bytes32(0),
            "VerifyHelpers: retired reentrancy storage used"
        );
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.upgrade.coordinator.owner"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.shared.diamond.loupe"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.owner.pausable"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.ownership"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.admin"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.issue.preview"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.issue"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.issue.basket"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.redeem"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.redeem.basket"), 1);
        _verifyFacetGeneration(art.diamond, keccak256("cybergold.helpers.recovery-share-receiver"), 1);
    }

    function _verifyFacetGeneration(address diamond, bytes32 namespace, uint64 expectedGeneration) internal view {
        bytes32 versionSlot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        require(
            uint64(uint256(vm.load(diamond, versionSlot))) == expectedGeneration,
            "VerifyHelpers: facet generation mismatch"
        );
        (bool ok, bytes memory data) =
            diamond.staticcall(abi.encodeWithSignature("facetGeneration(bytes32)", namespace));
        require(
            ok && data.length == 32 && abi.decode(data, (uint64)) == expectedGeneration,
            "VerifyHelpers: facet generation getter mismatch"
        );
        for (uint256 offset = 1; offset <= 4; ++offset) {
            bytes32 retiredSlot =
                keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + offset)));
            require(vm.load(diamond, retiredSlot) == bytes32(0), "VerifyHelpers: retired registry entry used");
        }
    }

    function _verifyFacetCode(address facet, bytes32 expectedCodehash, string memory label) internal view {
        require(facet.codehash == expectedCodehash, string.concat("VerifyHelpers: ", label, " facet runtime mismatch"));
    }

    /// @dev Normalize every configured immutable Permit2 word and compare against Foundry's canonical runtime template.
    function _verifyImmutableFacetCode(address facet, string memory artifact, address permit2_, string memory label)
        internal
        view
    {
        bytes memory actual = facet.code;
        bytes memory expected = vm.getDeployedCode(artifact);
        require(actual.length == expected.length, string.concat("VerifyHelpers: ", label, " facet runtime mismatch"));

        bytes32 immutableWord = bytes32(uint256(uint160(permit2_)));
        bool normalized;
        if (actual.length >= 32) {
            for (uint256 i; i <= actual.length - 32; ++i) {
                bytes32 word;
                bytes32 templateWord;
                assembly ("memory-safe") {
                    word := mload(add(add(actual, 0x20), i))
                    templateWord := mload(add(add(expected, 0x20), i))
                }
                if (word == immutableWord && templateWord == bytes32(0)) {
                    normalized = true;
                    for (uint256 j; j < 32; ++j) {
                        actual[i + j] = 0;
                    }
                    i += 31;
                }
            }
        }
        require(normalized, string.concat("VerifyHelpers: ", label, " immutable missing"));
        require(
            keccak256(actual) == keccak256(expected), string.concat("VerifyHelpers: ", label, " facet runtime mismatch")
        );
    }

    function _verifyAdapters(ICyberGoldHelpers router, HelperArtifacts memory art, DeployParams.Params memory params)
        internal
        view
    {
        require(router.isAdapterApproved(art.oneInchAdapter), "VerifyHelpers: 1inch adapter not approved");
        require(router.isAdapterApproved(art.uniswapAdapter), "VerifyHelpers: Uniswap adapter not approved");

        address[] memory approved = router.approvedAdapters();
        _verifyExactAdapterSet(approved, art.oneInchAdapter, art.uniswapAdapter);
        require(_contains(approved, art.oneInchAdapter), "VerifyHelpers: 1inch adapter missing from list");
        require(_contains(approved, art.uniswapAdapter), "VerifyHelpers: Uniswap adapter missing from list");

        require(
            IOneInchAdapterView(art.oneInchAdapter).AGGREGATION_ROUTER() == params.oneInchRouter,
            "VerifyHelpers: 1inch router mismatch"
        );
        require(
            IUniswapUniversalAdapterView(art.uniswapAdapter).UNIVERSAL_ROUTER() == params.uniswapRouter,
            "VerifyHelpers: Uniswap router mismatch"
        );
        require(
            IUniswapUniversalAdapterView(art.uniswapAdapter).PERMIT2() == params.permit2,
            "VerifyHelpers: Uniswap Permit2 mismatch"
        );
        require(
            IRecoverableSwapAdapter(art.oneInchAdapter).helpersDiamond() == art.diamond,
            "VerifyHelpers: 1inch recovery authority mismatch"
        );
        require(
            IRecoverableSwapAdapter(art.uniswapAdapter).helpersDiamond() == art.diamond,
            "VerifyHelpers: Uniswap recovery authority mismatch"
        );
    }

    function _verifyExactAdapterSet(address[] memory approved, address oneInch, address uniswap) internal pure {
        require(approved.length == 2, "VerifyHelpers: unexpected approved adapter count");
        require(_contains(approved, oneInch), "VerifyHelpers: 1inch adapter missing from list");
        require(_contains(approved, uniswap), "VerifyHelpers: Uniswap adapter missing from list");
    }

    function _contains(address[] memory values, address needle) internal pure returns (bool) {
        for (uint256 i; i < values.length; ++i) {
            if (values[i] == needle) {
                return true;
            }
        }
        return false;
    }

    function _writeOutput(
        HelperArtifacts memory art,
        DeployParams.Params memory params,
        string memory releaseManifestId,
        string memory releaseManifestSha256
    ) internal {
        string memory label = "verifyHelpers";
        string memory out = vm.serializeUint(label, "chainId", block.chainid);
        out = vm.serializeAddress(label, "diamond", art.diamond);
        out = vm.serializeAddress(label, "admin", params.admin);
        out = vm.serializeAddress(label, "coreDiamond", params.coreDiamond);
        out = vm.serializeUint(label, "helperFeePpm", params.helperFeePpm);
        out = vm.serializeAddress(label, "permit2", params.permit2);
        out = vm.serializeAddress(label, "wrappedNative", params.wrappedNative);
        out = vm.serializeAddress(label, "oneInchAdapter", art.oneInchAdapter);
        out = vm.serializeAddress(label, "uniswapAdapter", art.uniswapAdapter);
        out = vm.serializeUint(label, "approvedAdapterCount", 2);
        out = vm.serializeBytes32(
            label, "approvedAdapterSetHash", keccak256(abi.encode(art.oneInchAdapter, art.uniswapAdapter))
        );
        out = vm.serializeString(label, "releaseManifestId", releaseManifestId);
        out = vm.serializeString(label, "releaseManifestSha256", releaseManifestSha256);
        out = vm.serializeBool(label, "ok", true);
        vm.writeJson(out, DeployOutput.outPath(vm, "verify-helpers.json"));
    }

    function _logSummary(HelperArtifacts memory art, DeployParams.Params memory params) internal pure {
        console2.log("=== Helpers verification ===");
        console2.log("Helpers diamond", art.diamond);
        console2.log("Admin", params.admin);
        console2.log("Core diamond", params.coreDiamond);
        console2.log("Helper fee ppm", params.helperFeePpm);
        console2.log("OneInchAdapter", art.oneInchAdapter);
        console2.log("UniswapAdapter", art.uniswapAdapter);
    }
}
