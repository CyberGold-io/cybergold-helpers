// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";

import {HelpersDiamond} from "../diamond/HelpersDiamond.sol";
import {DiamondLiveInit} from "./DiamondLiveInit.sol";
import {BaseDiamondHelper} from "diamond-infra/deploy/BaseDiamondHelper.sol";
import {FacetSelectors as SharedFacetSelectors} from "diamond-infra/deploy/FacetSelectors.sol";
import {FacetSpec} from "diamond-infra/deploy/FacetSpec.sol";
import {OwnerFacetSpec} from "./OwnerFacetSpec.sol";
import {OwnerFacetSelectors} from "./OwnerFacetSelectors.sol";
import {DiamondCutFacet} from "diamond-1/facets/DiamondCutFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {OwnershipFacet} from "../facets/OwnershipFacet.sol";
import {OwnerPausableFacet} from "../facets/OwnerPausableFacet.sol";
import {RouterAdminFacet} from "../facets/RouterAdminFacet.sol";
import {RouterIssuePreviewFacet} from "../facets/RouterIssuePreviewFacet.sol";
import {RouterIssueFacet} from "../facets/RouterIssueFacet.sol";
import {RouterIssueBasketFacet} from "../facets/RouterIssueBasketFacet.sol";
import {RouterRedeemFacet} from "../facets/RouterRedeemFacet.sol";
import {RouterRedeemBasketFacet} from "../facets/RouterRedeemBasketFacet.sol";
import {RecoveryShareReceiverFacet} from "../facets/RecoveryShareReceiverFacet.sol";
import {DiamondCutOwnerLiveFacet} from "../facets/DiamondCutOwnerLiveFacet.sol";
import {FacetSelectors} from "./FacetSelectors.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice Shared deployment harness reused by scripts and integration tests to avoid drift.
library DeploymentHelper {
    /// @dev Deploy operation state.
    /// @param cfg Initializer or deployment config consumed by this function.
    /// @return out Deployed Helpers facets, initializer, adapters, and diamond.
    function deploy(DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out)
    {
        _validateConfig(cfg);
        out.facets = _deployFacets(cfg);
        out.diamondInit = new DiamondLiveInit();

        (IDiamond.FacetCut[] memory cut, DiamondArgs memory args) = _buildFullCutAndArgs(cfg, out, false);

        out.diamond = new HelpersDiamond(cut, args);
    }

    /// @dev Deploy a deterministic Helpers shell.
    /// @param bootstrapOwner Temporary owner used only for the reviewed finalizing diamond cut.
    /// @param salt CREATE2 salt used for the Helpers diamond shell.
    /// @return diamond Helpers diamond shell address.
    /// @return bootstrapDiamondCutFacet Bootstrap DiamondCut facet address used during shell deployment.
    function deployHelpersShell(address bootstrapOwner, bytes32 salt)
        internal
        returns (HelpersDiamond diamond, address bootstrapDiamondCutFacet)
    {
        return _deployHelpersShell(bootstrapOwner, salt, address(this));
    }

    /// @dev Foundry broadcasts salted creation through its configured CREATE2 deployer.
    function deployHelpersShellFrom(address bootstrapOwner, bytes32 salt, address create2Deployer)
        internal
        returns (HelpersDiamond diamond, address bootstrapDiamondCutFacet)
    {
        require(create2Deployer != address(0), "DeploymentHelper: CREATE2 deployer missing");
        return _deployHelpersShell(bootstrapOwner, salt, create2Deployer);
    }

    function _deployHelpersShell(address bootstrapOwner, bytes32 salt, address create2Deployer)
        private
        returns (HelpersDiamond diamond, address bootstrapDiamondCutFacet)
    {
        require(bootstrapOwner != address(0), "DeploymentHelper: bootstrap owner missing");

        bytes32 bootstrapSalt = keccak256(abi.encodePacked("cybergold.helpers.bootstrapCut", salt));
        bootstrapDiamondCutFacet =
            _create2Address(create2Deployer, bootstrapSalt, keccak256(type(DiamondCutFacet).creationCode));
        if (bootstrapDiamondCutFacet.code.length == 0) {
            DiamondCutFacet cutFacet = new DiamondCutFacet{salt: bootstrapSalt}();
            require(address(cutFacet) == bootstrapDiamondCutFacet, "DeploymentHelper: bootstrap address mismatch");
        } else {
            require(
                bootstrapDiamondCutFacet.codehash == keccak256(type(DiamondCutFacet).runtimeCode),
                "DeploymentHelper: bootstrap runtime mismatch"
            );
        }
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: bootstrapDiamondCutFacet,
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: SharedFacetSelectors.cutSelectors()
        });

        DiamondArgs memory args = BaseDiamondHelper.buildArgs(bootstrapOwner, address(0), "");
        bytes memory diamondInitCode = bytes.concat(type(HelpersDiamond).creationCode, abi.encode(cut, args));
        address diamondAddress = _create2Address(create2Deployer, salt, keccak256(diamondInitCode));
        if (diamondAddress.code.length == 0) {
            diamond = new HelpersDiamond{salt: salt}(cut, args);
            require(address(diamond) == diamondAddress, "DeploymentHelper: diamond address mismatch");
        } else {
            require(
                diamondAddress.codehash == keccak256(type(HelpersDiamond).runtimeCode),
                "DeploymentHelper: diamond runtime mismatch"
            );
            diamond = HelpersDiamond(payable(diamondAddress));
        }
    }

    function _create2Address(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    /// @dev Deploy each logical facet unless audited evidence supplied an exact runtime match.
    function _deployFacets(DeploymentTypes.DeployConfig memory cfg)
        private
        returns (DeploymentTypes.Facets memory facets)
    {
        address candidate = _reuse(cfg.facetOverrides.cut, "cut");
        facets.cut = candidate == address(0) ? new DiamondCutOwnerLiveFacet() : DiamondCutOwnerLiveFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.loupe, "loupe");
        facets.loupe = candidate == address(0) ? new ProtocolDiamondLoupeFacet() : ProtocolDiamondLoupeFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.ownership, "ownership");
        facets.ownership = candidate == address(0) ? new OwnershipFacet() : OwnershipFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.pause, "pause");
        facets.pause = candidate == address(0) ? new OwnerPausableFacet() : OwnerPausableFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.admin, "admin");
        facets.admin = candidate == address(0) ? new RouterAdminFacet(cfg.permit2) : RouterAdminFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.issuePreview, "issuePreview");
        facets.issuePreview =
            candidate == address(0) ? new RouterIssuePreviewFacet(cfg.permit2) : RouterIssuePreviewFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.issue, "issue");
        facets.issue = candidate == address(0) ? new RouterIssueFacet(cfg.permit2) : RouterIssueFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.issueBasket, "issueBasket");
        facets.issueBasket =
            candidate == address(0) ? new RouterIssueBasketFacet(cfg.permit2) : RouterIssueBasketFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.redeem, "redeem");
        facets.redeem = candidate == address(0) ? new RouterRedeemFacet(cfg.permit2) : RouterRedeemFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.redeemBasket, "redeemBasket");
        facets.redeemBasket =
            candidate == address(0) ? new RouterRedeemBasketFacet(cfg.permit2) : RouterRedeemBasketFacet(candidate);

        candidate = _reuse(cfg.facetOverrides.recoveryShareReceiver, "recoveryShareReceiver");
        facets.recoveryShareReceiver =
            candidate == address(0) ? new RecoveryShareReceiverFacet() : RecoveryShareReceiverFacet(candidate);
    }

    /// @dev Reject absent, mismatched, or unbound candidate code before it can enter a cut.
    function _reuse(DeploymentTypes.FacetOverride memory override_, string memory name) private view returns (address) {
        if (override_.facet == address(0)) {
            require(override_.runtimeCodeHash == bytes32(0), "DeploymentHelper: unused override has codehash");
            return address(0);
        }
        require(override_.runtimeCodeHash != bytes32(0), "DeploymentHelper: override codehash missing");
        require(
            override_.facet.codehash == override_.runtimeCodeHash,
            string.concat("DeploymentHelper: ", name, " runtime mismatch")
        );
        return override_.facet;
    }

    /// @dev Finalize an existing deterministic Helpers shell.
    /// @param diamond Helpers diamond shell to finalize.
    /// @param cfg Deployment configuration for the finalized Helpers diamond.
    /// @return out Deployment artifacts for the finalized diamond.
    function finalizeExisting(HelpersDiamond diamond, DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out)
    {
        bytes memory finalizationCalldata;
        (out, finalizationCalldata) = prepareExistingFinalization(diamond, cfg);
        (bool succeeded, bytes memory returndata) = address(diamond).call(finalizationCalldata);
        if (!succeeded) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
    }

    /// @dev Deploy fresh artifacts and encode the owner-authorized finalizing cut.
    /// @notice The returned calldata is intended for the shell owner (normally a Safe).
    /// It lets an EOA prepare audited facet/adapter artifacts without acquiring the
    /// authority to finalize a Safe-owned shell.
    function prepareExistingFinalization(HelpersDiamond diamond, DeploymentTypes.DeployConfig memory cfg)
        internal
        returns (DeploymentTypes.DeployArtifacts memory out, bytes memory finalizationCalldata)
    {
        require(address(diamond) != address(0), "DeploymentHelper: diamond missing");
        require(address(diamond).code.length != 0, "DeploymentHelper: diamond has no code");
        _validateConfig(cfg);

        out.facets = _deployFacets(cfg);
        out.diamondInit = new DiamondLiveInit();
        out.diamond = diamond;

        (IDiamond.FacetCut[] memory cut, DiamondArgs memory args) = _buildFullCutAndArgs(cfg, out, true);
        IDiamond.FacetCut[] memory finalizedCut = new IDiamond.FacetCut[](cut.length + 1);
        finalizedCut[0] = IDiamond.FacetCut({
            facetAddress: address(out.facets.cut),
            action: IDiamond.FacetCutAction.Replace,
            functionSelectors: OwnerFacetSelectors.cutSelectors()
        });
        bytes4[] memory generationSelector = new bytes4[](1);
        generationSelector[0] = OwnerFacetSelectors.liveCutSelectors()[1];
        finalizedCut[1] = IDiamond.FacetCut({
            facetAddress: address(out.facets.cut),
            action: IDiamond.FacetCutAction.Add,
            functionSelectors: generationSelector
        });
        for (uint256 i = 1; i < cut.length; ++i) {
            finalizedCut[i + 1] = cut[i];
        }

        finalizationCalldata =
            abi.encodeWithSelector(IDiamondCut.diamondCut.selector, finalizedCut, args.init, args.initCalldata);
    }

    /// @dev Build the full facet cut and initialization args for a Helpers deployment.
    function _buildFullCutAndArgs(
        DeploymentTypes.DeployConfig memory cfg,
        DeploymentTypes.DeployArtifacts memory out,
        bool requirePristineShell
    ) private pure returns (IDiamond.FacetCut[] memory cut, DiamondArgs memory args) {
        cut = FacetSpec.buildCut(facetSpecs(out));
        uint256 expectedSelectorCount;
        for (uint256 i; i < cut.length; ++i) {
            expectedSelectorCount += cut[i].functionSelectors.length;
        }

        DiamondLiveInit.InitConfig memory initCfg = DiamondLiveInit.InitConfig({
            owner: cfg.admin,
            requirePristineShell: requirePristineShell,
            expectedSelectorCount: expectedSelectorCount,
            loupeFacet: address(out.facets.loupe),
            pausableFacet: address(out.facets.pause),
            ownershipFacet: address(out.facets.ownership),
            adminFacet: address(out.facets.admin),
            issuePreviewFacet: address(out.facets.issuePreview),
            issueFacet: address(out.facets.issue),
            issueBasketFacet: address(out.facets.issueBasket),
            redeemFacet: address(out.facets.redeem),
            redeemBasketFacet: address(out.facets.redeemBasket),
            recoveryShareReceiverFacet: address(out.facets.recoveryShareReceiver),
            coreDiamond: cfg.coreDiamond,
            wrappedNative: cfg.wrappedNative,
            helperFeePpm: cfg.helperFeePpm,
            approvedAdapters: cfg.approvedAdapters
        });

        args = BaseDiamondHelper.buildArgs(
            cfg.admin, address(out.diamondInit), abi.encodeWithSelector(DiamondLiveInit.init.selector, initCfg)
        );
    }

    function _validateConfig(DeploymentTypes.DeployConfig memory cfg) private pure {
        require(cfg.admin != address(0), "DeploymentHelper: admin missing");
        require(cfg.permit2 != address(0), "DeploymentHelper: Permit2 missing");
    }

    /// @notice Build the canonical ordered facet specification for deployment and artifacts.
    function facetSpecs(DeploymentTypes.DeployArtifacts memory art)
        internal
        pure
        returns (FacetSpec.Entry[] memory specs)
    {
        FacetSpec.Entry[] memory baseSpecs = OwnerFacetSpec.liveBase(
            address(art.facets.cut),
            address(art.facets.loupe),
            address(art.facets.ownership),
            address(art.facets.pause),
            true
        );
        FacetSpec.Entry[] memory routerSpecs = FacetSelectors.specs(
            address(art.facets.admin),
            address(art.facets.issuePreview),
            address(art.facets.issue),
            address(art.facets.issueBasket),
            address(art.facets.redeem),
            address(art.facets.redeemBasket),
            address(art.facets.recoveryShareReceiver)
        );
        specs = FacetSpec.concat(baseSpecs, routerSpecs);
    }
}
