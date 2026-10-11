// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UniswapMultiProtocolAdapter} from "../src/adapters/UniswapMultiProtocolAdapter.sol";
import {UniswapRouterEncoding} from "../src/adapters/UniswapRouterEncoding.sol";
import {IMultiProtocolSwapTypes} from "../src/interfaces/IMultiProtocolSwapTypes.sol";
import {MockERC20Adapter} from "./mocks/MockERC20Adapter.sol";
import {MockPermit2Allowance} from "./UniswapUniversalAdapter.t.sol";
import {IssueTestToken} from "./BasketRouterIssue.t.sol";
import {AdapterAccounting} from "../src/adapters/AdapterAccounting.sol";

/// @dev Synthetic execution fixture: validates the pinned tuple/action shapes, not live pool behavior.
contract MultiProtocolRouterMock {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    MockPermit2Allowance public immutable permit2;
    address public shortInput;
    uint256 public multiplier = 2;
    uint256 public calls;
    address public leakedIntermediate;
    address public burnedIntermediate;
    bool public burnAtRouter;
    uint256[] public fundedLots;
    bytes public commandLog;

    constructor(MockPermit2Allowance permit2_) {
        permit2 = permit2_;
    }

    function configure(address shortInput_, uint256 multiplier_) external {
        shortInput = shortInput_;
        multiplier = multiplier_;
    }

    function configureIntermediateLeak(address token) external {
        leakedIntermediate = token;
    }

    function configureIntermediateBurn(address token, bool atRouter) external {
        burnedIntermediate = token;
        burnAtRouter = atRouter;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        require(deadline >= block.timestamp, "deadline");
        require(commands.length == 1 && inputs.length == 1, "one command");
        ++calls;
        commandLog = abi.encodePacked(commandLog, commands);
        bytes1 command = commands[0];
        if (command == 0x10) {
            _v4(inputs[0]);
            return;
        }
        bool exactIn = command == 0x00 || command == 0x08;
        address recipient;
        uint256 specified;
        uint256 limit;
        bool payer;
        uint256[] memory prices;
        address input;
        address output;
        uint256 hops;
        if (command == 0x08 || command == 0x09) {
            address[] memory path;
            (recipient, specified, limit, path, payer, prices) =
                abi.decode(inputs[0], (address, uint256, uint256, address[], bool, uint256[]));
            input = path[0];
            output = path[path.length - 1];
            hops = path.length - 1;
        } else {
            require(command == 0x00 || command == 0x01, "swap only");
            bytes memory path;
            (recipient, specified, limit, path, payer, prices) =
                abi.decode(inputs[0], (address, uint256, uint256, bytes, bool, uint256[]));
            require(path.length >= 43 && (path.length - 20) % 23 == 0, "packed path");
            input = _address(path, exactIn ? 0 : path.length - 20);
            output = _address(path, exactIn ? path.length - 20 : 0);
            hops = (path.length - 20) / 23;
        }
        require(payer && recipient == msg.sender && prices.length == 0, "custody");
        uint256 spend = exactIn ? specified : (specified + (2 ** hops) - 1) / (2 ** hops);
        if (exactIn && input == shortInput) --spend;
        if (!exactIn) require(spend <= limit, "maximum");
        fundedLots.push(exactIn ? specified : limit);
        permit2.transferFrom(msg.sender, address(0xBEEF), spend.toUint160(), input);
        MockERC20Adapter(output).mint(recipient, exactIn ? spend * multiplier : specified);
        if (leakedIntermediate != address(0)) MockERC20Adapter(leakedIntermediate).mint(address(this), 1);
        if (burnedIntermediate != address(0) && calls == 2) {
            IssueTestToken(burnedIntermediate).burn(burnAtRouter ? address(this) : msg.sender, 1);
        }
    }

    function _v4(bytes calldata payload) private {
        (bytes memory actions, bytes[] memory params) = abi.decode(payload, (bytes, bytes[]));
        if (keccak256(actions) == keccak256(hex"0b060e0e")) {
            (address input, uint256 funded, bool payer) = abi.decode(params[0], (address, uint256, bool));
            UniswapRouterEncoding.ExactInputSingle memory p =
                abi.decode(params[1], (UniswapRouterEncoding.ExactInputSingle));
            require(p.amountIn == 0 && p.amountOutMinimum == 0 && p.minHopPriceX36 == 0 && payer, "open credit");
            require(input == (p.zeroForOne ? p.poolKey.currency0 : p.poolKey.currency1), "input");
            // Model the canonical checked credit representation, excluding all resting router funds.
            funded.toUint128();
            address output = p.zeroForOne ? p.poolKey.currency1 : p.poolKey.currency0;
            (address outCurrency, address recipient, uint256 take) = abi.decode(params[2], (address, address, uint256));
            (address refundCurrency, address refundRecipient, uint256 refundTake) =
                abi.decode(params[3], (address, address, uint256));
            require(
                outCurrency == output && refundCurrency == input && recipient == msg.sender
                    && refundRecipient == msg.sender && take == 0 && refundTake == 0,
                "delta recipients"
            );
            fundedLots.push(funded);
            permit2.transferFrom(msg.sender, address(this), funded.toUint160(), input);
            uint256 spend = input == shortInput ? funded - 1 : funded;
            if (funded != spend) IERC20(input).safeTransfer(msg.sender, funded - spend);
            IERC20(input).safeTransfer(address(0xBEEF), spend);
            MockERC20Adapter(output).mint(msg.sender, spend * multiplier);
            return;
        }
        require(keccak256(actions) == keccak256(hex"090c0f"), "swap settlement only");
        UniswapRouterEncoding.ExactOutput memory outParams = abi.decode(params[0], (UniswapRouterEncoding.ExactOutput));
        (address outInput, uint256 maximum) = abi.decode(params[1], (address, uint256));
        (address outCurrency, uint256 minimum) = abi.decode(params[2], (address, uint256));
        require(
            outInput == outParams.path[0].intermediateCurrency && outCurrency == outParams.currencyOut && minimum == 0
                && maximum == outParams.amountInMaximum && outParams.minHopPriceX36.length == 0,
            "exact outCurrency path"
        );
        uint256 divisor = 2 ** outParams.path.length;
        uint256 outSpend = (uint256(outParams.amountOut) + divisor - 1) / divisor;
        require(outSpend <= maximum, "maximum");
        fundedLots.push(maximum);
        permit2.transferFrom(msg.sender, address(0xBEEF), outSpend.toUint160(), outInput);
        MockERC20Adapter(outCurrency).mint(msg.sender, outParams.amountOut);
    }

    function _address(bytes memory path, uint256 offset) private pure returns (address token) {
        assembly ("memory-safe") { token := shr(96, mload(add(add(path, 32), offset))) }
    }
}

contract UniswapMultiProtocolAdapterTest is Test, IMultiProtocolSwapTypes {
    MockERC20Adapter private a;
    MockERC20Adapter private b;
    MockERC20Adapter private c;
    MockERC20Adapter private d;
    MockPermit2Allowance private permit2;
    MultiProtocolRouterMock private router;
    UniswapMultiProtocolAdapter private adapter;

    function setUp() public {
        vm.warp(1000);
        a = new MockERC20Adapter("A", "A");
        b = new MockERC20Adapter("B", "B");
        c = new MockERC20Adapter("C", "C");
        d = new MockERC20Adapter("D", "D");
        permit2 = new MockPermit2Allowance();
        router = new MultiProtocolRouterMock(permit2);
        adapter = new UniswapMultiProtocolAdapter(address(this), address(router), address(permit2));
        a.mint(address(this), 1_000_000);
        a.approve(address(adapter), type(uint256).max);
        a.mint(address(adapter), 7);
        d.mint(address(adapter), 11);
        b.mint(address(adapter), 13);
        b.mint(address(router), 17);
        c.mint(address(adapter), 19);
        c.mint(address(router), 23);
    }

    function _hop(Protocol protocol, address token) private pure returns (Hop memory) {
        return Hop(protocol, token, 100, 1, address(0), "");
    }

    function _plan(bool exactIn, Protocol protocol, uint256 hops) private view returns (SwapPlan memory p) {
        p.exactIn = exactIn;
        p.amountLimit = exactIn ? 1 : 800;
        p.deadline = block.timestamp + 60;
        p.branches = new Branch[](1);
        p.branches[0].amountIn = 100;
        p.branches[0].hops = new Hop[](hops);
        if (hops == 1) {
            p.branches[0].hops[0] = _hop(protocol, address(d));
        } else {
            p.branches[0].hops[0] = _hop(protocol, address(b));
            p.branches[0].hops[1] = _hop(protocol, address(c));
            p.branches[0].hops[2] = _hop(protocol, address(d));
        }
    }

    function _baselines() private view {
        assertEq(a.balanceOf(address(adapter)), 7);
        assertEq(d.balanceOf(address(adapter)), 11);
        assertEq(b.balanceOf(address(adapter)), 13);
        assertEq(b.balanceOf(address(router)), 17);
        assertEq(c.balanceOf(address(adapter)), 19);
        assertEq(c.balanceOf(address(router)), 23);
        assertEq(a.allowance(address(adapter), address(permit2)), 0);
        assertEq(b.allowance(address(adapter), address(permit2)), 0);
        assertEq(c.allowance(address(adapter), address(permit2)), 0);
    }

    function testHomogeneousEveryProtocolBothModesAndMultihop() public {
        for (uint256 protocol; protocol < 3; ++protocol) {
            uint256 received = adapter.swap(address(a), address(d), 100, abi.encode(_plan(true, Protocol(protocol), 3)));
            assertEq(received, 800);
            _baselines();
            received = adapter.swap(address(a), address(d), 150, abi.encode(_plan(false, Protocol(protocol), 3)));
            assertEq(received, 800);
            _baselines();
        }
    }

    function testMixedV3V4V2UsesActualPredecessorLot() public {
        SwapPlan memory p = _plan(true, Protocol.V3, 3);
        p.branches[0].hops[1].protocol = Protocol.V4;
        p.branches[0].hops[2].protocol = Protocol.V2;
        uint256 received = adapter.swap(address(a), address(d), 100, abi.encode(p));
        assertEq(received, 800);
        assertEq(router.fundedLots(0), 100);
        assertEq(router.fundedLots(1), 200);
        assertEq(router.fundedLots(2), 400);
        assertEq(router.commandLog(), hex"001008");
        _baselines();
    }

    function testMixedV2V3V4Order() public {
        SwapPlan memory p = _plan(true, Protocol.V2, 3);
        p.branches[0].hops[1].protocol = Protocol.V3;
        p.branches[0].hops[2].protocol = Protocol.V4;
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 800);
        _baselines();
    }

    function testIntermediateUnderconsumptionRevertsAtomically() public {
        SwapPlan memory p = _plan(true, Protocol.V3, 3);
        router.configure(address(b), 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapMultiProtocolAdapter.UnsettledIntermediateCurrency.selector, address(b), uint256(1)
            )
        );
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        assertEq(router.calls(), 0);
        assertEq(a.balanceOf(address(this)), 1_000_000);
        _baselines();
    }

    function testOriginalInputUnderconsumptionRefundsWithoutNewFullSpendPredicate() public {
        router.configure(address(a), 2);
        uint256 before = a.balanceOf(address(this));
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(_plan(true, Protocol.V4, 1))), 198);
        assertEq(before - a.balanceOf(address(this)), 99);
        _baselines();
    }

    function testSplitAllocationsAndAllocationDust() public {
        SwapPlan memory p = _plan(true, Protocol.V2, 1);
        Branch memory first = p.branches[0];
        p.branches = new Branch[](2);
        p.branches[0] = first;
        p.branches[0].amountIn = 40;
        p.branches[1] = Branch(59, new Hop[](1));
        p.branches[1].hops[0] = _hop(Protocol.V4, address(d));
        uint256 before = a.balanceOf(address(this));
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 198);
        assertEq(before - a.balanceOf(address(this)), 99);
        assertEq(router.fundedLots(0), 40);
        assertEq(router.fundedLots(1), 59);
        _baselines();
    }

    function testZeroSuccessorDoesNotSpendDonatedRouterBalance() public {
        router.configure(address(0), 0);
        SwapPlan memory p = _plan(true, Protocol.V3, 3);
        p.amountLimit = 0;
        p.branches[0].hops[1].protocol = Protocol.V2;
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 0);
        assertEq(router.calls(), 1);
        _baselines();
    }

    function testMixedExactOutputIsUnsupportedAndFundingRollsBack() public {
        SwapPlan memory p = _plan(false, Protocol.V3, 3);
        p.branches[0].hops[1].protocol = Protocol.V4;
        vm.expectRevert(UniswapRouterEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swap(address(a), address(d), 150, abi.encode(p));
        _baselines();
    }

    function testAggregateFloorAndDeadlineRollback() public {
        SwapPlan memory p = _plan(true, Protocol.V2, 1);
        p.amountLimit = 201;
        vm.expectRevert(
            abi.encodeWithSelector(UniswapMultiProtocolAdapter.InsufficientOutput.selector, uint256(201), uint256(200))
        );
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        _baselines();
        p.amountLimit = 1;
        p.deadline = block.timestamp - 1;
        vm.expectRevert();
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        _baselines();
    }

    function testLiteralV4AmountsCannotTruncate() public {
        uint256 amount = uint256(type(uint128).max) + 1;
        a.mint(address(this), amount);
        SwapPlan memory p = _plan(true, Protocol.V4, 1);
        p.branches[0].amountIn = amount;
        vm.expectRevert();
        adapter.swap(address(a), address(d), amount, abi.encode(p));
        _baselines();
    }

    function testAllocationsCannotConsumeOldInput() public {
        SwapPlan memory p = _plan(true, Protocol.V2, 1);
        p.branches[0].amountIn = 101;
        vm.expectRevert();
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        _baselines();
    }

    function testLegacyV3TupleCompatibilityBothModes() public {
        bytes memory forward = abi.encodePacked(address(a), uint24(100), address(d));
        assertEq(
            adapter.swap(address(a), address(d), 100, abi.encode(forward, uint256(1), block.timestamp + 60, true)), 200
        );
        bytes memory reverse = abi.encodePacked(address(d), uint24(100), address(a));
        assertEq(
            adapter.swap(address(a), address(d), 150, abi.encode(reverse, uint256(200), block.timestamp + 60, false)),
            200
        );
        _baselines();
    }

    function testLegacyPackedPathCannotBypassAcceptedIntermediateSettlement() public {
        bytes memory path = abi.encodePacked(address(a), uint24(100), address(b), uint24(100), address(d));
        router.configureIntermediateLeak(address(b));
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapMultiProtocolAdapter.UnsettledIntermediateCurrency.selector, address(b), uint256(1)
            )
        );
        adapter.swap(address(a), address(d), 100, abi.encode(path, uint256(1), block.timestamp + 60, true));
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testInvalidConstructorEndpointsAndEmptyLotRetainExistingBoundaries() public {
        vm.expectRevert(UniswapMultiProtocolAdapter.InvalidAddress.selector);
        new UniswapMultiProtocolAdapter(address(this), address(0), address(permit2));
        vm.expectRevert(UniswapMultiProtocolAdapter.InvalidAddress.selector);
        new UniswapMultiProtocolAdapter(address(this), address(router), address(0));
        bytes memory data = abi.encode(_plan(true, Protocol.V2, 1));
        vm.expectRevert(UniswapMultiProtocolAdapter.InvalidAddress.selector);
        adapter.swap(address(0), address(d), 100, data);
        vm.expectRevert(UniswapMultiProtocolAdapter.InvalidAddress.selector);
        adapter.swap(address(a), address(0), 100, data);
        vm.expectRevert(UniswapMultiProtocolAdapter.InvalidAmount.selector);
        adapter.swap(address(a), address(d), 0, data);
        _baselines();
    }

    function testExactOutputSplitIsUnsupportedWithoutMovingFunding() public {
        SwapPlan memory p = _plan(false, Protocol.V2, 1);
        Branch memory branch = p.branches[0];
        p.branches = new Branch[](2);
        p.branches[0] = branch;
        p.branches[1] = branch;
        vm.expectRevert(UniswapRouterEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        _baselines();
    }

    function testSharedIntermediateAcrossOrderedBranchesIsAccountedOnce() public {
        SwapPlan memory p = _plan(true, Protocol.V3, 1);
        p.branches = new Branch[](2);
        for (uint256 i; i < 2; ++i) {
            p.branches[i] = Branch(i == 0 ? 40 : 60, new Hop[](2));
            p.branches[i].hops[0] = _hop(Protocol.V3, address(b));
            p.branches[i].hops[1] = _hop(Protocol.V2, address(d));
        }
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 400);
        _baselines();
    }

    function testHistoricalIntermediateDebitsAtEitherCustodianRollback() public {
        for (uint256 atRouter; atRouter < 2; ++atRouter) {
            IssueTestToken token = new IssueTestToken("Burnable", "BURN");
            token.mint(address(adapter), 13);
            token.mint(address(router), 17);
            router.configureIntermediateBurn(address(token), atRouter == 1);
            SwapPlan memory p = _plan(true, Protocol.V3, 1);
            p.branches[0].hops = new Hop[](2);
            p.branches[0].hops[0] = _hop(Protocol.V3, address(token));
            p.branches[0].hops[1] = _hop(Protocol.V3, address(d));
            vm.expectRevert(
                abi.encodeWithSelector(
                    AdapterAccounting.PreExistingInputConsumed.selector,
                    address(token),
                    atRouter == 1 ? uint256(17) : uint256(13),
                    atRouter == 1 ? uint256(16) : uint256(12)
                )
            );
            adapter.swap(address(a), address(d), 100, abi.encode(p));
            assertEq(token.balanceOf(address(adapter)), 13);
            assertEq(token.balanceOf(address(router)), 17);
            _baselines();
        }
    }
}
