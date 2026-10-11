// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {AdapterDeployer} from "src/deploy/AdapterDeployer.sol";
import {DeployOutput} from "src/deploy/DeployOutput.sol";
import {DeploymentHelper} from "src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "src/deploy/DeploymentTypes.sol";
import {DeployParams} from "src/deploy/DeployParams.sol";
import {HelpersDiamond} from "src/diamond/HelpersDiamond.sol";

contract DeployHelpers is Script {
    using DeployParams for DeployParams.Params;

    struct DeploymentResult {
        DeploymentTypes.DeployArtifacts art;
        DeploymentTypes.DeployConfig resolvedCfg;
        address oneInchAdapter;
        address uniswapAdapter;
    }

    function run() external {
        DeployParams.Params memory params = DeployParams.fromEnv(vm);
        address deployer = msg.sender;

        DeploymentTypes.DeployConfig memory cfg = params.toConfig();

        DeploymentResult memory deployed = _deploy(cfg, params);
        _logDeployment(deployed, params, deployer);

        string memory outPath = DeployOutput.outPath(vm, "deploy-helpers.json");
        DeployParams.writeJson(
            vm, deployed.resolvedCfg, deployed.art, params, deployed.oneInchAdapter, deployed.uniswapAdapter, outPath
        );
    }

    function _deploy(DeploymentTypes.DeployConfig memory cfg, DeployParams.Params memory params)
        internal
        returns (DeploymentResult memory deployed)
    {
        address existingDiamond = vm.envAddress("HELPERS_DIAMOND_ADDRESS");
        require(existingDiamond.code.length != 0, "DeployHelpers: Helpers shell missing");

        AdapterDeployer.AdapterDeployment memory adapters = AdapterDeployer.deploy(params, existingDiamond);
        deployed.oneInchAdapter = adapters.oneInchAdapter;
        deployed.uniswapAdapter = adapters.uniswapAdapter;

        deployed.resolvedCfg = AdapterDeployer.applyToConfig(cfg, adapters);
        deployed.art = DeploymentHelper.finalizeExisting(HelpersDiamond(payable(existingDiamond)), deployed.resolvedCfg);
    }

    function _logDeployment(DeploymentResult memory deployed, DeployParams.Params memory params, address deployer)
        internal
        pure
    {
        console2.log("=== Helper deployment ===");
        console2.log("HelpersDiamond:", address(deployed.art.diamond));
        console2.log("DiamondInit:", address(deployed.art.diamondInit));
        console2.log("AdminFacet:", address(deployed.art.facets.admin));
        console2.log("IssuePreviewFacet:", address(deployed.art.facets.issuePreview));
        console2.log("IssueFacet:", address(deployed.art.facets.issue));
        console2.log("RedeemFacet:", address(deployed.art.facets.redeem));
        console2.log("OneInchAdapter:", deployed.oneInchAdapter);
        console2.log("UniswapAdapter:", deployed.uniswapAdapter);
        console2.log("Core diamond:", params.coreDiamond);
        console2.log("Simulation sender:", deployer);
        console2.log("Permit2:", params.permit2);
        console2.log("Wrapped native:", params.wrappedNative);
        console2.log("Router owner:", params.admin);
        console2.log("Helper fee (ppm):", params.helperFeePpm);
        console2.log("Post-deploy checklist:");
        console2.log("1) verify adapter approvals for 1inch/Uniswap; already set during deployment.");
        console2.log("2) verify helper fee with helperFeePpm() after deployment.");
        console2.log("3) confirm the owner was set during diamond construction.");
        console2.log("4) record helper addresses for integrators.");
        console2.log("5) confirm immutable Permit2 and WETH identities.");
    }
}
