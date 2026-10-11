// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {IssueTestToken, IssueTestCore, IssueTestPermit2, IssueBasketFacetHarness} from "./BasketRouterIssue.t.sol";
import {ImportedPermitToken, AdversarialPermitToken} from "./RouterIssueTokenPermit.t.sol";

/// @notice A later native permit can mutate an earlier asset; basket conservation must reject it.
contract CrossAssetPermitToken is ImportedPermitToken {
    ImportedPermitToken public earlierToken;
    address public router;

    function configure(ImportedPermitToken token, address target) external {
        earlierToken = token;
        router = target;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        override
    {
        super.permit(owner, spender, value, deadline, v, r, s);
        earlierToken.mint(router, 1);
    }
}

contract RouterIssueBasketMixedPermitsTest is Test {
    uint256 private constant USER_KEY = 0x2612;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    address private constant OWNER = address(0xA11CE);
    address private constant RECIPIENT = address(0xCAFE);
    address private user;
    AdversarialPermitToken private a;
    AdversarialPermitToken private b;
    IssueTestPermit2 private permit2;
    IssueTestCore private core;
    IssueBasketFacetHarness private basket;

    function setUp() public {
        user = vm.addr(USER_KEY);
        a = new AdversarialPermitToken();
        b = new AdversarialPermitToken();
        permit2 = new IssueTestPermit2();
        core = new IssueTestCore(address(a), address(b));
        basket = new IssueBasketFacetHarness(address(permit2));
        basket.configure(OWNER, address(core), 1_000);
        a.mint(user, 100 ether);
        b.mint(user, 100 ether);
    }

    function testAllNativeExactOutUsesNoPermit2SetupAndOneVectorEvent() public {
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 1, 5 ether, 5 ether);
        a.mint(address(basket), 2 ether);
        b.mint(address(basket), 3 ether);
        vm.recordLogs();
        IBasketRouterTypes.BasketIssueResult memory result = _out(inputs, _batch(inputs, 1));
        assertEq(result.netCygldOut, 10 ether);
        assertEq(a.nonces(user), 1);
        assertEq(b.nonces(user), 1);
        assertEq(a.allowance(user, address(basket)), 0);
        assertEq(b.allowance(user, address(basket)), 0);
        assertEq(a.allowance(user, address(permit2)), 0);
        assertEq(b.allowance(user, address(permit2)), 0);
        assertFalse(permit2.used(user, 1));
        _assertSettlement(result, 5 ether, 5 ether, 2 ether, 3 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 outcomes;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics[0]
                    == keccak256("IssuedFromBasket(address,address,address[],uint256[],uint256,uint256,uint256)")
            ) {
                ++outcomes;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), user);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), RECIPIENT);
                (
                    address[] memory assets,
                    uint256[] memory actual,
                    uint256 net,
                    uint256 protocolFee,
                    uint256 helperFee
                ) = abi.decode(logs[i].data, (address[], uint256[], uint256, uint256, uint256));
                assertEq(assets[0], address(a));
                assertEq(assets[1], address(b));
                assertEq(actual, result.actualAmountsIn);
                assertEq(net, result.netCygldOut);
                assertEq(protocolFee, result.fees.protocolFeeCygld);
                assertEq(helperFee, result.fees.helperFeeCygld);
            }
        }
        assertEq(outcomes, 1);
    }

    function testNativeAndPermit2SubsetWorkInEitherCorePosition() public {
        _approveSetup();
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, 5 ether, 5 ether);
        _out(inputs, _batch(inputs, 2));
        assertEq(a.nonces(user), 1);
        assertEq(b.nonces(user), 0);
        assertTrue(permit2.used(user, 2));
        inputs = _inputs(2, 1, 5 ether, 5 ether);
        _out(inputs, _batch(inputs, 3));
        assertEq(a.nonces(user), 1);
        assertEq(b.nonces(user), 1);
        assertTrue(permit2.used(user, 3));
        assertEq(a.allowance(user, address(permit2)), type(uint256).max);
        assertEq(b.allowance(user, address(permit2)), type(uint256).max);
    }

    function testNonPermitTokenUsesCompactPermit2WithoutNativeCapability() public {
        IssueTestToken ordinary = new IssueTestToken("Ordinary token", "ORD");
        ordinary.mint(user, 100 ether);
        core = new IssueTestCore(address(a), address(ordinary));
        basket.configure(OWNER, address(core), 1_000);
        (bool hasDomain,) = address(ordinary).staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertFalse(hasDomain, "ordinary token provides no native permit interface");
        vm.prank(user);
        ordinary.approve(address(permit2), type(uint256).max);
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, 5 ether, 5 ether);
        inputs[1].token = address(ordinary);
        delete inputs[1].permit;
        IBasketRouterTypes.BasketIssueResult memory result = _out(inputs, _batch(inputs, 20));
        assertEq(result.netCygldOut, 10 ether);
        assertEq(ordinary.balanceOf(user), 95 ether);
        assertEq(ordinary.balanceOf(address(basket)), 0);
        assertEq(ordinary.allowance(user, address(basket)), 0);
        assertEq(ordinary.allowance(user, address(permit2)), type(uint256).max);
        assertEq(ordinary.allowance(address(basket), address(core)), 0);
        assertEq(a.nonces(user), 1);
        assertTrue(permit2.used(user, 20));
    }

    function testExactInPreservesBudgetsFreshLotsRefundsAndFees() public {
        _approveSetup();
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, 8 ether, 9 ether);
        vm.prank(user);
        IBasketRouterTypes.BasketIssueResult memory result = basket.issueFromBasketExactInWithMixedPermits(
            IBasketRouterTypes.BasketIssueExactInRequest(RECIPIENT, 15.984 ether), inputs, _batch(inputs, 4)
        );
        assertEq(result.netCygldOut, 15.984 ether);
        assertEq(result.fees.helperFeeCygld, 0.016 ether);
        assertEq(core.lastMaximumInputs(), _amounts(8 ether, 8 ether));
        assertEq(a.allowance(user, address(basket)), 0);
        _assertSettlement(result, 5 ether, 5 ether, 0, 0);
    }

    function testOrdinaryAndConsumedNativeAllowancesRemainUsableWithoutNewSignatures() public {
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 1, 5 ether, 5 ether);
        IBasketRouterTypes.PermitParams memory p = inputs[0].permit;
        a.permit(user, address(basket), p.value, p.deadline, p.v, p.r, p.s);
        _out(inputs, _batch(inputs, 5));
        assertEq(a.nonces(user), 1, "front-run permit reused through existing allowance");
        vm.startPrank(user);
        a.approve(address(basket), 5 ether);
        b.approve(address(basket), 5 ether);
        vm.stopPrank();
        inputs = _inputs(0, 1, 5 ether, 5 ether);
        delete inputs[1].permit;
        _out(inputs, _batch(inputs, 6));
        assertEq(a.nonces(user), 1);
        assertEq(b.nonces(user), 1, "already sufficient legacy allowance needs no permit");
        assertEq(a.allowance(user, address(basket)), 0);
        assertEq(b.allowance(user, address(basket)), 0);
        vm.startPrank(user);
        a.approve(address(basket), 5 ether);
        b.approve(address(basket), 5 ether);
        vm.stopPrank();
        inputs = _inputs(0, 0, 5 ether, 5 ether);
        _out(inputs, _batch(inputs, 7));
        assertFalse(permit2.used(user, 7));
    }

    function testAllPermit2MatchesRetainedBasketEconomics() public {
        _approveSetup();
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(2, 2, 5 ether, 5 ether);
        IBasketRouterTypes.BasketIssueResult memory mixed = _out(inputs, _batch(inputs, 8));
        vm.prank(user);
        IBasketRouterTypes.BasketIssueResult memory retained =
            basket.issueFromBasketExactOutWithPermit2(_request(), _batch(inputs, 9));
        assertEq(keccak256(abi.encode(mixed)), keccak256(abi.encode(retained)));
        assertEq(a.nonces(user), 0);
        assertEq(b.nonces(user), 0);
    }

    function testZeroRequiredMembersRemainStructuralWithoutApplyingNativePermit() public {
        core.setCurrentInputs(0, 5 ether);
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 1, 0, 5 ether);
        delete inputs[0].permit;
        _out(inputs, _batch(inputs, 10));
        assertEq(a.nonces(user), 0);
        assertEq(b.nonces(user), 1);
        core.setCurrentInputs(0, 5 ether);
        inputs = _inputs(2, 1, 0, 5 ether);
        _out(inputs, _batch(inputs, 11));
        assertTrue(permit2.used(user, 11), "zero Permit2 member remains in the compact signed subset");
        assertEq(a.balanceOf(user), 100 ether);
    }

    function testInputLengthOrderAndLimitsRejectBeforeAnyAuthorization() public {
        IBasketRouterTypes.BasketIssueInput[] memory inputs = new IBasketRouterTypes.BasketIssueInput[](1);
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.CoreAssetAmountsLengthMismatch.selector, 2, 1));
        _out(inputs, _emptyBatch());
        inputs = _inputs(1, 1, 5 ether, 5 ether);
        inputs[0].token = address(b);
        vm.expectRevert(
            abi.encodeWithSelector(IBasketRouterTypes.CoreAssetMismatch.selector, 0, address(b), address(a))
        );
        _out(inputs, _emptyBatch());
        inputs = _inputs(1, 1, 4 ether, 5 ether);
        vm.expectRevert(IBasketRouterTypes.InsufficientInput.selector);
        _out(inputs, _emptyBatch());
        assertEq(a.nonces(user), 0);
        assertEq(b.nonces(user), 0);
        assertEq(core.safeIssueCallCount(), 0);
    }

    function testPermit2SubsetLengthOrderCeilingAndDeadlineRejectBeforeNativePull() public {
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, 5 ether, 5 ether);
        IBasketRouterTypes.Permit2BatchParams memory p = _emptyBatch();
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.Permit2BatchLengthMismatch.selector, 0, 1));
        _out(inputs, p);
        p = _batch(inputs, 12);
        p.permit.permitted[0].token = address(a);
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.InvalidPermit2Token.selector, address(a), address(b)));
        _out(inputs, p);
        p = _batch(inputs, 12);
        p.permit.permitted[0].amount = 4 ether;
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.Permit2AmountTooLow.selector, 4 ether, 5 ether));
        _out(inputs, p);
        p = _batch(inputs, 12);
        p.permit.deadline = 0;
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitExpired.selector, 0, block.timestamp));
        _out(inputs, p);
        assertEq(a.nonces(user), 0);
        assertFalse(permit2.used(user, 12));
        assertEq(a.balanceOf(user), 100 ether);
    }

    function testRecipientAndExactInMinimumRejectBeforeAcquisition() public {
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 1, 5 ether, 5 ether);
        IBasketRouterTypes.BasketIssueExactOutRequest memory request = _request();
        request.recipient = address(basket);
        vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
        vm.prank(user);
        basket.issueFromBasketExactOutWithMixedPermits(request, inputs, _emptyBatch());
        IBasketRouterTypes.BasketIssueExactInRequest memory exactIn =
            IBasketRouterTypes.BasketIssueExactInRequest(address(0), 1);
        vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
        vm.prank(user);
        basket.issueFromBasketExactInWithMixedPermits(exactIn, inputs, _emptyBatch());
        exactIn.recipient = RECIPIENT;
        exactIn.minimumNetCygldOut = 0;
        vm.expectRevert(IBasketRouterTypes.ZeroFinalMinimum.selector);
        vm.prank(user);
        basket.issueFromBasketExactInWithMixedPermits(exactIn, inputs, _emptyBatch());
        exactIn.minimumNetCygldOut = 11 ether;
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.InsufficientOutput.selector, 11 ether, 9.99 ether));
        vm.prank(user);
        basket.issueFromBasketExactInWithMixedPermits(exactIn, inputs, _emptyBatch());
        core.setForceExactInZero(true);
        vm.expectRevert(IBasketRouterTypes.AmountTooSmallAfterFees.selector);
        vm.prank(user);
        basket.issueFromBasketExactInWithMixedPermits(exactIn, inputs, _emptyBatch());
        assertEq(a.nonces(user), 0);
    }

    function testMissingPermit2SetupAndLateNativeFailureRollBackEarlierPermit() public {
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, 5 ether, 5 ether);
        vm.expectRevert();
        _out(inputs, _batch(inputs, 13));
        assertEq(a.nonces(user), 0);
        assertFalse(permit2.used(user, 13));
        inputs = _inputs(1, 1, 5 ether, 5 ether);
        inputs[1].permit.r = bytes32(0);
        vm.expectRevert();
        _out(inputs, _emptyBatch());
        assertEq(a.nonces(user), 0);
        assertEq(a.allowance(user, address(basket)), 0);
        assertEq(a.balanceOf(user), 100 ether);
    }

    function testMixedReplayAndAllNativeReplayRollBackAtomically() public {
        _approveSetup();
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, 5 ether, 5 ether);
        IBasketRouterTypes.Permit2BatchParams memory p = _batch(inputs, 14);
        _out(inputs, p);
        inputs = _inputs(1, 2, 5 ether, 5 ether);
        vm.expectRevert(bytes("nonce"));
        _out(inputs, p);
        assertEq(a.nonces(user), 1);
        assertEq(a.balanceOf(user), 95 ether);
        inputs = _inputs(1, 1, 5 ether, 5 ether);
        _out(inputs, _emptyBatch());
        vm.expectRevert();
        _out(inputs, _emptyBatch());
        assertEq(a.nonces(user), 2);
        assertEq(b.nonces(user), 1);
    }

    function testCoreFailureAndUpwardDriftRollBackBothAuthorizationKinds() public {
        _approveSetup();
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, 5 ether, 5 ether);
        core.setSafeProtocolFeeOverride(1 ether, true);
        vm.expectRevert(IBasketRouterTypes.CoreIssuanceResultMismatch.selector);
        _out(inputs, _batch(inputs, 15));
        core.setSafeProtocolFeeOverride(0, false);
        permit2.setBatchDrift(core, 6 ether, 5 ether);
        vm.expectRevert(bytes("max"));
        _out(inputs, _batch(inputs, 16));
        assertEq(a.nonces(user), 0);
        assertFalse(permit2.used(user, 15));
        assertFalse(permit2.used(user, 16));
        assertEq(a.balanceOf(user), 100 ether);
        assertEq(b.balanceOf(user), 100 ether);
        assertEq(core.safeIssueCallCount(), 0);
    }

    function testNativePermitReentryIsBlockedAndNoOpPermitCannotSupplyAllowance() public {
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 1, 5 ether, 5 ether);
        a.configure(
            false,
            AdversarialPermitToken.TransferBehavior.Exact,
            address(basket),
            abi.encodeCall(basket.issueFromBasketExactOutWithMixedPermits, (_request(), inputs, _emptyBatch()))
        );
        _out(inputs, _emptyBatch());
        assertTrue(a.reentryBlocked());
        inputs = _inputs(1, 1, 5 ether, 5 ether);
        a.configure(true, AdversarialPermitToken.TransferBehavior.Exact, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitAllowanceTooLow.selector, 0, 5 ether));
        _out(inputs, _emptyBatch());
        assertEq(a.nonces(user), 1);
    }

    function testTransferTaxAndSenderSurchargeRejectBothAcquisitionKinds() public {
        _approveSetup();
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, 5 ether, 5 ether);
        a.configure(false, AdversarialPermitToken.TransferBehavior.TransferTax, address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.RouterTokenCreditMismatch.selector, address(a), 5 ether, 4.5 ether
            )
        );
        _out(inputs, _batch(inputs, 17));
        a.configure(false, AdversarialPermitToken.TransferBehavior.Exact, address(0), "");
        b.configure(false, AdversarialPermitToken.TransferBehavior.SenderSurcharge, address(0), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.PayerTokenDebitMismatch.selector, address(b), user, 5 ether, 5.5 ether
            )
        );
        _out(inputs, _batch(inputs, 18));
        assertEq(a.nonces(user), 0);
        assertFalse(permit2.used(user, 18));
    }

    function testLaterTokenCannotChangeEarlierAcquisitionCredit() public {
        CrossAssetPermitToken other = new CrossAssetPermitToken();
        other.configure(a, address(basket));
        other.mint(user, 100 ether);
        core = new IssueTestCore(address(a), address(other));
        basket.configure(OWNER, address(core), 1_000);
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 1, 5 ether, 5 ether);
        inputs[1].token = address(other);
        inputs[1].permit = _sign(other, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.RouterTokenCreditMismatch.selector, address(a), 5 ether, 5 ether + 1
            )
        );
        _out(inputs, _emptyBatch());
        assertEq(a.nonces(user), 0);
        assertEq(other.nonces(user), 0);
    }

    function testFuzzMixedCeilingsAndRequirementDecreasePreserveCustody(uint96 first, uint96 second) public {
        uint256 budgetA = bound(first, 2, 20 ether);
        uint256 budgetB = bound(second, 2, 20 ether);
        uint256 requiredA = budgetA / 2;
        uint256 requiredB = budgetB / 2;
        core.setCurrentInputs(requiredA, requiredB);
        _approveSetup();
        a.mint(address(basket), 2 ether);
        b.mint(address(basket), 3 ether);
        permit2.setBatchDrift(core, requiredA / 2, requiredB / 2);
        IBasketRouterTypes.BasketIssueInput[] memory inputs = _inputs(1, 2, budgetA, budgetB);
        IBasketRouterTypes.BasketIssueResult memory result = _out(inputs, _batch(inputs, 19));
        _assertSettlement(result, requiredA / 2, requiredB / 2, 2 ether, 3 ether);
        assertEq(
            a.allowance(user, address(basket)), budgetA - requiredA, "finite trade budget; only fresh exact lot pulled"
        );
        assertEq(core.lastMaximumInputs(), _amounts(requiredA, requiredB));
        assertTrue(permit2.used(user, 19));
    }

    function _request() private pure returns (IBasketRouterTypes.BasketIssueExactOutRequest memory) {
        return IBasketRouterTypes.BasketIssueExactOutRequest(10 ether, RECIPIENT);
    }

    function _out(IBasketRouterTypes.BasketIssueInput[] memory inputs, IBasketRouterTypes.Permit2BatchParams memory p)
        private
        returns (IBasketRouterTypes.BasketIssueResult memory)
    {
        vm.prank(user);
        return basket.issueFromBasketExactOutWithMixedPermits(_request(), inputs, p);
    }

    function _inputs(uint8 modeA, uint8 modeB, uint256 budgetA, uint256 budgetB)
        private
        view
        returns (IBasketRouterTypes.BasketIssueInput[] memory inputs)
    {
        inputs = new IBasketRouterTypes.BasketIssueInput[](2);
        inputs[0] = IBasketRouterTypes.BasketIssueInput(
            address(a), budgetA, IBasketRouterTypes.BasketInputAuthorization(modeA), _sign(a, budgetA)
        );
        inputs[1] = IBasketRouterTypes.BasketIssueInput(
            address(b), budgetB, IBasketRouterTypes.BasketInputAuthorization(modeB), _sign(b, budgetB)
        );
    }

    function _sign(ImportedPermitToken token, uint256 value)
        private
        view
        returns (IBasketRouterTypes.PermitParams memory p)
    {
        p.value = value;
        p.deadline = block.timestamp + 1 days;
        bytes32 message =
            keccak256(abi.encode(PERMIT_TYPEHASH, user, address(basket), value, token.nonces(user), p.deadline));
        (p.v, p.r, p.s) = vm.sign(USER_KEY, keccak256(abi.encodePacked(hex"1901", token.DOMAIN_SEPARATOR(), message)));
    }

    function _batch(IBasketRouterTypes.BasketIssueInput[] memory inputs, uint256 nonce)
        private
        view
        returns (IBasketRouterTypes.Permit2BatchParams memory p)
    {
        uint256 count;
        for (uint256 i; i < inputs.length; ++i) {
            if (inputs[i].authorization == IBasketRouterTypes.BasketInputAuthorization.Permit2) ++count;
        }
        p.permit.permitted = new ISignatureTransfer.TokenPermissions[](count);
        uint256 cursor;
        for (uint256 i; i < inputs.length; ++i) {
            if (inputs[i].authorization == IBasketRouterTypes.BasketInputAuthorization.Permit2) {
                p.permit.permitted[cursor++] =
                    ISignatureTransfer.TokenPermissions(inputs[i].token, inputs[i].maximumInputAmount);
            }
        }
        p.permit.nonce = nonce;
        p.permit.deadline = block.timestamp + 1 days;
        p.signature = hex"01";
    }

    function _emptyBatch() private pure returns (IBasketRouterTypes.Permit2BatchParams memory p) {
        p.permit.permitted = new ISignatureTransfer.TokenPermissions[](0);
    }

    function _approveSetup() private {
        vm.startPrank(user);
        a.approve(address(permit2), type(uint256).max);
        b.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    function _amounts(uint256 first, uint256 second) private pure returns (uint256[] memory values) {
        values = new uint256[](2);
        values[0] = first;
        values[1] = second;
    }

    function _assertSettlement(
        IBasketRouterTypes.BasketIssueResult memory r,
        uint256 usedA,
        uint256 usedB,
        uint256 staleA,
        uint256 staleB
    ) private view {
        assertEq(r.actualAmountsIn, _amounts(usedA, usedB));
        assertEq(a.balanceOf(user), 100 ether - usedA);
        assertEq(b.balanceOf(user), 100 ether - usedB);
        assertEq(a.balanceOf(address(basket)), staleA);
        assertEq(b.balanceOf(address(basket)), staleB);
        assertEq(a.allowance(address(basket), address(core)), 0);
        assertEq(b.allowance(address(basket), address(core)), 0);
        assertEq(core.balanceOf(RECIPIENT), r.netCygldOut);
        assertEq(core.balanceOf(OWNER), r.fees.helperFeeCygld);
        assertEq(r.fees.protocolFeeCygld, core.protocolFeeCygld());
    }
}
