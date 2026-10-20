// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LibAppStorage} from "../../src/diamond/LibAppStorage.sol";
import {ITradeExactInput} from "../../src/interfaces/ITradeExactInput.sol";
import {IUniswapRoutingTypes} from "../../src/interfaces/IUniswapRoutingTypes.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {INativeSwapAdapter} from "../../src/interfaces/INativeSwapAdapter.sol";
import {RecoveryShareReceiverFacet} from "../../src/facets/RecoveryShareReceiverFacet.sol";
import {TradeExactInFacet} from "../../src/facets/TradeExactInFacet.sol";
import {UniswapRoutingAdapter} from "../../src/adapters/UniswapRoutingAdapter.sol";
import {TradeExactInputDeployment} from "../../src/deploy/TradeExactInputDeployment.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";
import {
    MintableToken,
    MockPermitToken,
    MockWETH,
    MockPermit2,
    MockCoreController
} from "../mocks/BasketRouterMocks.sol";
import {MixedRedemptionCore} from "../mocks/MixedRedemptionCore.sol";

/// @dev Exercise the actual compiled facet through custody-preserving delegatecall, without
/// inheriting its deeply nested public ABI into a separately compiled test harness.
contract ExactInputTestProxy {
    using EnumerableSet for EnumerableSet.AddressSet;
    address private immutable IMPLEMENTATION;
    address private immutable RECEIVER;

    constructor(address implementation, address receiver) {
        IMPLEMENTATION = implementation;
        RECEIVER = receiver;
    }

    function configure(address core, address weth, address adapter, address owner, uint256 fee) external {
        LibAppStorage.RouterStorage storage rs = LibAppStorage.routerStorage();
        rs.coreDiamond = core;
        rs.wrappedNative = weth;
        rs.helperFeePpm = fee;
        rs.approvedAdapters.add(adapter);
        LibDiamond.setContractOwner(owner);
    }

    function approveAdapter(address adapter, bool approved) external {
        if (approved) LibAppStorage.routerStorage().approvedAdapters.add(adapter);
        else LibAppStorage.routerStorage().approvedAdapters.remove(adapter);
    }

    fallback() external payable {
        address target = msg.sig == IERC1155Receiver.onERC1155BatchReceived.selector ? RECEIVER : IMPLEMENTATION;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(success) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    receive() external payable {}
}

import {ExactInputBoundaryAdapter} from "../mocks/ExactInputBoundaryAdapter.sol";

contract ExactInputRejectNative {
    receive() external payable {
        revert("reject");
    }
}

contract ExactInputReentrantRecipient {
    address private immutable TARGET;
    bytes private _calldata;
    bool public blocked;

    constructor(address target, bytes memory callData) {
        TARGET = target;
        _calldata = callData;
    }

    receive() external payable {
        (bool success, bytes memory errorData) = TARGET.call(_calldata);
        require(!success, "reentered");
        require(bytes4(errorData) == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "wrong failure");
        blocked = true;
    }
}

contract TradeExactInFacetTest is Test, ITradeExactInput, IUniswapRoutingTypes {
    function executeExactInput(ExactInputPlan calldata, FundingBundle calldata)
        external
        payable
        returns (TradeResult memory)
    {
        revert("test type namespace only");
    }
    address private constant USER = address(0xBEEF);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant OWNER = address(0xA11CE);
    uint256 private constant HELPER_FEE = 5_000;
    MockPermitToken private payment;
    MintableToken private a;
    MintableToken private b;
    MockWETH private weth;
    MockPermit2 private permit2;
    MockCoreController private core;
    ExactInputBoundaryAdapter private adapter;
    ExactInputTestProxy private proxy;
    ITradeExactInput private trade;

    function setUp() public {
        payment = new MockPermitToken("Payment", "PAY");
        a = new MintableToken("Asset A", "A");
        b = new MintableToken("Asset B", "B");
        weth = new MockWETH();
        permit2 = new MockPermit2();
        core = new MockCoreController(_assets(), _pair(500_000, 500_000), _pair(1 ether, 1 ether));
        adapter = new ExactInputBoundaryAdapter();
        address implementation =
            vm.deployCode("TradeExactInFacet.sol:TradeExactInFacet", abi.encode(address(permit2), address(adapter)));
        proxy = new ExactInputTestProxy(implementation, address(new RecoveryShareReceiverFacet()));
        proxy.configure(address(core), address(weth), address(adapter), OWNER, HELPER_FEE);
        trade = ITradeExactInput(address(proxy));
        payment.mint(USER, 1_000_000);
        a.mint(USER, 1_000_000);
        b.mint(USER, 1_000_000);
        core.mint(USER, 10_000);
        payment.mint(address(proxy), 23);
        a.mint(address(proxy), 11);
        b.mint(address(proxy), 13);
        core.mint(address(proxy), 17);
        weth.mint(address(proxy), 19);
        payment.mint(address(adapter), 1_000_000);
        a.mint(address(adapter), 1_000_000);
        b.mint(address(adapter), 1_000_000);
        core.mint(address(adapter), 1_000_000);
        weth.mint(address(adapter), 1_000_000);
        a.mint(address(core), 1_000_000);
        b.mint(address(core), 1_000_000);
        vm.deal(USER, 10 ether);
        vm.deal(address(proxy), 29);
        vm.deal(address(adapter), 10 ether);
        vm.deal(address(weth), 10 ether);
        vm.startPrank(USER);
        payment.approve(address(proxy), type(uint256).max);
        a.approve(address(proxy), type(uint256).max);
        b.approve(address(proxy), type(uint256).max);
        core.approve(address(proxy), type(uint256).max);
        vm.stopPrank();
        _rate(address(payment), address(core), 2, 0);
        _rate(address(0), address(core), 2, 0);
        _rate(address(weth), address(core), 2, 0);
        _rate(address(core), address(payment), 2, 0);
        _rate(address(core), address(0), 2, 0);
        _rate(address(core), address(weth), 2, 0);
        _rate(address(payment), address(a), 1, 0);
        _rate(address(payment), address(b), 1, 0);
        _rate(address(a), address(core), 2, 0);
        _rate(address(b), address(core), 2, 0);
        _rate(address(a), address(payment), 2, 0);
        _rate(address(b), address(payment), 2, 0);
        _rate(address(a), address(0), 2, 0);
        _rate(address(b), address(0), 2, 0);
    }

    function _assets() private view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(a);
        assets[1] = address(b);
    }

    function _pair(uint256 x, uint256 y) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = x;
        values[1] = y;
    }

    function _rate(address input, address output, uint256 multiplier, uint256 returned) private {
        adapter.setRate(input, output, multiplier, 1, returned);
    }

    function _route(address input, address output) private pure returns (AmmTemplate memory route) {
        route.inputCurrency = input;
        route.outputCurrency = output;
        route.routes = new WeightedRoute[](1);
        route.routes[0].sharePpm = 1_000_000;
        route.routes[0].steps = new Step[](1);
        route.routes[0].steps[0] = Step(StepKind.V4, output, 500, 10);
    }

    function _plan(Intent intent, address input, uint256 amount, address output)
        private
        view
        returns (ExactInputPlan memory plan)
    {
        plan.intent = intent;
        plan.inputs = new AssetAmount[](1);
        plan.inputs[0] = AssetAmount(input, amount);
        plan.outputCurrency = output;
        plan.recipient = RECIPIENT;
        plan.deadline = block.timestamp + 60;
        plan.minimumOutput = intent == Intent.RedeemBasket ? 0 : 1;
    }

    function _market(uint256 amount, address input, address output, uint256 fee)
        private
        pure
        returns (TradeBranch memory)
    {
        return TradeBranch(BranchKind.Market, amount, abi.encode(MarketBody(_route(input, output), fee)));
    }

    function _scalar(ExactInputPlan memory plan, TradeBranch[] memory branches)
        private
        pure
        returns (ExactInputPlan memory)
    {
        plan.body = abi.encode(ScalarBody(branches));
        return plan;
    }

    function _oneMarket(Intent intent, address input, uint256 amount, address output, uint256 fee)
        private
        view
        returns (ExactInputPlan memory plan)
    {
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = _market(amount, input, output, fee);
        return _scalar(_plan(intent, input, amount, output), branches);
    }

    function _funding(uint256 count) private pure returns (FundingBundle memory funding) {
        funding.authorizations = new FundingAuthorization[](count);
    }

    function _call(ExactInputPlan memory plan) private returns (TradeResult memory result) {
        return _callWith(plan, _funding(plan.inputs.length));
    }

    function _callWith(ExactInputPlan memory plan, FundingBundle memory funding)
        private
        returns (TradeResult memory result)
    {
        uint256 nativeValue;
        for (uint256 i; i < plan.inputs.length; ++i) {
            if (plan.inputs[i].currency == address(0)) nativeValue += plan.inputs[i].amount;
        }
        vm.prank(USER);
        return trade.executeExactInput{value: nativeValue}(plan, funding);
    }

    function _continuations(uint256 firstFee, uint256 secondFee) private view returns (Continuation[] memory values) {
        values = new Continuation[](2);
        values[0] = Continuation(_route(address(a), address(core)), firstFee);
        values[1] = Continuation(_route(address(b), address(core)), secondFee);
    }

    function _coreBuy(uint256 first, uint256 second, uint256 firstFee, uint256 secondFee)
        private
        view
        returns (CoreBuyBody memory body)
    {
        body.basketAssets = _assets();
        body.acquisitions = new Acquisition[](2);
        body.acquisitions[0] = Acquisition(first, _route(address(payment), address(a)));
        body.acquisitions[1] = Acquisition(second, _route(address(payment), address(b)));
        body.continuations = _continuations(firstFee, secondFee);
    }

    function _buyCorePlan(uint256 budget, CoreBuyBody memory body) private view returns (ExactInputPlan memory) {
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Core, budget, abi.encode(body));
        return _scalar(_plan(Intent.BuyCygld, address(payment), budget, address(core)), branches);
    }

    function _minimums(ICoreRedemption.TokenAmount[] memory outputs)
        private
        pure
        returns (ICoreRedemption.TokenMinimum[] memory mins)
    {
        mins = new ICoreRedemption.TokenMinimum[](outputs.length);
        for (uint256 i; i < outputs.length; ++i) {
            mins[i] = ICoreRedemption.TokenMinimum(outputs[i].kind, outputs[i].token, outputs[i].id, outputs[i].amount);
        }
    }

    function testIntentRecipientAndFundingErrorsPreserveOriginalBalances() public {
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(payment), 100, address(core), 0);
        plan.recipient = address(0);
        vm.expectRevert(InvalidRecipient.selector);
        _call(plan);
        plan.recipient = address(proxy);
        vm.expectRevert(InvalidRecipient.selector);
        _call(plan);
        plan.recipient = RECIPIENT;
        plan.inputs = new AssetAmount[](0);
        vm.expectRevert(abi.encodeWithSelector(CoreAssetAmountsLengthMismatch.selector, 1, 0));
        _call(plan);
        plan.inputs = new AssetAmount[](1);
        plan.inputs[0] = AssetAmount(address(payment), 0);
        vm.expectRevert(ZeroInputAmount.selector);
        _call(plan);
        plan.inputs[0].amount = 100;
        plan.intent = Intent.SellCygld;
        vm.expectRevert(abi.encodeWithSelector(RouteCurrencyMismatch.selector, address(payment), address(core)));
        _call(plan);
        plan.intent = Intent.BuyCygld;
        plan.outputCurrency = address(payment);
        vm.expectRevert(abi.encodeWithSelector(RouteCurrencyMismatch.selector, address(payment), address(core)));
        _call(plan);
        plan.outputCurrency = address(core);
        plan.minimumOutput = 0;
        vm.expectRevert(ZeroFinalMinimum.selector);
        _call(plan);
        plan.minimumOutput = 1;
        vm.expectRevert(abi.encodeWithSelector(CoreAssetAmountsLengthMismatch.selector, 1, 0));
        _callWith(plan, _funding(0));
        FundingBundle memory funding = _funding(1);
        funding.authorizations[0].kind = BasketInputAuthorization.Permit2;
        vm.expectRevert(abi.encodeWithSelector(Permit2BatchLengthMismatch.selector, 0, 1));
        _callWith(plan, funding);
        assertEq(payment.balanceOf(USER), 1_000_000);
        assertEq(payment.balanceOf(address(proxy)), 23);
    }

    function testCurrencyNormalizationRejectsOnlyUnsupportedConversions() public {
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Market, 100, abi.encode(MarketBody(_route(address(a), address(core)), 0)));
        vm.expectRevert(abi.encodeWithSelector(RouteCurrencyMismatch.selector, address(payment), address(a)));
        _call(_scalar(_plan(Intent.BuyCygld, address(payment), 100, address(core)), branches));
        branches[0] =
            TradeBranch(BranchKind.Market, 100, abi.encode(MarketBody(_route(address(payment), address(core)), 0)));
        vm.expectRevert(abi.encodeWithSelector(RouteCurrencyMismatch.selector, address(0), address(payment)));
        _call(_scalar(_plan(Intent.BuyCygld, address(0), 100, address(core)), branches));
        vm.prank(USER);
        weth.mint(USER, 100);
        vm.prank(USER);
        weth.approve(address(proxy), 100);
        vm.expectRevert(abi.encodeWithSelector(RouteCurrencyMismatch.selector, address(weth), address(payment)));
        _call(_scalar(_plan(Intent.BuyCygld, address(weth), 100, address(core)), branches));
    }

    function testIdentityRedemptionTemplateHonorsItsFloorBeforeNativePayout() public {
        MixedRedemptionCore mixed = new MixedRedemptionCore();
        mixed.mint(USER, 1_000);
        weth.mint(address(mixed), 200);
        ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
        outputs[0] = ICoreRedemption.TokenAmount(ICoreRedemption.TokenKind.ERC20, address(weth), 0, 200);
        mixed.configureOutputs(outputs);
        proxy.configure(address(mixed), address(weth), address(adapter), OWNER, HELPER_FEE);
        vm.prank(USER);
        mixed.approve(address(proxy), 1_000);
        CoreSellBody memory body;
        body.expectedOutputs = _minimums(outputs);
        body.conversions = new AmmTemplate[](1);
        body.conversions[0].inputCurrency = address(weth);
        body.conversions[0].outputCurrency = address(weth);
        body.conversions[0].minimumOutput = 201;
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Core, 1_000, abi.encode(body));
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 201, 200));
        _call(_scalar(_plan(Intent.SellCygld, address(mixed), 1_000, address(0)), branches));
        body.conversions[0].minimumOutput = 200;
        branches[0].data = abi.encode(body);
        uint256 beforeEth = RECIPIENT.balance;
        TradeResult memory result = _call(_scalar(_plan(Intent.SellCygld, address(mixed), 1_000, address(0)), branches));
        assertEq(result.recipientOutputs[0].amount, 200);
        assertEq(RECIPIENT.balance - beforeEth, 200);
        assertEq(weth.balanceOf(address(proxy)), 19);
        assertEq(adapter.calls(), 0);
    }

    function testMalformedCoreTemplatesAndMarketFeeCannotConsumeSiblingLots() public {
        CoreBuyBody memory buy = _coreBuy(500, 500, 0, 0);
        buy.acquisitions = new Acquisition[](0);
        vm.expectRevert(abi.encodeWithSelector(QuoteLengthMismatch.selector, 0, 2));
        _call(_buyCorePlan(1_000, buy));
        buy = _coreBuy(500, 500, 0, 0);
        buy.continuations = new Continuation[](0);
        vm.expectRevert(abi.encodeWithSelector(QuoteLengthMismatch.selector, 0, 2));
        _call(_buyCorePlan(1_000, buy));
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 201, 200));
        _call(_oneMarket(Intent.BuyCygld, address(payment), 100, address(core), 201));
        ExactInputPlan memory market = _oneMarket(Intent.SellCygld, address(core), 100, address(payment), 0);
        market.minimumOutput = 0;
        vm.expectRevert(ZeroFinalMinimum.selector);
        _call(market);
        CoreSellBody memory sell;
        ICoreRedemption.RedemptionQuote memory preview = ICoreRedemption(address(core)).previewRedeemExactIn(995);
        sell.expectedOutputs = _minimums(preview.outputs);
        sell.conversions = new AmmTemplate[](0);
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Core, 1_000, abi.encode(sell));
        vm.expectRevert(abi.encodeWithSelector(QuoteLengthMismatch.selector, 0, 2));
        _call(_scalar(_plan(Intent.SellCygld, address(core), 1_000, address(payment)), branches));
        assertEq(core.safeRedeemCallCount(), 0);
        assertEq(core.safeIssueCallCount(), 0);
        assertEq(adapter.calls(), 0);
    }

    function testMarketVenueFailureRollsBackAcquisitionAndApproval() public {
        adapter.setFault(false, true);
        vm.expectRevert(bytes("venue failed"));
        _call(_oneMarket(Intent.BuyCygld, address(payment), 100, address(core), 0));
        assertEq(payment.balanceOf(USER), 1_000_000);
        assertEq(payment.allowance(address(proxy), address(adapter)), 0);
        assertEq(adapter.calls(), 0);
    }

    function testReleaseFactoryBindsOneSuccessorWithoutInstallingItsMetadata() public {
        (TradeExactInFacet implementation, UniswapRoutingAdapter successor) =
            TradeExactInputDeployment.deploy(address(proxy), address(adapter), address(permit2), address(weth));
        address deployedFacet = address(implementation);
        address deployedAdapter = address(successor);
        (bool ok, bytes memory value) = deployedFacet.staticcall(abi.encodeWithSignature("ROUTING_ADAPTER()"));
        assertTrue(ok);
        assertEq(abi.decode(value, (address)), deployedAdapter);
        (ok, value) = deployedAdapter.staticcall(abi.encodeWithSignature("WETH()"));
        assertTrue(ok);
        assertEq(abi.decode(value, (address)), address(weth));
        assertEq(TradeExactInputDeployment.selectors().length, 1);
    }

    function testMarketBuyRetainsMeasuredAndUnallocatedInputWithoutTouchingHistory() public {
        _rate(address(payment), address(core), 2, 100);
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(payment), 1_000, address(core), 7);
        plan.inputs[0].amount = 1_100;
        TradeResult memory result = _call(plan);
        assertEq(core.balanceOf(RECIPIENT), 1_793);
        assertEq(core.balanceOf(OWNER), 7);
        assertEq(payment.balanceOf(USER), 998_900);
        assertEq(payment.balanceOf(address(proxy)), 223);
        assertEq(core.balanceOf(address(proxy)), 17);
        assertEq(payment.allowance(address(proxy), address(adapter)), 0);
        assertEq(result.retainedInputs.length, 2);
        assertEq(result.retainedInputs[0].amount, 100);
        assertEq(result.retainedInputs[1].amount, 100);
        assertEq(result.stages[0].fundedInput, 1_000);
        assertEq(result.stages[0].returnedInput, 100);
        assertEq(result.stages[0].consumedInput, 900);
        assertEq(result.marketFeeCygld, 7);
        assertEq(result.retainedCustodian, address(proxy));
        assertEq(result.feeBeneficiaryAtSettlement, OWNER);
        assertEq(result.acquiredInputs[0].amount, 1_100);
        assertEq(adapter.lastDeadline(), plan.deadline);
    }

    function testNativeMarketBuyRetainsEthAndSaleSettlesNative() public {
        _rate(address(0), address(core), 2, 100);
        TradeResult memory buy = _call(_oneMarket(Intent.BuyCygld, address(0), 1_000, address(core), 3));
        assertEq(address(proxy).balance, 129);
        assertEq(buy.retainedInputs[0].currency, address(0));
        assertEq(buy.retainedInputs[0].amount, 100);
        assertEq(core.balanceOf(RECIPIENT), 1_797);
        _rate(address(core), address(0), 2, 90);
        TradeResult memory sale = _call(_oneMarket(Intent.SellCygld, address(core), 1_000, address(0), 10));
        assertEq(RECIPIENT.balance, 1_800);
        assertEq(address(proxy).balance, 129);
        assertEq(core.balanceOf(address(proxy)), 107);
        assertEq(sale.stages[0].fundedInput, 990);
        assertEq(sale.stages[0].returnedInput, 90);
        assertEq(sale.marketFeeCygld, 10);
        assertEq(core.balanceOf(OWNER), 13);
    }

    function testNativeFundingWrapRetainsTheReturnedWethRepresentation() public {
        _rate(address(weth), address(core), 2, 100);
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(0), 1_000, address(core), 0);
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = _market(1_000, address(weth), address(core), 0);
        plan.body = abi.encode(ScalarBody(branches));
        TradeResult memory result = _call(plan);
        assertEq(result.stages.length, 2);
        assertEq(result.stages[0].inputCurrency, address(0));
        assertEq(result.stages[0].outputCurrency, address(weth));
        assertEq(result.retainedInputs[0].currency, address(weth));
        assertEq(result.retainedInputs[0].amount, 100);
        assertEq(weth.balanceOf(address(proxy)), 119);
        assertEq(address(proxy).balance, 29);
        assertEq(core.balanceOf(RECIPIENT), 1_800);
    }

    function testWethFundingUnwrapRetainsReturnedEthWithoutSpendingHistory() public {
        weth.mint(USER, 1_000);
        vm.prank(USER);
        weth.approve(address(proxy), 1_000);
        _rate(address(0), address(core), 2, 100);
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = _market(1_000, address(0), address(core), 0);
        TradeResult memory result =
            _call(_scalar(_plan(Intent.BuyCygld, address(weth), 1_000, address(core)), branches));
        assertEq(result.stages[0].inputCurrency, address(weth));
        assertEq(result.stages[0].outputCurrency, address(0));
        assertEq(result.retainedInputs[0].currency, address(0));
        assertEq(result.retainedInputs[0].amount, 100);
        assertEq(weth.balanceOf(address(proxy)), 19);
        assertEq(address(proxy).balance, 129);
        assertEq(core.balanceOf(RECIPIENT), 1_800);
    }

    function testNativeOutputUnwrapUsesOnlyCurrentOutputLot() public {
        ExactInputPlan memory plan = _oneMarket(Intent.SellCygld, address(core), 1_000, address(0), 10);
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = _market(1_000, address(core), address(weth), 10);
        plan.body = abi.encode(ScalarBody(branches));
        TradeResult memory result = _call(plan);
        assertEq(RECIPIENT.balance, 1_980);
        assertEq(weth.balanceOf(address(proxy)), 19);
        assertEq(address(proxy).balance, 29);
        assertEq(result.stages[1].inputCurrency, address(weth));
        assertEq(result.stages[1].outputCurrency, address(0));
        assertEq(result.stages[1].fundedInput, 1_980);
    }

    function testRuntimeCoreIssueUsesAcquiredLotsActualDebitsAndContinuationFees() public {
        core.setIssuanceFeePpm(10_000);
        core.setSafeIssueRequiredAmounts(_pair(350, 400));
        _rate(address(a), address(core), 2, 50);
        TradeResult memory result = _call(_buyCorePlan(1_000, _coreBuy(600, 400, 7, 99)));
        assertEq(core.safeIssueCallCount(), 1);
        assertEq(core.lastIssueNetCygldOut(), 792);
        assertEq(core.lastSafeIssueMaxAmountsIn()[0], 400);
        assertEq(core.lastSafeIssueMaxAmountsIn()[1], 400);
        // Core's minimum gross for net 792 is 799: floor(799 * 1%) is seven.
        assertEq(result.coreProtocolFeeCygld, 7);
        assertEq(result.coreHelpersFeeCygld, 3);
        assertEq(result.marketFeeCygld, 7);
        assertEq(result.stages.length, 5);
        assertEq(result.stages[2].fundedInput, 600);
        assertEq(result.stages[2].returnedInput, 250);
        assertEq(result.stages[2].consumedInput, 350);
        assertEq(result.stages[3].fundedInput, 250);
        assertEq(result.stages[3].returnedInput, 50);
        assertEq(result.retainedInputs.length, 1);
        assertEq(result.retainedInputs[0].currency, address(a));
        assertEq(result.retainedInputs[0].amount, 50);
        assertEq(core.balanceOf(RECIPIENT), 1_182);
        assertEq(core.balanceOf(OWNER), 10);
        assertEq(a.balanceOf(address(proxy)), 61);
        assertEq(b.balanceOf(address(proxy)), 13);
        assertEq(a.allowance(address(proxy), address(core)), 0);
        assertEq(b.allowance(address(proxy), address(core)), 0);
    }

    function testZeroCoreIssuanceContinuesPositiveLotsAndSkipsZeroLotFees() public {
        _rate(address(payment), address(b), 2, 0);
        TradeResult memory result = _call(_buyCorePlan(100, _coreBuy(0, 100, type(uint256).max, 5)));
        assertEq(core.safeIssueCallCount(), 0);
        assertEq(result.coreProtocolFeeCygld, 0);
        assertEq(result.coreHelpersFeeCygld, 0);
        assertEq(result.marketFeeCygld, 5);
        assertEq(core.balanceOf(RECIPIENT), 395);
        assertEq(adapter.calls(), 2);
        assertEq(a.balanceOf(address(proxy)), 11);
        assertEq(b.balanceOf(address(proxy)), 13);
    }

    function testMixedCoreMarketBranchesSettleOneAggregateOutput() public {
        TradeBranch[] memory branches = new TradeBranch[](2);
        branches[0] = TradeBranch(BranchKind.Core, 600, abi.encode(_coreBuy(300, 300, 0, 0)));
        branches[1] = _market(400, address(payment), address(core), 11);
        TradeResult memory result =
            _call(_scalar(_plan(Intent.BuyCygld, address(payment), 1_000, address(core)), branches));
        assertEq(core.balanceOf(RECIPIENT), 1_386);
        assertEq(core.balanceOf(OWNER), 14);
        assertEq(result.coreHelpersFeeCygld, 3);
        assertEq(result.marketFeeCygld, 11);
        assertEq(result.stages[result.stages.length - 1].branch, 1);
        assertEq(result.retainedInputs.length, 0);
    }

    function testNativeCoreMarketPartialBuyAndSaleUseTheSameOwnedBudget() public {
        CoreBuyBody memory buyBody = _coreBuy(300, 300, 0, 0);
        buyBody.acquisitions[0].route = _route(address(0), address(a));
        buyBody.acquisitions[1].route = _route(address(0), address(b));
        _rate(address(0), address(a), 1, 0);
        _rate(address(0), address(b), 1, 0);
        TradeBranch[] memory branches = new TradeBranch[](2);
        branches[0] = TradeBranch(BranchKind.Core, 600, abi.encode(buyBody));
        branches[1] = _market(400, address(0), address(core), 11);
        TradeResult memory result = _call(_scalar(_plan(Intent.BuyCygld, address(0), 1_000, address(core)), branches));
        assertEq(core.balanceOf(RECIPIENT), 1_386);
        assertEq(address(proxy).balance, 29);
        assertEq(result.coreHelpersFeeCygld, 3);
        assertEq(result.marketFeeCygld, 11);
        ICoreRedemption.RedemptionQuote memory quote = core.previewRedeemExactIn(597);
        CoreSellBody memory sellBody;
        sellBody.expectedOutputs = _minimums(quote.outputs);
        sellBody.conversions = new AmmTemplate[](2);
        sellBody.conversions[0] = _route(address(a), address(0));
        sellBody.conversions[1] = _route(address(b), address(0));
        branches[0] = TradeBranch(BranchKind.Core, 600, abi.encode(sellBody));
        branches[1] = _market(400, address(core), address(0), 7);
        result = _call(_scalar(_plan(Intent.SellCygld, address(core), 1_000, address(0)), branches));
        assertEq(RECIPIENT.balance, 2 * (quote.outputs[0].amount + quote.outputs[1].amount) + 786);
        assertEq(address(proxy).balance, 29);
        assertEq(a.balanceOf(address(proxy)), 11);
        assertEq(b.balanceOf(address(proxy)), 13);
        assertEq(core.balanceOf(address(proxy)), 17);
        assertEq(result.retainedInputs.length, 0);
    }

    function testDirectBasketIssueAndSameAssetAcquisitionNeedNoFakeSwap() public {
        ExactInputPlan memory plan = _plan(Intent.IssueBasket, address(a), 600, address(core));
        plan.inputs = new AssetAmount[](2);
        plan.inputs[0] = AssetAmount(address(a), 600);
        plan.inputs[1] = AssetAmount(address(b), 400);
        plan.body = abi.encode(BasketIssueBody(_continuations(7, 0)));
        TradeResult memory result = _call(plan);
        assertEq(core.balanceOf(RECIPIENT), 1_189);
        assertEq(result.coreHelpersFeeCygld, 4);
        assertEq(result.marketFeeCygld, 7);
        assertEq(adapter.calls(), 1);
        assertEq(a.balanceOf(address(proxy)), 11);
        assertEq(b.balanceOf(address(proxy)), 13);

        CoreBuyBody memory body = _coreBuy(300, 300, 0, 0);
        body.acquisitions[0].route = AmmTemplate(address(0xdead), address(0xbead), 0, new WeightedRoute[](0));
        body.acquisitions[1].route = _route(address(a), address(b));
        _rate(address(a), address(b), 1, 0);
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Core, 600, abi.encode(body));
        _call(_scalar(_plan(Intent.BuyCygld, address(a), 600, address(core)), branches));
        assertEq(adapter.calls(), 2);
        assertEq(core.safeIssueCallCount(), 2);
    }

    function testCoreSaleFeesAndIdentityOutputThenMarketPartialPlan() public {
        core.setRedemptionFeePpm(10_000);
        uint256 grossCore = 600 - 600 * HELPER_FEE / 1_000_000;
        ICoreRedemption.RedemptionQuote memory quote = core.previewRedeemExactIn(grossCore);
        CoreSellBody memory body;
        body.expectedOutputs = _minimums(quote.outputs);
        body.conversions = new AmmTemplate[](2);
        body.conversions[0] = _route(address(a), address(a));
        body.conversions[1] = _route(address(b), address(a));
        _rate(address(b), address(a), 2, 0);
        _rate(address(core), address(a), 2, 10);
        TradeBranch[] memory branches = new TradeBranch[](2);
        branches[0] = TradeBranch(BranchKind.Core, 600, abi.encode(body));
        branches[1] = _market(400, address(core), address(a), 7);
        TradeResult memory result = _call(_scalar(_plan(Intent.SellCygld, address(core), 1_000, address(a)), branches));
        assertEq(core.lastSafeRedeemGrossCygldIn(), grossCore);
        assertEq(result.coreHelpersFeeCygld, 3);
        assertEq(result.coreProtocolFeeCygld, quote.protocolFeeCygld);
        assertEq(result.marketFeeCygld, 7);
        assertEq(a.balanceOf(RECIPIENT), quote.outputs[0].amount + 2 * quote.outputs[1].amount + 766);
        assertEq(core.balanceOf(OWNER), 10);
        assertEq(core.balanceOf(address(proxy)), 27);
        assertEq(result.retainedInputs[0].amount, 10);
        assertEq(adapter.calls(), 2);
    }

    function testRedeemBasketReturnsCompleteVectorWithoutScalarSwap() public {
        ICoreRedemption.RedemptionQuote memory quote = core.previewRedeemExactIn(995);
        ExactInputPlan memory plan = _plan(Intent.RedeemBasket, address(core), 1_000, address(0));
        plan.body = abi.encode(BasketRedeemBody(_minimums(quote.outputs)));
        TradeResult memory result = _call(plan);
        assertEq(result.recipientOutputs.length, 2);
        assertEq(a.balanceOf(RECIPIENT), quote.outputs[0].amount);
        assertEq(b.balanceOf(RECIPIENT), quote.outputs[1].amount);
        assertEq(core.balanceOf(OWNER), 5);
        assertEq(core.balanceOf(address(proxy)), 17);
        assertEq(adapter.calls(), 0);
        assertEq(result.coreHelpersFeeCygld, 5);
        assertEq(result.recoveryShares.length, 0);
    }

    function testRecoverySharesForwardDuringScalarAndBasketRedemption() public {
        MixedRedemptionCore mixed = new MixedRedemptionCore();
        mixed.mint(USER, 2_000);
        mixed.mint(address(proxy), 17);
        mixed.primeShare(address(proxy), 123, 7);
        mixed.primeShare(RECIPIENT, 123, 10);
        ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](2);
        outputs[0] = ICoreRedemption.TokenAmount(ICoreRedemption.TokenKind.ERC20, address(a), 0, 200);
        outputs[1] = ICoreRedemption.TokenAmount(ICoreRedemption.TokenKind.ERC1155, address(mixed), 123, 55);
        mixed.configureOutputs(outputs);
        a.mint(address(mixed), 400);
        proxy.configure(address(mixed), address(weth), address(adapter), OWNER, HELPER_FEE);
        vm.prank(USER);
        mixed.approve(address(proxy), 2_000);
        ExactInputPlan memory plan = _plan(Intent.RedeemBasket, address(mixed), 1_000, address(0));
        plan.body = abi.encode(BasketRedeemBody(_minimums(outputs)));
        TradeResult memory result = _call(plan);
        assertEq(result.recoveryShares.length, 1);
        assertEq(result.recoveryShares[0].amount, 55);
        assertEq(mixed.balanceOf(RECIPIENT, 123), 65);
        assertEq(mixed.balanceOf(address(proxy), 123), 7);
        assertEq(a.balanceOf(RECIPIENT), 200);
        CoreSellBody memory body;
        body.expectedOutputs = _minimums(outputs);
        body.conversions = new AmmTemplate[](2);
        body.conversions[0] = _route(address(a), address(payment));
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Core, 1_000, abi.encode(body));
        result = _call(_scalar(_plan(Intent.SellCygld, address(mixed), 1_000, address(payment)), branches));
        assertEq(payment.balanceOf(RECIPIENT), 400);
        assertEq(result.recoveryShares[0].id, 123);
        assertEq(mixed.balanceOf(RECIPIENT, 123), 120);
        assertEq(mixed.balanceOf(address(proxy), 123), 7);
    }

    function testTwoCoreBranchesHaveIndependentRecoveryReceiptLifecycles() public {
        MixedRedemptionCore mixed = new MixedRedemptionCore();
        mixed.mint(USER, 1_000);
        mixed.mint(address(proxy), 17);
        mixed.primeShare(address(proxy), 123, 7);
        mixed.primeShare(RECIPIENT, 123, 10);
        ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](2);
        outputs[0] = ICoreRedemption.TokenAmount(ICoreRedemption.TokenKind.ERC20, address(a), 0, 200);
        outputs[1] = ICoreRedemption.TokenAmount(ICoreRedemption.TokenKind.ERC1155, address(mixed), 123, 55);
        mixed.configureOutputs(outputs);
        a.mint(address(mixed), 400);
        proxy.configure(address(mixed), address(weth), address(adapter), OWNER, HELPER_FEE);
        vm.prank(USER);
        mixed.approve(address(proxy), 1_000);
        CoreSellBody memory body;
        body.expectedOutputs = _minimums(outputs);
        body.conversions = new AmmTemplate[](2);
        body.conversions[0] = _route(address(a), address(payment));
        TradeBranch[] memory branches = new TradeBranch[](2);
        branches[0] = TradeBranch(BranchKind.Core, 500, abi.encode(body));
        branches[1] = TradeBranch(BranchKind.Core, 500, abi.encode(body));
        TradeResult memory result =
            _call(_scalar(_plan(Intent.SellCygld, address(mixed), 1_000, address(payment)), branches));
        assertEq(mixed.safeRedeemCallCount(), 2);
        assertEq(result.recoveryShares.length, 2);
        assertEq(result.recoveryShares[0].amount, 55);
        assertEq(result.recoveryShares[1].amount, 55);
        assertEq(mixed.balanceOf(RECIPIENT, 123), 120);
        assertEq(mixed.balanceOf(address(proxy), 123), 7);
        assertEq(payment.balanceOf(RECIPIENT), 800);
        assertEq(mixed.balanceOf(address(proxy)), 17);
    }

    function testShareOnlyScalarRedemptionPreservesHistoricalZeroMinimum() public {
        MixedRedemptionCore mixed = new MixedRedemptionCore();
        mixed.mint(USER, 1_000);
        mixed.primeShare(address(proxy), 123, 7);
        ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
        outputs[0] = ICoreRedemption.TokenAmount(ICoreRedemption.TokenKind.ERC1155, address(mixed), 123, 55);
        mixed.configureOutputs(outputs);
        proxy.configure(address(mixed), address(weth), address(adapter), OWNER, HELPER_FEE);
        vm.prank(USER);
        mixed.approve(address(proxy), 1_000);
        CoreSellBody memory body;
        body.expectedOutputs = _minimums(outputs);
        body.conversions = new AmmTemplate[](1);
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Core, 1_000, abi.encode(body));
        ExactInputPlan memory plan = _scalar(_plan(Intent.SellCygld, address(mixed), 1_000, address(payment)), branches);
        plan.minimumOutput = 0;
        TradeResult memory result = _call(plan);
        assertEq(result.recipientOutputs[0].amount, 0);
        assertEq(result.recoveryShares.length, 1);
        assertEq(result.recoveryShares[0].amount, 55);
        assertEq(mixed.balanceOf(RECIPIENT, 123), 55);
        assertEq(mixed.balanceOf(address(proxy), 123), 7);
        assertEq(result.coreHelpersFeeCygld, 5);
        assertEq(adapter.calls(), 0);
    }

    function testScalarPositiveErc20RedemptionStillRequiresPositiveMinimum() public {
        ICoreRedemption.RedemptionQuote memory quote = core.previewRedeemExactIn(995);
        CoreSellBody memory body;
        body.expectedOutputs = _minimums(quote.outputs);
        body.conversions = new AmmTemplate[](2);
        body.conversions[0] = _route(address(a), address(payment));
        body.conversions[1] = _route(address(b), address(payment));
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Core, 1_000, abi.encode(body));
        ExactInputPlan memory plan = _scalar(_plan(Intent.SellCygld, address(core), 1_000, address(payment)), branches);
        plan.minimumOutput = 0;
        vm.expectRevert(ZeroFinalMinimum.selector);
        _call(plan);
        assertEq(core.safeRedeemCallCount(), 0);
        assertEq(adapter.calls(), 0);
        assertEq(core.balanceOf(USER), 10_000);
    }

    function testWeightedAdapterPayloadUsesRuntimeLotAndLastPathRemainder() public {
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(payment), 1_003, address(core), 0);
        AmmTemplate memory route = _route(address(payment), address(core));
        route.routes = new WeightedRoute[](3);
        for (uint256 i; i < 3; ++i) {
            route.routes[i].sharePpm = 333_333;
            route.routes[i].steps = new Step[](1);
            route.routes[i].steps[0] = Step(StepKind(i), address(core), 500, 10);
        }
        TradeBranch[] memory branches = new TradeBranch[](1);
        branches[0] = TradeBranch(BranchKind.Market, 1_003, abi.encode(MarketBody(route, 0)));
        _call(_scalar(plan, branches));
        uint256[] memory allocations = adapter.allocations();
        assertEq(allocations[0], 334);
        assertEq(allocations[1], 334);
        assertEq(allocations[2], 335);
    }

    function testFullInputGainIsRetainedWithoutFundingCap() public {
        adapter.setGain(address(payment), address(core), 105);
        TradeResult memory result = _call(_oneMarket(Intent.BuyCygld, address(payment), 100, address(core), 0));
        assertEq(result.stages[0].returnedInput, 105);
        assertEq(result.stages[0].consumedInput, 0);
        assertEq(result.stages[0].inputGain, 5);
        assertEq(result.retainedInputs[0].amount, 105);
        assertEq(payment.balanceOf(address(proxy)), 128);
        assertEq(core.balanceOf(RECIPIENT), 200);
    }

    function testAggregateMinimumFailureRollsBackAllBranchesAndFees() public {
        TradeBranch[] memory branches = new TradeBranch[](2);
        branches[0] = TradeBranch(BranchKind.Core, 600, abi.encode(_coreBuy(300, 300, 0, 0)));
        branches[1] = _market(400, address(payment), address(core), 11);
        ExactInputPlan memory plan = _scalar(_plan(Intent.BuyCygld, address(payment), 1_000, address(core)), branches);
        plan.minimumOutput = 1_387;
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 1_387, 1_386));
        _call(plan);
        assertEq(payment.balanceOf(USER), 1_000_000);
        assertEq(core.safeIssueCallCount(), 0);
        assertEq(adapter.calls(), 0);
        assertEq(core.balanceOf(OWNER), 0);
        assertEq(core.balanceOf(RECIPIENT), 0);
        assertEq(payment.balanceOf(address(proxy)), 23);
        assertEq(a.balanceOf(address(proxy)), 11);
    }

    function testContinuationCannotUseSiblingOutputToSubsidizeItsFee() public {
        ExactInputPlan memory plan = _buyCorePlan(1_000, _coreBuy(501, 499, 5, 0));
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 5, 4));
        _call(plan);
        assertEq(core.safeIssueCallCount(), 0);
        assertEq(core.balanceOf(OWNER), 0);
        assertEq(core.balanceOf(RECIPIENT), 0);
    }

    function testPositiveCoreFailurePropagatesRatherThanFallingBackToMarket() public {
        core.setSafeIssueProtocolFeeOverride(123);
        vm.expectRevert(CoreIssuanceResultMismatch.selector);
        _call(_buyCorePlan(1_000, _coreBuy(500, 500, 0, 0)));
        assertEq(core.safeIssueCallCount(), 0);
        assertEq(adapter.calls(), 0);
        assertEq(payment.balanceOf(USER), 1_000_000);
    }

    function testPerStageMinimumAndAdapterOutputMismatchRollback() public {
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(payment), 100, address(core), 0);
        TradeBranch[] memory branches = new TradeBranch[](1);
        AmmTemplate memory route = _route(address(payment), address(core));
        route.minimumOutput = 201;
        branches[0] = TradeBranch(BranchKind.Market, 100, abi.encode(MarketBody(route, 0)));
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 201, 200));
        _call(_scalar(plan, branches));
        adapter.setFault(true, false);
        vm.expectRevert(abi.encodeWithSelector(AdapterOutputMismatch.selector, address(core), address(adapter), 200, 0));
        _call(plan);
        assertEq(payment.balanceOf(USER), 1_000_000);
        assertEq(adapter.calls(), 0);
    }

    function testPermit2FundingAndNonceFailureRollback() public {
        vm.prank(USER);
        payment.approve(address(proxy), 0);
        vm.prank(USER);
        payment.approve(address(permit2), 1_000);
        FundingBundle memory funding = _funding(1);
        funding.authorizations[0].kind = BasketInputAuthorization.Permit2;
        funding.permit2.permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
        funding.permit2.permit.permitted[0] = ISignatureTransfer.TokenPermissions(address(payment), 1_000);
        funding.permit2.permit.nonce = 42;
        funding.permit2.permit.deadline = block.timestamp + 60;
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(payment), 1_000, address(core), 0);
        plan.minimumOutput = 2_001;
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 2_001, 2_000));
        _callWith(plan, funding);
        assertFalse(permit2.usedNonces(USER, 42));
        plan.minimumOutput = 1;
        _callWith(plan, funding);
        assertTrue(permit2.usedNonces(USER, 42));
        assertEq(payment.allowance(USER, address(proxy)), 0);
        vm.expectRevert(bytes("nonce"));
        _callWith(plan, funding);
        assertEq(core.balanceOf(RECIPIENT), 2_000);
    }

    function testTokenPermitAndMixedBasketPermit2Funding() public {
        vm.prank(USER);
        payment.approve(address(proxy), 0);
        FundingBundle memory funding = _funding(1);
        funding.authorizations[0].kind = BasketInputAuthorization.TokenPermit;
        funding.authorizations[0].permit.value = 100;
        funding.authorizations[0].permit.deadline = block.timestamp + 60;
        _callWith(_oneMarket(Intent.BuyCygld, address(payment), 100, address(core), 0), funding);
        assertEq(payment.nonces(USER), 1);
        assertEq(payment.allowance(USER, address(proxy)), 0);
        ExactInputPlan memory plan = _plan(Intent.IssueBasket, address(a), 100, address(core));
        plan.inputs = new AssetAmount[](2);
        plan.inputs[0] = AssetAmount(address(a), 100);
        plan.inputs[1] = AssetAmount(address(b), 100);
        plan.body = abi.encode(BasketIssueBody(_continuations(0, 0)));
        funding = _funding(2);
        funding.authorizations[1].kind = BasketInputAuthorization.Permit2;
        funding.permit2.permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
        funding.permit2.permit.permitted[0] = ISignatureTransfer.TokenPermissions(address(b), 100);
        funding.permit2.permit.nonce = 7;
        funding.permit2.permit.deadline = block.timestamp + 60;
        vm.prank(USER);
        b.approve(address(proxy), 0);
        vm.prank(USER);
        b.approve(address(permit2), 100);
        _callWith(plan, funding);
        assertTrue(permit2.usedNonces(USER, 7));
        assertEq(core.balanceOf(RECIPIENT), 399);
    }

    function testPermit2DescriptorAndAmountErrorsIdentifyExactPredicate() public {
        FundingBundle memory funding = _funding(1);
        funding.authorizations[0].kind = BasketInputAuthorization.Permit2;
        funding.permit2.permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
        funding.permit2.permit.permitted[0] = ISignatureTransfer.TokenPermissions(address(a), 100);
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(payment), 100, address(core), 0);
        vm.expectRevert(abi.encodeWithSelector(InvalidPermit2Token.selector, address(a), address(payment)));
        _callWith(plan, funding);
        funding.permit2.permit.permitted[0] = ISignatureTransfer.TokenPermissions(address(payment), 99);
        vm.expectRevert(abi.encodeWithSelector(Permit2AmountTooLow.selector, 99, 100));
        _callWith(plan, funding);
    }

    function testExactNativeFundingAndAdapterApprovalKeepHistoricalBalances() public {
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(0), 100, address(core), 0);
        vm.expectRevert(abi.encodeWithSelector(NativeValueMismatch.selector, 100, 99));
        vm.prank(USER);
        trade.executeExactInput{value: 99}(plan, _funding(1));
        assertEq(address(proxy).balance, 29);
        proxy.approveAdapter(address(adapter), false);
        vm.expectRevert(abi.encodeWithSelector(AdapterNotApproved.selector, address(adapter)));
        _call(plan);
        assertEq(address(proxy).balance, 29);
        assertEq(adapter.calls(), 0);
    }

    function testNativeRecipientFailureRollsBackFundingAndVenue() public {
        ExactInputPlan memory plan = _oneMarket(Intent.SellCygld, address(core), 1_000, address(0), 7);
        plan.recipient = address(new ExactInputRejectNative());
        vm.expectRevert(EthRefundFailed.selector);
        _call(plan);
        assertEq(core.balanceOf(USER), 10_000);
        assertEq(core.balanceOf(OWNER), 0);
        assertEq(core.balanceOf(address(proxy)), 17);
        assertEq(address(proxy).balance, 29);
        assertEq(adapter.calls(), 0);
    }

    function testNativeRecipientCallbackCannotReenterTheEngine() public {
        ExactInputPlan memory plan = _oneMarket(Intent.SellCygld, address(core), 1_000, address(0), 7);
        ExactInputReentrantRecipient receiver = new ExactInputReentrantRecipient(
            address(proxy), abi.encodeCall(ITradeExactInput.executeExactInput, (plan, _funding(1)))
        );
        plan.recipient = address(receiver);
        _call(plan);
        assertTrue(receiver.blocked());
        assertEq(address(receiver).balance, 1_986);
        assertEq(core.balanceOf(address(proxy)), 17);
        assertEq(core.balanceOf(OWNER), 7);
    }

    function testZeroBranchesAndFeeOnlySaleDoNotChargeSkippedStage() public {
        TradeBranch[] memory branches = new TradeBranch[](2);
        branches[0] = TradeBranch(BranchKind.Core, 0, "not decoded");
        branches[1] = _market(100, address(core), address(payment), 100);
        ExactInputPlan memory plan = _scalar(_plan(Intent.SellCygld, address(core), 100, address(payment)), branches);
        plan.minimumOutput = 1;
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, 1, 0));
        _call(plan);
        branches = new TradeBranch[](3);
        branches[0] = TradeBranch(BranchKind.Core, 0, "not decoded");
        branches[1] = _market(100, address(core), address(payment), 100);
        branches[2] = _market(100, address(core), address(payment), 7);
        TradeResult memory result =
            _call(_scalar(_plan(Intent.SellCygld, address(core), 200, address(payment)), branches));
        assertEq(adapter.calls(), 1);
        assertEq(result.marketFeeCygld, 7);
        assertEq(result.retainedInputs[0].amount, 100);
        assertEq(core.balanceOf(address(proxy)), 117);
        assertEq(payment.balanceOf(RECIPIENT), 186);
    }

    function testExpiredTradeAndOverallocationRevertAtomically() public {
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(payment), 100, address(core), 0);
        vm.warp(1_000);
        plan.deadline = 999;
        vm.expectRevert(abi.encodeWithSelector(TradeExpired.selector, 999, 1_000));
        _call(plan);
        plan.deadline = 1_060;
        plan.inputs[0].amount = 99;
        vm.expectRevert(stdError.arithmeticError);
        _call(plan);
        assertEq(payment.balanceOf(USER), 1_000_000);
        assertEq(payment.balanceOf(address(proxy)), 23);
    }

    function testBackendFixtureCalldataAndAllNestedBodiesRoundTripInSolidity() public view {
        // Synthetic cross-language vectors prove ABI fidelity, not Core semantic validity.
        // In particular the deliberately large recovery ID tests preservation of uint256.
        string memory json = vm.readFile("test/fixtures/universal-exact-input.json");
        assertEq(vm.parseJsonString(json, ".schema"), "ITradeExactInput-v1");
        for (uint256 i; i < 4; ++i) {
            string memory path = string.concat(".cases[", vm.toString(i), "]");
            bytes memory encoded = vm.parseJsonBytes(json, string.concat(path, ".encodedPlan"));
            ExactInputPlan memory plan = abi.decode(encoded, (ExactInputPlan));
            assertEq(abi.encode(plan), encoded);
            assertEq(uint256(plan.intent), i);
            assertEq(plan.deadline, 2_000_000_000);
            assertEq(plan.recipient, address(0x4444444444444444444444444444444444444444));
            bytes memory callData = vm.parseJsonBytes(json, string.concat(path, ".calldata"));
            assertEq(bytes4(callData), ITradeExactInput.executeExactInput.selector);
            bytes memory arguments = new bytes(callData.length - 4);
            for (uint256 j; j < arguments.length; ++j) {
                arguments[j] = callData[j + 4];
            }
            (ExactInputPlan memory callPlan, FundingBundle memory funding) =
                abi.decode(arguments, (ExactInputPlan, FundingBundle));
            assertEq(abi.encode(callPlan), encoded);
            assertEq(abi.encodeCall(ITradeExactInput.executeExactInput, (plan, funding)), callData);
            assertEq(funding.authorizations.length, plan.inputs.length);
            _assertNestedFixtureBody(plan);
        }
    }

    function _assertNestedFixtureBody(ExactInputPlan memory plan) private pure {
        if (plan.intent == Intent.BuyCygld || plan.intent == Intent.SellCygld) {
            ScalarBody memory scalar = abi.decode(plan.body, (ScalarBody));
            assertEq(abi.encode(scalar), plan.body);
            assertEq(scalar.branches.length, 2);
            for (uint256 i; i < scalar.branches.length; ++i) {
                TradeBranch memory branch = scalar.branches[i];
                if (branch.kind == BranchKind.Market) {
                    MarketBody memory market = abi.decode(branch.data, (MarketBody));
                    assertEq(abi.encode(market), branch.data);
                    assertEq(market.feeCygld, 1);
                    assertEq(uint256(market.route.routes[0].steps[0].kind), 2);
                    assertEq(market.route.routes[0].steps[0].fee, 3_000);
                    assertEq(market.route.routes[0].steps[0].tickSpacing, 60);
                } else if (plan.intent == Intent.BuyCygld) {
                    CoreBuyBody memory buy = abi.decode(branch.data, (CoreBuyBody));
                    assertEq(abi.encode(buy), branch.data);
                    assertEq(buy.basketAssets.length, 2);
                    assertEq(buy.acquisitions[0].amountIn, 25);
                    assertEq(buy.acquisitions[1].amountIn, 26);
                    assertEq(buy.continuations.length, 2);
                } else {
                    CoreSellBody memory sell = abi.decode(branch.data, (CoreSellBody));
                    assertEq(abi.encode(sell), branch.data);
                    assertEq(sell.expectedOutputs[1].id, uint256(1) << 200);
                    assertEq(sell.conversions.length, 2);
                }
            }
        } else if (plan.intent == Intent.IssueBasket) {
            BasketIssueBody memory issue = abi.decode(plan.body, (BasketIssueBody));
            assertEq(abi.encode(issue), plan.body);
            assertEq(issue.continuations.length, 2);
            assertEq(plan.inputs.length, 2);
        } else {
            BasketRedeemBody memory redeem = abi.decode(plan.body, (BasketRedeemBody));
            assertEq(abi.encode(redeem), plan.body);
            assertEq(redeem.expectedOutputs[1].id, uint256(1) << 200);
            assertEq(redeem.expectedOutputs[1].minimumAmount, 3);
        }
    }

    function testBackendAdapterFixturePreservesUint256LimitsAndNoHookStepAbi() public view {
        string memory json = vm.readFile("test/fixtures/universal-exact-input.json");
        for (uint256 i; i < 2; ++i) {
            bytes memory encoded = vm.parseJsonBytes(json, string.concat(".adapterCases[", vm.toString(i), "].encoded"));
            SwapPlan memory plan = abi.decode(encoded, (SwapPlan));
            assertEq(abi.encode(plan), encoded);
            assertEq(plan.exactIn, i == 0);
            assertEq(plan.amountLimit, uint256(1) << 150);
            assertEq(plan.deadline, 2_000_000_000);
            assertEq(plan.branches[0].amountIn, i == 0 ? 101 : 0);
            Step memory step = plan.branches[0].steps[0];
            assertEq(uint256(step.kind), 2);
            assertEq(step.currencyOut, address(0x1111111111111111111111111111111111111111));
            assertEq(step.fee, 3_000);
            assertEq(step.tickSpacing, 60);
        }
    }

    function testActivationAndRetirementMatchIndependentFrozenSelectorInventory() public view {
        bytes4[] memory activation = TradeExactInputDeployment.selectors();
        assertEq(activation.length, 1);
        assertEq(activation[0], bytes4(0xabf176fd));
        IDiamond.FacetCut[] memory add = TradeExactInputDeployment.activationCut(address(0x1234));
        assertEq(add.length, 1);
        assertEq(add[0].facetAddress, address(0x1234));
        assertEq(uint256(add[0].action), uint256(IDiamond.FacetCutAction.Add));
        assertEq(add[0].functionSelectors[0], activation[0]);
        bytes4[12] memory expected = [
            bytes4(0xadfc9f4e),
            bytes4(0xf2c4c397),
            bytes4(0x065600b2),
            bytes4(0x300b4423),
            bytes4(0x3b25a19c),
            bytes4(0x6fa6d883),
            bytes4(0x1c0b4907),
            bytes4(0xc2f2261c),
            bytes4(0xddf6a573),
            bytes4(0x233f8db8),
            bytes4(0x705b2d0b),
            bytes4(0xe813952e)
        ];
        bytes4[] memory retired = TradeExactInputDeployment.retiredSelectors();
        assertEq(retired.length, expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assertEq(retired[i], expected[i]);
            assertTrue(retired[i] != activation[0]);
            for (uint256 j; j < i; ++j) {
                assertTrue(retired[j] != retired[i]);
            }
        }
        IDiamond.FacetCut[] memory remove = TradeExactInputDeployment.retirementCut();
        assertEq(remove.length, 1);
        assertEq(remove[0].facetAddress, address(0));
        assertEq(uint256(remove[0].action), uint256(IDiamond.FacetCutAction.Remove));
        assertEq(abi.encode(remove[0].functionSelectors), abi.encode(retired));
        string memory topology = vm.readFile("generated/topology/HelpersExactInput.json");
        _assertTopologySet(topology, ".migration.removeExecution", 12, retired, true);
        _assertTopologySet(topology, ".migration.retainExactInputPreviews", 6, retired, false);
        _assertTopologySet(topology, ".migration.retainExactOutputExecution", 7, retired, false);
        _assertTopologySet(topology, ".migration.retainExactOutputPreviews", 4, retired, false);
        assertEq(vm.parseJsonUint(topology, ".migration.expectedConsolidatedSelectorCount"), 45);
    }

    function _assertTopologySet(
        string memory json,
        string memory path,
        uint256 count,
        bytes4[] memory retired,
        bool removed
    ) private view {
        for (uint256 i; i < count; ++i) {
            bytes4 selector = bytes4(vm.parseJsonBytes(json, string.concat(path, "[", vm.toString(i), "].selector")));
            bool found;
            for (uint256 j; j < retired.length; ++j) {
                if (retired[j] == selector) found = true;
            }
            assertEq(found, removed);
        }
        assertFalse(vm.keyExistsJson(json, string.concat(path, "[", vm.toString(count), "]")));
    }

    function testFuzzMarketRetentionConservation(uint96 fundingSeed, uint96 refundSeed, uint96 unallocatedSeed) public {
        uint256 funded = bound(fundingSeed, 1, 100_000);
        uint256 refund = bound(refundSeed, 0, funded - 1);
        uint256 unallocated = bound(unallocatedSeed, 0, 100_000);
        _rate(address(payment), address(core), 2, refund);
        ExactInputPlan memory plan = _oneMarket(Intent.BuyCygld, address(payment), funded, address(core), 0);
        plan.inputs[0].amount += unallocated;
        TradeResult memory result = _call(plan);
        assertEq(payment.balanceOf(address(proxy)), 23 + refund + unallocated);
        assertEq(payment.balanceOf(USER), 1_000_000 - funded - unallocated);
        assertEq(core.balanceOf(RECIPIENT), 2 * (funded - refund));
        assertEq(result.stages[0].consumedInput + result.stages[0].returnedInput, funded);
        assertEq(core.balanceOf(address(proxy)), 17);
    }
}
