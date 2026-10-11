// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {DeploymentHelper} from "./DeploymentHelper.sol";
import {DeployParamsHelper} from "diamond-infra/deploy/DeployParamsHelper.sol";

/// @notice Centralized parameter builder for helpers deployments.
library DeployParams {
    bytes32 private constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant STRICT_IDENTITY_POLICY_HASH = keccak256("strict-proxy-codehash-v1");
    bytes32 private constant LOCAL_IDENTITY_POLICY_HASH = keccak256("local-unsealed");
    bytes32 private constant RUNTIME_KIND_HASH = keccak256("runtime");
    bytes32 private constant DIAMOND_KIND_HASH = keccak256("diamond");
    bytes32 private constant EIP1967_PROXY_KIND_HASH = keccak256("eip1967-proxy");

    /// @notice Environment-derived deployment parameters.
    struct Params {
        address admin;
        uint256 helperFeePpm;
        address coreDiamond;
        address permit2;
        address wrappedNative;
        address oneInchRouter;
        address uniswapRouter;
        DeploymentTypes.FacetOverrides facetOverrides;
    }

    /// @notice Load params from environment variables used by the helper script.
    /// @dev HELPER_ADMIN is the owner configured in the diamond constructor.
    /// Required envs: CORE_DIAMOND_ADDRESS, HELPER_FEE_PPM, PERMIT2_ADDR, ONEINCH_ROUTER,
    /// UNISWAP_ROUTER, WETH_ADDR, and HELPER_ADMIN.
    /// @param vm_ Foundry VM cheatcode handle used to read environment variables.
    /// @return p Deployment parameters assembled from the environment.
    function fromEnv(Vm vm_) internal view returns (Params memory p) {
        p.admin = DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("HELPER_ADMIN"));
        p.helperFeePpm = DeployParamsHelper.envUintRequired(vm_, DeployParamsHelper.keys1("HELPER_FEE_PPM"));
        p.coreDiamond = DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("CORE_DIAMOND_ADDRESS"));
        p.permit2 = DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("PERMIT2_ADDR"));
        p.oneInchRouter = DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("ONEINCH_ROUTER"));
        p.uniswapRouter = DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("UNISWAP_ROUTER"));
        p.wrappedNative = DeployParamsHelper.envAddressRequired(vm_, DeployParamsHelper.keys1("WETH_ADDR"));
        p.facetOverrides = _facetOverridesFromEvidence(vm_);

        validate(p);
        _preflightDependencies(vm_, p);
    }

    /// @notice Validate required deployment dependencies independently of their source.
    /// @param p Deployment parameters to validate.
    function validate(Params memory p) internal pure {
        _requireAddress(p.admin, "HELPER_ADMIN");
        _requireAddress(p.coreDiamond, "CORE_DIAMOND_ADDRESS");
        _requireAddress(p.permit2, "PERMIT2_ADDR");
        _requireAddress(p.oneInchRouter, "ONEINCH_ROUTER");
        _requireAddress(p.uniswapRouter, "UNISWAP_ROUTER");
        _requireAddress(p.wrappedNative, "WETH_ADDR");
    }

    /// @dev Return to config.
    /// @param p Deployment parameter struct being loaded or serialized.
    /// @return cfg Configuration view or deployment parameters assembled by the helper.
    function toConfig(Params memory p) internal pure returns (DeploymentTypes.DeployConfig memory cfg) {
        cfg.admin = p.admin;
        cfg.coreDiamond = p.coreDiamond;
        cfg.permit2 = p.permit2;
        cfg.wrappedNative = p.wrappedNative;
        cfg.helperFeePpm = p.helperFeePpm;
        cfg.facetOverrides = p.facetOverrides;
    }

    /// @notice Persist deployment outputs to disk for reproducibility.
    /// @param vm_ Foundry VM cheatcode handle used to serialize and write JSON.
    /// @param cfg Helpers deployment configuration being serialized.
    /// @param art Deployed diamond and facet artifact addresses.
    /// @param p Raw deployment parameters loaded from the environment.
    /// @param oneInchAdapter Deployed 1inch adapter address.
    /// @param uniswapAdapter Deployed Uniswap universal router adapter address.
    /// @param path Output path for the deployment JSON file.
    function writeJson(
        Vm vm_,
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory art,
        Params memory p,
        address oneInchAdapter,
        address uniswapAdapter,
        string memory path
    ) internal {
        string memory label = "deploy";
        string memory out = DeployParamsHelper.baseJson(vm_, label, cfg.admin, address(art.diamondInit));
        out = vm_.serializeAddress(label, "diamond", address(art.diamond));
        out = vm_.serializeAddress(label, "coreDiamond", cfg.coreDiamond);
        out = vm_.serializeUint(label, "helperFeePpm", p.helperFeePpm);
        out = vm_.serializeAddress(label, "permit2", cfg.permit2);
        out = vm_.serializeAddress(label, "wrappedNative", cfg.wrappedNative);
        out = vm_.serializeAddress(label, "oneInchRouter", p.oneInchRouter);
        out = vm_.serializeAddress(label, "uniswapRouter", p.uniswapRouter);
        out = vm_.serializeAddress(label, "oneInchAdapter", oneInchAdapter);
        out = vm_.serializeAddress(label, "uniswapAdapter", uniswapAdapter);
        vm_.serializeUint(label, "approvedAdapterCount", 2);
        vm_.serializeBytes32(label, "approvedAdapterSetHash", keccak256(abi.encode(oneInchAdapter, uniswapAdapter)));
        out = DeployParamsHelper.writeFacetsFromSpecs(vm_, label, DeploymentHelper.facetSpecs(art));
        vm_.writeJson(out, path);
    }

    /// @dev Require one configured address to be nonzero.
    /// @param value Configured deployment address.
    /// @param label Environment-variable label used in an actionable error.
    function _requireAddress(address value, string memory label) private pure {
        require(value != address(0), string.concat(label, " must be provided"));
    }

    /// @dev Read Ops evidence that matched optional facet addresses to the sealed artifact runtime.
    /// The deployment helper independently rechecks every supplied address.codehash.
    function _facetOverridesFromEvidence(Vm vm_)
        private
        view
        returns (DeploymentTypes.FacetOverrides memory overrides_)
    {
        string memory path = vm_.envOr("HELPERS_FACET_REUSE_EVIDENCE_PATH", string(""));
        if (bytes(path).length == 0) return overrides_;

        string memory evidence = vm_.readFile(path);
        require(
            keccak256(bytes(vm_.parseJsonString(evidence, ".kind"))) == keccak256("cybergold-facet-reuse-evidence"),
            "DeployParams: invalid facet reuse evidence"
        );
        require(
            keccak256(bytes(vm_.parseJsonString(evidence, ".scope"))) == keccak256("helpers"),
            "DeployParams: facet reuse scope mismatch"
        );
        require(vm_.parseJsonUint(evidence, ".chainId") == block.chainid, "DeployParams: facet reuse chain mismatch");
        if (
            keccak256(bytes(vm_.envOr("HELPERS_IDENTITY_POLICY", string("local-unsealed"))))
                == STRICT_IDENTITY_POLICY_HASH
        ) {
            require(
                keccak256(bytes(vm_.parseJsonString(evidence, ".releaseManifest.id")))
                    == keccak256(bytes(vm_.envString("RELEASE_MANIFEST_ID"))),
                "DeployParams: facet reuse release ID mismatch"
            );
            require(
                keccak256(bytes(vm_.parseJsonString(evidence, ".releaseManifest.sha256")))
                    == keccak256(bytes(vm_.envString("RELEASE_MANIFEST_SHA256"))),
                "DeployParams: facet reuse release hash mismatch"
            );
        }

        overrides_.cut = _facetOverride(vm_, evidence, "cut");
        overrides_.loupe = _facetOverride(vm_, evidence, "loupe");
        overrides_.ownership = _facetOverride(vm_, evidence, "ownership");
        overrides_.pause = _facetOverride(vm_, evidence, "pause");
        overrides_.admin = _facetOverride(vm_, evidence, "admin");
        overrides_.issuePreview = _facetOverride(vm_, evidence, "issuePreview");
        overrides_.issue = _facetOverride(vm_, evidence, "issue");
        overrides_.issueBasket = _facetOverride(vm_, evidence, "issueBasket");
        overrides_.redeem = _facetOverride(vm_, evidence, "redeem");
        overrides_.redeemBasket = _facetOverride(vm_, evidence, "redeemBasket");
        overrides_.recoveryShareReceiver = _facetOverride(vm_, evidence, "recoveryShareReceiver");
    }

    function _facetOverride(Vm vm_, string memory evidence, string memory field)
        private
        view
        returns (DeploymentTypes.FacetOverride memory override_)
    {
        string memory path = string.concat(".overrides.", field);
        if (!vm_.keyExistsJson(evidence, path)) return override_;
        override_.facet = vm_.parseJsonAddress(evidence, string.concat(path, ".address"));
        override_.runtimeCodeHash = vm_.parseJsonBytes32(evidence, string.concat(path, ".runtimeCodehash"));
        require(override_.facet != address(0), "DeployParams: facet reuse address missing");
        require(override_.runtimeCodeHash != bytes32(0), "DeployParams: facet reuse codehash missing");
    }

    /// @dev Fail before adapter deployment or shell finalization on the wrong chain or dependency identity.
    function _preflightDependencies(Vm vm_, Params memory p) private view {
        bytes32 policy = keccak256(bytes(vm_.envOr("HELPERS_IDENTITY_POLICY", string("local-unsealed"))));
        bool strict = policy == STRICT_IDENTITY_POLICY_HASH;
        require(strict || policy == LOCAL_IDENTITY_POLICY_HASH, "DeployParams: unsupported identity policy");
        if (block.chainid == 1) {
            require(strict, "DeployParams: strict identity policy required on mainnet");
        }
        uint256 expectedChainId = vm_.envOr("EXPECTED_CHAIN_ID", uint256(0));
        if (strict) {
            require(expectedChainId != 0, "DeployParams: expected chain ID missing");
        } else if (expectedChainId == 0) {
            expectedChainId = block.chainid;
        }
        require(expectedChainId == block.chainid, "DeployParams: chain ID mismatch");

        _requireCode(p.coreDiamond, "CORE");
        _requireCode(p.permit2, "PERMIT2");
        _requireCode(p.wrappedNative, "WETH");
        _requireCode(p.oneInchRouter, "ONEINCH_ROUTER");
        _requireCode(p.uniswapRouter, "UNISWAP_ROUTER");

        if (!strict) return;

        require(bytes(vm_.envString("RELEASE_MANIFEST_ID")).length != 0, "DeployParams: release manifest ID missing");
        require(
            bytes(vm_.envString("RELEASE_MANIFEST_SHA256")).length == 64,
            "DeployParams: release manifest SHA-256 missing"
        );
        _verifyExternalIdentity(vm_, p.coreDiamond, "CORE");
        _verifyExternalIdentity(vm_, p.permit2, "PERMIT2");
        _verifyExternalIdentity(vm_, p.wrappedNative, "WETH");
        _verifyExternalIdentity(vm_, p.oneInchRouter, "ONEINCH_ROUTER");
        _verifyExternalIdentity(vm_, p.uniswapRouter, "UNISWAP_ROUTER");
    }

    function _requireCode(address target, string memory label) private view {
        require(target.code.length != 0, string.concat("DeployParams: ", label, " has no bytecode"));
    }

    function _verifyExternalIdentity(Vm vm_, address target, string memory label) private view {
        bytes32 kind = keccak256(bytes(vm_.envString(string.concat("EXPECTED_", label, "_KIND"))));
        bytes32 expectedCodehash = vm_.envBytes32(string.concat("EXPECTED_", label, "_CODEHASH"));
        require(target.codehash == expectedCodehash, string.concat("DeployParams: ", label, " codehash mismatch"));

        bytes32 implementationWord = vm_.load(target, EIP1967_IMPLEMENTATION_SLOT);
        if (kind == EIP1967_PROXY_KIND_HASH) {
            address expectedImplementation = vm_.envAddress(string.concat("EXPECTED_", label, "_IMPLEMENTATION"));
            bytes32 expectedImplementationCodehash =
                vm_.envBytes32(string.concat("EXPECTED_", label, "_IMPLEMENTATION_CODEHASH"));
            address actualImplementation = address(uint160(uint256(implementationWord)));
            require(
                implementationWord == bytes32(uint256(uint160(actualImplementation))),
                string.concat("DeployParams: ", label, " malformed implementation slot")
            );
            require(
                actualImplementation == expectedImplementation,
                string.concat("DeployParams: ", label, " implementation mismatch")
            );
            require(
                actualImplementation.code.length != 0,
                string.concat("DeployParams: ", label, " implementation has no bytecode")
            );
            require(
                actualImplementation.codehash == expectedImplementationCodehash,
                string.concat("DeployParams: ", label, " implementation codehash mismatch")
            );
            return;
        }

        require(
            kind == RUNTIME_KIND_HASH || kind == DIAMOND_KIND_HASH,
            string.concat("DeployParams: ", label, " unsupported identity kind")
        );
        require(implementationWord == bytes32(0), string.concat("DeployParams: ", label, " undeclared proxy"));
    }
}
