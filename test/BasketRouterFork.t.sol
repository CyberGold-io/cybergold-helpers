// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {OneInchAdapter} from "../src/adapters/OneInchAdapter.sol";
import {HelpersDiamond} from "../src/diamond/HelpersDiamond.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {MockCoreController, MockPermit2} from "./mocks/BasketRouterMocks.sol";

interface IAggregationRouterV6 {
    function unoswap(uint256 srcToken, uint256 amount, uint256 minReturn, uint256 dex)
        external
        returns (uint256 returnAmount);
}

interface IUniswapV2PairFork {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// @notice Canonical 1inch payload evidence through the retained generic issue/redeem routes.
contract BasketRouterForkTest is Test {
    address private constant AGG_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant UNIV2_USDC_WETH = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    uint32 private constant UNISWAP_V2_NUMERATOR = 997_000_000;
    uint32 private constant UNO_DENOMINATOR = 1_000_000_000;

    address private constant USER = address(0xBEEF);

    OneInchAdapter private adapter;
    ICyberGoldHelpers private router;
    MockCoreController private core;
    MockPermit2 private permit2;

    function setUp() public {
        if (
            WETH.code.length == 0 || USDC.code.length == 0 || AGG_ROUTER.code.length == 0
                || UNIV2_USDC_WETH.code.length == 0
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
        permit2 = new MockPermit2();

        (HelpersDiamond shell,) = DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers.oneinch.fork"));
        adapter = new OneInchAdapter(address(shell), AGG_ROUTER);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = address(core);
        cfg.permit2 = address(permit2);
        cfg.wrappedNative = WETH;
        cfg.approvedAdapters = new address[](1);
        cfg.approvedAdapters[0] = address(adapter);
        DeploymentHelper.finalizeExisting(shell, cfg);
        router = ICyberGoldHelpers(address(shell));
    }

    function testGenericIssueAndRedeemThroughCanonicalOneInchPayloads() public {
        uint256 targetCygld = 1 ether;
        _issueFromWeth(targetCygld);
        assertEq(IERC20(address(core)).balanceOf(USER), targetCygld);

        uint256 wethBefore = IERC20(WETH).balanceOf(USER);
        IBasketRouterTypes.AggregatedRedemptionResult memory result = _redeemToWeth(targetCygld);
        assertGt(result.amountOut, 0);
        assertEq(IERC20(WETH).balanceOf(USER), wethBefore + result.amountOut);
        assertEq(IERC20(address(core)).balanceOf(USER), 0);
    }

    function _issueFromWeth(uint256 targetCygld) private {
        (, uint256[] memory required,) = core.previewIssueFromBasketExactOut(targetCygld);
        uint256 swapAmountIn = _amountInForExactOut(required[0], true);
        uint256 maximumInput = swapAmountIn + required[1];
        uint256 dex = _encodeUnoPool(UNIV2_USDC_WETH, false);

        IBasketRouterTypes.IssueSwapLeg[] memory legs = new IBasketRouterTypes.IssueSwapLeg[](1);
        legs[0] = IBasketRouterTypes.IssueSwapLeg({
            adapter: address(adapter),
            amountIn: swapAmountIn,
            minimumAmountOut: required[0],
            data: abi.encodeWithSelector(
                IAggregationRouterV6.unoswap.selector, uint256(uint160(WETH)), swapAmountIn, required[0], dex
            )
        });
        IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
            inputToken: WETH, maximumInputAmount: maximumInput, netCygldOut: targetCygld
        });
        IBasketRouterTypes.IssueExecutionParams memory execution =
            IBasketRouterTypes.IssueExecutionParams({recipient: USER, expectedOrderedCoreAssets: core.basketAssets()});

        deal(WETH, USER, maximumInput);
        vm.startPrank(USER);
        IERC20(WETH).approve(address(router), maximumInput);
        router.issueFromTokenExactOut(params, execution, legs);
        vm.stopPrank();
    }

    function _redeemToWeth(uint256 grossCygldIn)
        private
        returns (IBasketRouterTypes.AggregatedRedemptionResult memory result)
    {
        ICoreRedemption.RedemptionQuote memory corePreview = core.previewRedeemExactIn(grossCygldIn);
        uint256 minimumSwapOut = _amountOutForExactIn(corePreview.outputs[0].amount, false) * 99 / 100;
        uint256 dex = _encodeUnoPool(UNIV2_USDC_WETH, true);
        IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
        legs[0] = IBasketRouterTypes.RedemptionSwapLeg({
            adapter: address(adapter),
            minimumAmountOut: minimumSwapOut,
            data: abi.encodeWithSelector(
                IAggregationRouterV6.unoswap.selector,
                uint256(uint160(USDC)),
                corePreview.outputs[0].amount,
                minimumSwapOut,
                dex
            )
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

    function _encodeUnoPool(address pair, bool zeroForOne) private pure returns (uint256 word) {
        word = uint256(uint160(pair)) | (uint256(UNISWAP_V2_NUMERATOR) << 160);
        if (zeroForOne) word |= uint256(1) << 247;
    }

    function _amountInForExactOut(uint256 amountOut, bool reversed) private view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2PairFork(UNIV2_USDC_WETH).getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            reversed ? (uint256(reserve1), uint256(reserve0)) : (uint256(reserve0), uint256(reserve1));
        uint256 numerator = amountOut * reserveIn * UNO_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * UNISWAP_V2_NUMERATOR;
        return numerator / denominator + 1;
    }

    function _amountOutForExactIn(uint256 amountIn, bool reversed) private view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2PairFork(UNIV2_USDC_WETH).getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            reversed ? (uint256(reserve1), uint256(reserve0)) : (uint256(reserve0), uint256(reserve1));
        uint256 amountInWithFee = amountIn * UNISWAP_V2_NUMERATOR;
        return amountInWithFee * reserveOut / (reserveIn * UNO_DENOMINATOR + amountInWithFee);
    }
}
