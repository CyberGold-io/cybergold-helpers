// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {ICygldApprovalCallback} from "cybergold-core/interfaces/ICygldApprovalCallback.sol";
import {ICygldOutflowCallback} from "cybergold-core/interfaces/ICygldOutflowCallback.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";
import {IRecoveryTypes} from "cybergold-core/interfaces/IRecoveryTypes.sol";
import {IRecoveryShareOutflowCallback} from "cybergold-core/interfaces/IRecoveryShareOutflowCallback.sol";
import {IRecoveryShareRedemptionCallback} from "cybergold-core/interfaces/IRecoveryShareRedemptionCallback.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {DeploymentHelper as CoreDeploymentHelper} from "cybergold-core/deploy/DeploymentHelper.sol";
import {DeploymentTypes as CoreDeploymentTypes} from "cybergold-core/deploy/DeploymentTypes.sol";

import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ILegacyHelpers as ICyberGoldHelpers} from "./fixtures/legacy-exact-input/ILegacyHelpers.sol";
import {
    LegacyDeploymentHelper as HelpersDeploymentHelper
} from "./fixtures/legacy-exact-input/LegacyDeploymentHelper.sol";
import {DeploymentTypes as HelpersDeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {MockERC20} from "shared/mocks/MockERC20.sol";
import {MockSafeWalletFactory} from "shared/helpers/MockSafeWallet.sol";
import {MockPermit2, MockSwapAdapterRouter} from "./mocks/BasketRouterMocks.sol";

/// @notice Production-Core regression token that becomes unusable after its exit entitlement is frozen.
contract UnreadableReserveToken is MockERC20 {
    bool private _unreadable;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function setUnreadable(bool unreadable_) external {
        _unreadable = unreadable_;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_unreadable) revert("unreadable reserve");
        return super.balanceOf(account);
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        if (_unreadable) revert("unreadable reserve");
        return super.approve(spender, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (_unreadable) revert("unreadable reserve");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (_unreadable) revert("unreadable reserve");
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Acceptance-critical integration between the retained generic Helpers routes and the real Core revision.
contract CoreHelpersFeeIntegrationTest is Test {
    uint256 private constant HELPER_FEE_PPM = 2_000;
    uint256 private constant ISSUANCE_FEE_PPM = 5_000;
    uint256 private constant REDEMPTION_FEE_PPM = 10_000;
    uint256 private constant PPM_DENOMINATOR = 1_000_000;

    address private constant USER = address(0xBEEF);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant CORE_TREASURY = address(0xC0A7);
    address private constant HELPERS_OWNER = address(0xA11CE);

    MockERC20 private assetA;
    UnreadableReserveToken private assetB;
    MockERC20 private assetC;
    MockERC20 private wrappedNative;
    MockSwapAdapterRouter private adapter;
    MockPermit2 private permit2;
    ICyberGoldCore private core;
    ICyberGoldHelpers private helpers;
    address private coreSafeWallet;

    function setUp() public {
        assetA = new MockERC20("Gold A", "GLDA", 18);
        assetB = new UnreadableReserveToken("Gold B", "GLDB", 18);
        assetC = new MockERC20("Gold C", "GLDC", 18);
        wrappedNative = new MockERC20("Wrapped native", "WNATIVE", 18);

        CoreDeploymentTypes.DeployConfig memory coreConfig;
        coreConfig.admin = address(this);
        coreSafeWallet = MockSafeWalletFactory.deploy(address(this));
        coreConfig.safeWallet = coreSafeWallet;
        coreConfig.name = "CyberGold";
        coreConfig.symbol = "CYGLD";
        coreConfig.coreTreasury = CORE_TREASURY;
        coreConfig.basketAssets = new address[](2);
        coreConfig.basketAssets[0] = address(assetA);
        coreConfig.basketAssets[1] = address(assetB);
        coreConfig.basketTargetsPpm = new uint256[](2);
        coreConfig.basketTargetsPpm[0] = 500_000;
        coreConfig.basketTargetsPpm[1] = 500_000;
        coreConfig.basketGoldRefGramsFp18 = new uint256[](2);
        coreConfig.basketGoldRefGramsFp18[0] = 1 ether;
        coreConfig.basketGoldRefGramsFp18[1] = 1 ether;
        coreConfig.cygldRefGramsFp18 = 1 ether;
        coreConfig.maxTotalSupply = 250 ether;
        coreConfig.issuanceFeePpm = ISSUANCE_FEE_PPM;
        coreConfig.redemptionFeePpm = REDEMPTION_FEE_PPM;
        core = ICyberGoldCore(address(CoreDeploymentHelper.deploy(coreConfig).diamond));

        adapter = new MockSwapAdapterRouter();
        permit2 = new MockPermit2();
        HelpersDeploymentTypes.DeployConfig memory helpersConfig;
        helpersConfig.admin = HELPERS_OWNER;
        helpersConfig.coreDiamond = address(core);
        helpersConfig.permit2 = address(permit2);
        helpersConfig.wrappedNative = address(wrappedNative);
        helpersConfig.helperFeePpm = HELPER_FEE_PPM;
        helpersConfig.approvedAdapters = new address[](1);
        helpersConfig.approvedAdapters[0] = address(adapter);
        helpers = ICyberGoldHelpers(address(HelpersDeploymentHelper.deploy(helpersConfig).diamond));

        vm.prank(coreSafeWallet);
        core.unpause();

        assetA.mint(USER, 1_000 ether);
        assetB.mint(USER, 1_000 ether);
        assetA.mint(address(adapter), 1_000 ether);
        assetB.mint(address(adapter), 1_000 ether);
        assetC.mint(USER, 1_000 ether);
        assetC.mint(address(adapter), 1_000 ether);
        vm.startPrank(USER);
        assetA.approve(address(core), type(uint256).max);
        assetB.approve(address(core), type(uint256).max);
        core.issue(100 ether);
        vm.stopPrank();
    }

    function testRealCoreDirectBasketIssueAndRedeemAmountDirections() public {
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        uint256[] memory budgets = new uint256[](2);
        budgets[0] = 10 ether;
        budgets[1] = 10 ether;

        IBasketRouterTypes.BasketIssueExactInPreview memory exactInIssue =
            helpers.previewIssueFromBasketExactIn(budgets);
        uint256 recipientCygldBefore = IERC20(address(core)).balanceOf(RECIPIENT);
        vm.startPrank(USER);
        assetA.approve(address(permit2), type(uint256).max);
        assetB.approve(address(permit2), type(uint256).max);
        IBasketRouterTypes.BasketIssueResult memory exactInResult = helpers.issueFromBasketExactInWithPermit2(
            IBasketRouterTypes.BasketIssueExactInRequest({
                recipient: RECIPIENT, minimumNetCygldOut: exactInIssue.netCygldOut
            }),
            _batchPermit(assets, budgets, 101)
        );
        vm.stopPrank();
        assertEq(exactInResult.netCygldOut, exactInIssue.netCygldOut);
        assertEq(exactInResult.actualAmountsIn, exactInIssue.amountsInExact);
        assertEq(IERC20(address(core)).balanceOf(RECIPIENT), recipientCygldBefore + exactInIssue.netCygldOut);

        IBasketRouterTypes.BasketIssueExactOutPreview memory exactOutIssue =
            helpers.previewIssueFromBasketExactOut(5 ether);
        vm.prank(USER);
        IBasketRouterTypes.BasketIssueResult memory exactOutResult = helpers.issueFromBasketExactOutWithPermit2(
            IBasketRouterTypes.BasketIssueExactOutRequest({netCygldOut: 5 ether, recipient: RECIPIENT}),
            _batchPermit(assets, exactOutIssue.amountsInExact, 102)
        );
        assertEq(exactOutResult.netCygldOut, 5 ether);
        assertEq(exactOutResult.actualAmountsIn, exactOutIssue.amountsInExact);

        IBasketRouterTypes.BasketRedemptionExactInPreview memory exactInRedeem =
            helpers.previewRedeemToBasketExactIn(10 ether);
        IBasketRouterTypes.BasketRedemptionExactOutPreview memory exactOutRedeem =
            helpers.previewRedeemToBasketExactOut(_minimums(exactInRedeem.projectedCoreOutputs));
        uint256 recipientAssetABefore = assetA.balanceOf(RECIPIENT);
        uint256 recipientAssetBBefore = assetB.balanceOf(RECIPIENT);
        vm.startPrank(USER);
        IERC20(address(core)).approve(address(helpers), exactOutRedeem.grossCygldIn);
        IBasketRouterTypes.BasketRedemptionResult memory redeemResult = helpers.redeemToBasketExactIn(
            IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: exactOutRedeem.grossCygldIn,
                recipient: RECIPIENT,
                expectedCoreOutputs: _minimums(exactOutRedeem.projectedCoreOutputs)
            })
        );
        vm.stopPrank();
        assertEq(redeemResult.outputs.length, 2);
        assertEq(assetA.balanceOf(RECIPIENT) - recipientAssetABefore, redeemResult.outputs[0].amount);
        assertEq(assetB.balanceOf(RECIPIENT) - recipientAssetBBefore, redeemResult.outputs[1].amount);
        assertEq(IERC20(address(core)).balanceOf(address(helpers)), 0);
        assertEq(assetA.balanceOf(address(helpers)), 0);
        assertEq(assetB.balanceOf(address(helpers)), 0);
    }

    function testHelpersIsCodeBearingAndDoesNotAdvertiseProtectedAccountCallbacks() public view {
        assertGt(address(helpers).code.length, 0);
        IERC165 interfaceView = IERC165(address(helpers));
        assertFalse(interfaceView.supportsInterface(type(ICygldOutflowCallback).interfaceId));
        assertFalse(interfaceView.supportsInterface(type(ICygldApprovalCallback).interfaceId));
        assertFalse(interfaceView.supportsInterface(type(IRecoveryShareOutflowCallback).interfaceId));
        assertFalse(interfaceView.supportsInterface(type(IRecoveryShareRedemptionCallback).interfaceId));
    }

    function testRealCoreGenericIssueAndRedeemPreserveBothFeeLayers() public {
        uint256 requestedNetCygld = 5 ether;
        uint256 coreNetCygld = _grossForNet(requestedNetCygld, HELPER_FEE_PPM);
        (, uint256[] memory required, address[] memory assets) = core.previewIssueFromBasketExactOut(coreNetCygld);
        IBasketRouterTypes.IssueSwapLeg[] memory issueLegs = new IBasketRouterTypes.IssueSwapLeg[](1);
        issueLegs[0] = IBasketRouterTypes.IssueSwapLeg({
            adapter: address(adapter),
            amountIn: required[1],
            minimumAmountOut: required[1],
            data: abi.encode(address(assetB), required[1])
        });
        IBasketRouterTypes.IssueFromTokenExactOutParams memory issueParams =
            IBasketRouterTypes.IssueFromTokenExactOutParams({
                inputToken: address(assetA),
                maximumInputAmount: required[0] + required[1],
                netCygldOut: requestedNetCygld
            });
        IBasketRouterTypes.IssueExactOutPreview memory issuePreview =
            helpers.previewIssueFromTokenExactOut(issueParams, issueLegs);
        assertGt(issuePreview.fees.protocolFeeCygld, 0);
        assertGt(issuePreview.fees.helperFeeCygld, 0);

        uint256 recipientCygldBefore = IERC20(address(core)).balanceOf(RECIPIENT);
        uint256 protocolTreasuryBefore = IERC20(address(core)).balanceOf(CORE_TREASURY);
        uint256 helperOwnerBefore = IERC20(address(core)).balanceOf(HELPERS_OWNER);
        // Two issuance payouts plus the redemption helper-fee payout and CYGLD burn
        // each probe the code-bearing Helpers account with the frozen stipend.
        _expectExactProbe(type(ICygldOutflowCallback).interfaceId, 4);
        vm.startPrank(USER);
        assetA.approve(address(helpers), issueParams.maximumInputAmount);
        IBasketRouterTypes.Fees memory issueFees = helpers.issueFromTokenExactOut(
            issueParams,
            IBasketRouterTypes.IssueExecutionParams({recipient: RECIPIENT, expectedOrderedCoreAssets: assets}),
            issueLegs
        );
        vm.stopPrank();
        assertEq(IERC20(address(core)).balanceOf(RECIPIENT), recipientCygldBefore + requestedNetCygld);
        assertEq(issueFees.protocolFeeCygld, issuePreview.fees.protocolFeeCygld);
        assertEq(issueFees.helperFeeCygld, issuePreview.fees.helperFeeCygld);
        assertEq(IERC20(address(core)).balanceOf(CORE_TREASURY), protocolTreasuryBefore + issueFees.protocolFeeCygld);
        assertEq(IERC20(address(core)).balanceOf(HELPERS_OWNER), helperOwnerBefore + issueFees.helperFeeCygld);

        uint256 grossCygldIn = 10 ether;
        IBasketRouterTypes.AggregatedRedemptionPreview memory redeemPreview = _redemptionPreview(grossCygldIn);
        assertGt(redeemPreview.fees.protocolFeeCygld, 0);
        assertEq(redeemPreview.fees.helperFeeCygld, grossCygldIn * HELPER_FEE_PPM / PPM_DENOMINATOR);
        IBasketRouterTypes.RedemptionSwapLeg[] memory redeemLegs = _redemptionLegs(redeemPreview);
        IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
            grossCygldIn: grossCygldIn,
            outputToken: address(assetA),
            recipient: RECIPIENT,
            minimumAmountOut: redeemPreview.minimumAmountOut,
            expectedCoreOutputs: _minimums(redeemPreview.projectedCoreOutputs)
        });
        uint256 recipientAssetBefore = assetA.balanceOf(RECIPIENT);
        protocolTreasuryBefore = IERC20(address(core)).balanceOf(CORE_TREASURY);
        helperOwnerBefore = IERC20(address(core)).balanceOf(HELPERS_OWNER);
        uint256 totalSupplyBefore = core.totalSupply();
        vm.startPrank(USER);
        IERC20(address(core)).approve(address(helpers), grossCygldIn);
        IBasketRouterTypes.AggregatedRedemptionResult memory result = helpers.redeemToTokenExactIn(request, redeemLegs);
        vm.stopPrank();
        assertEq(result.amountOut, redeemPreview.minimumAmountOut);
        assertEq(result.fees.protocolFeeCygld, redeemPreview.fees.protocolFeeCygld);
        assertEq(result.fees.helperFeeCygld, redeemPreview.fees.helperFeeCygld);
        assertEq(assetA.balanceOf(RECIPIENT), recipientAssetBefore + result.amountOut);
        assertEq(IERC20(address(core)).balanceOf(CORE_TREASURY), protocolTreasuryBefore + result.fees.protocolFeeCygld);
        assertEq(IERC20(address(core)).balanceOf(HELPERS_OWNER), helperOwnerBefore + result.fees.helperFeeCygld);
        assertEq(
            core.totalSupply(),
            totalSupplyBefore - (grossCygldIn - result.fees.helperFeeCygld - result.fees.protocolFeeCygld)
        );
        assertEq(IERC20(address(core)).balanceOf(address(helpers)), 0);
        assertEq(assetA.balanceOf(address(helpers)), 0);
        assertEq(assetB.balanceOf(address(helpers)), 0);
    }

    function testRealCoreImpairedAssetRedeemsAsCurrentStateRecoverySharesThroughGenericRoute() public {
        _activateAssetARecovery();
        uint256 grossCygldIn = 20 ether;
        IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
        IBasketRouterTypes.AggregatedRedemptionPreview memory preview = helpers.previewRedeemToTokenExactIn(
            IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: grossCygldIn, outputToken: address(assetB)}),
            noLegs
        );
        assertEq(preview.projectedCoreOutputs.length, 2);
        assertEq(uint256(preview.projectedCoreOutputs[0].kind), uint256(ICoreRedemption.TokenKind.ERC20));
        assertEq(preview.projectedCoreOutputs[0].token, address(assetB));
        assertEq(uint256(preview.projectedCoreOutputs[1].kind), uint256(ICoreRedemption.TokenKind.ERC1155));
        assertEq(preview.projectedCoreOutputs[1].token, address(core));
        assertEq(preview.projectedCoreOutputs[1].id, uint256(uint160(address(assetA))));
        assertGt(preview.projectedCoreOutputs[1].amount, 0);

        IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
            grossCygldIn: grossCygldIn,
            outputToken: address(assetB),
            recipient: RECIPIENT,
            minimumAmountOut: preview.minimumAmountOut,
            expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
        });
        _expectExactProbe(type(ICygldOutflowCallback).interfaceId, 2);
        _expectExactProbe(type(IRecoveryShareOutflowCallback).interfaceId, 1);
        vm.startPrank(USER);
        IERC20(address(core)).approve(address(helpers), grossCygldIn);
        IBasketRouterTypes.AggregatedRedemptionResult memory result = helpers.redeemToTokenExactIn(request, noLegs);
        vm.stopPrank();

        assertEq(result.amountOut, preview.minimumAmountOut);
        assertEq(result.recoveryShareOutputs.length, 1);
        assertEq(result.recoveryShareOutputs[0].id, uint256(uint160(address(assetA))));
        assertEq(result.recoveryShareOutputs[0].amount, preview.projectedCoreOutputs[1].amount);
        assertEq(core.balanceOf(RECIPIENT, uint256(uint160(address(assetA)))), result.recoveryShareOutputs[0].amount);
        assertEq(core.balanceOf(address(helpers), uint256(uint160(address(assetA)))), 0);
    }

    function testHelpersCygldOutflowHasNoPreProbeGasThreshold() public {
        vm.prank(USER);
        assertTrue(IERC20(address(core)).transfer(address(helpers), 1 ether));

        _assertThresholdFreeMinimumCallerGas(
            abi.encodeCall(IERC20.transfer, (RECIPIENT, 1 ether)), type(ICygldOutflowCallback).interfaceId
        );
        assertEq(IERC20(address(core)).balanceOf(address(helpers)), 1 ether);
        assertEq(IERC20(address(core)).balanceOf(RECIPIENT), 0);
    }

    function testHelpersRecoveryShareOutflowHasNoPreProbeGasThreshold() public {
        _activateAssetARecovery();
        uint256 shareId = uint256(uint160(address(assetA)));
        dealERC1155(address(core), address(helpers), shareId, 2);

        _assertThresholdFreeMinimumCallerGas(
            abi.encodeCall(ICyberGoldCore.safeTransferFrom, (address(helpers), RECIPIENT, shareId, 1, "")),
            type(IRecoveryShareOutflowCallback).interfaceId
        );
        assertEq(core.balanceOf(address(helpers), shareId), 2);
        assertEq(core.balanceOf(RECIPIENT, shareId), 0);
    }

    function testRealCoreOneAssetExactInPreviewNeedsNoSwapLeg() public {
        // Clean launch requires two positive targets. Recovery activation is the supported
        // production transition that can leave one current issuance asset.
        _activateAssetARecovery();

        IBasketRouterTypes.IssueSwapLeg[] memory noLegs = new IBasketRouterTypes.IssueSwapLeg[](0);
        IBasketRouterTypes.IssueExactInPreview memory preview = helpers.previewIssueFromTokenExactIn(
            IBasketRouterTypes.IssueFromTokenExactInParams({inputToken: address(assetB), inputAmount: 10 ether}), noLegs
        );
        assertGt(preview.netCygldOut, 0);
        assertEq(preview.orderedCoreAssets.length, 1);
        assertEq(preview.orderedCoreAssets[0], address(assetB));
    }

    function testRealCoreExitingUnreadableAssetDoesNotBlockGenericIssuance() public {
        _beginAssetBExitAndDisableReads();

        IBasketRouterTypes.IssueSwapLeg[] memory legs = new IBasketRouterTypes.IssueSwapLeg[](1);
        legs[0] = IBasketRouterTypes.IssueSwapLeg({
            adapter: address(adapter),
            amountIn: 3 ether,
            minimumAmountOut: 3 ether,
            data: abi.encode(address(assetC), 3 ether)
        });
        IBasketRouterTypes.IssueExactInPreview memory preview = helpers.previewIssueFromTokenExactIn(
            IBasketRouterTypes.IssueFromTokenExactInParams({inputToken: address(assetA), inputAmount: 10 ether}), legs
        );
        assertGt(preview.netCygldOut, 0);
        assertEq(preview.orderedCoreAssets.length, 3);
        assertEq(core.basketTargetsPpm()[1], 0);

        uint256 recipientBefore = IERC20(address(core)).balanceOf(RECIPIENT);
        vm.startPrank(USER);
        assetA.approve(address(helpers), 10 ether);
        helpers.issueFromTokenExactOut(
            IBasketRouterTypes.IssueFromTokenExactOutParams({
                inputToken: address(assetA), maximumInputAmount: 10 ether, netCygldOut: preview.netCygldOut
            }),
            IBasketRouterTypes.IssueExecutionParams({
                recipient: RECIPIENT, expectedOrderedCoreAssets: preview.orderedCoreAssets
            }),
            legs
        );
        vm.stopPrank();
        assertEq(IERC20(address(core)).balanceOf(RECIPIENT), recipientBefore + preview.netCygldOut);
    }

    function testRealCoreExitingUnreadableAssetDoesNotBlockDirectBasketIssuance() public {
        _beginAssetBExitAndDisableReads();

        address[] memory assets = core.basketAssets();
        uint256[] memory budgets = new uint256[](3);
        budgets[0] = 10 ether;
        budgets[1] = 123 ether;
        budgets[2] = 10 ether;
        IBasketRouterTypes.BasketIssueExactInPreview memory preview = helpers.previewIssueFromBasketExactIn(budgets);
        assertEq(preview.amountsInExact[1], 0);

        vm.startPrank(USER);
        assetA.approve(address(permit2), type(uint256).max);
        assetC.approve(address(permit2), type(uint256).max);
        IBasketRouterTypes.BasketIssueResult memory result = helpers.issueFromBasketExactInWithPermit2(
            IBasketRouterTypes.BasketIssueExactInRequest({
                recipient: RECIPIENT, minimumNetCygldOut: preview.netCygldOut
            }),
            _batchPermit(assets, budgets, 201)
        );
        vm.stopPrank();
        assertEq(result.netCygldOut, preview.netCygldOut);
        assertEq(result.actualAmountsIn[1], 0);
    }

    function _redemptionPreview(uint256 grossCygldIn)
        private
        view
        returns (IBasketRouterTypes.AggregatedRedemptionPreview memory preview)
    {
        uint256 helperFee = grossCygldIn * HELPER_FEE_PPM / PPM_DENOMINATOR;
        ICoreRedemption.RedemptionQuote memory corePreview = core.previewRedeemExactIn(grossCygldIn - helperFee);
        IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
        legs[0] = IBasketRouterTypes.RedemptionSwapLeg({
            adapter: address(adapter),
            minimumAmountOut: corePreview.outputs[1].amount,
            data: abi.encode(address(assetA), corePreview.outputs[1].amount)
        });
        preview = helpers.previewRedeemToTokenExactIn(
            IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: grossCygldIn, outputToken: address(assetA)}),
            legs
        );
    }

    function _redemptionLegs(IBasketRouterTypes.AggregatedRedemptionPreview memory preview)
        private
        view
        returns (IBasketRouterTypes.RedemptionSwapLeg[] memory legs)
    {
        legs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
        legs[0] = IBasketRouterTypes.RedemptionSwapLeg({
            adapter: address(adapter),
            minimumAmountOut: preview.projectedCoreOutputs[1].amount,
            data: abi.encode(address(assetA), preview.projectedCoreOutputs[1].amount)
        });
    }

    function _activateAssetARecovery() private {
        vm.prank(address(core));
        assertTrue(assetA.transfer(address(0xDEAD), 20 ether));
        core.pause();

        address[] memory replacementAssets = new address[](1);
        replacementAssets[0] = address(assetB);
        uint256[] memory replacementTargets = new uint256[](1);
        replacementTargets[0] = PPM_DENOMINATOR;
        uint256[] memory replacementRefs = new uint256[](1);
        replacementRefs[0] = 1 ether;
        bytes32 expectedBasketHash = core.basketConfigHash();
        uint256 expectedEntitlementRaw = assetA.balanceOf(address(core));
        vm.prank(coreSafeWallet);
        core.activateRecovery(
            IRecoveryTypes.RecoveryActivation({
                impairedAsset: address(assetA),
                expectedLifecycle: IRecoveryTypes.ReserveLifecycle.Active,
                expectedBasketHash: expectedBasketHash,
                expectedEntitlementRaw: expectedEntitlementRaw,
                replacementBasketAssets: replacementAssets,
                replacementTargetsPpm: replacementTargets,
                replacementGoldRefGramsFp18: replacementRefs,
                cygldSupplyCap: 200 ether
            })
        );
        vm.prank(coreSafeWallet);
        core.unpause();
    }

    function _beginAssetBExitAndDisableReads() private {
        core.pause();
        address[] memory activationAssets = new address[](3);
        activationAssets[0] = address(assetA);
        activationAssets[1] = address(assetB);
        activationAssets[2] = address(assetC);
        uint256[] memory activationTargets = new uint256[](3);
        activationTargets[0] = 400_000;
        activationTargets[1] = 300_000;
        activationTargets[2] = 300_000;
        uint256[] memory activationReferences = new uint256[](3);
        activationReferences[0] = 1 ether;
        activationReferences[1] = 1 ether;
        activationReferences[2] = 1 ether;
        bytes32 activationBasketHash = core.basketConfigHash();
        vm.prank(coreSafeWallet);
        core.activateAsset(
            IRecoveryTypes.AssetActivationRequest({
                asset: address(assetC),
                expectedLifecycle: IRecoveryTypes.ReserveLifecycle.Inactive,
                expectedBasketHash: activationBasketHash,
                expectedActiveAvailableRaw: 0,
                resultingBasketAssets: activationAssets,
                resultingTargetsPpm: activationTargets,
                resultingGoldRefGramsFp18: activationReferences
            })
        );

        address[] memory assets = core.basketAssets();
        uint256[] memory targets = core.basketTargetsPpm();
        uint256[] memory goldReferences = core.basketGoldRefGramsFp18();
        uint256 exitEntitlementRaw = assetB.balanceOf(address(core));
        targets[0] += targets[1];
        targets[1] = 0;
        bytes32 exitBasketHash = core.basketConfigHash();
        vm.prank(coreSafeWallet);
        core.beginReserveExit(
            IRecoveryTypes.ReserveExitRequest({
                asset: address(assetB),
                expectedBasketHash: exitBasketHash,
                expectedExitEntitlementRaw: exitEntitlementRaw,
                resultingBasketAssets: assets,
                resultingTargetsPpm: targets,
                resultingGoldRefGramsFp18: goldReferences
            })
        );
        vm.prank(coreSafeWallet);
        core.unpause();
        assetB.setUnreadable(true);
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

    function _grossForNet(uint256 netAmount, uint256 feePpm) private pure returns (uint256) {
        return ((netAmount - 1) * PPM_DENOMINATOR) / (PPM_DENOMINATOR - feePpm) + 1;
    }

    function _batchPermit(address[] memory assets, uint256[] memory ceilings, uint256 nonce)
        private
        view
        returns (IBasketRouterTypes.Permit2BatchParams memory params)
    {
        params.permit.permitted = new ISignatureTransfer.TokenPermissions[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            params.permit.permitted[i] = ISignatureTransfer.TokenPermissions({token: assets[i], amount: ceilings[i]});
        }
        params.permit.nonce = nonce;
        params.permit.deadline = block.timestamp + 1 days;
        params.signature = hex"01";
    }

    function _expectExactProbe(bytes4 interfaceId, uint64 count) private {
        vm.expectCall(address(helpers), 0, 30_000, abi.encodeCall(IERC165.supportsInterface, (interfaceId)), count);
    }

    function _assertThresholdFreeMinimumCallerGas(bytes memory callData, bytes4 interfaceId) private {
        uint256 low = 1;
        uint256 high = 250_000;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            (bool success,) = _callCoreFromHelpersWithSnapshot(callData, mid);
            if (success) high = mid;
            else low = mid + 1;
        }

        vm.expectCall(address(helpers), abi.encodeCall(IERC165.supportsInterface, (interfaceId)));
        (bool exactSuccess,) = _callCoreFromHelpersWithSnapshot(callData, low);
        assertTrue(exactSuccess, "minimum successful caller gas must complete without a probe threshold");

        vm.prank(address(helpers));
        (bool oneLessSuccess, bytes memory oneLessReturnData) = address(core).call{gas: low - 1}(callData);
        assertFalse(oneLessSuccess, "one gas below the complete operation minimum must fail atomically");
        assertEq(oneLessReturnData.length, 0, "one-less failure must be natural OOG, not a typed probe checkpoint");
    }

    function _callCoreFromHelpersWithSnapshot(bytes memory callData, uint256 gasLimit)
        private
        returns (bool success, bytes memory returnData)
    {
        uint256 snapshot = vm.snapshotState();
        vm.prank(address(helpers));
        (success, returnData) = address(core).call{gas: gasLimit}(callData);
        assertTrue(vm.revertToStateAndDelete(snapshot));
    }
}
