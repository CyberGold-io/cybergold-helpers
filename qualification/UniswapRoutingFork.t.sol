// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapRoutingTypes} from "../src/interfaces/IUniswapRoutingTypes.sol";
import {UniswapRoutingAdapter} from "../src/adapters/UniswapRoutingAdapter.sol";
import {MintableToken} from "../test/mocks/BasketRouterMocks.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {ITradeExactInput as T} from "../src/interfaces/ITradeExactInput.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

interface IRoutingForkPoolManager {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
    }
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
}

interface IRoutingForkV3Factory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IRoutingForkV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address owner, int24 lower, int24 upper, uint128 liquidity, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
}

/// @dev Fork-only bounded V3 liquidity; the factory, pool and Router code are real.
contract RoutingForkV3Liquidity {
    address private immutable POOL;
    address private immutable TOKEN0;
    address private immutable TOKEN1;

    constructor(address pool, address x, address y) {
        POOL = pool;
        (TOKEN0, TOKEN1) = x < y ? (x, y) : (y, x);
    }

    function fund() external {
        IRoutingForkV3Pool(POOL).initialize(uint160(1) << 96);
        IRoutingForkV3Pool(POOL).mint(address(this), -600, 600, 1e21, "");
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == POOL, "pool");
        require(IERC20(TOKEN0).transfer(POOL, amount0), "pay0");
        require(IERC20(TOKEN1).transfer(POOL, amount1), "pay1");
    }
}

/// @dev Only liquidity and token funding are synthetic. Router and PoolManager bytecode
/// are the actual pinned Mainnet deployment, including their real unlock credit accounting.
contract RoutingForkLiquidity {
    IRoutingForkPoolManager private immutable MANAGER;

    constructor(address manager) {
        MANAGER = IRoutingForkPoolManager(manager);
    }

    function fund(IRoutingForkPoolManager.PoolKey[] memory keys) external {
        MANAGER.unlock(abi.encode(keys));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(MANAGER), "manager");
        IRoutingForkPoolManager.PoolKey[] memory keys = abi.decode(data, (IRoutingForkPoolManager.PoolKey[]));
        for (uint256 i; i < keys.length; ++i) {
            MANAGER.initialize(keys[i], uint160(1) << 96);
            (int256 delta,) = MANAGER.modifyLiquidity(
                keys[i], IRoutingForkPoolManager.ModifyLiquidityParams(-600, 600, 1e21, bytes32(0)), ""
            );
            _settle(keys[i].currency0, int128(delta >> 128));
            _settle(keys[i].currency1, int128(delta));
        }
        return "";
    }

    function _settle(address currency, int128 delta) private {
        if (delta >= 0) return;
        uint256 debt = uint256(-int256(delta));
        MANAGER.sync(currency);
        if (currency == address(0)) {
            MANAGER.settle{value: debt}();
        } else {
            require(IERC20(currency).transfer(address(MANAGER), debt), "pay");
            MANAGER.settle();
        }
    }

    receive() external payable {}
}

contract UniswapRoutingForkTest is Test, IUniswapRoutingTypes {
    address private constant ROUTER = 0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address private constant CYGLD = 0x601da021cAF3DB5AA63e700D239b5935C370601d;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    uint256 private constant SNAPSHOT = 26164733;
    UniswapRoutingAdapter private adapter;
    MintableToken private a;
    MintableToken private b;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), SNAPSHOT);
        adapter = new UniswapRoutingAdapter(address(this), ROUTER, PERMIT2, WETH);
        a = new MintableToken("Fork Asset A", "FA");
        b = new MintableToken("Fork Asset B", "FB");
        RoutingForkLiquidity liquidity = new RoutingForkLiquidity(MANAGER);
        vm.deal(address(liquidity), 200 ether);
        a.mint(address(liquidity), 1_000_000 ether);
        b.mint(address(liquidity), 1_000_000 ether);
        IRoutingForkPoolManager.PoolKey[] memory keys = new IRoutingForkPoolManager.PoolKey[](3);
        keys[0] = _key(address(0), address(a));
        keys[1] = _key(address(0), address(b));
        keys[2] = _key(address(a), address(b));
        liquidity.fund(keys);
        vm.deal(address(this), 1 ether);
        vm.deal(address(adapter), 29);
        a.mint(address(adapter), 31);
        b.mint(address(adapter), 37);
    }

    function _key(address x, address y) private pure returns (IRoutingForkPoolManager.PoolKey memory) {
        return x < y
            ? IRoutingForkPoolManager.PoolKey(x, y, 3_000, 60, address(0))
            : IRoutingForkPoolManager.PoolKey(y, x, 3_000, 60, address(0));
    }

    function _plan(uint256 amount, Step[] memory steps) private view returns (SwapPlan memory plan) {
        plan.exactIn = true;
        plan.amountLimit = 1;
        plan.deadline = block.timestamp + 60;
        plan.branches = new Branch[](1);
        plan.branches[0] = Branch(amount, steps);
    }

    function testActualV4NativeInputGroupedPathKeyAndNativeOutput() public {
        Step[] memory steps = new Step[](2);
        steps[0] = Step(StepKind.V4, address(a), 3_000, 60);
        steps[1] = Step(StepKind.V4, address(b), 3_000, 60);
        uint256 output = adapter.swapNative{value: 1e16}(address(b), abi.encode(_plan(1e16, steps)));
        assertGt(output, 0);
        assertEq(b.balanceOf(address(this)), output);
        b.approve(address(adapter), output);
        steps[0] = Step(StepKind.V4, address(a), 3_000, 60);
        steps[1] = Step(StepKind.V4, address(0), 3_000, 60);
        uint256 beforeEth = address(this).balance;
        uint256 proceeds = adapter.swap(address(b), address(0), output, abi.encode(_plan(output, steps)));
        assertEq(address(this).balance - beforeEth, proceeds);
        assertGt(proceeds, 0);
        _fixtureBaselines();
    }

    function testActualV4NativeIntermediateStaysInsideOnePathKeyGroup() public {
        a.mint(address(this), 1e16);
        a.approve(address(adapter), 1e16);
        uint256 routerEth = ROUTER.balance;
        Step[] memory steps = new Step[](2);
        steps[0] = Step(StepKind.V4, address(0), 3_000, 60);
        steps[1] = Step(StepKind.V4, address(b), 3_000, 60);
        uint256 output = adapter.swap(address(a), address(b), 1e16, abi.encode(_plan(1e16, steps)));
        assertGt(output, 0);
        assertEq(ROUTER.balance, routerEth);
        _fixtureBaselines();
    }

    function testActualV4SplitNativeBranchesAndExactOutputRefund() public {
        Step[] memory first = new Step[](2);
        first[0] = Step(StepKind.V4, address(a), 3_000, 60);
        first[1] = Step(StepKind.V4, address(b), 3_000, 60);
        SwapPlan memory plan = _plan(1e16, first);
        plan.branches = new Branch[](2);
        plan.branches[0] = Branch(6e15, first);
        Step[] memory second = new Step[](1);
        second[0] = Step(StepKind.V4, address(b), 3_000, 60);
        plan.branches[1] = Branch(4e15, second);
        assertGt(adapter.swapNative{value: 1e16}(address(b), abi.encode(plan)), 0);
        a.mint(address(this), 1e16);
        a.approve(address(adapter), 1e16);
        plan = _plan(1e16, first);
        plan.exactIn = false;
        plan.amountLimit = 1e13;
        plan.branches[0].steps = second;
        uint256 beforeA = a.balanceOf(address(this));
        uint256 beforeB = b.balanceOf(address(this));
        assertEq(adapter.swap(address(a), address(b), 1e16, abi.encode(plan)), 1e13);
        assertEq(b.balanceOf(address(this)) - beforeB, 1e13);
        assertGt(a.balanceOf(address(this)), beforeA - 1e16);
        _fixtureBaselines();
    }

    function testActualV2AndV3ExactInputAndRetainedExactOutputPayloads() public {
        for (uint256 protocol; protocol < 2; ++protocol) {
            for (uint256 mode; mode < 2; ++mode) {
                deal(WETH, address(this), 1e16);
                IERC20(WETH).approve(address(adapter), 1e16);
                Step[] memory steps = new Step[](1);
                steps[0] = Step(StepKind(protocol), USDC, 500, 0);
                SwapPlan memory plan = _plan(1e16, steps);
                plan.exactIn = mode == 0;
                plan.amountLimit = mode == 0 ? 1 : 1e6;
                uint256 output = adapter.swap(WETH, USDC, 1e16, abi.encode(plan));
                if (mode == 0) {
                    assertGt(output, 0);
                } else {
                    assertEq(output, 1e6);
                    assertGt(IERC20(WETH).balanceOf(address(this)), 0);
                }
                assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
                assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
                assertEq(IERC20(WETH).allowance(address(adapter), PERMIT2), 0);
            }
        }
    }

    function testActualV3AndV4EndpointUnderconsumptionReturnsMeasuredInput() public {
        address pool = IRoutingForkV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984)
            .createPool(address(a), address(b), 3_000);
        RoutingForkV3Liquidity liquidity = new RoutingForkV3Liquidity(pool, address(a), address(b));
        a.mint(address(liquidity), 1_000_000 ether);
        b.mint(address(liquidity), 1_000_000 ether);
        liquidity.fund();
        for (uint256 protocol = 1; protocol <= 2; ++protocol) {
            uint256 funded = 100_000 ether;
            a.mint(address(this), funded);
            a.approve(address(adapter), funded);
            uint256 beforeInput = a.balanceOf(address(this));
            uint256 beforeOutput = b.balanceOf(address(this));
            Step[] memory steps = _oneStep(StepKind(protocol), address(b), 3_000, 60);
            uint256 output = adapter.swap(address(a), address(b), funded, abi.encode(_plan(funded, steps)));
            uint256 consumed = beforeInput - a.balanceOf(address(this));
            assertGt(output, 0);
            assertGt(consumed, 0);
            assertLt(consumed, funded, "bounded liquidity must leave endpoint input");
            assertEq(b.balanceOf(address(this)) - beforeOutput, output);
            assertEq(a.allowance(address(adapter), PERMIT2), 0);
            _fixtureBaselines();
        }
    }

    function testActualCanonicalV4ExactInputAndRetainedExactOutput() public {
        deal(PAXG, address(this), 1e14);
        IERC20(PAXG).approve(address(adapter), 1e14);
        Step[] memory steps = new Step[](1);
        steps[0] = Step(StepKind.V4, CYGLD, 100, 1);
        SwapPlan memory plan = _plan(1e14, steps);
        assertGt(adapter.swap(PAXG, CYGLD, 1e14, abi.encode(plan)), 0);
        deal(PAXG, address(this), 1e14);
        IERC20(PAXG).approve(address(adapter), 1e14);
        plan.exactIn = false;
        plan.amountLimit = 1e12;
        assertEq(adapter.swap(PAXG, CYGLD, 1e14, abi.encode(plan)), 1e12);
        assertGt(IERC20(PAXG).balanceOf(address(this)), 0);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 0);
        assertEq(IERC20(CYGLD).balanceOf(address(adapter)), 0);
    }

    function testActualMixedV2V3V4PreservesHistoricalIntermediateCustody() public {
        deal(USDC, address(this), 1e6);
        IERC20(USDC).approve(address(adapter), 1e6);
        deal(WETH, address(adapter), 41);
        deal(PAXG, address(adapter), 43);
        uint256 oldWeth = IERC20(WETH).balanceOf(ROUTER);
        uint256 oldPaxg = IERC20(PAXG).balanceOf(ROUTER);
        Step[] memory steps = new Step[](3);
        steps[0] = Step(StepKind.V2, WETH, 0, 0);
        steps[1] = Step(StepKind.V3, PAXG, 3_000, 0);
        steps[2] = Step(StepKind.V4, CYGLD, 100, 1);
        assertGt(adapter.swap(USDC, CYGLD, 1e6, abi.encode(_plan(1e6, steps))), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 41);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 43);
        assertEq(IERC20(WETH).balanceOf(ROUTER), oldWeth);
        assertEq(IERC20(PAXG).balanceOf(ROUTER), oldPaxg);
    }

    function testActualWrapAndUnwrapConnectNativeToV3AndCanonicalV4() public {
        Step[] memory steps = new Step[](3);
        steps[0] = Step(StepKind.WrapNative, WETH, 0, 0);
        steps[1] = Step(StepKind.V3, PAXG, 3_000, 0);
        steps[2] = Step(StepKind.V4, CYGLD, 100, 1);
        uint256 output = adapter.swapNative{value: 1e16}(CYGLD, abi.encode(_plan(1e16, steps)));
        assertGt(output, 0);
        IERC20(CYGLD).approve(address(adapter), output);
        steps[0] = Step(StepKind.V4, PAXG, 100, 1);
        steps[1] = Step(StepKind.V3, WETH, 3_000, 0);
        steps[2] = Step(StepKind.UnwrapNative, address(0), 0, 0);
        uint256 beforeEth = address(this).balance;
        uint256 proceeds = adapter.swap(CYGLD, address(0), output, abi.encode(_plan(output, steps)));
        assertEq(address(this).balance - beforeEth, proceeds);
        assertGt(proceeds, 0);
        assertEq(address(adapter).balance, 29);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 0);
    }

    function testActualCoreNativeBuyAndSaleWithCanonicalMarketPartialBranches() public {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = CYGLD;
        cfg.permit2 = PERMIT2;
        cfg.wrappedNative = WETH;
        cfg.helperFeePpm = 5_000;
        cfg.approvedAdapters = new address[](0);
        address helpers = address(DeploymentHelper.deploy(cfg).diamond);
        UniswapRoutingAdapter venue = new UniswapRoutingAdapter(helpers, ROUTER, PERMIT2, WETH);
        address facet = vm.deployCode("TradeExactInFacet.sol:TradeExactInFacet", abi.encode(PERMIT2, address(venue)));
        IDiamond.FacetCut[] memory cut = new IDiamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = T.executeExactInput.selector;
        cut[0] = IDiamond.FacetCut(facet, IDiamond.FacetCutAction.Add, selectors);
        IDiamondCut(helpers).diamondCut(cut, address(0), "");
        ICyberGoldHelpers(helpers).setAdapterApproval(address(venue), false, true);
        T.ExactInputPlan memory plan;
        plan.intent = T.Intent.BuyCygld;
        plan.inputs = new T.AssetAmount[](1);
        plan.inputs[0] = T.AssetAmount(address(0), 1e16);
        plan.outputCurrency = CYGLD;
        plan.recipient = address(this);
        plan.deadline = block.timestamp + 60;
        plan.minimumOutput = 1;
        T.ScalarBody memory scalar;
        scalar.branches = new T.TradeBranch[](2);
        T.CoreBuyBody memory coreBuy;
        coreBuy.basketAssets = new address[](2);
        coreBuy.basketAssets[0] = PAXG;
        coreBuy.basketAssets[1] = XAUT;
        coreBuy.acquisitions = new T.Acquisition[](2);
        coreBuy.acquisitions[0] = T.Acquisition(3e15, _template(WETH, PAXG, _oneStep(StepKind.V3, PAXG, 3_000, 0)));
        coreBuy.acquisitions[1] = T.Acquisition(3e15, _template(WETH, XAUT, _oneStep(StepKind.V3, XAUT, 3_000, 0)));
        coreBuy.continuations = new T.Continuation[](2);
        coreBuy.continuations[0] = T.Continuation(_template(PAXG, CYGLD, _oneStep(StepKind.V4, CYGLD, 100, 1)), 0);
        Step[] memory fromXaut = new Step[](3);
        fromXaut[0] = Step(StepKind.V3, WETH, 3_000, 0);
        fromXaut[1] = Step(StepKind.V3, PAXG, 3_000, 0);
        fromXaut[2] = Step(StepKind.V4, CYGLD, 100, 1);
        coreBuy.continuations[1] = T.Continuation(_template(XAUT, CYGLD, fromXaut), 0);
        scalar.branches[0] = T.TradeBranch(T.BranchKind.Core, 6e15, abi.encode(coreBuy));
        Step[] memory toCygld = new Step[](2);
        toCygld[0] = Step(StepKind.V3, PAXG, 3_000, 0);
        toCygld[1] = Step(StepKind.V4, CYGLD, 100, 1);
        scalar.branches[1] =
            T.TradeBranch(T.BranchKind.Market, 4e15, abi.encode(T.MarketBody(_template(WETH, CYGLD, toCygld), 1)));
        plan.body = abi.encode(scalar);
        T.FundingBundle memory funding;
        funding.authorizations = new T.FundingAuthorization[](1);
        uint256 supplyBefore = IERC20(CYGLD).totalSupply();
        T.TradeResult memory bought = T(helpers).executeExactInput{value: 1e16}(plan, funding);
        assertGt(IERC20(CYGLD).totalSupply(), supplyBefore, "actual Core issuance required");
        assertGt(bought.coreHelpersFeeCygld, 0);
        assertEq(bought.marketFeeCygld, 1);
        assertGt(bought.recipientOutputs[0].amount, 0);
        assertEq(IERC20(PAXG).allowance(helpers, CYGLD), 0);
        assertEq(IERC20(XAUT).allowance(helpers, CYGLD), 0);
        assertEq(IERC20(WETH).allowance(helpers, address(venue)), 0);
        _executeActualCoreNativeSale(helpers, address(venue), bought.recipientOutputs[0].amount / 2);
    }

    function _executeActualCoreNativeSale(address helpers, address venue, uint256 amount) private {
        uint256 coreAllocation = amount / 2;
        vm.prank(helpers);
        ICoreRedemption.RedemptionQuote memory projected =
            ICoreRedemption(CYGLD).previewRedeemExactIn(coreAllocation - coreAllocation * 5_000 / 1_000_000);
        T.CoreSellBody memory coreSell;
        coreSell.expectedOutputs = new ICoreRedemption.TokenMinimum[](projected.outputs.length);
        coreSell.conversions = new T.AmmTemplate[](projected.outputs.length);
        for (uint256 i; i < projected.outputs.length; ++i) {
            ICoreRedemption.TokenAmount memory output = projected.outputs[i];
            coreSell.expectedOutputs[i] =
                ICoreRedemption.TokenMinimum(output.kind, output.token, output.id, output.amount);
            if (output.kind == ICoreRedemption.TokenKind.ERC20) {
                coreSell.conversions[i] = _template(output.token, WETH, _oneStep(StepKind.V3, WETH, 3_000, 0));
            }
        }
        T.ScalarBody memory scalar;
        scalar.branches = new T.TradeBranch[](2);
        scalar.branches[0] = T.TradeBranch(T.BranchKind.Core, coreAllocation, abi.encode(coreSell));
        Step[] memory steps = new Step[](2);
        steps[0] = Step(StepKind.V4, PAXG, 100, 1);
        steps[1] = Step(StepKind.V3, WETH, 3_000, 0);
        scalar.branches[1] = T.TradeBranch(
            T.BranchKind.Market, amount - coreAllocation, abi.encode(T.MarketBody(_template(CYGLD, WETH, steps), 1))
        );
        T.ExactInputPlan memory plan;
        plan.intent = T.Intent.SellCygld;
        plan.inputs = new T.AssetAmount[](1);
        plan.inputs[0] = T.AssetAmount(CYGLD, amount);
        plan.outputCurrency = address(0);
        plan.recipient = address(this);
        plan.deadline = block.timestamp + 60;
        plan.minimumOutput = 1;
        plan.body = abi.encode(scalar);
        T.FundingBundle memory funding;
        funding.authorizations = new T.FundingAuthorization[](1);
        IERC20(CYGLD).approve(helpers, amount);
        uint256 supplyBefore = IERC20(CYGLD).totalSupply();
        uint256 ethBefore = address(this).balance;
        T.TradeResult memory sold = T(helpers).executeExactInput(plan, funding);
        assertLt(IERC20(CYGLD).totalSupply(), supplyBefore, "actual Core redemption required");
        assertGt(sold.coreHelpersFeeCygld, 0);
        assertEq(sold.marketFeeCygld, 1);
        assertGt(sold.recipientOutputs[0].amount, 0);
        assertEq(address(this).balance - ethBefore, sold.recipientOutputs[0].amount);
        assertEq(IERC20(CYGLD).allowance(helpers, venue), 0);
    }

    function _oneStep(StepKind kind, address output, uint24 fee, int24 spacing)
        private
        pure
        returns (Step[] memory steps)
    {
        steps = new Step[](1);
        steps[0] = Step(kind, output, fee, spacing);
    }

    function _template(address input, address output, Step[] memory steps)
        private
        pure
        returns (T.AmmTemplate memory route)
    {
        route.inputCurrency = input;
        route.outputCurrency = output;
        route.routes = new T.WeightedRoute[](1);
        route.routes[0] = T.WeightedRoute(1_000_000, steps);
    }

    function _fixtureBaselines() private view {
        assertEq(address(adapter).balance, 29);
        assertEq(a.balanceOf(address(adapter)), 31);
        assertEq(b.balanceOf(address(adapter)), 37);
    }

    receive() external payable {}
}
