// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {
    IssueTestToken,
    IssueTestCore,
    IssueTestAdapter,
    IssueTestPermit2,
    IssueFacetHarness,
    IssuePreviewFacetHarness
} from "./BasketRouterIssue.t.sol";

/// @notice A standard ERC-2612 input unrelated to the configured Core reserve identities.
contract ImportedPermitToken is ERC20, ERC20Permit {
    constructor() ERC20("Imported authorization domain", "IMPORT") ERC20Permit("Imported authorization domain") {}

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

/// @notice Test-only deviations from standard permit and transfer behavior.
contract AdversarialPermitToken is ImportedPermitToken {
    enum TransferBehavior {
        Exact,
        TransferTax,
        SenderSurcharge
    }

    bool public noOpPermit;
    bool public reentryBlocked;
    TransferBehavior public transferBehavior;
    address public reentryTarget;
    bytes public reentryCalldata;

    function configure(bool noOp, TransferBehavior behavior, address target, bytes calldata callData) external {
        noOpPermit = noOp;
        transferBehavior = behavior;
        reentryTarget = target;
        reentryCalldata = callData;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
        override
    {
        if (noOpPermit) return;
        super.permit(owner, spender, value, deadline, v, r, s);
        if (reentryTarget != address(0)) {
            (bool success, bytes memory reason) = reentryTarget.call(reentryCalldata);
            require(!success, "reentry succeeded");
            require(reason.length >= 4, "reentry error missing");
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(reason, 0x20))
            }
            require(selector == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector, "wrong reentry error");
            reentryBlocked = true;
        }
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (transferBehavior == TransferBehavior.TransferTax) _burn(to, amount / 10);
        if (transferBehavior == TransferBehavior.SenderSurcharge) _burn(from, amount / 10);
        return true;
    }
}

contract RouterIssueTokenPermitTest is Test {
    uint256 private constant USER_KEY = 0x2612;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    address private user;
    address private constant OWNER = address(0xA11CE);
    address private constant RECIPIENT = address(0xCAFE);
    ImportedPermitToken private input;
    IssueTestToken private assetA;
    IssueTestToken private assetB;
    IssueTestCore private core;
    IssueTestAdapter private adapter;
    IssueTestPermit2 private permit2;
    IssueFacetHarness private issue;
    IssuePreviewFacetHarness private previews;

    function setUp() public {
        user = vm.addr(USER_KEY);
        input = new ImportedPermitToken();
        assetA = new IssueTestToken("Asset A", "A");
        assetB = new IssueTestToken("Asset B", "B");
        core = new IssueTestCore(address(assetA), address(assetB));
        adapter = new IssueTestAdapter();
        permit2 = new IssueTestPermit2();
        issue = new IssueFacetHarness(address(permit2));
        previews = new IssuePreviewFacetHarness(address(permit2));
        issue.configure(OWNER, address(core), address(0xBEEF), address(adapter), 1_000);
        previews.configure(address(core), address(0xBEEF), address(adapter), 1_000);
        input.mint(user, 100 ether);
        assetA.mint(address(adapter), 100 ether);
        assetB.mint(address(adapter), 100 ether);
    }

    function testFirstPurchaseConsumesExactCeilingPermitAndPreservesSharedSettlement() public {
        input.mint(address(issue), 3 ether);
        assetA.mint(address(issue), 4 ether);
        assetB.mint(address(issue), 5 ether);
        IBasketRouterTypes.IssueFromTokenExactOutParams memory params = _params();
        IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs();
        IBasketRouterTypes.IssueExactOutPreview memory preview = previews.previewIssueFromTokenExactOut(params, legs);
        IBasketRouterTypes.PermitParams memory permit = _sign(params.maximumInputAmount);

        assertEq(input.allowance(user, address(issue)), 0);
        assertEq(input.allowance(user, address(permit2)), 0);
        vm.prank(user);
        IBasketRouterTypes.Fees memory fees = issue.issueFromTokenExactOutWithPermit(params, _execution(), permit, legs);

        assertEq(input.nonces(user), 1);
        assertEq(input.allowance(user, address(issue)), 0, "ceiling is pulled once before refunds");
        assertEq(input.allowance(user, address(permit2)), 0);
        assertEq(input.balanceOf(user), 90 ether, "unused ceiling returned to payer");
        assertEq(core.balanceOf(RECIPIENT), params.netCygldOut);
        assertEq(core.balanceOf(OWNER), preview.fees.helperFeeCygld);
        assertEq(fees.helperFeeCygld, preview.fees.helperFeeCygld);
        assertEq(fees.protocolFeeCygld, preview.fees.protocolFeeCygld);
        assertEq(input.balanceOf(address(issue)), 3 ether);
        assertEq(assetA.balanceOf(address(issue)), 4 ether);
        assertEq(assetB.balanceOf(address(issue)), 5 ether);
        assertEq(input.allowance(address(issue), address(adapter)), 0);
        assertEq(assetA.allowance(address(issue), address(core)), 0);
        assertEq(assetB.allowance(address(issue), address(core)), 0);
    }

    function testExactInputPreviewConstructsSamePermitExecutor() public {
        IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs();
        IBasketRouterTypes.IssueExactInPreview memory preview = previews.previewIssueFromTokenExactIn(
            IBasketRouterTypes.IssueFromTokenExactInParams({inputToken: address(input), inputAmount: 12 ether}), legs
        );
        IBasketRouterTypes.IssueFromTokenExactOutParams memory params = _params();
        params.netCygldOut = preview.netCygldOut;
        IBasketRouterTypes.PermitParams memory permit = _sign(params.maximumInputAmount);
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(params, _execution(), permit, legs);
        assertEq(core.balanceOf(RECIPIENT), preview.netCygldOut);
        assertEq(input.allowance(user, address(issue)), 0);
    }

    function testPubliclyConsumedPermitUsesSufficientAllowanceWithoutSecondPermit() public {
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        input.permit(user, address(issue), permit.value, permit.deadline, permit.v, permit.r, permit.s);
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        assertEq(input.nonces(user), 1, "pre-consumed nonce must not be retried");
        assertEq(input.allowance(user, address(issue)), 0);
        assertEq(core.balanceOf(RECIPIENT), 10 ether);
    }

    function testExistingAllowanceSkipsEvenExpiredUnusablePermit() public {
        vm.prank(user);
        input.approve(address(issue), 12 ether);
        IBasketRouterTypes.PermitParams memory emptyPermit;
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), emptyPermit, _legs());
        assertEq(input.nonces(user), 0);
        assertEq(input.allowance(user, address(issue)), 0);
        assertEq(core.balanceOf(RECIPIENT), 10 ether);
    }

    function testConsumedPermitWithInsufficientAllowanceReturnsTokenSignatureFailure() public {
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        input.permit(user, address(issue), permit.value, permit.deadline, permit.v, permit.r, permit.s);
        vm.prank(address(issue));
        input.transferFrom(user, address(0xDEAD), 1 ether);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        assertEq(input.nonces(user), 1);
        assertEq(input.allowance(user, address(issue)), 11 ether);
        assertEq(core.balanceOf(RECIPIENT), 0);
    }

    function testNonzeroInsufficientAllowanceNeedsPermitForFullCeiling() public {
        vm.prank(user);
        input.approve(address(issue), 2 ether);
        IBasketRouterTypes.PermitParams memory permit = _sign(10 ether);
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitAmountTooLow.selector, 10 ether, 12 ether));
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        assertEq(input.nonces(user), 0);
        assertEq(input.allowance(user, address(issue)), 2 ether);
        permit = _sign(12 ether);
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        assertEq(input.nonces(user), 1);
        assertEq(input.allowance(user, address(issue)), 0);
    }

    function testExpiredPermitRetainsExpiryErrorAndNoEconomicEffects() public {
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        vm.warp(permit.deadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IBasketRouterTypes.PermitExpired.selector, permit.deadline, block.timestamp)
        );
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        _assertRolledBack();
    }

    function testWrongSignerAndPayerBindingRetainTokenSignatureError() public {
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        vm.prank(address(0xBAD));
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        _assertRolledBack();
    }

    function testPurchaseRevertAfterPermitRollsBackNonceAllowanceAndEveryEconomicBalance() public {
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs();
        legs[1].data = abi.encode(4 ether, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.InsufficientOutputForNeed.selector, address(assetB), 5 ether, 4 ether
            )
        );
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, legs);
        _assertRolledBack();
        assertEq(assetA.balanceOf(address(adapter)), 100 ether);
        assertEq(assetB.balanceOf(address(adapter)), 100 ether);
        assertEq(adapter.swapCallCount(), 0);
    }

    function testZeroTokenAddressRetainsExistingValidation() public {
        IBasketRouterTypes.IssueFromTokenExactOutParams memory params = _params();
        params.inputToken = address(0);
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        vm.expectRevert(IBasketRouterTypes.ZeroAddress.selector);
        issue.issueFromTokenExactOutWithPermit(params, _execution(), permit, _legs());
    }

    function testNoOpPermitCannotFundPurchase() public {
        AdversarialPermitToken adversarial = _adversarial();
        adversarial.configure(true, AdversarialPermitToken.TransferBehavior.Exact, address(0), "");
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitAllowanceTooLow.selector, 0, 12 ether));
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        _assertRolledBack();
    }

    function testMaliciousPermitCallbackCannotReenterPurchase() public {
        AdversarialPermitToken adversarial = _adversarial();
        adversarial.configure(
            false,
            AdversarialPermitToken.TransferBehavior.Exact,
            address(issue),
            abi.encodeWithSelector(issue.issueFromTokenExactOut.selector, _params(), _execution(), _legs())
        );
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        assertTrue(adversarial.reentryBlocked());
        assertEq(core.safeIssueCallCount(), 1);
        assertEq(input.nonces(user), 1);
        assertEq(core.balanceOf(RECIPIENT), 10 ether);
    }

    function testNativePermitTransferTaxIsRejectedWithMeasuredCreditError() public {
        AdversarialPermitToken adversarial = _adversarial();
        adversarial.configure(false, AdversarialPermitToken.TransferBehavior.TransferTax, address(0), "");
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.RouterTokenCreditMismatch.selector, address(input), 12 ether, 10.8 ether
            )
        );
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        _assertRolledBack();
    }

    function testNativePermitSenderSurchargeIsRejectedWithMeasuredDebitError() public {
        AdversarialPermitToken adversarial = _adversarial();
        adversarial.configure(false, AdversarialPermitToken.TransferBehavior.SenderSurcharge, address(0), "");
        IBasketRouterTypes.PermitParams memory permit = _sign(12 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.PayerTokenDebitMismatch.selector, address(input), user, 12 ether, 13.2 ether
            )
        );
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
        _assertRolledBack();
    }

    function testWrongTokenSpenderNonceAndNetworkDomainsRetainSignatureErrors() public {
        ImportedPermitToken otherToken = new ImportedPermitToken();
        IBasketRouterTypes.PermitParams memory wrongToken = _signFor(otherToken.DOMAIN_SEPARATOR(), address(issue), 0);
        _assertInvalidSignature(wrongToken);
        IBasketRouterTypes.PermitParams memory wrongSpender = _signFor(input.DOMAIN_SEPARATOR(), address(0xBAD), 0);
        _assertInvalidSignature(wrongSpender);
        IBasketRouterTypes.PermitParams memory wrongNonce = _signFor(input.DOMAIN_SEPARATOR(), address(issue), 1);
        _assertInvalidSignature(wrongNonce);
        IBasketRouterTypes.PermitParams memory wrongNetwork = _sign(12 ether);
        vm.chainId(block.chainid + 1);
        _assertInvalidSignature(wrongNetwork);
        _assertRolledBack();
    }

    function testOrderedBasketValidationPrecedesPermitAcquisition() public {
        IBasketRouterTypes.IssueExecutionParams memory execution = _execution();
        execution.expectedOrderedCoreAssets[0] = address(assetB);
        IBasketRouterTypes.PermitParams memory expiredPermit;
        vm.expectRevert(
            abi.encodeWithSelector(IBasketRouterTypes.CoreAssetMismatch.selector, 0, address(assetB), address(assetA))
        );
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), execution, expiredPermit, _legs());
        _assertRolledBack();
    }

    function testFuzzExactPermitCeilingAndRefundCannotRestoreAllowance(uint96 surplusSeed, uint96 refundSeed) public {
        uint256 surplus = bound(uint256(surplusSeed), 0, 50 ether);
        uint256 refund = bound(uint256(refundSeed), 0, 2 ether);
        IBasketRouterTypes.IssueFromTokenExactOutParams memory params = _params();
        params.maximumInputAmount = 12 ether + surplus;
        IBasketRouterTypes.PermitParams memory permit = _sign(params.maximumInputAmount);
        IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs();
        legs[0].data = abi.encode(5 ether, refund);
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(params, _execution(), permit, legs);
        assertEq(input.allowance(user, address(issue)), 0);
        assertEq(input.nonces(user), 1);
        assertEq(input.balanceOf(user), 100 ether - (11 ether - refund));
        assertEq(input.balanceOf(address(issue)), 0);
        assertEq(core.balanceOf(RECIPIENT), params.netCygldOut);
    }

    function _adversarial() private returns (AdversarialPermitToken token) {
        token = new AdversarialPermitToken();
        token.mint(user, 100 ether);
        input = token;
    }

    function _assertInvalidSignature(IBasketRouterTypes.PermitParams memory permit) private {
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        vm.prank(user);
        issue.issueFromTokenExactOutWithPermit(_params(), _execution(), permit, _legs());
    }

    function _signFor(bytes32 domain, address spender, uint256 nonce)
        private
        view
        returns (IBasketRouterTypes.PermitParams memory permit)
    {
        permit.value = 12 ether;
        permit.deadline = block.timestamp + 1 days;
        bytes32 message = keccak256(abi.encode(PERMIT_TYPEHASH, user, spender, permit.value, nonce, permit.deadline));
        (permit.v, permit.r, permit.s) = vm.sign(USER_KEY, keccak256(abi.encodePacked(hex"1901", domain, message)));
    }

    function _assertRolledBack() private view {
        assertEq(input.nonces(user), 0);
        assertEq(input.allowance(user, address(issue)), 0);
        assertEq(input.balanceOf(user), 100 ether);
        assertEq(input.balanceOf(address(issue)), 0);
        assertEq(input.balanceOf(address(adapter)), 0);
        assertEq(assetA.balanceOf(address(issue)), 0);
        assertEq(assetB.balanceOf(address(issue)), 0);
        assertEq(assetA.balanceOf(address(core)), 0);
        assertEq(assetB.balanceOf(address(core)), 0);
        assertEq(core.balanceOf(RECIPIENT), 0);
        assertEq(core.balanceOf(OWNER), 0);
        assertEq(core.safeIssueCallCount(), 0);
    }

    function _sign(uint256 value) private view returns (IBasketRouterTypes.PermitParams memory permit) {
        permit.value = value;
        permit.deadline = block.timestamp + 1 days;
        bytes32 message =
            keccak256(abi.encode(PERMIT_TYPEHASH, user, address(issue), value, input.nonces(user), permit.deadline));
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", input.DOMAIN_SEPARATOR(), message));
        (permit.v, permit.r, permit.s) = vm.sign(USER_KEY, digest);
    }

    function _params() private view returns (IBasketRouterTypes.IssueFromTokenExactOutParams memory) {
        return IBasketRouterTypes.IssueFromTokenExactOutParams({
            inputToken: address(input), maximumInputAmount: 12 ether, netCygldOut: 10 ether
        });
    }

    function _execution() private view returns (IBasketRouterTypes.IssueExecutionParams memory) {
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        return IBasketRouterTypes.IssueExecutionParams({recipient: RECIPIENT, expectedOrderedCoreAssets: assets});
    }

    function _legs() private view returns (IBasketRouterTypes.IssueSwapLeg[] memory legs) {
        legs = new IBasketRouterTypes.IssueSwapLeg[](2);
        for (uint256 i; i < legs.length; ++i) {
            legs[i] = IBasketRouterTypes.IssueSwapLeg({
                adapter: address(adapter),
                amountIn: 6 ether,
                minimumAmountOut: 5 ether,
                data: abi.encode(5 ether, 1 ether)
            });
        }
    }
}
