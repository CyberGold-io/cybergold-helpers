// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {MintableToken, MockCoreController} from "./mocks/BasketRouterMocks.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";

contract ReleaseAbiConformanceTest is Test {
    function testGeneratedReleaseAbiMatchesDeployedCutWithoutAggregateErc165Claim() public {
        MintableToken asset = new MintableToken("Gold", "GLD");
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;
        MockCoreController core = new MockCoreController(assets, values, values);

        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = address(core);
        cfg.permit2 = address(0x2222);
        cfg.wrappedNative = address(0xBEEF);
        cfg.approvedAdapters = new address[](0);
        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(cfg);

        // Reading the generated release ABI is the purpose of this conformance test.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/generated/abi/HelpersDiamond.json"));
        uint256[] memory selectorInts = abi.decode(vm.parseJson(json, ".selectorInts"), (uint256[]));
        bytes4[] memory expected = new bytes4[](selectorInts.length);
        for (uint256 i; i < selectorInts.length; ++i) {
            expected[i] = bytes4(uint32(selectorInts[i]));
        }
        bytes4 interfaceId = bytes4(uint32(vm.parseJsonUint(json, ".interfaceIdInt")));
        assertEq(selectorInts.length, 54, "frozen release selector count");
        assertEq(interfaceId, bytes4(0x57d58bc4), "frozen release interface id");
        IDiamondLoupe loupe = IDiamondLoupe(address(deployed.diamond));

        uint256 installedCount;
        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        for (uint256 i; i < facets.length; ++i) {
            installedCount += facets[i].functionSelectors.length;
        }
        assertEq(installedCount, expected.length, "release ABI/cut selector count");
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(loupe.facetAddress(expected[i]) != address(0), "release selector missing from cut");
            for (uint256 j = i + 1; j < expected.length; ++j) {
                assertTrue(expected[i] != expected[j], "duplicate release selector");
            }
        }
        IERC165 interfaceView = IERC165(address(deployed.diamond));
        assertFalse(interfaceView.supportsInterface(interfaceId), "aggregate release ABI must not be advertised");
        assertTrue(interfaceView.supportsInterface(type(IERC165).interfaceId), "IERC165 missing");
        assertTrue(interfaceView.supportsInterface(type(IDiamondCut).interfaceId), "IDiamondCut missing");
        assertTrue(interfaceView.supportsInterface(type(IDiamondLoupe).interfaceId), "IDiamondLoupe missing");
        assertTrue(interfaceView.supportsInterface(type(IERC173).interfaceId), "IERC173 missing");
        assertTrue(interfaceView.supportsInterface(type(IERC1155Receiver).interfaceId), "IERC1155Receiver missing");
        assertFalse(
            interfaceView.supportsInterface(type(ICygldOutflowCallback).interfaceId),
            "Helpers must not advertise the CYGLD outflow callback"
        );
        assertFalse(
            interfaceView.supportsInterface(type(ICygldApprovalCallback).interfaceId),
            "Helpers must not advertise the CYGLD approval callback"
        );
        assertFalse(
            interfaceView.supportsInterface(type(IRecoveryShareOutflowCallback).interfaceId),
            "Helpers must not advertise the recovery-share outflow callback"
        );
        assertFalse(
            interfaceView.supportsInterface(type(IRecoveryShareRedemptionCallback).interfaceId),
            "Helpers must not advertise the recovery-share redemption callback"
        );
        assertEq(interfaceId, type(ICyberGoldHelpers).interfaceId, "generated Solidity interface id");
    }
}
