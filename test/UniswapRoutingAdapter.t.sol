// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {UniswapRoutingAdapter} from "../src/adapters/UniswapRoutingAdapter.sol";
import {UniswapRoutingEncoding} from "../src/adapters/UniswapRoutingEncoding.sol";
import {IUniswapRoutingTypes} from "../src/interfaces/IUniswapRoutingTypes.sol";
import {AdapterAccounting} from "../src/adapters/AdapterAccounting.sol";
import {MockPermit2Allowance} from "./UniswapUniversalAdapter.t.sol";
import {MockERC20Adapter} from "./mocks/MockERC20Adapter.sol";
import {MockWETH} from "./mocks/BasketRouterMocks.sol";
import {ConditionalSenderSurchargeToken} from "./mocks/ConditionalSenderSurchargeToken.sol";
import {TransferTaxToken} from "./mocks/TransferTaxToken.sol";

/// @dev Pool liquidity is held outside the router, so resting router ETH is never output liquidity.
contract RoutingVenueMock {
    function payNative(address recipient, uint256 amount) external {
        (bool ok,) = recipient.call{value: amount}("");
        require(ok, "native output");
    }
    receive() external payable {}
}

/// @dev Tests the pinned ABI shapes, current-unlock currency netting and partial consumption.
/// It is not evidence of live pool pricing or a substitute for the pinned-router fork suite.
contract RoutingRouterMock {
    using SafeCast for uint256;
    MockPermit2Allowance public immutable permit2;
    RoutingVenueMock public immutable venue;
    address public shortCurrency;
    bool public underconsume;
    uint256 public multiplier = 2;
    uint256 public calls;
    bytes public commandsSeen;
    uint256[] public groupLengths;
    uint256[] public fundedLots;
    address public zeroOutputCurrency;
    bool public zeroOutputConfigured;
    bytes public groupedFailure;
    bytes public singleFailure;
    mapping(address => uint256) private credit;

    error SwapAmountCannotBeZero();

    struct DecodedSwap {
        address recipient;
        uint256 specified;
        uint256 limit;
        address input;
        address output;
        uint256 hops;
    }

    constructor(MockPermit2Allowance permit2_, RoutingVenueMock venue_) {
        permit2 = permit2_;
        venue = venue_;
    }

    function configureShort(address currency) external {
        shortCurrency = currency;
        underconsume = true;
    }

    function configureMultiplier(uint256 value) external {
        multiplier = value;
    }

    function configureZeroOutput(address currency) external {
        zeroOutputCurrency = currency;
        zeroOutputConfigured = true;
    }

    function configureV4Failure(bytes calldata grouped, bytes calldata single) external {
        groupedFailure = grouped;
        singleFailure = single;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        require(deadline >= block.timestamp, "deadline");
        require(commands.length == 1 && inputs.length == 1, "single command");
        ++calls;
        commandsSeen = abi.encodePacked(commandsSeen, commands);
        if (commands[0] == 0x10) _v4(inputs[0]);
        else _v2v3(commands[0], inputs[0]);
    }

    function _v2v3(bytes1 command, bytes calldata payload) private {
        DecodedSwap memory s = _decodeV2V3(command, payload);
        bool exactIn = command == 0x00 || command == 0x08;
        uint256 spend = exactIn ? s.specified : (s.specified + 2 ** s.hops - 1) / (2 ** s.hops);
        if (exactIn && command == 0x00 && underconsume && s.input == shortCurrency) --spend;
        if (!exactIn) require(spend <= s.limit, "maximum");
        fundedLots.push(exactIn ? s.specified : s.limit);
        _fund(s.input, spend);
        _pay(s.output, s.recipient, exactIn ? spend * multiplier : s.specified);
    }

    function _decodeV2V3(bytes1 command, bytes calldata payload) private view returns (DecodedSwap memory s) {
        bool payer;
        uint256[] memory prices;
        bool exactIn = command == 0x00 || command == 0x08;
        if (command == 0x08 || command == 0x09) {
            address[] memory path;
            (s.recipient, s.specified, s.limit, path, payer, prices) =
                abi.decode(payload, (address, uint256, uint256, address[], bool, uint256[]));
            s.input = path[0];
            s.output = path[path.length - 1];
            s.hops = path.length - 1;
        } else {
            require(command == 0x00 || command == 0x01, "command");
            bytes memory path;
            (s.recipient, s.specified, s.limit, path, payer, prices) =
                abi.decode(payload, (address, uint256, uint256, bytes, bool, uint256[]));
            require(path.length >= 43 && (path.length - 20) % 23 == 0, "path ABI");
            s.input = _address(path, exactIn ? 0 : path.length - 20);
            s.output = _address(path, exactIn ? path.length - 20 : 0);
            s.hops = (path.length - 20) / 23;
        }
        require(payer && s.recipient == msg.sender && prices.length == 0, "payer/custody/price ABI");
    }

    function _v4(bytes calldata payload) private {
        (bytes memory actions, bytes[] memory params) = abi.decode(payload, (bytes, bytes[]));
        if (actions[0] == 0x09) {
            _v4ExactOut(actions, params);
            return;
        }
        require(actions[0] == 0x0b && actions[1] == 0x07, "settle/multihop exact-in ABI");
        (address input, uint256 amount, bool payer) = abi.decode(params[0], (address, uint256, bool));
        UniswapRoutingEncoding.ExactInput memory p = abi.decode(params[1], (UniswapRoutingEncoding.ExactInput));
        require(payer && p.currencyIn == input && p.amountIn == 0 && p.amountOutMinimum == 0, "open-credit ABI");
        require(p.minHopPriceX36.length == 0 && params.length == p.path.length + 3, "take/price ABI");
        groupLengths.push(p.path.length);
        fundedLots.push(amount);
        amount.toUint128(); // pinned V4Router's checked full-credit conversion
        _fund(input, amount);
        credit[input] = amount;
        bytes memory failure = p.path.length > 1 ? groupedFailure : singleFailure;
        if (failure.length != 0) {
            assembly ("memory-safe") { revert(add(failure, 32), mload(failure)) }
        }
        for (uint256 i; i < p.path.length; ++i) {
            if (amount == 0) revert SwapAmountCannotBeZero();
            UniswapRoutingEncoding.PathKey memory key = p.path[i];
            require(key.hooks == address(0) && key.hookData.length == 0, "no hooks");
            uint256 spend = amount;
            if (underconsume && input == shortCurrency) --spend;
            credit[input] -= spend;
            amount = zeroOutputConfigured && input == zeroOutputCurrency ? 0 : spend * multiplier;
            credit[key.intermediateCurrency] += amount;
            input = key.intermediateCurrency;
        }
        for (uint256 i = 2; i < params.length; ++i) {
            require(actions[i] == 0x0e, "TAKE ABI");
            (address currency, address recipient, uint256 take) = abi.decode(params[i], (address, address, uint256));
            require(recipient == msg.sender && take == 0, "take current credit to adapter");
            uint256 value = credit[currency];
            credit[currency] = 0;
            _pay(currency, recipient, value);
        }
    }

    function _v4ExactOut(bytes memory actions, bytes[] memory params) private {
        require(keccak256(actions) == keccak256(hex"090c0f"), "exact-out actions");
        UniswapRoutingEncoding.ExactOutput memory p = abi.decode(params[0], (UniswapRoutingEncoding.ExactOutput));
        (address input, uint256 maximum) = abi.decode(params[1], (address, uint256));
        (address output, uint256 minimum) = abi.decode(params[2], (address, uint256));
        require(input == p.path[0].intermediateCurrency && maximum == p.amountInMaximum, "input path order");
        require(output == p.currencyOut && minimum == 0 && p.minHopPriceX36.length == 0, "output/price ABI");
        for (uint256 i; i < p.path.length; ++i) {
            require(p.path[i].hooks == address(0) && p.path[i].hookData.length == 0, "no hooks");
        }
        uint256 spend = (uint256(p.amountOut) + 2 ** p.path.length - 1) / (2 ** p.path.length);
        require(spend <= maximum, "maximum");
        _fund(input, spend);
        _pay(output, msg.sender, p.amountOut);
    }

    function _fund(address currency, uint256 amount) private {
        if (currency == address(0)) {
            (bool ok,) = address(venue).call{value: amount}("");
            require(ok, "native funding");
        } else {
            permit2.transferFrom(msg.sender, address(venue), amount.toUint160(), currency);
        }
    }

    function _pay(address currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency == address(0)) venue.payNative(recipient, amount);
        else MockERC20Adapter(currency).mint(recipient, amount);
    }

    function _address(bytes memory path, uint256 offset) private pure returns (address currency) {
        assembly ("memory-safe") { currency := shr(96, mload(add(add(path, 32), offset))) }
    }
    receive() external payable {}
}

contract RejectRoutingNative {
    function run(UniswapRoutingAdapter adapter, IERC20 input, uint256 amount, bytes calldata data) external {
        input.approve(address(adapter), amount);
        adapter.swap(address(input), address(0), amount, data);
    }
}

contract ReentrantRoutingCaller {
    UniswapRoutingAdapter private immutable adapter;
    address private immutable output;
    bytes private nestedPlan;
    bool public attempted;
    bool public nestedSucceeded;
    bytes4 public nestedError;

    constructor(UniswapRoutingAdapter adapter_, address output_, bytes memory nestedPlan_) {
        adapter = adapter_;
        output = output_;
        nestedPlan = nestedPlan_;
    }

    function run(bytes calldata data) external payable {
        adapter.swapNative{value: msg.value}(output, data);
    }

    receive() external payable {
        if (!attempted) {
            attempted = true;
            (bool ok, bytes memory reason) =
                address(adapter).call{value: 2}(abi.encodeCall(adapter.swapNative, (output, nestedPlan)));
            nestedSucceeded = ok;
            nestedError = bytes4(reason);
        }
    }
}

contract UniswapRoutingAdapterTest is Test, IUniswapRoutingTypes {
    MockERC20Adapter private a;
    MockERC20Adapter private b;
    MockERC20Adapter private c;
    MockERC20Adapter private d;
    MockWETH private weth;
    MockPermit2Allowance private permit2;
    RoutingVenueMock private venue;
    RoutingRouterMock private router;
    UniswapRoutingAdapter private adapter;

    function setUp() public {
        vm.warp(1000);
        a = new MockERC20Adapter("A", "A");
        b = new MockERC20Adapter("B", "B");
        c = new MockERC20Adapter("C", "C");
        d = new MockERC20Adapter("D", "D");
        weth = new MockWETH();
        permit2 = new MockPermit2Allowance();
        venue = new RoutingVenueMock();
        router = new RoutingRouterMock(permit2, venue);
        adapter = new UniswapRoutingAdapter(address(this), address(router), address(permit2), address(weth));
        a.mint(address(this), 1_000_000);
        a.approve(address(adapter), type(uint256).max);
        a.mint(address(adapter), 7);
        d.mint(address(adapter), 11);
        b.mint(address(adapter), 13);
        b.mint(address(router), 17);
        c.mint(address(adapter), 19);
        c.mint(address(router), 23);
        vm.deal(address(this), 100 ether);
        vm.deal(address(venue), 100 ether);
        vm.deal(address(weth), 100 ether);
        vm.deal(address(adapter), 7);
        vm.deal(address(router), 17);
    }

    function _step(StepKind kind, address output) private pure returns (Step memory) {
        return Step(kind, output, 100, 1);
    }

    function _plan(StepKind kind, address[] memory outputs, uint256 amount) private view returns (SwapPlan memory p) {
        p.exactIn = true;
        p.amountLimit = 1;
        p.deadline = block.timestamp + 60;
        p.branches = new Branch[](1);
        p.branches[0] = Branch(amount, new Step[](outputs.length));
        for (uint256 i; i < outputs.length; ++i) {
            p.branches[0].steps[i] = _step(kind, outputs[i]);
        }
    }

    function _one(StepKind kind, address output, uint256 amount) private view returns (SwapPlan memory) {
        address[] memory outputs = new address[](1);
        outputs[0] = output;
        return _plan(kind, outputs, amount);
    }

    function _baselines() private view {
        assertEq(a.balanceOf(address(adapter)), 7);
        assertEq(d.balanceOf(address(adapter)), 11);
        assertEq(b.balanceOf(address(adapter)), 13);
        assertEq(b.balanceOf(address(router)), 17);
        assertEq(c.balanceOf(address(adapter)), 19);
        assertEq(c.balanceOf(address(router)), 23);
        assertEq(address(adapter).balance, 7);
        assertEq(address(router).balance, 17);
        assertEq(a.allowance(address(adapter), address(permit2)), 0);
        assertEq(b.allowance(address(adapter), address(permit2)), 0);
        assertEq(c.allowance(address(adapter), address(permit2)), 0);
    }

    function testEveryProtocolExactInputAndHomogeneousExactOutputRefund() public {
        address[] memory outputs = new address[](3);
        outputs[0] = address(b);
        outputs[1] = address(c);
        outputs[2] = address(d);
        for (uint256 k; k < 3; ++k) {
            SwapPlan memory p = _plan(StepKind(k), outputs, 100);
            assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 800);
            _baselines();
            p.exactIn = false;
            p.amountLimit = 800;
            uint256 before = a.balanceOf(address(this));
            assertEq(adapter.swap(address(a), address(d), 150, abi.encode(p)), 800);
            assertEq(before - a.balanceOf(address(this)), 100);
            _baselines();
        }
    }

    function testConstructorNamesTheMissingIdentity() public {
        vm.expectRevert(UniswapRoutingAdapter.InvalidRouter.selector);
        new UniswapRoutingAdapter(address(this), address(0), address(permit2), address(weth));
        vm.expectRevert(UniswapRoutingAdapter.InvalidPermit2.selector);
        new UniswapRoutingAdapter(address(this), address(router), address(0), address(weth));
        vm.expectRevert(UniswapRoutingAdapter.InvalidWrappedNative.selector);
        new UniswapRoutingAdapter(address(this), address(router), address(permit2), address(0));
    }

    function testV4GroupsAdjacentHopsInOneCallAndPreservesNativeIntermediate() public {
        address[] memory outputs = new address[](3);
        outputs[0] = address(b);
        outputs[1] = address(0);
        outputs[2] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 800);
        assertEq(router.calls(), 1);
        assertEq(router.groupLengths(0), 3);
        _baselines();
    }

    function testV4ZeroOutputAtEveryInteriorPositionRetriesOnlyOwnedSingleHopLots() public {
        address[] memory outputs = new address[](4);
        outputs[0] = address(b);
        outputs[1] = address(c);
        outputs[2] = address(weth);
        outputs[3] = address(d);
        weth.mint(address(adapter), 29);
        weth.mint(address(router), 31);
        for (uint256 zero; zero < 3; ++zero) {
            router.configureZeroOutput(zero == 0 ? address(a) : outputs[zero - 1]);
            SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
            p.amountLimit = 0;
            uint256 callsBefore = router.calls();
            uint256 payerBefore = a.balanceOf(address(this));
            uint256 venueBefore = a.balanceOf(address(venue));
            assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 0);
            assertEq(router.calls() - callsBefore, zero + 1);
            for (uint256 i; i <= zero; ++i) {
                assertEq(router.groupLengths(callsBefore + i), 1);
                assertEq(router.fundedLots(callsBefore + i), 100 * 2 ** i);
            }
            assertEq(payerBefore - a.balanceOf(address(this)), 100);
            assertEq(a.balanceOf(address(venue)) - venueBefore, 100, "failed group funding rolled back");
            assertEq(weth.balanceOf(address(adapter)), 29);
            assertEq(weth.balanceOf(address(router)), 31);
            _baselines();
        }
    }

    function testV4ZeroOutputBranchDoesNotBlockPositiveSiblingMinimum() public {
        router.configureZeroOutput(address(a));
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        Branch memory tiny = p.branches[0];
        p.branches = new Branch[](2);
        p.branches[0] = tiny;
        p.branches[1] = Branch(200, new Step[](1));
        p.branches[1].steps[0] = _step(StepKind.V3, address(d));
        p.amountLimit = 400;
        assertEq(adapter.swap(address(a), address(d), 300, abi.encode(p)), 400);
        assertEq(router.calls(), 2);
        assertEq(router.commandsSeen(), hex"1000");
        assertEq(a.balanceOf(address(venue)), 300);
        _baselines();
    }

    function testV4NativeZeroRetryPreservesHistoricalNativeBalances() public {
        router.configureZeroOutput(address(0));
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        p.amountLimit = 0;
        uint256 payerBefore = address(this).balance;
        uint256 venueBefore = address(venue).balance;
        assertEq(adapter.swapNative{value: 100}(address(d), abi.encode(p)), 0);
        assertEq(payerBefore - address(this).balance, 100);
        assertEq(address(venue).balance - venueBefore, 100);
        assertEq(router.calls(), 1);
        assertEq(router.groupLengths(0), 1);
        _baselines();
    }

    function testV4ZeroRetryPreservesEndpointReturnAndIntermediateRemainderBoundary() public {
        address[] memory outputs = new address[](3);
        outputs[0] = address(b);
        outputs[1] = address(c);
        outputs[2] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        p.amountLimit = 0;
        router.configureShort(address(a));
        router.configureZeroOutput(address(a));
        uint256 payerBefore = a.balanceOf(address(this));
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 0);
        assertEq(payerBefore - a.balanceOf(address(this)), 99);
        assertEq(a.balanceOf(address(venue)), 100, "returned endpoint credit is minted by this mock");
        _baselines();
        router.configureShort(address(b));
        router.configureZeroOutput(address(b));
        payerBefore = a.balanceOf(address(this));
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingAdapter.UnsettledIntermediateCurrency.selector, address(b), 1)
        );
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        assertEq(a.balanceOf(address(this)), payerBefore);
        assertEq(router.calls(), 1, "intermediate-remainder failure rolls back every retry hop");
        _baselines();
    }

    function testV4SpoofedZeroErrorReplaysEveryHopAndPreservesAggregateMinimum() public {
        bytes memory zero = abi.encodeWithSignature("SwapAmountCannotBeZero()");
        router.configureV4Failure(zero, "");
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        p.amountLimit = 400;
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 400);
        assertEq(router.calls(), 2);
        assertEq(router.groupLengths(0), 1);
        assertEq(router.groupLengths(1), 1);
        assertEq(a.balanceOf(address(venue)), 100);
        p.amountLimit = 401;
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingAdapter.InsufficientOutput.selector, 401, 400));
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        assertEq(router.calls(), 2);
        assertEq(a.balanceOf(address(venue)), 100);
        _baselines();
    }

    function testV4RetryPreservesTheSingleHopFailureAndRollsBackAllFunding() public {
        bytes memory reason = abi.encodeWithSignature("Error(string)", "replayed venue rejected lot");
        router.configureV4Failure(abi.encodeWithSignature("SwapAmountCannotBeZero()"), reason);
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(d);
        uint256 payerBefore = a.balanceOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingAdapter.UniversalRouterSwapFailed.selector, reason));
        adapter.swap(address(a), address(d), 100, abi.encode(_plan(StepKind.V4, outputs, 100)));
        assertEq(a.balanceOf(address(this)), payerBefore);
        assertEq(a.balanceOf(address(venue)), 0);
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testV4NeverRetriesSingleHopOrInexactZeroSwapErrors() public {
        bytes memory zero = abi.encodeWithSignature("SwapAmountCannotBeZero()");
        router.configureV4Failure("", zero);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingAdapter.UniversalRouterSwapFailed.selector, zero));
        adapter.swap(address(a), address(d), 100, abi.encode(_one(StepKind.V4, address(d), 100)));
        bytes[] memory reasons = new bytes[](4);
        reasons[0] = hex"be8b85";
        reasons[1] = abi.encodePacked(zero, bytes1(0));
        reasons[2] = abi.encodeWithSignature("CurrencyNotSettled()");
        reasons[3] = abi.encodeWithSignature("ExecutionFailed(uint256,bytes)", 0, zero);
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(d);
        for (uint256 i; i < reasons.length; ++i) {
            router.configureV4Failure(reasons[i], "");
            vm.expectRevert(
                abi.encodeWithSelector(UniswapRoutingAdapter.UniversalRouterSwapFailed.selector, reasons[i])
            );
            adapter.swap(address(a), address(d), 100, abi.encode(_plan(StepKind.V4, outputs, 100)));
        }
        assertEq(a.balanceOf(address(venue)), 0);
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testMixedProtocolsPropagateMeasuredLots() public {
        address[] memory outputs = new address[](4);
        outputs[0] = address(b);
        outputs[1] = address(c);
        outputs[2] = address(weth);
        outputs[3] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        p.branches[0].steps[0].kind = StepKind.V2;
        p.branches[0].steps[3].kind = StepKind.V3;
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 1600);
        assertEq(router.commandsSeen(), hex"081000");
        assertEq(router.fundedLots(0), 100);
        assertEq(router.fundedLots(1), 200);
        assertEq(router.fundedLots(2), 800);
        _baselines();
    }

    function testNativeFundingReturnsOnlyCurrentOriginalInputRemainderToPublicCaller() public {
        router.configureShort(address(0));
        uint256 before = address(this).balance;
        assertEq(adapter.swapNative{value: 100}(address(d), abi.encode(_one(StepKind.V4, address(d), 100))), 198);
        assertEq(before - address(this).balance, 99);
        _baselines();
    }

    function testNativeOutputAndExplicitWrapTransition() public {
        SwapPlan memory p = _one(StepKind.V4, address(0), 100);
        uint256 before = address(this).balance;
        assertEq(adapter.swap(address(a), address(0), 100, abi.encode(p)), 200);
        assertEq(address(this).balance - before, 200);
        address[] memory outputs = new address[](3);
        outputs[0] = address(0);
        outputs[1] = address(weth);
        outputs[2] = address(d);
        p = _plan(StepKind.V4, outputs, 100);
        p.branches[0].steps[1].kind = StepKind.WrapNative;
        p.branches[0].steps[2].kind = StepKind.V3;
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 400);
        _baselines();
    }

    function testExplicitUnwrapIntoNativeV4Input() public {
        weth.mint(address(this), 100);
        weth.approve(address(adapter), 100);
        address[] memory outputs = new address[](2);
        outputs[0] = address(0);
        outputs[1] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        p.branches[0].steps[0].kind = StepKind.UnwrapNative;
        assertEq(adapter.swap(address(weth), address(d), 100, abi.encode(p)), 200);
        _baselines();
    }

    function testGroupedNativeIntermediateRemainderRetainsExactCurrencyDiagnosisAndRollback() public {
        router.configureShort(address(0));
        address[] memory outputs = new address[](2);
        outputs[0] = address(0);
        outputs[1] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingAdapter.UnsettledIntermediateCurrency.selector, address(0), 1)
        );
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testRepeatedCurrencyPartitionsCannotAbsorbAnEarlierRemainder() public {
        router.configureShort(address(b));
        address[] memory outputs = new address[](4);
        outputs[0] = address(b);
        outputs[1] = address(c);
        outputs[2] = address(b);
        outputs[3] = address(d);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingAdapter.UnsettledIntermediateCurrency.selector, address(b), 2)
        );
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        _baselines();
    }

    function testRepeatedCurrencyRouteExecutesAsTwoGroupsWithoutRouteRejection() public {
        address[] memory outputs = new address[](4);
        outputs[0] = address(b);
        outputs[1] = address(c);
        outputs[2] = address(b);
        outputs[3] = address(d);
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(_plan(StepKind.V4, outputs, 100))), 1600);
        assertEq(router.calls(), 2);
        assertEq(router.groupLengths(0), 2);
        assertEq(router.groupLengths(1), 2);
        _baselines();
    }

    function testCyclicInputGainReturnsEntireInputDeltaWithoutCap() public {
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(a);
        SwapPlan memory p = _plan(StepKind.V4, outputs, 100);
        p.amountLimit = 0;
        uint256 before = a.balanceOf(address(this));
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 0);
        assertEq(a.balanceOf(address(this)) - before, 300);
        _baselines();
    }

    function testSplitAllocationsPermitUnallocatedInputAndDifferentProtocols() public {
        SwapPlan memory p = _one(StepKind.V2, address(d), 40);
        Branch memory first = p.branches[0];
        p.branches = new Branch[](2);
        p.branches[0] = first;
        p.branches[1] = Branch(59, new Step[](1));
        p.branches[1].steps[0] = _step(StepKind.V4, address(d));
        uint256 before = a.balanceOf(address(this));
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 198);
        assertEq(before - a.balanceOf(address(this)), 99);
        _baselines();
    }

    function testZeroMeasuredOutputSkipsDownstreamSentinels() public {
        router.configureMultiplier(0);
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(d);
        SwapPlan memory p = _plan(StepKind.V3, outputs, 100);
        p.branches[0].steps[1].kind = StepKind.V2;
        p.amountLimit = 0;
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 0);
        assertEq(router.calls(), 1);
        _baselines();
    }

    function testBoundsAndFundingCannotConsumeDonations() public {
        SwapPlan memory p = _one(StepKind.V4, address(d), 101);
        vm.expectRevert();
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        p.branches[0].amountIn = 100;
        p.amountLimit = 201;
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingAdapter.InsufficientOutput.selector, 201, 200));
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        _baselines();
    }

    function testV4CreditConversionDoesNotTruncateOversizedLot() public {
        uint256 amount = uint256(type(uint128).max) + 1;
        a.mint(address(this), amount);
        vm.expectRevert();
        adapter.swap(address(a), address(d), amount, abi.encode(_one(StepKind.V4, address(d), amount)));
        _baselines();
    }

    function testUnsupportedExactOutputShapesRetainTheirOrdinaryError() public {
        SwapPlan memory p = _one(StepKind.V4, address(0), 100);
        p.exactIn = false;
        vm.expectRevert(UniswapRoutingEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swap(address(a), address(0), 100, abi.encode(p));
        p = _one(StepKind.V4, address(d), 100);
        p.exactIn = false;
        vm.expectRevert(UniswapRoutingEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swapNative{value: 100}(address(d), abi.encode(p));
        _baselines();
    }

    function testNativePayoutFailureRollsBackVenueAndFunding() public {
        RejectRoutingNative rejector = new RejectRoutingNative();
        a.mint(address(rejector), 100);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapRoutingAdapter.NativePayoutFailed.selector, address(rejector), 200)
        );
        rejector.run(adapter, a, 100, abi.encode(_one(StepKind.V4, address(0), 100)));
        assertEq(a.balanceOf(address(rejector)), 100);
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testNativeInputReturnCannotReenterFunding() public {
        router.configureShort(address(0));
        ReentrantRoutingCaller caller =
            new ReentrantRoutingCaller(adapter, address(d), abi.encode(_one(StepKind.V4, address(d), 2)));
        vm.deal(address(caller), 100);
        caller.run{value: 100}(abi.encode(_one(StepKind.V4, address(d), 100)));
        assertTrue(caller.attempted());
        assertFalse(caller.nestedSucceeded());
        assertEq(caller.nestedError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(d.balanceOf(address(caller)), 198);
        assertEq(router.calls(), 1);
        _baselines();
    }

    function testConversionCannotSpendAnotherCurrencyLotOrHistoricalWeth() public {
        SwapPlan memory p = _one(StepKind.WrapNative, address(weth), 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingAdapter.InvalidConversionInput.selector, StepKind.WrapNative, address(a)
            )
        );
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        _baselines();
    }

    function testEmptyAndNativeFundingErrorsNameTheInvalidInput() public {
        bytes memory data = abi.encode(_one(StepKind.V4, address(d), 100));
        vm.expectRevert(UniswapRoutingAdapter.InvalidAddress.selector);
        adapter.swap(address(0), address(d), 100, data);
        vm.expectRevert(UniswapRoutingAdapter.InvalidAmount.selector);
        adapter.swap(address(a), address(d), 0, data);
        vm.expectRevert(UniswapRoutingAdapter.InvalidAmount.selector);
        adapter.swapNative(address(d), data);
        vm.expectRevert(abi.encodeWithSelector(AdapterAccounting.IdenticalSwapTokens.selector, address(0)));
        adapter.swapNative{value: 100}(address(0), data);
        _baselines();
    }

    function testZeroBranchAndZeroDeadlinePreserveOnlyTheFundedOperation() public {
        SwapPlan memory p = _one(StepKind.V4, address(d), 100);
        Branch memory funded = p.branches[0];
        p.branches = new Branch[](2);
        p.branches[0] = Branch(0, new Step[](1));
        p.branches[0].steps[0] = _step(StepKind.V3, address(b));
        p.branches[1] = funded;
        p.deadline = 0;
        assertEq(adapter.swap(address(a), address(d), 100, abi.encode(p)), 200);
        assertEq(router.calls(), 1);
        _baselines();
    }

    function testExactOutputCannotUseSplitMixedOrConversionRoutes() public {
        SwapPlan memory p = _one(StepKind.V4, address(d), 100);
        p.exactIn = false;
        p.branches = new Branch[](0);
        vm.expectRevert(UniswapRoutingEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        p.branches = new Branch[](2);
        vm.expectRevert(UniswapRoutingEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        p = _one(StepKind.WrapNative, address(d), 100);
        p.exactIn = false;
        vm.expectRevert(UniswapRoutingEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(d);
        p = _plan(StepKind.V2, outputs, 100);
        p.exactIn = false;
        p.branches[0].steps[1].kind = StepKind.V3;
        vm.expectRevert(UniswapRoutingEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        p.branches[0].steps[1] = _step(StepKind.V2, address(0));
        vm.expectRevert(UniswapRoutingEncoding.UnsupportedExactOutputRoute.selector);
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        _baselines();
    }

    function testExplicitConversionsRejectDifferentActualCurrencies() public {
        SwapPlan memory p = _one(StepKind.WrapNative, address(b), 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingAdapter.InvalidConversionOutput.selector, StepKind.WrapNative, address(b)
            )
        );
        adapter.swapNative{value: 100}(address(b), abi.encode(p));
        p = _one(StepKind.UnwrapNative, address(0), 100);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingAdapter.InvalidConversionInput.selector, StepKind.UnwrapNative, address(a)
            )
        );
        adapter.swap(address(a), address(0), 100, abi.encode(p));
        weth.mint(address(this), 100);
        weth.approve(address(adapter), 100);
        p.branches[0].steps[0].currencyOut = address(b);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapRoutingAdapter.InvalidConversionOutput.selector, StepKind.UnwrapNative, address(b)
            )
        );
        adapter.swap(address(weth), address(b), 100, abi.encode(p));
        assertEq(weth.balanceOf(address(this)), 100);
        _baselines();
    }

    function testCallerFundingCannotChargeAnUndisclosedSenderSurcharge() public {
        ConditionalSenderSurchargeToken token = new ConditionalSenderSurchargeToken();
        token.mint(address(this), 1000);
        token.setSurchargedSender(address(this));
        token.approve(address(adapter), 100);
        vm.expectRevert(
            abi.encodeWithSelector(AdapterAccounting.CallerTokenDebitMismatch.selector, address(token), 100, 110)
        );
        adapter.swap(address(token), address(d), 100, abi.encode(_one(StepKind.V4, address(d), 100)));
        assertEq(token.balanceOf(address(this)), 1000);
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testCallerFundingCannotSubstituteTaxedCreditForTheDeclaredLot() public {
        TransferTaxToken token = new TransferTaxToken();
        token.mint(address(this), 1000);
        token.approve(address(adapter), 100);
        vm.expectRevert(abi.encodeWithSelector(AdapterAccounting.InputAmountMismatch.selector, 100, 90));
        adapter.swap(address(token), address(d), 100, abi.encode(_one(StepKind.V4, address(d), 100)));
        assertEq(token.balanceOf(address(this)), 1000);
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testPayoutCannotReportMoreThanTheRecipientActuallyReceives() public {
        TransferTaxToken token = new TransferTaxToken();
        vm.expectRevert(
            abi.encodeWithSelector(
                AdapterAccounting.AdapterRecipientCreditMismatch.selector, address(token), address(this), 200, 180
            )
        );
        adapter.swap(address(a), address(token), 100, abi.encode(_one(StepKind.V4, address(token), 100)));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testPayoutCannotUseHistoricalOutputToPayItsSenderTax() public {
        ConditionalSenderSurchargeToken token = new ConditionalSenderSurchargeToken();
        token.mint(address(adapter), 20);
        token.setSurchargedSender(address(adapter));
        vm.expectRevert(
            abi.encodeWithSelector(AdapterAccounting.AdapterTokenDebitMismatch.selector, address(token), 200, 220)
        );
        adapter.swap(address(a), address(token), 100, abi.encode(_one(StepKind.V4, address(token), 100)));
        assertEq(token.balanceOf(address(adapter)), 20);
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testVenueFundingCannotSpendHistoricalOriginalInput() public {
        ConditionalSenderSurchargeToken token = new ConditionalSenderSurchargeToken();
        token.mint(address(this), 1000);
        token.mint(address(adapter), 20);
        token.setSurchargedSender(address(adapter));
        token.approve(address(adapter), 100);
        vm.expectRevert(
            abi.encodeWithSelector(AdapterAccounting.PreExistingInputConsumed.selector, address(token), 20, 10)
        );
        adapter.swap(address(token), address(d), 100, abi.encode(_one(StepKind.V4, address(d), 100)));
        assertEq(token.balanceOf(address(adapter)), 20);
        assertEq(token.balanceOf(address(this)), 1000);
        _baselines();
    }

    function testVenueFundingCannotSpendHistoricalIntermediate() public {
        ConditionalSenderSurchargeToken token = new ConditionalSenderSurchargeToken();
        token.mint(address(adapter), 100);
        token.setSurchargedSender(address(adapter));
        address[] memory outputs = new address[](2);
        outputs[0] = address(token);
        outputs[1] = address(d);
        SwapPlan memory p = _plan(StepKind.V3, outputs, 100);
        p.branches[0].steps[1].kind = StepKind.V2;
        vm.expectRevert(
            abi.encodeWithSelector(AdapterAccounting.PreExistingInputConsumed.selector, address(token), 100, 80)
        );
        adapter.swap(address(a), address(d), 100, abi.encode(p));
        assertEq(token.balanceOf(address(adapter)), 100);
        _baselines();
    }

    function testRouterHistoricalIntermediateDecreaseIsNotCurrentOutput() public {
        bytes[] memory observed = new bytes[](2);
        observed[0] = abi.encode(uint256(17));
        observed[1] = abi.encode(uint256(16));
        vm.mockCalls(address(b), abi.encodeCall(b.balanceOf, (address(router))), observed);
        address[] memory outputs = new address[](2);
        outputs[0] = address(b);
        outputs[1] = address(d);
        vm.expectRevert(abi.encodeWithSelector(AdapterAccounting.PreExistingInputConsumed.selector, address(b), 17, 16));
        adapter.swap(address(a), address(d), 100, abi.encode(_plan(StepKind.V4, outputs, 100)));
        vm.clearMockedCalls();
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testRouterRevertKeepsItsOriginalFailureAndRollsBackFunding() public {
        bytes memory reason = abi.encodeWithSignature("Error(string)", "venue rejected lot");
        vm.mockCallRevert(address(router), abi.encodeWithSelector(RoutingRouterMock.execute.selector), reason);
        vm.expectRevert(abi.encodeWithSelector(UniswapRoutingAdapter.UniversalRouterSwapFailed.selector, reason));
        adapter.swap(address(a), address(d), 100, abi.encode(_one(StepKind.V3, address(d), 100)));
        vm.clearMockedCalls();
        assertEq(router.calls(), 0);
        _baselines();
    }

    function testFuzzSplitInputConservation(uint96 first, uint96 second, uint96 dust) public {
        uint256 amount = uint256(first) + second + dust + 2;
        a.mint(address(this), amount);
        SwapPlan memory p = _one(StepKind.V2, address(d), uint256(first) + 1);
        Branch memory initial = p.branches[0];
        p.branches = new Branch[](2);
        p.branches[0] = initial;
        p.branches[1] = Branch(uint256(second) + 1, new Step[](1));
        p.branches[1].steps[0] = _step(StepKind.V4, address(d));
        uint256 before = a.balanceOf(address(this));
        uint256 consumed = uint256(first) + second + 2;
        assertEq(adapter.swap(address(a), address(d), amount, abi.encode(p)), consumed * 2);
        assertEq(before - a.balanceOf(address(this)), consumed);
        _baselines();
    }

    receive() external payable {}
}
