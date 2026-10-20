// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IUniswapRoutingTypes} from "../src/interfaces/IUniswapRoutingTypes.sol";
import {UniswapRoutingAdapter} from "../src/adapters/UniswapRoutingAdapter.sol";
import {MintableToken} from "../test/mocks/BasketRouterMocks.sol";
import {IRoutingForkPoolManager, RoutingForkLiquidity} from "./UniswapRoutingFork.t.sol";

/// @dev No venue is mocked. Tiny fee-bearing trades use actual pinned Router/PoolManager
/// bytecode and fork-only no-hook pools; their rounding to zero is the audited trigger.
contract UniswapRoutingZeroOutputForkTest is Test, IUniswapRoutingTypes {
    address private constant ROUTER = 0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes private constant EXECUTE = abi.encodeWithSignature("execute(bytes,bytes[],uint256)");
    UniswapRoutingAdapter private adapter;
    MintableToken[5] private tokens;
    uint256 private routerNative;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 26164733);
        adapter = new UniswapRoutingAdapter(address(this), ROUTER, PERMIT2, WETH);
        RoutingForkLiquidity liquidity = new RoutingForkLiquidity(MANAGER);
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i] = new MintableToken("Zero Output Fork Asset", "ZO");
            tokens[i].mint(address(liquidity), 1_000_000 ether);
            tokens[i].mint(address(adapter), 31 + i);
            tokens[i].mint(ROUTER, 41 + i);
            tokens[i].mint(address(this), 1 ether);
            tokens[i].approve(address(adapter), type(uint256).max);
        }
        vm.deal(address(liquidity), 200 ether);
        IRoutingForkPoolManager.PoolKey[] memory keys = new IRoutingForkPoolManager.PoolKey[](8);
        keys[0] = _key(address(0), address(tokens[0]));
        keys[1] = _key(address(0), address(tokens[1]));
        for (uint256 i; i < 4; ++i) {
            keys[i + 2] = _key(address(tokens[i]), address(tokens[i + 1]));
        }
        keys[6] = _key(address(tokens[2]), address(tokens[0]));
        keys[7] = _key(address(tokens[0]), address(tokens[3]));
        liquidity.fund(keys);
        vm.deal(address(this), 1 ether);
        vm.deal(address(adapter), 29);
        routerNative = ROUTER.balance;
    }

    function testActualGroupedZeroAtFirstInteriorHopSkipsRemainingHops() public {
        _assertZeroPosition(0, 1);
    }

    function testActualGroupedZeroAtSecondInteriorHopSkipsRemainingHops() public {
        _assertZeroPosition(1, 3);
    }

    function testActualGroupedZeroAtThirdInteriorHopSkipsRemainingHops() public {
        _assertZeroPosition(2, 5);
    }

    function _assertZeroPosition(uint256 zero, uint256 amount) private {
        uint256 snapshot = vm.snapshotState();
        uint256 current = amount;
        // Establish the actual rounding position independently through single-hop execution.
        for (uint256 i; i <= zero; ++i) {
            Step[] memory one = new Step[](1);
            one[0] = _step(address(tokens[i + 1]));
            current =
                adapter.swap(address(tokens[i]), address(tokens[i + 1]), current, abi.encode(_plan(current, one, 0)));
            if (i < zero) assertGt(current, 0, "earlier hop must have positive realized output");
            else assertEq(current, 0, "specified interior hop must round to zero");
        }
        assertTrue(vm.revertToState(snapshot));
        uint256 beforeInput = tokens[0].balanceOf(address(this));
        vm.expectCall(ROUTER, EXECUTE, uint64(zero + 2)); // reverted group plus nonzero single-hop replay prefix
        assertEq(
            adapter.swap(address(tokens[0]), address(tokens[4]), amount, abi.encode(_plan(amount, _forward(), 0))), 0
        );
        assertEq(beforeInput - tokens[0].balanceOf(address(this)), amount);
        _baselines();
    }

    function testActualGroupedPositiveOutputStillUsesOneRouterCall() public {
        vm.expectCall(ROUTER, EXECUTE, uint64(1));
        assertGt(adapter.swap(address(tokens[0]), address(tokens[4]), 1e12, abi.encode(_plan(1e12, _forward(), 1))), 1);
        _baselines();
    }

    function testActualGroupedZeroBranchPreservesPositiveSiblingAndAggregateMinimum() public {
        SwapPlan memory plan = _plan(1, _forward(), 1);
        Branch memory tiny = plan.branches[0];
        plan.branches = new Branch[](2);
        plan.branches[0] = tiny;
        plan.branches[1] = Branch(1e12, _forward());
        uint256 inputBefore = tokens[0].balanceOf(address(this));
        uint256 outputBefore = tokens[4].balanceOf(address(this));
        vm.expectCall(ROUTER, EXECUTE, uint64(3)); // failed tiny group, one tiny replay, one positive group
        uint256 output = adapter.swap(address(tokens[0]), address(tokens[4]), 1e12 + 1, abi.encode(plan));
        assertGt(output, plan.amountLimit);
        assertEq(tokens[4].balanceOf(address(this)) - outputBefore, output);
        assertEq(inputBefore - tokens[0].balanceOf(address(this)), 1e12 + 1);
        _baselines();
    }

    function testActualNativeInputZeroRetryPreservesHistoricalCustody() public {
        Step[] memory steps = new Step[](2);
        steps[0] = _step(address(tokens[0]));
        steps[1] = _step(address(tokens[1]));
        uint256 nativeBefore = address(this).balance;
        vm.expectCall(ROUTER, EXECUTE, uint64(2));
        assertEq(adapter.swapNative{value: 1}(address(tokens[1]), abi.encode(_plan(1, steps, 0))), 0);
        assertEq(nativeBefore - address(this).balance, 1);
        _baselines();
    }

    function testActualNativeIntermediateZeroRetryPreservesHistoricalCustody() public {
        Step[] memory steps = new Step[](2);
        steps[0] = _step(address(0));
        steps[1] = _step(address(tokens[1]));
        uint256 inputBefore = tokens[0].balanceOf(address(this));
        vm.expectCall(ROUTER, EXECUTE, uint64(2));
        assertEq(adapter.swap(address(tokens[0]), address(tokens[1]), 1, abi.encode(_plan(1, steps, 0))), 0);
        assertEq(inputBefore - tokens[0].balanceOf(address(this)), 1);
        _baselines();
    }

    function testActualRepeatedCurrencyPartitionRetriesOnlyItsZeroOutputGroup() public {
        Step[] memory steps = new Step[](5);
        steps[0] = _step(address(tokens[1]));
        steps[1] = _step(address(tokens[2]));
        steps[2] = _step(address(tokens[0]));
        steps[3] = _step(address(tokens[3]));
        steps[4] = _step(address(tokens[4]));
        uint256 inputBefore = tokens[0].balanceOf(address(this));
        vm.expectCall(ROUTER, EXECUTE, uint64(3)); // positive first group, failed second group, one-hop replay
        assertEq(adapter.swap(address(tokens[0]), address(tokens[4]), 5, abi.encode(_plan(5, steps, 0))), 0);
        assertEq(inputBefore - tokens[0].balanceOf(address(this)), 5);
        _baselines();
    }

    function testActualUnrelatedV4FailurePreservesErrorAndAtomicFunding() public {
        Step[] memory steps = _forward();
        steps[1].fee = 100; // this fork-only pool was not initialized
        uint256 inputBefore = tokens[0].balanceOf(address(this));
        vm.expectCall(ROUTER, EXECUTE, uint64(1));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingAdapter.UniversalRouterSwapFailed.selector,
                abi.encodeWithSignature("PoolNotInitialized()")
            )
        );
        adapter.swap(address(tokens[0]), address(tokens[4]), 1e12, abi.encode(_plan(1e12, steps, 0)));
        assertEq(tokens[0].balanceOf(address(this)), inputBefore);
        _baselines();
    }

    function _key(address x, address y) private pure returns (IRoutingForkPoolManager.PoolKey memory) {
        return x < y
            ? IRoutingForkPoolManager.PoolKey(x, y, 3_000, 60, address(0))
            : IRoutingForkPoolManager.PoolKey(y, x, 3_000, 60, address(0));
    }

    function _step(address output) private pure returns (Step memory) {
        return Step(StepKind.V4, output, 3_000, 60);
    }

    function _forward() private view returns (Step[] memory steps) {
        steps = new Step[](4);
        for (uint256 i; i < 4; ++i) {
            steps[i] = _step(address(tokens[i + 1]));
        }
    }

    function _plan(uint256 amount, Step[] memory steps, uint256 minimum) private view returns (SwapPlan memory plan) {
        plan.exactIn = true;
        plan.amountLimit = minimum;
        plan.deadline = block.timestamp + 60;
        plan.branches = new Branch[](1);
        plan.branches[0] = Branch(amount, steps);
    }

    function _baselines() private view {
        assertEq(address(adapter).balance, 29);
        assertEq(ROUTER.balance, routerNative);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(tokens[i].balanceOf(address(adapter)), 31 + i);
            assertEq(tokens[i].balanceOf(ROUTER), 41 + i);
            assertEq(tokens[i].allowance(address(adapter), PERMIT2), 0);
        }
    }

    receive() external payable {}
}
