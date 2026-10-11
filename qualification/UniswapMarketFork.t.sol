// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IMarketSwap} from "../src/interfaces/IMarketSwap.sol";
import {IMultiProtocolSwapTypes} from "../src/interfaces/IMultiProtocolSwapTypes.sol";
import {UniswapRouterEncoding} from "../src/adapters/UniswapRouterEncoding.sol";
import {UniswapMultiProtocolAdapter} from "../src/adapters/UniswapMultiProtocolAdapter.sol";
import {MarketFacetHarness} from "../test/MarketSwapFacet.t.sol";

interface IV4MarketQuoter {
    struct QuoteSingle {
        UniswapRouterEncoding.PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }
    function quoteExactInputSingle(QuoteSingle memory params) external returns (uint256, uint256);
    function quoteExactOutputSingle(QuoteSingle memory params) external returns (uint256, uint256);
}

interface IV2MarketFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IV2MarketPair {
    function mint(address to) external returns (uint256 liquidity);
}

/// @notice Actual Router 2.2 and funded PAXG/CYGLD pool on a pinned Mainnet fork.
/// @dev Funding is synthetic test funding; pool liquidity and token implementations are unchanged.
contract UniswapMarketForkTest is Test, IMarketSwap, IMultiProtocolSwapTypes {
    address private constant ROUTER = 0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address private constant CYGLD = 0x601da021cAF3DB5AA63e700D239b5935C370601d;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant OWNER = address(0xA11CE);
    address private constant RECIPIENT = address(0xCAFE);
    uint256 private constant KEY = 0x2612;
    uint256 private constant SNAPSHOT = 26164733;
    bytes32 private constant PERMIT_HASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    UniswapMultiProtocolAdapter private adapter;
    MarketFacetHarness private market;
    address private user;

    struct SplitObservation {
        uint256 oldWeth;
        uint256 oldPaxg;
        uint256 isolatedSecond;
        uint256 splitOutput;
        bytes32 splitState;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envOr("UNISWAP_MARKET_FORK_BLOCK", SNAPSHOT));
        user = vm.addr(KEY);
        market = new MarketFacetHarness(PERMIT2);
        adapter = new UniswapMultiProtocolAdapter(address(market), ROUTER, PERMIT2);
        market.configure(CYGLD, address(adapter), OWNER);
    }

    function _v4Plan(bool exactIn, bool buy, uint256 lot, uint256 limit) private view returns (bytes memory) {
        SwapPlan memory p;
        p.exactIn = exactIn;
        p.amountLimit = limit;
        p.deadline = block.timestamp + 60;
        p.branches = new Branch[](1);
        p.branches[0] = Branch(lot, new Hop[](1));
        p.branches[0].hops[0] = Hop(Protocol.V4, buy ? CYGLD : PAXG, 100, 1, address(0), "");
        return abi.encode(p);
    }

    function _quote(bool exactIn, bool buy, uint256 amount) private returns (uint256 quote) {
        IV4MarketQuoter.QuoteSingle memory p = IV4MarketQuoter.QuoteSingle(
            UniswapRouterEncoding.PoolKey(PAXG, CYGLD, 100, 1, address(0)), buy, uint128(amount), ""
        );
        (quote,) = exactIn
            ? IV4MarketQuoter(QUOTER).quoteExactInputSingle(p)
            : IV4MarketQuoter(QUOTER).quoteExactOutputSingle(p);
    }

    function _native(address input, uint256 acquisition) private view returns (FundingAuthorization memory auth) {
        auth.mode = FundingMode.NativePermit;
        auth.nativePermit.value = acquisition;
        auth.nativePermit.deadline = block.timestamp + 60;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20Permit(input).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        PERMIT_HASH,
                        user,
                        address(market),
                        acquisition,
                        IERC20Permit(input).nonces(user),
                        auth.nativePermit.deadline
                    )
                )
            )
        );
        (auth.nativePermit.v, auth.nativePermit.r, auth.nativePermit.s) = vm.sign(KEY, digest);
    }

    function _market(bool exactIn, bool buy) private {
        MarketSwapParams memory p;
        p.side = buy ? MarketSide.BuyCygld : MarketSide.SellCygld;
        p.counterToken = PAXG;
        p.recipient = RECIPIENT;
        p.deadline = block.timestamp + 60;
        p.adapter = address(adapter);
        uint256 acquisition;
        uint256 venueAmount;
        uint256 grossTarget;
        if (exactIn) {
            acquisition = buy ? 1e14 : 1e15;
            p.amount = acquisition;
            venueAmount = buy ? acquisition : acquisition * 1_000_000 / 1_001_000;
            uint256 quoted = _quote(true, buy, venueAmount);
            p.feeCygld = ((buy ? quoted : venueAmount) + 999) / 1000;
            p.routedInput = buy ? 0 : venueAmount;
            p.bound = (quoted - (buy ? p.feeCygld : 0)) * 99 / 100;
            grossTarget = p.bound + (buy ? p.feeCygld : 0);
        } else {
            p.amount = buy ? 1e15 : 1e13;
            grossTarget = buy ? (p.amount * 1_000_000 + 998_999) / 999_000 : p.amount;
            uint256 quote = _quote(false, buy, grossTarget);
            p.feeCygld = buy ? grossTarget - p.amount : (quote + 999) / 1000;
            acquisition = quote * 101 / 100 + (buy ? 0 : p.feeCygld);
            p.bound = acquisition;
            venueAmount = buy ? acquisition : acquisition - p.feeCygld;
        }
        address input = buy ? PAXG : CYGLD;
        address output = buy ? CYGLD : PAXG;
        p.data = _v4Plan(exactIn, buy, venueAmount, grossTarget);
        deal(input, user, acquisition);
        assertEq(IERC20(input).allowance(user, address(market)), 0);
        assertEq(IERC20(input).allowance(user, PERMIT2), 0);
        uint256 supplyBefore = IERC20(CYGLD).totalSupply();
        uint256 ownerBefore = IERC20(CYGLD).balanceOf(OWNER);
        uint256 recipientBefore = IERC20(output).balanceOf(RECIPIENT);
        FundingAuthorization memory auth = _native(input, acquisition);
        vm.prank(user);
        MarketSwapResult memory r = exactIn ? market.swapExactInput(p, auth) : market.swapExactOutput(p, auth);
        assertEq(IERC20(CYGLD).totalSupply(), supplyBefore);
        assertEq(IERC20(input).allowance(user, address(market)), 0);
        assertEq(IERC20(input).allowance(user, PERMIT2), 0);
        assertEq(IERC20(input).balanceOf(address(market)), 0);
        assertEq(IERC20(output).balanceOf(address(market)), 0);
        assertEq(IERC20(input).balanceOf(address(adapter)), 0);
        assertEq(IERC20(output).balanceOf(address(adapter)), 0);
        assertEq(IERC20(CYGLD).balanceOf(OWNER) - ownerBefore, p.feeCygld);
        assertEq(IERC20(output).balanceOf(RECIPIENT) - recipientBefore, r.amountOut);
        assertLe(r.swapInput + (buy ? 0 : p.feeCygld), acquisition);
        if (exactIn) assertGe(r.amountOut, p.bound);
        else assertEq(r.amountOut, p.amount);
    }

    function testFundedPaxgNativePermitBuyExactInput() public {
        _market(true, true);
    }

    function testFundedPaxgNativePermitBuyExactOutput() public {
        _market(false, true);
    }

    function testFundedCygldNativePermitSellExactInput() public {
        _market(true, false);
    }

    function testFundedCygldNativePermitSellExactOutput() public {
        _market(false, false);
    }

    function testActualV2AndV3BothModesAtRouter22() public {
        for (uint256 protocol; protocol < 2; ++protocol) {
            for (uint256 mode; mode < 2; ++mode) {
                bool exactIn = mode == 0;
                uint256 lot = 1e16;
                SwapPlan memory p;
                p.exactIn = exactIn;
                p.amountLimit = exactIn ? 1 : 1e6;
                p.deadline = block.timestamp + 60;
                p.branches = new Branch[](1);
                p.branches[0] = Branch(lot, new Hop[](1));
                p.branches[0].hops[0] = Hop(Protocol(protocol), USDC, 500, 0, address(0), "");
                deal(WETH, address(this), lot);
                IERC20(WETH).approve(address(adapter), lot);
                uint256 received = adapter.swap(WETH, USDC, lot, abi.encode(p));
                if (exactIn) assertGt(received, 0);
                else assertEq(received, 1e6);
                assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
                assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
            }
        }
    }

    function testActualMixedV2V3V4UsesExistingFundedPool() public {
        uint256 lot = 1e6;
        deal(USDC, address(this), lot);
        IERC20(USDC).approve(address(adapter), lot);
        SwapPlan memory p;
        p.exactIn = true;
        p.amountLimit = 1;
        p.deadline = block.timestamp + 60;
        p.branches = new Branch[](1);
        p.branches[0] = Branch(lot, new Hop[](3));
        p.branches[0].hops[0] = Hop(Protocol.V2, WETH, 0, 0, address(0), "");
        p.branches[0].hops[1] = Hop(Protocol.V3, PAXG, 3000, 0, address(0), "");
        p.branches[0].hops[2] = Hop(Protocol.V4, CYGLD, 100, 1, address(0), "");
        uint256 oldWeth = IERC20(WETH).balanceOf(ROUTER);
        uint256 oldPaxg = IERC20(PAXG).balanceOf(ROUTER);
        deal(WETH, address(adapter), 37);
        deal(PAXG, address(adapter), 41);
        assertGt(adapter.swap(USDC, CYGLD, lot, abi.encode(p)), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 37);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 41);
        assertEq(IERC20(WETH).balanceOf(ROUTER), oldWeth);
        assertEq(IERC20(PAXG).balanceOf(ROUTER), oldPaxg);
    }

    function _mixedBuyPlan(uint256 lot) private view returns (SwapPlan memory p) {
        p.exactIn = true;
        p.amountLimit = 1;
        p.deadline = block.timestamp + 60;
        p.branches = new Branch[](1);
        p.branches[0] = Branch(lot, new Hop[](3));
        p.branches[0].hops[0] = Hop(Protocol.V2, WETH, 0, 0, address(0), "");
        p.branches[0].hops[1] = Hop(Protocol.V3, PAXG, 3000, 0, address(0), "");
        p.branches[0].hops[2] = Hop(Protocol.V4, CYGLD, 100, 1, address(0), "");
    }

    function _fundedPoolState() private view returns (bytes32) {
        (bool success, bytes memory state) = address(0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227)
            .staticcall(
                abi.encodeWithSignature(
                    "getSlot0(bytes32)", bytes32(0x33fd4629a4e190b9a98a8a3758afb7a2639eb740088a04bd4d3016e3ac9d55a4)
                )
            );
        require(success, "funded pool slot");
        return keccak256(state);
    }

    function testActualReverseMixedV4V3V2PreservesIntermediateBalances() public {
        uint256 lot = 1e15;
        deal(CYGLD, address(this), lot);
        IERC20(CYGLD).approve(address(adapter), lot);
        SwapPlan memory p = _mixedBuyPlan(lot);
        p.branches[0].hops[0] = Hop(Protocol.V4, PAXG, 100, 1, address(0), "");
        p.branches[0].hops[1] = Hop(Protocol.V3, WETH, 3000, 0, address(0), "");
        p.branches[0].hops[2] = Hop(Protocol.V2, USDC, 0, 0, address(0), "");
        uint256 oldWeth = IERC20(WETH).balanceOf(ROUTER);
        uint256 oldPaxg = IERC20(PAXG).balanceOf(ROUTER);
        deal(WETH, address(adapter), 37);
        deal(PAXG, address(adapter), 41);
        assertGt(adapter.swap(CYGLD, USDC, lot, abi.encode(p)), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 37);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 41);
        assertEq(IERC20(WETH).balanceOf(ROUTER), oldWeth);
        assertEq(IERC20(PAXG).balanceOf(ROUTER), oldPaxg);
        assertEq(IERC20(CYGLD).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
    }

    function testActualSharedPoolSplitMatchesOrderedExecutionAndMovesPrice() public {
        deal(USDC, address(this), 1e6);
        IERC20(USDC).approve(address(adapter), 1e6);
        deal(WETH, address(adapter), 37);
        deal(PAXG, address(adapter), 41);
        SplitObservation memory observed;
        observed.oldWeth = IERC20(WETH).balanceOf(ROUTER);
        observed.oldPaxg = IERC20(PAXG).balanceOf(ROUTER);
        uint256 initial = vm.snapshotState();
        observed.isolatedSecond = adapter.swap(USDC, CYGLD, 350_000, abi.encode(_mixedBuyPlan(350_000)));
        assertTrue(vm.revertToState(initial));
        SwapPlan memory split = _mixedBuyPlan(650_000);
        split.branches = new Branch[](2);
        split.branches[0] = _mixedBuyPlan(650_000).branches[0];
        split.branches[1] = _mixedBuyPlan(350_000).branches[0];
        observed.splitOutput = adapter.swap(USDC, CYGLD, 1e6, abi.encode(split));
        observed.splitState = _fundedPoolState();
        assertTrue(vm.revertToStateAndDelete(initial));
        uint256 firstOutput = adapter.swap(USDC, CYGLD, 650_000, abi.encode(_mixedBuyPlan(650_000)));
        uint256 secondOutput = adapter.swap(USDC, CYGLD, 350_000, abi.encode(_mixedBuyPlan(350_000)));
        assertEq(firstOutput + secondOutput, observed.splitOutput);
        assertLt(secondOutput, observed.isolatedSecond, "second branch sees consumed shared liquidity");
        assertEq(_fundedPoolState(), observed.splitState);
        emit log_named_uint("splitCygldOutput", observed.splitOutput);
        emit log_named_uint("firstBranchCygldOutput", firstOutput);
        emit log_named_uint("secondBranchCygldOutputAfterFirst", secondOutput);
        emit log_named_uint("secondBranchCygldOutputAtInitialState", observed.isolatedSecond);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 37);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 41);
        assertEq(IERC20(WETH).balanceOf(ROUTER), observed.oldWeth);
        assertEq(IERC20(PAXG).balanceOf(ROUTER), observed.oldPaxg);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(CYGLD).balanceOf(address(adapter)), 0);
    }

    function testSyntheticV2ConnectorCompletesV3V4V2AtActualRouter() public {
        // No CYGLD V2 pool exists at this snapshot. Create and fund a fork-only
        // connector through the canonical V2 factory; the V3/V4 pools stay real.
        address pair = IV2MarketFactory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f).createPair(CYGLD, USDC);
        deal(CYGLD, pair, 1e21);
        deal(USDC, pair, 1e9);
        assertGt(IV2MarketPair(pair).mint(address(this)), 0);
        uint256 lot = 1e14;
        deal(WETH, address(this), lot);
        IERC20(WETH).approve(address(adapter), lot);
        SwapPlan memory p = _mixedBuyPlan(lot);
        p.branches[0].hops[0] = Hop(Protocol.V3, PAXG, 3000, 0, address(0), "");
        p.branches[0].hops[1] = Hop(Protocol.V4, CYGLD, 100, 1, address(0), "");
        p.branches[0].hops[2] = Hop(Protocol.V2, USDC, 0, 0, address(0), "");
        uint256 oldPaxg = IERC20(PAXG).balanceOf(ROUTER);
        uint256 oldCygld = IERC20(CYGLD).balanceOf(ROUTER);
        deal(PAXG, address(adapter), 41);
        deal(CYGLD, address(adapter), 43);
        assertGt(adapter.swap(WETH, USDC, lot, abi.encode(p)), 0);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 41);
        assertEq(IERC20(CYGLD).balanceOf(address(adapter)), 43);
        assertEq(IERC20(PAXG).balanceOf(ROUTER), oldPaxg);
        assertEq(IERC20(CYGLD).balanceOf(ROUTER), oldCygld);
    }

    function testActualMixedAggregateFloorAfterPriceMovementRollsBack() public {
        uint256 lot = 1e6;
        deal(USDC, address(this), lot);
        IERC20(USDC).approve(address(adapter), lot);
        uint256 initial = vm.snapshotState();
        SwapPlan memory p = _mixedBuyPlan(lot);
        p.amountLimit = adapter.swap(USDC, CYGLD, lot, abi.encode(p));
        assertTrue(vm.revertToStateAndDelete(initial));
        deal(PAXG, address(this), 1e15);
        IERC20(PAXG).approve(address(adapter), 1e15);
        assertGt(adapter.swap(PAXG, CYGLD, 1e15, _v4Plan(true, true, 1e15, 1)), 0);
        bytes32 movedState = _fundedPoolState();
        uint256 cygldBefore = IERC20(CYGLD).balanceOf(address(this));
        uint256 routerPaxgBefore = IERC20(PAXG).balanceOf(ROUTER);
        emit log_named_uint("priorQuoteCygldFloor", p.amountLimit);
        vm.expectPartialRevert(UniswapMultiProtocolAdapter.InsufficientOutput.selector);
        adapter.swap(USDC, CYGLD, lot, abi.encode(p));
        assertEq(_fundedPoolState(), movedState, "failed route restores changed pool state");
        assertEq(IERC20(USDC).balanceOf(address(this)), lot);
        assertEq(IERC20(CYGLD).balanceOf(address(this)), cygldBefore);
        assertEq(IERC20(PAXG).balanceOf(ROUTER), routerPaxgBefore);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(CYGLD).balanceOf(address(adapter)), 0);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 0);
        assertEq(IERC20(WETH).balanceOf(address(adapter)), 0);
    }

    function testActualLegacyV3BothModesAtRouter22() public {
        uint256 lot = 1e16;
        deal(WETH, address(this), lot);
        IERC20(WETH).approve(address(adapter), lot);
        bytes memory path = abi.encodePacked(WETH, uint24(500), USDC);
        assertGt(adapter.swap(WETH, USDC, lot, abi.encode(path, uint256(1), block.timestamp + 60, true)), 0);
        deal(WETH, address(this), lot);
        IERC20(WETH).approve(address(adapter), lot);
        path = abi.encodePacked(USDC, uint24(500), WETH);
        assertEq(adapter.swap(WETH, USDC, lot, abi.encode(path, uint256(1e6), block.timestamp + 60, false)), 1e6);
    }

    function testDeployedV4ExactOutputRejectsSyntheticPartialDeltaAndRollsBack() public {
        uint256 lot = 1e23;
        deal(PAXG, address(this), lot);
        IERC20(PAXG).approve(address(adapter), lot);
        bytes memory payload = _v4Plan(false, true, lot, 1e24);
        // Isolate the deployed router's underfill check without thousands of empty tick reads.
        // The six funded execution tests above use the unmodified pool and real deltas.
        bytes4 swapSelector =
            bytes4(keccak256("swap((address,address,uint24,int24,address),(bool,int256,uint160),bytes)"));
        vm.mockCall(
            0x000000000004444c5dc75cB358380D2e3dE08A90,
            abi.encodePacked(swapSelector),
            abi.encode(-(int256(1) << 128) + 1)
        );
        (bool success, bytes memory reason) =
            address(adapter).call(abi.encodeCall(adapter.swap, (PAXG, CYGLD, lot, payload)));
        assertFalse(success);
        assertEq(bytes4(reason), UniswapMultiProtocolAdapter.UniversalRouterSwapFailed.selector);
        bytes memory tail = new bytes(reason.length - 4);
        for (uint256 i; i < tail.length; ++i) {
            tail[i] = reason[i + 4];
        }
        bytes memory upstream = abi.decode(tail, (bytes));
        assertEq(bytes4(upstream), bytes4(keccak256("V4ExactOutputUnfilled(uint256,uint256)")));
        assertEq(IERC20(PAXG).balanceOf(address(this)), lot);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 0);
        assertEq(IERC20(CYGLD).balanceOf(address(adapter)), 0);
    }

    function swapExactInput(MarketSwapParams calldata, FundingAuthorization calldata)
        external
        pure
        returns (MarketSwapResult memory)
    {
        revert();
    }

    function swapExactOutput(MarketSwapParams calldata, FundingAuthorization calldata)
        external
        pure
        returns (MarketSwapResult memory)
    {
        revert();
    }
}
