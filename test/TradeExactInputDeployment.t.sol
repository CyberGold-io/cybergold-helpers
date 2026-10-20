// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {TradeExactInputDeployment} from "../src/deploy/TradeExactInputDeployment.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {MarketSwapFacet} from "../src/facets/MarketSwapFacet.sol";
import {RouterRedeemFacet} from "../src/facets/RouterRedeemFacet.sol";
import {RouterRedeemBasketFacet} from "../src/facets/RouterRedeemBasketFacet.sol";
import {RouterIssueBasketFacet} from "../src/facets/RouterIssueBasketFacet.sol";
import {UniswapRoutingAdapter} from "../src/adapters/UniswapRoutingAdapter.sol";
import {ITradeExactInput} from "../src/interfaces/ITradeExactInput.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {IMarketSwap} from "../src/interfaces/IMarketSwap.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ILegacyHelpers} from "./fixtures/legacy-exact-input/ILegacyHelpers.sol";
import {MockPermit2, MockWETH} from "./mocks/BasketRouterMocks.sol";

contract TradeExactInputDeploymentTest is Test {
    function testCurrentBaseAndScopedExtensionsComposeFortyFiveSelectors() public {
        MockPermit2 permit2 = new MockPermit2();
        MockWETH weth = new MockWETH();
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = address(0xC0FE);
        cfg.permit2 = address(permit2);
        cfg.wrappedNative = address(weth);
        cfg.approvedAdapters = new address[](0);
        DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(cfg);
        address helpers = address(deployed.diamond);
        IDiamondLoupe loupe = IDiamondLoupe(helpers);
        assertEq(_selectorCount(loupe), 43);
        MarketSwapFacet market = new MarketSwapFacet(address(permit2));
        IDiamond.FacetCut[] memory marketCut = new IDiamond.FacetCut[](1);
        bytes4[] memory marketSelectors = new bytes4[](1);
        marketSelectors[0] = IMarketSwap.swapExactOutput.selector;
        marketCut[0] = IDiamond.FacetCut(address(market), IDiamond.FacetCutAction.Add, marketSelectors);
        IDiamondCut(helpers).diamondCut(marketCut, address(0), "");
        assertEq(_selectorCount(loupe), 44);
        UniswapRoutingAdapter adapter =
            new UniswapRoutingAdapter(helpers, address(0x220), address(permit2), address(weth));
        address facet =
            vm.deployCode("TradeExactInFacet.sol:TradeExactInFacet", abi.encode(address(permit2), address(adapter)));
        IDiamondCut(helpers).diamondCut(TradeExactInputDeployment.activationCut(facet), address(0), "");
        assertEq(_selectorCount(loupe), 45);
        assertEq(loupe.facetAddress(ITradeExactInput.executeExactInput.selector), facet);
        assertEq(loupe.facetAddress(IMarketSwap.swapExactOutput.selector), address(market));
        bytes4[] memory retired = TradeExactInputDeployment.retiredSelectors();
        for (uint256 i; i < retired.length; ++i) {
            assertEq(loupe.facetAddress(retired[i]), address(0));
        }
        assertEq(adapter.helpersDiamond(), helpers);
        assertEq(adapter.UNIVERSAL_ROUTER(), address(0x220));
        assertEq(adapter.PERMIT2(), address(permit2));
        assertEq(adapter.WETH(), address(weth));
        assertFalse(IERC165(helpers).supportsInterface(type(ICyberGoldHelpers).interfaceId));
        _assertInstalledManifest(loupe, "generated/abi/HelpersDiamond.json", 43);
        _assertInstalledManifest(loupe, "generated/abi/HelpersMarket.json", 1);
        string memory exactInputJson = vm.readFile("generated/abi/HelpersExactInput.json");
        bytes4 exactInputSelector = bytes4(vm.parseJsonBytes(exactInputJson, ".selectors[0].selector"));
        assertEq(exactInputSelector, ITradeExactInput.executeExactInput.selector);
        assertEq(loupe.facetAddress(exactInputSelector), facet);
        assertFalse(vm.keyExistsJson(exactInputJson, ".selectors[1]"));
    }

    function testCurrentProductionFacetsContainNoRetiredDispatchers() public {
        bytes4[] memory retired = TradeExactInputDeployment.retiredSelectors();
        bytes[] memory calls = _retiredCalls();
        address market = address(new MarketSwapFacet(address(1)));
        address redeem = address(new RouterRedeemFacet(address(1)));
        address basketRedeem = address(new RouterRedeemBasketFacet(address(1)));
        address basketIssue = address(new RouterIssueBasketFacet(address(1)));
        for (uint256 i; i < retired.length; ++i) {
            address target = i == 0 ? market : i < 7 ? redeem : i < 10 ? basketRedeem : basketIssue;
            assertEq(bytes4(calls[i]), retired[i]);
            // Full, well-formed old calldata reaches a named validation error if that
            // dispatcher remains; selector-only calldata would fail ABI decoding either way.
            (bool success, bytes memory reason) = target.call(calls[i]);
            assertFalse(success);
            assertEq(reason.length, 0);
        }
    }

    function _retiredCalls() private pure returns (bytes[] memory calls) {
        calls = new bytes[](12);
        IMarketSwap.MarketSwapParams memory market;
        IMarketSwap.FundingAuthorization memory auth;
        calls[0] = abi.encodeCall(IMarketSwap.swapExactInput, (market, auth));
        IBasketRouterTypes.AggregatedNativeRedemptionRequest memory nativeRequest;
        IBasketRouterTypes.AggregatedRedemptionRequest memory tokenRequest;
        IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
        IBasketRouterTypes.PermitParams memory permit;
        IBasketRouterTypes.Permit2Params memory permit2;
        calls[1] = abi.encodeCall(ILegacyHelpers.redeemToNativeExactIn, (nativeRequest, legs));
        calls[2] = abi.encodeCall(ILegacyHelpers.redeemToNativeExactInWithPermit, (nativeRequest, permit, legs));
        calls[3] = abi.encodeCall(ILegacyHelpers.redeemToNativeExactInWithPermit2, (nativeRequest, permit2, legs));
        calls[4] = abi.encodeCall(ILegacyHelpers.redeemToTokenExactIn, (tokenRequest, legs));
        calls[5] = abi.encodeCall(ILegacyHelpers.redeemToTokenExactInWithPermit, (tokenRequest, permit, legs));
        calls[6] = abi.encodeCall(ILegacyHelpers.redeemToTokenExactInWithPermit2, (tokenRequest, permit2, legs));
        IBasketRouterTypes.BasketRedemptionRequest memory basket;
        calls[7] = abi.encodeCall(ILegacyHelpers.redeemToBasketExactIn, (basket));
        calls[8] = abi.encodeCall(ILegacyHelpers.redeemToBasketExactInWithPermit, (basket, permit));
        calls[9] = abi.encodeCall(ILegacyHelpers.redeemToBasketExactInWithPermit2, (basket, permit2));
        IBasketRouterTypes.BasketIssueExactInRequest memory issue;
        IBasketRouterTypes.BasketIssueInput[] memory inputs = new IBasketRouterTypes.BasketIssueInput[](0);
        IBasketRouterTypes.Permit2BatchParams memory batch;
        calls[10] = abi.encodeCall(ILegacyHelpers.issueFromBasketExactInWithMixedPermits, (issue, inputs, batch));
        calls[11] = abi.encodeCall(ILegacyHelpers.issueFromBasketExactInWithPermit2, (issue, batch));
    }

    function _selectorCount(IDiamondLoupe loupe) private view returns (uint256 count) {
        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        for (uint256 i; i < facets.length; ++i) {
            count += facets[i].functionSelectors.length;
        }
    }

    function _assertInstalledManifest(IDiamondLoupe loupe, string memory file, uint256 expected) private view {
        string memory json = vm.readFile(file);
        uint256[] memory selectors = abi.decode(vm.parseJson(json, ".selectorInts"), (uint256[]));
        assertEq(selectors.length, expected);
        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = bytes4(uint32(selectors[i]));
            assertTrue(loupe.facetAddress(selector) != address(0));
            for (uint256 j; j < i; ++j) {
                assertTrue(selectors[j] != selectors[i]);
            }
        }
    }
}
