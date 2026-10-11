// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {MarketSwapFacet} from "../src/facets/MarketSwapFacet.sol";
import {IMarketSwap} from "../src/interfaces/IMarketSwap.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {IssueTestAdapter, IssueTestPermit2} from "./BasketRouterIssue.t.sol";
import {ImportedPermitToken, AdversarialPermitToken} from "./RouterIssueTokenPermit.t.sol";

contract MarketFacetHarness is MarketSwapFacet {
    using EnumerableSet for EnumerableSet.AddressSet;
    constructor(address permit2_) MarketSwapFacet(permit2_) {}

    function configure(address core, address adapter, address owner) external {
        LibAppStorage.RouterStorage storage rs = LibAppStorage.routerStorage();
        rs.coreDiamond = core;
        rs.approvedAdapters.add(adapter);
        LibDiamond.setContractOwner(owner);
    }

    function setOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function pause() external {
        _pause();
    }
}

contract MarketSwapFacetTest is Test, IMarketSwap {
    uint256 private constant KEY = 0x2612;
    bytes32 private constant PERMIT_HASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    address private user;
    address private constant OWNER = address(0xA11CE);
    address private constant RECIPIENT = address(0xCAFE);
    ImportedPermitToken private cygld;
    ImportedPermitToken private counter;
    IssueTestAdapter private adapter;
    IssueTestPermit2 private permit2;
    MarketFacetHarness private market;

    function setUp() public {
        user = vm.addr(KEY);
        cygld = new ImportedPermitToken();
        counter = new ImportedPermitToken();
        adapter = new IssueTestAdapter();
        permit2 = new IssueTestPermit2();
        market = new MarketFacetHarness(address(permit2));
        market.configure(address(cygld), address(adapter), OWNER);
        cygld.mint(user, 100_000);
        counter.mint(user, 100_000);
        cygld.mint(address(adapter), 100_000);
        counter.mint(address(adapter), 100_000);
        cygld.mint(address(market), 17);
        counter.mint(address(market), 19);
    }

    function _params(MarketSide side, bool exactIn) private view returns (MarketSwapParams memory p) {
        p = MarketSwapParams(
            side,
            address(counter),
            exactIn ? 1002 : 1000,
            exactIn ? 999 : 1100,
            side == MarketSide.SellCygld && exactIn ? 1000 : 0,
            1,
            RECIPIENT,
            block.timestamp + 60,
            address(adapter),
            ""
        );
        p.data = abi.encode(uint256(side == MarketSide.BuyCygld ? 1001 : 1000), uint256(exactIn ? 0 : 99));
    }

    function _native(IERC20 input, uint256 amount) private view returns (FundingAuthorization memory auth) {
        auth.mode = FundingMode.NativePermit;
        uint256 deadline = block.timestamp + 60;
        ImportedPermitToken token = ImportedPermitToken(address(input));
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_HASH, user, address(market), amount, token.nonces(user), deadline))
            )
        );
        (auth.nativePermit.v, auth.nativePermit.r, auth.nativePermit.s) = vm.sign(KEY, digest);
        auth.nativePermit.value = amount;
        auth.nativePermit.deadline = deadline;
    }

    function _call(MarketSwapParams memory p, FundingAuthorization memory auth, bool exactIn)
        private
        returns (MarketSwapResult memory r)
    {
        vm.prank(user);
        return exactIn ? market.swapExactInput(p, auth) : market.swapExactOutput(p, auth);
    }

    function _baselines() private view {
        assertEq(cygld.balanceOf(address(market)), 17);
        assertEq(counter.balanceOf(address(market)), 19);
        assertEq(cygld.allowance(address(market), address(adapter)), 0);
        assertEq(counter.allowance(address(market), address(adapter)), 0);
    }

    function testNativePermitFourDirectionModesAndNoSetup() public {
        for (uint256 side; side < 2; ++side) {
            for (uint256 mode; mode < 2; ++mode) {
                bool exactIn = mode == 0;
                MarketSwapParams memory p = _params(MarketSide(side), exactIn);
                ImportedPermitToken input = side == 0 ? counter : cygld;
                uint256 budget = exactIn ? p.amount : p.bound;
                assertEq(input.allowance(user, address(market)), 0);
                assertEq(input.allowance(user, address(permit2)), 0);
                MarketSwapResult memory r = _call(p, _native(input, budget), exactIn);
                assertEq(r.amountOut, 1000);
                assertEq(r.feeCygld, 1);
                assertEq(r.feeRecipient, OWNER);
                assertEq(r.inputRefund, exactIn ? (side == 1 ? 1 : 0) : 99);
                assertEq(input.allowance(user, address(market)), 0);
                _baselines();
            }
        }
        assertEq(cygld.balanceOf(OWNER), 4);
        assertEq(cygld.balanceOf(RECIPIENT), 2000);
        assertEq(counter.balanceOf(RECIPIENT), 2000);
    }

    function testExactInputSaleRoutesExplicitSAndRefundsDust() public {
        MarketSwapParams memory p = _params(MarketSide.SellCygld, true);
        MarketSwapResult memory r = _call(p, _native(cygld, p.amount), true);
        assertEq(r.swapInput, 1000);
        assertEq(r.inputRefund, 1);
        assertEq(cygld.balanceOf(user), 98_999);
        _baselines();
    }

    function testExactOutputReturnsOutputExcessToPayerNotRecipient() public {
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, false);
        p.data = abi.encode(uint256(1010), uint256(99));
        uint256 payerBefore = cygld.balanceOf(user);
        MarketSwapResult memory r = _call(p, _native(counter, p.bound), false);
        assertEq(r.outputRefund, 9);
        assertEq(cygld.balanceOf(user) - payerBefore, 9);
        assertEq(cygld.balanceOf(RECIPIENT), 1000);
        _baselines();
    }

    function testFavorableExactInputOutputIsUncappedAndOwnerIsLive() public {
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, true);
        p.data = abi.encode(uint256(1010), uint256(0));
        market.setOwner(user);
        p.recipient = user;
        MarketSwapResult memory r = _call(p, _native(counter, p.amount), true);
        assertEq(r.amountOut, 1009);
        assertEq(r.feeRecipient, user);
        assertEq(cygld.balanceOf(user), 101_010);
        _baselines();
    }

    function testOrdinaryAllowanceAndExternallyConsumedPermit() public {
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, true);
        FundingAuthorization memory auth = _native(counter, p.amount);
        IBasketRouterTypes.PermitParams memory signature = auth.nativePermit;
        counter.permit(
            user, address(market), signature.value, signature.deadline, signature.v, signature.r, signature.s
        );
        _call(p, auth, true);
        assertEq(counter.nonces(user), 1);
        vm.prank(user);
        counter.approve(address(market), p.amount);
        auth.mode = FundingMode.Allowance;
        _call(p, auth, true);
        _baselines();
    }

    function testPermit2FallbackHasIndependentSetupAndNonce() public {
        MarketSwapParams memory p = _params(MarketSide.SellCygld, false);
        vm.prank(user);
        cygld.approve(address(permit2), p.bound);
        FundingAuthorization memory auth;
        auth.mode = FundingMode.Permit2;
        auth.permit2.permit = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(address(cygld), p.bound), 42, block.timestamp + 60
        );
        MarketSwapResult memory r = _call(p, auth, false);
        assertEq(r.inputRefund, 99);
        assertTrue(permit2.used(user, 42));
        assertEq(cygld.allowance(user, address(market)), 0);
        _baselines();
    }

    function testNetSlippageRollsBackPermitFeeAndAllCustody() public {
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, true);
        p.bound = 1001;
        FundingAuthorization memory auth = _native(counter, p.amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.InsufficientOutputForMinAmountOut.selector,
                address(cygld),
                uint256(1002),
                uint256(1001)
            )
        );
        _call(p, auth, true);
        assertEq(counter.nonces(user), 0);
        assertEq(counter.balanceOf(user), 100_000);
        assertEq(cygld.balanceOf(OWNER), 0);
        assertEq(adapter.swapCallCount(), 0);
        _baselines();
    }

    function testNativeSignatureCannotPullAnUnrelatedPayer() public {
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, true);
        FundingAuthorization memory auth = _native(counter, p.amount);
        vm.expectRevert();
        vm.prank(address(0xBAD));
        market.swapExactInput(p, auth);
        assertEq(counter.balanceOf(user), 100_000);
        _baselines();
    }

    function testUnapprovedAdapterAndPauseUseExistingBoundaries() public {
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, true);
        FundingAuthorization memory auth = _native(counter, p.amount);
        p.adapter = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.AdapterNotApproved.selector, p.adapter));
        _call(p, auth, true);
        p.adapter = address(adapter);
        market.pause();
        vm.expectRevert();
        _call(p, auth, true);
        assertEq(counter.nonces(user), 0);
        _baselines();
    }

    function testPermitCallbackCannotReenterOtherMarketMode() public {
        AdversarialPermitToken evil = new AdversarialPermitToken();
        evil.mint(user, 100_000);
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, true);
        p.counterToken = address(evil);
        FundingAuthorization memory auth = _native(evil, p.amount);
        evil.configure(
            false,
            AdversarialPermitToken.TransferBehavior.Exact,
            address(market),
            abi.encodeCall(market.swapExactOutput, (p, auth))
        );
        _call(p, auth, true);
        assertTrue(evil.reentryBlocked());
    }

    function testLiteralZeroFeeRemainsPermissionlessPolicyBoundary() public {
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, true);
        p.feeCygld = 0;
        MarketSwapResult memory r = _call(p, _native(counter, p.amount), true);
        assertEq(r.amountOut, 1001);
        assertEq(cygld.balanceOf(OWNER), 0);
        _baselines();
    }

    function testInvalidEconomicsCannotConsumeOldCustodyOrPermit() public {
        MarketSwapParams memory p = _params(MarketSide.SellCygld, true);
        FundingAuthorization memory auth = _native(cygld, p.amount);
        p.routedInput = 1003;
        vm.expectRevert(
            abi.encodeWithSelector(IBasketRouterTypes.InvalidQuoteAmount.selector, uint256(1003), uint256(1001))
        );
        _call(p, auth, true);
        p = _params(MarketSide.BuyCygld, true);
        auth = _native(counter, p.amount);
        adapter.setReportedAmount(1002);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.AdapterOutputMismatch.selector,
                address(cygld),
                address(adapter),
                uint256(1002),
                uint256(1001)
            )
        );
        _call(p, auth, true);
        assertEq(counter.nonces(user), 0);
        assertEq(cygld.nonces(user), 0);
        _baselines();
    }

    function testInvalidEndpointsAmountAndExpiredIntentRetainOrdinaryErrors() public {
        MarketSwapParams memory p = _params(MarketSide.BuyCygld, true);
        FundingAuthorization memory auth = _native(counter, p.amount);
        p.counterToken = address(0);
        vm.expectRevert(IBasketRouterTypes.ZeroAddress.selector);
        _call(p, auth, true);
        p.counterToken = address(counter);
        p.recipient = address(0);
        vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
        _call(p, auth, true);
        p.recipient = RECIPIENT;
        p.amount = 0;
        vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
        _call(p, auth, true);
        p.amount = 1002;
        vm.warp(1000);
        p.deadline = 999;
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitExpired.selector, uint256(999), uint256(1000)));
        _call(p, auth, true);
        assertEq(counter.nonces(user), 0);
        _baselines();
    }

    // The test contract implements no market entrypoint; inherited types are used above.
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
