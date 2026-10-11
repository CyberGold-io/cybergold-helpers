// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {DeployOutput} from "src/deploy/DeployOutput.sol";
import {DeploymentHelper} from "src/deploy/DeploymentHelper.sol";
import {HelpersDiamond} from "src/diamond/HelpersDiamond.sol";

contract DeployHelpersShell is Script {
    function run() external returns (HelpersDiamond diamond, address bootstrapDiamondCutFacet) {
        bytes32 salt = vm.envBytes32("HELPERS_DIAMOND_SALT");
        address bootstrapOwner = vm.envAddress("HELPERS_DIAMOND_BOOTSTRAP_OWNER");
        address create2Deployer = vm.envAddress("HELPERS_CREATE2_DEPLOYER");
        address expected = vm.envOr("HELPERS_DIAMOND_EXPECTED_ADDRESS", address(0));
        require(bootstrapOwner != address(0), "DeployHelpersShell: bootstrap owner missing");

        (diamond, bootstrapDiamondCutFacet) =
            DeploymentHelper.deployHelpersShellFrom(bootstrapOwner, salt, create2Deployer);

        if (expected != address(0)) {
            require(address(diamond) == expected, "DeployHelpersShell: expected address mismatch");
        }

        _writeOutput(salt, bootstrapOwner, address(diamond), bootstrapDiamondCutFacet);
        console2.log("=== Helpers diamond shell deployment ===");
        console2.log("Helpers diamond shell", address(diamond));
        console2.log("Bootstrap DiamondCutFacet", bootstrapDiamondCutFacet);
        console2.log("Bootstrap owner", bootstrapOwner);
        console2.logBytes32(salt);
    }

    function _writeOutput(bytes32 salt, address bootstrapOwner, address diamond, address bootstrapDiamondCutFacet)
        private
    {
        string memory label = "deploy";
        string memory out = vm.serializeUint(label, "chainId", block.chainid);
        out = vm.serializeAddress(label, "diamond", diamond);
        out = vm.serializeAddress(label, "bootstrapDiamondCutFacet", bootstrapDiamondCutFacet);
        out = vm.serializeAddress(label, "bootstrapOwner", bootstrapOwner);
        out = vm.serializeBytes32(label, "salt", salt);
        vm.writeJson(out, DeployOutput.outPath(vm, "deploy-helpers-shell.json"));
    }
}
