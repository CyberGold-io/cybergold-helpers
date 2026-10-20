// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ILegacyHelpers as ICyberGoldHelpers} from "./fixtures/legacy-exact-input/ILegacyHelpers.sol";
import {LegacyDeploymentHelper as DeploymentHelper} from "./fixtures/legacy-exact-input/LegacyDeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

import {
    IssueTestToken,
    IssueTestWeth,
    IssueTestPermit2,
    IssueTestCore,
    IssueTestAdapter
} from "./BasketRouterIssue.t.sol";
import {MixedRedemptionCore} from "./BasketRouterRedeem.t.sol";
import {MintableToken, MockPermit2, MockSwapAdapterRouter, MockWETH} from "./mocks/BasketRouterMocks.sol";

struct GenericRouteDependencies {
    ICyberGoldHelpers issueRouter;
    IssueTestToken issueAssetA;
    IssueTestToken issueAssetB;
    IssueTestWeth issueWeth;
    IssueTestCore issueCore;
    IssueTestAdapter issueAdapter;
    ICyberGoldHelpers redeemRouter;
    MixedRedemptionCore redeemCore;
    MintableToken redeemAssetA;
    MintableToken redeemAssetB;
    MintableToken redeemOutput;
    MockWETH redeemWeth;
    MockSwapAdapterRouter redeemAdapter;
}

/// @notice Stateful driver for only the retained generic issuance and mixed-redemption routes.
/// @dev Each action catches an unexpected route revert and records it as a permanent invariant failure.
contract GenericRoutesHandler {
    uint256 private constant PPM = 1_000_000;
    uint256 private constant HELPER_FEE_PPM = 1_000;
    uint256 private constant CORE_INPUT = 5 ether;
    uint256 private constant MAX_ACTION_AMOUNT = 100 ether;

    address public immutable feeOwner;
    address public immutable recipient;
    ICyberGoldHelpers public immutable issueRouter;
    IssueTestToken public immutable issueAssetA;
    IssueTestToken public immutable issueAssetB;
    IssueTestWeth public immutable issueWeth;
    IssueTestCore public immutable issueCore;
    IssueTestAdapter public immutable issueAdapter;
    ICyberGoldHelpers public immutable redeemRouter;
    MixedRedemptionCore public immutable redeemCore;
    MintableToken public immutable redeemAssetA;
    MintableToken public immutable redeemAssetB;
    MintableToken public immutable redeemOutput;
    MockWETH public immutable redeemWeth;
    MockSwapAdapterRouter public immutable redeemAdapter;

    uint256 public immutable shareIdA;
    uint256 public immutable shareIdB;

    uint256 public immutable issueAssetABaseline;
    uint256 public immutable issueAssetBBaseline;
    uint256 public immutable issueWethBaseline;
    uint256 public immutable issueCoreBaseline;
    uint256 public immutable redeemAssetABaseline;
    uint256 public immutable redeemAssetBBaseline;
    uint256 public immutable redeemOutputBaseline;
    uint256 public immutable redeemWethBaseline;
    uint256 public immutable redeemCoreBaseline;
    uint256 public immutable redeemShareABaseline;
    uint256 public immutable redeemShareBBaseline;

    bool public issuanceDustIsLocal = true;
    bool public issuanceFeesAreExact = true;
    bool public tokenConservationHolds = true;
    bool public nativeConservationHolds = true;
    bool public redemptionSettlementIsClean = true;
    bool public redemptionBindingIsExact = true;
    bool public positiveShareVectorIsOrdered = true;

    uint256 public issueTokenAttempts;
    uint256 public issueTokenSuccesses;
    uint256 public issueNativeAttempts;
    uint256 public issueNativeSuccesses;
    uint256 public redeemMixedAttempts;
    uint256 public redeemMixedSuccesses;
    uint256 public redeemNativeAttempts;
    uint256 public redeemNativeSuccesses;

    struct MixedRedemptionExpectations {
        uint256 grossCygldIn;
        uint256 amountOut;
        uint256 shareA;
        uint256 shareB;
        bytes32 expectedHash;
        uint256 payerBefore;
        uint256 ownerBefore;
        uint256 recipientTokenBefore;
        uint256 recipientShareABefore;
        uint256 recipientShareBBefore;
    }

    struct NativeRedemptionExpectations {
        uint256 grossCygldIn;
        uint256 amountOut;
        uint256 shareAmount;
        bytes32 expectedHash;
        uint256 payerBefore;
        uint256 ownerBefore;
        uint256 recipientNativeBefore;
        uint256 recipientShareBefore;
    }

    constructor(
        GenericRouteDependencies memory deps,
        address feeOwner_,
        address recipient_,
        uint256 shareIdA_,
        uint256 shareIdB_
    ) {
        feeOwner = feeOwner_;
        recipient = recipient_;
        issueRouter = deps.issueRouter;
        issueAssetA = deps.issueAssetA;
        issueAssetB = deps.issueAssetB;
        issueWeth = deps.issueWeth;
        issueCore = deps.issueCore;
        issueAdapter = deps.issueAdapter;
        redeemRouter = deps.redeemRouter;
        redeemCore = deps.redeemCore;
        redeemAssetA = deps.redeemAssetA;
        redeemAssetB = deps.redeemAssetB;
        redeemOutput = deps.redeemOutput;
        redeemWeth = deps.redeemWeth;
        redeemAdapter = deps.redeemAdapter;
        shareIdA = shareIdA_;
        shareIdB = shareIdB_;

        issueAssetABaseline = deps.issueAssetA.balanceOf(address(deps.issueRouter));
        issueAssetBBaseline = deps.issueAssetB.balanceOf(address(deps.issueRouter));
        issueWethBaseline = deps.issueWeth.balanceOf(address(deps.issueRouter));
        issueCoreBaseline = deps.issueCore.balanceOf(address(deps.issueRouter));
        redeemAssetABaseline = deps.redeemAssetA.balanceOf(address(deps.redeemRouter));
        redeemAssetBBaseline = deps.redeemAssetB.balanceOf(address(deps.redeemRouter));
        redeemOutputBaseline = deps.redeemOutput.balanceOf(address(deps.redeemRouter));
        redeemWethBaseline = deps.redeemWeth.balanceOf(address(deps.redeemRouter));
        redeemCoreBaseline = deps.redeemCore.balanceOf(address(deps.redeemRouter));
        redeemShareABaseline = deps.redeemCore.balanceOf(address(deps.redeemRouter), shareIdA_);
        redeemShareBBaseline = deps.redeemCore.balanceOf(address(deps.redeemRouter), shareIdB_);

        deps.issueAssetA.approve(address(deps.issueRouter), type(uint256).max);
        deps.redeemCore.approve(address(deps.redeemRouter), type(uint256).max);
    }

    receive() external payable {}

    /// @notice Exercise token issuance with independently fuzzed input allocation and adapter refund.
    function issueToken(uint256 netSeed, uint256 legSeed, uint256 refundSeed) external {
        ++issueTokenAttempts;
        uint256 netCygldOut = _bound(netSeed, 1, MAX_ACTION_AMOUNT);
        uint256 legAmount = _bound(legSeed, CORE_INPUT, 20 ether);
        uint256 adapterRefund = refundSeed % (legAmount + 1);
        uint256 maximumInput = CORE_INPUT + legAmount;

        IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
            inputToken: address(issueAssetA), maximumInputAmount: maximumInput, netCygldOut: netCygldOut
        });
        IBasketRouterTypes.IssueExecutionParams memory execution = _issueExecution();
        IBasketRouterTypes.IssueSwapLeg[] memory legs = new IBasketRouterTypes.IssueSwapLeg[](1);
        legs[0] = IBasketRouterTypes.IssueSwapLeg({
            adapter: address(issueAdapter),
            amountIn: legAmount,
            minimumAmountOut: CORE_INPUT,
            data: abi.encode(CORE_INPUT, adapterRefund)
        });

        uint256 payerBefore = issueAssetA.balanceOf(address(this));
        uint256 ownerBefore = issueCore.balanceOf(feeOwner);
        uint256 recipientBefore = issueCore.balanceOf(recipient);
        try issueRouter.issueFromTokenExactOut(params, execution, legs) returns (IBasketRouterTypes.Fees memory fees) {
            ++issueTokenSuccesses;
            (uint256 gross, uint256 expectedHelperFee) = _grossForNet(netCygldOut);
            issuanceFeesAreExact = issuanceFeesAreExact && fees.helperFeeCygld == expectedHelperFee
                && gross == netCygldOut + fees.helperFeeCygld
                && issueCore.balanceOf(feeOwner) - ownerBefore == expectedHelperFee
                && issueCore.balanceOf(recipient) - recipientBefore == netCygldOut;
            uint256 expectedUsed = CORE_INPUT + legAmount - adapterRefund;
            tokenConservationHolds =
                tokenConservationHolds && payerBefore - issueAssetA.balanceOf(address(this)) == expectedUsed;
            issuanceDustIsLocal = issuanceDustIsLocal && issueBaselinesIntact();
        } catch {
            issuanceDustIsLocal = false;
            issuanceFeesAreExact = false;
            tokenConservationHolds = false;
        }
    }

    /// @notice Exercise native issuance, including WETH normalization and operation-local native refunds.
    function issueNative(uint256 netSeed, uint256 firstLegSeed, uint256 secondLegSeed, uint256 refundSeed) external {
        ++issueNativeAttempts;
        uint256 netCygldOut = _bound(netSeed, 1, MAX_ACTION_AMOUNT);
        uint256 firstLegAmount = _bound(firstLegSeed, CORE_INPUT, 20 ether);
        uint256 secondLegAmount = _bound(secondLegSeed, CORE_INPUT, 20 ether);
        uint256 firstRefund = refundSeed % (firstLegAmount + 1);
        uint256 secondRefund = uint256(keccak256(abi.encode(refundSeed))) % (secondLegAmount + 1);
        uint256 maximumNative = firstLegAmount + secondLegAmount;

        IBasketRouterTypes.IssueFromNativeExactOutParams memory params = IBasketRouterTypes.IssueFromNativeExactOutParams({
            maximumNativeIn: maximumNative, netCygldOut: netCygldOut
        });
        IBasketRouterTypes.IssueSwapLeg[] memory legs = new IBasketRouterTypes.IssueSwapLeg[](2);
        legs[0] = IBasketRouterTypes.IssueSwapLeg({
            adapter: address(issueAdapter),
            amountIn: firstLegAmount,
            minimumAmountOut: CORE_INPUT,
            data: abi.encode(CORE_INPUT, firstRefund)
        });
        legs[1] = IBasketRouterTypes.IssueSwapLeg({
            adapter: address(issueAdapter),
            amountIn: secondLegAmount,
            minimumAmountOut: CORE_INPUT,
            data: abi.encode(CORE_INPUT, secondRefund)
        });

        uint256 payerNativeBefore = address(this).balance;
        uint256 ownerBefore = issueCore.balanceOf(feeOwner);
        uint256 recipientBefore = issueCore.balanceOf(recipient);
        try issueRouter.issueFromNativeExactOut{value: maximumNative}(params, _issueExecution(), legs) returns (
            IBasketRouterTypes.Fees memory fees
        ) {
            ++issueNativeSuccesses;
            (uint256 gross, uint256 expectedHelperFee) = _grossForNet(netCygldOut);
            issuanceFeesAreExact = issuanceFeesAreExact && fees.helperFeeCygld == expectedHelperFee
                && gross == netCygldOut + fees.helperFeeCygld
                && issueCore.balanceOf(feeOwner) - ownerBefore == expectedHelperFee
                && issueCore.balanceOf(recipient) - recipientBefore == netCygldOut;
            uint256 expectedUsed = maximumNative - firstRefund - secondRefund;
            nativeConservationHolds =
                nativeConservationHolds && payerNativeBefore - address(this).balance == expectedUsed;
            issuanceDustIsLocal = issuanceDustIsLocal && issueBaselinesIntact();
        } catch {
            issuanceDustIsLocal = false;
            issuanceFeesAreExact = false;
            nativeConservationHolds = false;
        }
    }

    /// @notice Exercise a mixed token redemption with structural-zero and positive recovery outputs.
    function redeemMixed(
        uint256 grossSeed,
        uint256 assetASeed,
        uint256 assetBSeed,
        uint256 shareASeed,
        uint256 shareBSeed
    ) external {
        ++redeemMixedAttempts;
        uint256 grossCygldIn = _bound(grossSeed, 1, MAX_ACTION_AMOUNT);
        uint256 amountA = assetASeed % (20 ether + 1);
        uint256 amountB = assetBSeed % (20 ether + 1);
        uint256 shareA = shareASeed % (20 ether + 1);
        uint256 shareB = shareBSeed % (20 ether + 1);
        if (amountA == 0 && amountB == 0 && shareA == 0 && shareB == 0) shareA = 1;

        ICoreRedemption.TokenAmount[] memory outputs = _mixedOutputs(amountA, amountB, shareA, shareB);
        redeemCore.configureOutputs(outputs);
        IBasketRouterTypes.RedemptionSwapLeg[] memory legs = _tokenRedemptionLegs(amountA, amountB);
        ICoreRedemption.TokenMinimum[] memory expected = _minimums(outputs);
        IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
            grossCygldIn: grossCygldIn,
            outputToken: address(redeemOutput),
            recipient: recipient,
            minimumAmountOut: amountA + amountB,
            expectedCoreOutputs: expected
        });

        MixedRedemptionExpectations memory expectedState = MixedRedemptionExpectations({
            grossCygldIn: grossCygldIn,
            amountOut: amountA + amountB,
            shareA: shareA,
            shareB: shareB,
            expectedHash: keccak256(abi.encode(expected)),
            payerBefore: redeemCore.balanceOf(address(this)),
            ownerBefore: redeemCore.balanceOf(feeOwner),
            recipientTokenBefore: redeemOutput.balanceOf(recipient),
            recipientShareABefore: redeemCore.balanceOf(recipient, shareIdA),
            recipientShareBBefore: redeemCore.balanceOf(recipient, shareIdB)
        });
        try redeemRouter.redeemToTokenExactIn(request, legs) returns (
            IBasketRouterTypes.AggregatedRedemptionResult memory result
        ) {
            ++redeemMixedSuccesses;
            _recordMixedRedemption(result, outputs, expectedState);
        } catch {
            tokenConservationHolds = false;
            redemptionSettlementIsClean = false;
            redemptionBindingIsExact = false;
            positiveShareVectorIsOrdered = false;
        }
    }

    /// @notice Exercise native redemption with one swapped and one direct WETH output plus recovery shares.
    function redeemNative(uint256 grossSeed, uint256 assetSeed, uint256 wethSeed, uint256 shareSeed) external {
        ++redeemNativeAttempts;
        uint256 grossCygldIn = _bound(grossSeed, 1, MAX_ACTION_AMOUNT);
        uint256 amountA = assetSeed % (20 ether + 1);
        uint256 wethAmount = wethSeed % (20 ether + 1);
        uint256 shareAmount = shareSeed % (20 ether + 1);
        if (amountA == 0 && wethAmount == 0 && shareAmount == 0) shareAmount = 1;

        ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](3);
        outputs[0] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC20, token: address(redeemAssetA), id: 0, amount: amountA
        });
        outputs[1] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC20, token: address(redeemWeth), id: 0, amount: wethAmount
        });
        outputs[2] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC1155, token: address(redeemCore), id: shareIdA, amount: shareAmount
        });
        redeemCore.configureOutputs(outputs);
        IBasketRouterTypes.RedemptionSwapLeg[] memory legs =
            new IBasketRouterTypes.RedemptionSwapLeg[](amountA == 0 ? 0 : 1);
        if (amountA != 0) {
            legs[0] = IBasketRouterTypes.RedemptionSwapLeg({
                adapter: address(redeemAdapter),
                minimumAmountOut: amountA,
                data: abi.encode(address(redeemWeth), amountA)
            });
        }
        ICoreRedemption.TokenMinimum[] memory expected = _minimums(outputs);
        IBasketRouterTypes.AggregatedNativeRedemptionRequest memory request =
            IBasketRouterTypes.AggregatedNativeRedemptionRequest({
                grossCygldIn: grossCygldIn,
                recipient: recipient,
                minimumAmountOut: amountA + wethAmount,
                expectedCoreOutputs: expected
            });

        NativeRedemptionExpectations memory expectedState = NativeRedemptionExpectations({
            grossCygldIn: grossCygldIn,
            amountOut: amountA + wethAmount,
            shareAmount: shareAmount,
            expectedHash: keccak256(abi.encode(expected)),
            payerBefore: redeemCore.balanceOf(address(this)),
            ownerBefore: redeemCore.balanceOf(feeOwner),
            recipientNativeBefore: recipient.balance,
            recipientShareBefore: redeemCore.balanceOf(recipient, shareIdA)
        });
        try redeemRouter.redeemToNativeExactIn(request, legs) returns (
            IBasketRouterTypes.AggregatedRedemptionResult memory result
        ) {
            ++redeemNativeSuccesses;
            _recordNativeRedemption(result, outputs, expectedState);
        } catch {
            nativeConservationHolds = false;
            tokenConservationHolds = false;
            redemptionSettlementIsClean = false;
            redemptionBindingIsExact = false;
            positiveShareVectorIsOrdered = false;
        }
    }

    function allActionsSucceeded() external view returns (bool) {
        return issueTokenAttempts == issueTokenSuccesses && issueNativeAttempts == issueNativeSuccesses
            && redeemMixedAttempts == redeemMixedSuccesses && redeemNativeAttempts == redeemNativeSuccesses;
    }

    function issueBaselinesIntact() public view returns (bool) {
        return issueAssetA.balanceOf(address(issueRouter)) == issueAssetABaseline
            && issueAssetB.balanceOf(address(issueRouter)) == issueAssetBBaseline
            && issueWeth.balanceOf(address(issueRouter)) == issueWethBaseline
            && issueCore.balanceOf(address(issueRouter)) == issueCoreBaseline;
    }

    function redeemBaselinesIntact() public view returns (bool) {
        return redeemAssetA.balanceOf(address(redeemRouter)) == redeemAssetABaseline
            && redeemAssetB.balanceOf(address(redeemRouter)) == redeemAssetBBaseline
            && redeemOutput.balanceOf(address(redeemRouter)) == redeemOutputBaseline
            && redeemWeth.balanceOf(address(redeemRouter)) == redeemWethBaseline
            && redeemCore.balanceOf(address(redeemRouter)) == redeemCoreBaseline
            && redeemCore.balanceOf(address(redeemRouter), shareIdA) == redeemShareABaseline
            && redeemCore.balanceOf(address(redeemRouter), shareIdB) == redeemShareBBaseline;
    }

    function _recordMixedRedemption(
        IBasketRouterTypes.AggregatedRedemptionResult memory result,
        ICoreRedemption.TokenAmount[] memory outputs,
        MixedRedemptionExpectations memory expectedState
    ) private {
        uint256 expectedHelperFee =
            expectedState.grossCygldIn * HELPER_FEE_PPM / PPM;
        tokenConservationHolds = tokenConservationHolds
            && expectedState.payerBefore - redeemCore.balanceOf(address(this)) == expectedState.grossCygldIn
            && redeemOutput.balanceOf(recipient) - expectedState.recipientTokenBefore == expectedState.amountOut;
        redemptionSettlementIsClean = redemptionSettlementIsClean && result.amountOut == expectedState.amountOut
            && result.fees.helperFeeCygld == expectedHelperFee
            && redeemCore.balanceOf(feeOwner) - expectedState.ownerBefore == expectedHelperFee
            && redeemBaselinesIntact();
        redemptionBindingIsExact =
            redemptionBindingIsExact && redeemCore.lastExpectedOutputsHash() == expectedState.expectedHash;
        positiveShareVectorIsOrdered = positiveShareVectorIsOrdered
            && _matchesPositiveShares(result.recoveryShareOutputs, outputs)
            && redeemCore.balanceOf(recipient, shareIdA) - expectedState.recipientShareABefore == expectedState.shareA
            && redeemCore.balanceOf(recipient, shareIdB) - expectedState.recipientShareBBefore == expectedState.shareB;
    }

    function _recordNativeRedemption(
        IBasketRouterTypes.AggregatedRedemptionResult memory result,
        ICoreRedemption.TokenAmount[] memory outputs,
        NativeRedemptionExpectations memory expectedState
    ) private {
        uint256 expectedHelperFee =
            expectedState.grossCygldIn * HELPER_FEE_PPM / PPM;
        nativeConservationHolds = nativeConservationHolds
            && recipient.balance - expectedState.recipientNativeBefore == expectedState.amountOut;
        tokenConservationHolds = tokenConservationHolds
            && expectedState.payerBefore - redeemCore.balanceOf(address(this)) == expectedState.grossCygldIn;
        redemptionSettlementIsClean = redemptionSettlementIsClean && result.amountOut == expectedState.amountOut
            && result.fees.helperFeeCygld == expectedHelperFee
            && redeemCore.balanceOf(feeOwner) - expectedState.ownerBefore == expectedHelperFee
            && redeemBaselinesIntact();
        redemptionBindingIsExact =
            redemptionBindingIsExact && redeemCore.lastExpectedOutputsHash() == expectedState.expectedHash;
        positiveShareVectorIsOrdered = positiveShareVectorIsOrdered
            && _matchesPositiveShares(result.recoveryShareOutputs, outputs)
            && redeemCore.balanceOf(recipient, shareIdA) - expectedState.recipientShareBefore
                == expectedState.shareAmount;
    }

    function _issueExecution() private view returns (IBasketRouterTypes.IssueExecutionParams memory execution) {
        execution.recipient = recipient;
        execution.expectedOrderedCoreAssets = new address[](2);
        execution.expectedOrderedCoreAssets[0] = address(issueAssetA);
        execution.expectedOrderedCoreAssets[1] = address(issueAssetB);
    }

    function _mixedOutputs(uint256 amountA, uint256 amountB, uint256 shareA, uint256 shareB)
        private
        view
        returns (ICoreRedemption.TokenAmount[] memory outputs)
    {
        outputs = new ICoreRedemption.TokenAmount[](4);
        outputs[0] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC20, token: address(redeemAssetA), id: 0, amount: amountA
        });
        outputs[1] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC20, token: address(redeemAssetB), id: 0, amount: amountB
        });
        outputs[2] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC1155, token: address(redeemCore), id: shareIdA, amount: shareA
        });
        outputs[3] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC1155, token: address(redeemCore), id: shareIdB, amount: shareB
        });
    }

    function _tokenRedemptionLegs(uint256 amountA, uint256 amountB)
        private
        view
        returns (IBasketRouterTypes.RedemptionSwapLeg[] memory legs)
    {
        uint256 count = (amountA == 0 ? 0 : 1) + (amountB == 0 ? 0 : 1);
        legs = new IBasketRouterTypes.RedemptionSwapLeg[](count);
        uint256 cursor;
        if (amountA != 0) {
            legs[cursor++] = IBasketRouterTypes.RedemptionSwapLeg({
                adapter: address(redeemAdapter),
                minimumAmountOut: amountA,
                data: abi.encode(address(redeemOutput), amountA)
            });
        }
        if (amountB != 0) {
            legs[cursor] = IBasketRouterTypes.RedemptionSwapLeg({
                adapter: address(redeemAdapter),
                minimumAmountOut: amountB,
                data: abi.encode(address(redeemOutput), amountB)
            });
        }
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

    function _matchesPositiveShares(
        ICoreRedemption.TokenAmount[] memory actual,
        ICoreRedemption.TokenAmount[] memory complete
    ) private pure returns (bool) {
        uint256 cursor;
        for (uint256 i; i < complete.length; ++i) {
            ICoreRedemption.TokenAmount memory output = complete[i];
            if (output.kind != ICoreRedemption.TokenKind.ERC1155 || output.amount == 0) continue;
            if (cursor == actual.length) return false;
            ICoreRedemption.TokenAmount memory retained = actual[cursor++];
            if (
                retained.kind != ICoreRedemption.TokenKind.ERC1155 || retained.token != output.token
                    || retained.id != output.id || retained.amount != output.amount
            ) return false;
        }
        return cursor == actual.length;
    }

    function _grossForNet(uint256 netCygldOut) private pure returns (uint256 gross, uint256 fee) {
        gross = ((netCygldOut - 1) * PPM) / (PPM - HELPER_FEE_PPM) + 1;
        fee = gross - netCygldOut;
    }

    function _bound(uint256 value, uint256 minimum, uint256 maximum) private pure returns (uint256) {
        return minimum + (value % (maximum - minimum + 1));
    }
}

/// @notice Bounded stateful and fuzz coverage for the retained generic Helpers API.
contract RouterGenericRoutesFuzzTest is StdInvariant, Test {
    uint256 private constant HELPER_FEE_PPM = 1_000;
    address private constant FEE_OWNER = address(0xA11CE);
    address private constant RECIPIENT = address(0xCAFE);
    uint256 private constant SHARE_ID_A = uint256(uint160(address(0x1000)));
    uint256 private constant SHARE_ID_B = uint256(uint160(address(0x2000)));
    bytes32 private constant RECOVERY_RECEIPT_SLOT = 0xb3f97b180a0a1d02be9ed9a6d933995b7bfe2281ea5507835729da1cc2e9a300;

    GenericRoutesHandler private handler;

    function setUp() public {
        GenericRouteDependencies memory deps = _deploySystems();
        _primeRouterBaselines(deps);
        handler = new GenericRoutesHandler(deps, FEE_OWNER, RECIPIENT, SHARE_ID_A, SHARE_ID_B);

        deps.issueAssetA.mint(address(handler), 1_000_000 ether);
        deps.issueAssetA.mint(address(deps.issueAdapter), 1_000_000 ether);
        deps.issueAssetB.mint(address(deps.issueAdapter), 1_000_000 ether);
        vm.deal(address(handler), 1_000_000 ether);

        deps.redeemCore.mint(address(handler), 1_000_000 ether);
        deps.redeemAssetA.mint(address(deps.redeemCore), 1_000_000 ether);
        deps.redeemAssetB.mint(address(deps.redeemCore), 1_000_000 ether);
        deps.redeemWeth.mint(address(deps.redeemCore), 1_000_000 ether);
        deps.redeemOutput.mint(address(deps.redeemAdapter), 1_000_000 ether);
        deps.redeemWeth.mint(address(deps.redeemAdapter), 1_000_000 ether);
        vm.deal(address(deps.redeemWeth), 2_000_000 ether);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = GenericRoutesHandler.issueToken.selector;
        selectors[1] = GenericRoutesHandler.issueNative.selector;
        selectors[2] = GenericRoutesHandler.redeemMixed.selector;
        selectors[3] = GenericRoutesHandler.redeemNative.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function testFuzzTokenIssuePreservesLocalDustAndExactFee(uint256 netSeed, uint256 legSeed, uint256 refundSeed)
        public
    {
        handler.issueToken(netSeed, legSeed, refundSeed);
        assertEq(handler.issueTokenAttempts(), 1);
        assertEq(handler.issueTokenSuccesses(), 1);
        assertTrue(handler.issuanceDustIsLocal());
        assertTrue(handler.issuanceFeesAreExact());
        assertTrue(handler.tokenConservationHolds());
        assertTrue(handler.issueBaselinesIntact());
    }

    function testFuzzNativeIssueConservesValueAndExactFee(
        uint256 netSeed,
        uint256 firstLegSeed,
        uint256 secondLegSeed,
        uint256 refundSeed
    ) public {
        handler.issueNative(netSeed, firstLegSeed, secondLegSeed, refundSeed);
        assertEq(handler.issueNativeAttempts(), 1);
        assertEq(handler.issueNativeSuccesses(), 1);
        assertTrue(handler.issuanceDustIsLocal());
        assertTrue(handler.issuanceFeesAreExact());
        assertTrue(handler.nativeConservationHolds());
        assertTrue(handler.issueBaselinesIntact());
    }

    function testFuzzMixedRedeemPreservesBindingAndPositiveShareOrder(
        uint256 grossSeed,
        uint256 assetASeed,
        uint256 assetBSeed,
        uint256 shareASeed,
        uint256 shareBSeed
    ) public {
        handler.redeemMixed(grossSeed, assetASeed, assetBSeed, shareASeed, shareBSeed);
        assertEq(handler.redeemMixedAttempts(), 1);
        assertEq(handler.redeemMixedSuccesses(), 1);
        _assertRedemptionProperties();
    }

    function testFuzzNativeRedeemConservesValueAndRestoresReceipt(
        uint256 grossSeed,
        uint256 assetSeed,
        uint256 wethSeed,
        uint256 shareSeed
    ) public {
        handler.redeemNative(grossSeed, assetSeed, wethSeed, shareSeed);
        assertEq(handler.redeemNativeAttempts(), 1);
        assertEq(handler.redeemNativeSuccesses(), 1);
        _assertRedemptionProperties();
        assertTrue(handler.nativeConservationHolds());
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 16
    function invariant_allGenericRouteActionsSucceed() public view {
        assertTrue(handler.allActionsSucceeded());
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 16
    function invariant_issuanceDustAndFeesStayOperationLocal() public view {
        assertTrue(handler.issuanceDustIsLocal());
        assertTrue(handler.issuanceFeesAreExact());
        assertTrue(handler.issueBaselinesIntact());
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 16
    function invariant_mixedRedemptionLeavesNoOperationAssets() public view {
        assertTrue(handler.redemptionSettlementIsClean());
        assertTrue(handler.redeemBaselinesIntact());
        _assertReceiptIdle();
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 16
    function invariant_bindingsShareOrderAndConservationHold() public view {
        assertTrue(handler.redemptionBindingIsExact());
        assertTrue(handler.positiveShareVectorIsOrdered());
        assertTrue(handler.tokenConservationHolds());
        assertTrue(handler.nativeConservationHolds());
    }

    function _assertRedemptionProperties() private view {
        assertTrue(handler.redemptionSettlementIsClean());
        assertTrue(handler.redemptionBindingIsExact());
        assertTrue(handler.positiveShareVectorIsOrdered());
        assertTrue(handler.redeemBaselinesIntact());
        _assertReceiptIdle();
    }

    function _assertReceiptIdle() private view {
        address router = address(handler.redeemRouter());
        assertEq(uint256(vm.load(router, RECOVERY_RECEIPT_SLOT)), 0, "receipt state/recipient not Idle");
        assertEq(uint256(vm.load(router, bytes32(uint256(RECOVERY_RECEIPT_SLOT) + 1))), 0, "receipt hash not cleared");
    }

    function _deploySystems() private returns (GenericRouteDependencies memory deps) {
        deps.issueAssetA = new IssueTestToken("Issue asset A", "IA");
        deps.issueAssetB = new IssueTestToken("Issue asset B", "IB");
        deps.issueWeth = new IssueTestWeth();
        IssueTestPermit2 issuePermit2 = new IssueTestPermit2();
        deps.issueCore = new IssueTestCore(address(deps.issueAssetA), address(deps.issueAssetB));
        deps.issueAdapter = new IssueTestAdapter();

        DeploymentTypes.DeployConfig memory issueCfg;
        issueCfg.admin = FEE_OWNER;
        issueCfg.coreDiamond = address(deps.issueCore);
        issueCfg.permit2 = address(issuePermit2);
        issueCfg.wrappedNative = address(deps.issueWeth);
        issueCfg.helperFeePpm = HELPER_FEE_PPM;
        issueCfg.approvedAdapters = new address[](1);
        issueCfg.approvedAdapters[0] = address(deps.issueAdapter);
        deps.issueRouter = ICyberGoldHelpers(address(DeploymentHelper.deploy(issueCfg).diamond));

        deps.redeemCore = new MixedRedemptionCore();
        deps.redeemAssetA = new MintableToken("Redeem asset A", "RA");
        deps.redeemAssetB = new MintableToken("Redeem asset B", "RB");
        deps.redeemOutput = new MintableToken("Redeem output", "RO");
        deps.redeemWeth = new MockWETH();
        MockPermit2 redeemPermit2 = new MockPermit2();
        deps.redeemAdapter = new MockSwapAdapterRouter();

        DeploymentTypes.DeployConfig memory redeemCfg;
        redeemCfg.admin = FEE_OWNER;
        redeemCfg.coreDiamond = address(deps.redeemCore);
        redeemCfg.permit2 = address(redeemPermit2);
        redeemCfg.wrappedNative = address(deps.redeemWeth);
        redeemCfg.helperFeePpm = HELPER_FEE_PPM;
        redeemCfg.approvedAdapters = new address[](1);
        redeemCfg.approvedAdapters[0] = address(deps.redeemAdapter);
        deps.redeemRouter = ICyberGoldHelpers(address(DeploymentHelper.deploy(redeemCfg).diamond));
    }

    function _primeRouterBaselines(GenericRouteDependencies memory deps) private {
        deps.issueAssetA.mint(address(deps.issueRouter), 11 ether);
        deps.issueAssetB.mint(address(deps.issueRouter), 13 ether);
        deps.issueWeth.mint(address(deps.issueRouter), 17 ether);
        deps.issueCore.mint(address(deps.issueRouter), 19 ether);

        deps.redeemAssetA.mint(address(deps.redeemRouter), 23 ether);
        deps.redeemAssetB.mint(address(deps.redeemRouter), 29 ether);
        deps.redeemOutput.mint(address(deps.redeemRouter), 31 ether);
        deps.redeemWeth.mint(address(deps.redeemRouter), 37 ether);
        deps.redeemCore.mint(address(deps.redeemRouter), 41 ether);
        deps.redeemCore.primeShare(address(deps.redeemRouter), SHARE_ID_A, 43 ether);
        deps.redeemCore.primeShare(address(deps.redeemRouter), SHARE_ID_B, 47 ether);
    }
}
