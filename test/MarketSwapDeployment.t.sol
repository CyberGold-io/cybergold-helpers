// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {MarketSwapDeployment as CurrentMarketSwapDeployment} from "../src/deploy/MarketSwapDeployment.sol";
import {MarketSwapFacet as CurrentMarketSwapFacet} from "../src/facets/MarketSwapFacet.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {LegacyDeploymentHelper as DeploymentHelper} from "./fixtures/legacy-exact-input/LegacyDeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {
    LegacyMarketSwapDeployment as MarketSwapDeployment
} from "./fixtures/legacy-exact-input/LegacyMarketSwapDeployment.sol";
import {LegacyMarketSwapFacet as MarketSwapFacet} from "./fixtures/legacy-exact-input/LegacyMarketSwapFacet.sol";
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

contract CurrentMarketSwapDeploymentTest is Test {
    function testCurrentMarketExtensionDeploysOnlyRetainedExactOutputSelector() public {
        (CurrentMarketSwapFacet facet, UniswapMultiProtocolAdapter adapter) =
            CurrentMarketSwapDeployment.deploy(address(this), address(0x220), address(0xA11CE2));
        bytes4[] memory selectors = CurrentMarketSwapDeployment.selectors();
        assertEq(selectors.length, 1);
        assertEq(selectors[0], IMarketSwap.swapExactOutput.selector);
        IDiamond.FacetCut[] memory cut = CurrentMarketSwapDeployment.facetCut(address(facet));
        assertEq(cut.length, 1);
        assertEq(cut[0].facetAddress, address(facet));
        assertEq(uint256(cut[0].action), uint256(IDiamond.FacetCutAction.Add));
        assertEq(cut[0].functionSelectors[0], IMarketSwap.swapExactOutput.selector);
        assertEq(adapter.helpersDiamond(), address(this));
        assertEq(adapter.UNIVERSAL_ROUTER(), address(0x220));
    }
}
