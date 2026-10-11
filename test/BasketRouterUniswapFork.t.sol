// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {UniswapUniversalAdapter} from "../src/adapters/UniswapUniversalAdapter.sol";
import {HelpersDiamond} from "../src/diamond/HelpersDiamond.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {MockCoreController} from "./mocks/BasketRouterMocks.sol";

interface IUniswapQuoterV2ForkBasket {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

/// @notice Canonical Universal Router payload evidence through the retained generic product routes.
contract BasketRouterUniswapForkTest is Test {
    address private constant UNIVERSAL_ROUTER = 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA;
    address private constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USER = address(0xBEEF);

    UniswapUniversalAdapter private adapter;
    ICyberGoldHelpers private router;
    MockCoreController private core;

    function setUp() public {
        if (
            WETH.code.length == 0 || USDC.code.length == 0 || QUOTER_V2.code.length == 0
                || UNIVERSAL_ROUTER.code.length == 0 || PERMIT2.code.length == 0
        ) revert("fork is not mainnet-like");

        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = WETH;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 500_000;
        weights[1] = 500_000;
        uint256[] memory conversions = new uint256[](2);
        conversions[0] = 1e30;
        conversions[1] = 1e18;
        core = new MockCoreController(assets, weights, conversions);

        (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers.uniswap.fork"));
        adapter = new UniswapUniversalAdapter(address(shell), UNIVERSAL_ROUTER, PERMIT2);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = address(core);
        cfg.permit2 = PERMIT2;
        cfg.wrappedNative = WETH;
        cfg.approvedAdapters = new address[](1);
        cfg.approvedAdapters[0] = address(adapter);
        DeploymentHelper.finalizeExisting(shell, cfg);
        router = ICyberGoldHelpers(address(shell));
    }

    function testGenericPreviewIssueAndRedeemViaUniversalRouter() public {
        uint256 targetCygld = 1 ether;
        (, uint256[] memory required,) = core.previewIssueFromBasketExactOut(targetCygld);
        (IBasketRouterTypes.IssueSwapLeg memory issueLeg,) = _issueLegMeetingMinimum(WETH, USDC, required[0], 1e12);
        IBasketRouterTypes.IssueSwapLeg[] memory issueLegs = new IBasketRouterTypes.IssueSwapLeg[](1);
        issueLegs[0] = issueLeg;
        uint256 maximumInput = required[1] + issueLeg.amountIn;
        IBasketRouterTypes.IssueFromTokenExactOutParams memory issueParams =
            IBasketRouterTypes.IssueFromTokenExactOutParams({
                inputToken: WETH, maximumInputAmount: maximumInput, netCygldOut: targetCygld
            });

        IBasketRouterTypes.IssueExactOutPreview memory issuePreview =
            router.previewIssueFromTokenExactOut(issueParams, issueLegs);
        assertEq(issuePreview.orderedCoreAssets, core.basketAssets());
        assertEq(issuePreview.fees.protocolFeeCygld, 0);

        deal(WETH, USER, maximumInput);
        vm.startPrank(USER);
        IERC20(WETH).approve(address(router), maximumInput);
        router.issueFromTokenExactOut(
            issueParams,
            IBasketRouterTypes.IssueExecutionParams({
                recipient: USER, expectedOrderedCoreAssets: issuePreview.orderedCoreAssets
            }),
            issueLegs
        );
        vm.stopPrank();
        assertEq(IERC20(address(core)).balanceOf(USER), targetCygld);

        IBasketRouterTypes.AggregatedRedemptionResult memory redemption = _redeemToWeth(targetCygld);
        assertGt(redemption.amountOut, 0);
        assertEq(IERC20(address(core)).balanceOf(USER), 0);
    }

    function testExactInPreviewsRemainAdvisoryAndDoNotInvokeUniversalRouter() public {
        uint256 inputAmount = 0.55 ether;
        uint256 swapAmount = 0.01 ether;
        (bytes memory path, uint256 quotedOut) = _quoteFirstPath(WETH, USDC, swapAmount);
        IBasketRouterTypes.IssueSwapLeg[] memory legs = new IBasketRouterTypes.IssueSwapLeg[](1);
        legs[0] = IBasketRouterTypes.IssueSwapLeg({
            adapter: address(adapter),
            amountIn: swapAmount,
            minimumAmountOut: quotedOut * 99 / 100,
            data: _adapterData(path, quotedOut * 99 / 100)
        });
        IBasketRouterTypes.IssueExactInPreview memory preview = router.previewIssueFromTokenExactIn(
            IBasketRouterTypes.IssueFromTokenExactInParams({inputToken: WETH, inputAmount: inputAmount}), legs
        );
        assertGt(preview.netCygldOut, 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
    }

    function _redeemToWeth(uint256 grossCygldIn)
        private
        returns (IBasketRouterTypes.AggregatedRedemptionResult memory result)
    {
        ICoreRedemption.RedemptionQuote memory quote = core.previewRedeemExactIn(grossCygldIn);
        (bytes memory path, uint256 quotedOut) = _quoteFirstPath(USDC, WETH, quote.outputs[0].amount);
        uint256 minimumSwapOut = quotedOut * 99 / 100;
        IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
        legs[0] = IBasketRouterTypes.RedemptionSwapLeg({
            adapter: address(adapter), minimumAmountOut: minimumSwapOut, data: _adapterData(path, minimumSwapOut)
        });
        IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
            IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: grossCygldIn, outputToken: WETH}), legs
        );
        IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
            grossCygldIn: grossCygldIn,
            outputToken: WETH,
            recipient: USER,
            minimumAmountOut: preview.minimumAmountOut,
            expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
        });
        vm.startPrank(USER);
        IERC20(address(core)).approve(address(router), grossCygldIn);
        result = router.redeemToTokenExactIn(request, legs);
        vm.stopPrank();
    }

    function _issueLegMeetingMinimum(address tokenIn, address tokenOut, uint256 minimumOut, uint256 startAmountIn)
        private
        returns (IBasketRouterTypes.IssueSwapLeg memory leg, uint256 quotedOut)
    {
        uint256 amountIn = startAmountIn;
        for (uint256 step; step < 18; ++step) {
            bytes memory path;
            (path, quotedOut) = _quoteFirstPath(tokenIn, tokenOut, amountIn);
            if (quotedOut >= minimumOut) {
                leg = IBasketRouterTypes.IssueSwapLeg({
                    adapter: address(adapter),
                    amountIn: amountIn,
                    minimumAmountOut: minimumOut,
                    data: _adapterData(path, minimumOut)
                });
                return (leg, quotedOut);
            }
            amountIn *= 2;
        }
        revert("unable to satisfy minimum");
    }

    function _quoteFirstPath(address tokenIn, address tokenOut, uint256 amountIn)
        private
        returns (bytes memory path, uint256 amountOut)
    {
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(10000)];
        for (uint256 i; i < fees.length; ++i) {
            path = abi.encodePacked(tokenIn, fees[i], tokenOut);
            try IUniswapQuoterV2ForkBasket(QUOTER_V2).quoteExactInput(path, amountIn) returns (
                uint256 output, uint160[] memory, uint32[] memory, uint256
            ) {
                if (output != 0) return (path, output);
            } catch {}
        }
        revert("no viable pool");
    }

    function _adapterData(bytes memory path, uint256 minimumOut) private view returns (bytes memory) {
        return abi.encode(path, minimumOut, block.timestamp + 30 minutes, true);
    }

    function _minimums(ICoreRedemption.TokenAmount[] memory outputs)
        private
        pure
        returns (ICoreRedemption.TokenMinimum[] memory minimums)
    {
        minimums = new ICoreRedemption.TokenMinimum[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            minimums[i] = ICoreRedemption.TokenMinimum({
                kind: outputs[i].kind, token: outputs[i].token, id: outputs[i].id, minimumAmount: outputs[i].amount
            });
        }
    }
}
