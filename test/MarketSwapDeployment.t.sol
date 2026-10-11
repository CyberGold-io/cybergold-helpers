// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {MarketSwapDeployment} from "../src/deploy/MarketSwapDeployment.sol";
import {MarketSwapFacet} from "../src/facets/MarketSwapFacet.sol";
import {UniswapMultiProtocolAdapter} from "../src/adapters/UniswapMultiProtocolAdapter.sol";
import {IMarketSwap} from "../src/interfaces/IMarketSwap.sol";

interface IMarketGeneration {
    function facetGeneration(bytes32 namespace) external view returns (uint64);
}

contract MarketSwapDeploymentTest is Test {
    function test_scopedCutUsesExistingCoordinatorAndPreservesCoreSelectors() public {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = address(0xC0FE);
        cfg.permit2 = address(0xA11CE2);
        cfg.wrappedNative = address(0xE7);
        cfg.approvedAdapters = new address[](0);
        DeploymentTypes.DeployArtifacts memory old = DeploymentHelper.deploy(cfg);
        address helpers = address(old.diamond);
        IDiamondLoupe loupe = IDiamondLoupe(helpers);
        bytes4 retainedSelector = bytes4(keccak256("coreDiamond()"));
        address retainedFacet = loupe.facetAddress(retainedSelector);
        (MarketSwapFacet facet, UniswapMultiProtocolAdapter adapter) =
            MarketSwapDeployment.deploy(helpers, address(0x220), cfg.permit2);
        IDiamondCut(helpers).diamondCut(MarketSwapDeployment.facetCut(address(facet)), address(0), "");
        assertEq(loupe.facetAddress(IMarketSwap.swapExactInput.selector), address(facet));
        assertEq(loupe.facetAddress(IMarketSwap.swapExactOutput.selector), address(facet));
        assertEq(loupe.facetAddress(retainedSelector), retainedFacet);
        assertEq(IMarketGeneration(helpers).facetGeneration(facet.FACET_NAMESPACE()), 1);
        assertEq(adapter.UNIVERSAL_ROUTER(), address(0x220));
    }
}
