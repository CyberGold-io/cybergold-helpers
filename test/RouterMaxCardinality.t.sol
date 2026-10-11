// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";
import {MixedRedemptionCore} from "./BasketRouterRedeem.t.sol";
import {MintableToken, MockPermit2, MockSwapAdapterRouter, MockWETH} from "./mocks/BasketRouterMocks.sol";

/// @notice Generic mixed-redemption evidence at Core's complete 64-output settlement bound.
contract RouterMaxCardinalityTest is Test {
    uint256 private constant MAX_CORE_SETTLEMENT_ASSETS = 64;
    uint256 private constant RECOVERY_ASSET_COUNT = MAX_CORE_SETTLEMENT_ASSETS - 1;
    uint256 private constant MAX_PREVIEW_GAS = 2_000_000;
    uint256 private constant MAX_EXECUTION_GAS = 12_000_000;
    uint256 private constant GROSS_CYGLD_IN = 20 ether;

    address private constant USER = address(0xBEEF);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant OWNER = address(0xA11CE);

    MixedRedemptionCore private core;
    MintableToken private healthyAsset;
    ICyberGoldHelpers private router;

    function setUp() public {
        core = new MixedRedemptionCore();
        healthyAsset = new MintableToken("Healthy Asset", "HLT");
        MockPermit2 permit2 = new MockPermit2();
        MockWETH weth = new MockWETH();
        MockSwapAdapterRouter adapter = new MockSwapAdapterRouter();

        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = OWNER;
        cfg.coreDiamond = address(core);
        cfg.permit2 = address(permit2);
        cfg.wrappedNative = address(weth);
        cfg.approvedAdapters = new address[](1);
        cfg.approvedAdapters[0] = address(adapter);
        DeploymentTypes.DeployArtifacts memory artifacts = DeploymentHelper.deploy(cfg);
        router = ICyberGoldHelpers(address(artifacts.diamond));

        core.mint(USER, 100 ether);
        vm.prank(USER);
        core.approve(address(router), type(uint256).max);
        healthyAsset.mint(address(core), 1 ether);

        ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](MAX_CORE_SETTLEMENT_ASSETS);
        outputs[0] = ICoreRedemption.TokenAmount({
            kind: ICoreRedemption.TokenKind.ERC20, token: address(healthyAsset), id: 0, amount: 1 ether
        });
        for (uint256 i; i < RECOVERY_ASSET_COUNT; ++i) {
            uint256 id = i + 1;
            outputs[i + 1] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC1155, token: address(core), id: id, amount: 1 ether
            });
        }
        core.configureOutputs(outputs);
    }

    function testGenericMixedPreviewAndExecutionAtCoreMaxCombinedCardinality() public {
        IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
        IBasketRouterTypes.RedeemToTokenExactInParams memory params = IBasketRouterTypes.RedeemToTokenExactInParams({
            grossCygldIn: GROSS_CYGLD_IN, outputToken: address(healthyAsset)
        });

        uint256 gasBefore = gasleft();
        IBasketRouterTypes.AggregatedRedemptionPreview memory preview =
            router.previewRedeemToTokenExactIn(params, noLegs);
        uint256 previewGas = gasBefore - gasleft();
        assertEq(preview.projectedCoreOutputs.length, MAX_CORE_SETTLEMENT_ASSETS);
        assertEq(preview.minimumAmountOut, 1 ether);
        assertLe(previewGas, MAX_PREVIEW_GAS, "64-output mixed preview exceeds gas ceiling");

        ICoreRedemption.TokenMinimum[] memory expected = new ICoreRedemption.TokenMinimum[](MAX_CORE_SETTLEMENT_ASSETS);
        for (uint256 i; i < MAX_CORE_SETTLEMENT_ASSETS; ++i) {
            ICoreRedemption.TokenAmount memory output = preview.projectedCoreOutputs[i];
            expected[i] = ICoreRedemption.TokenMinimum({
                kind: output.kind, token: output.token, id: output.id, minimumAmount: output.amount
            });
        }
        IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
            grossCygldIn: GROSS_CYGLD_IN,
            outputToken: address(healthyAsset),
            recipient: RECIPIENT,
            minimumAmountOut: 1 ether,
            expectedCoreOutputs: expected
        });

        gasBefore = gasleft();
        vm.prank(USER);
        IBasketRouterTypes.AggregatedRedemptionResult memory result = router.redeemToTokenExactIn(request, noLegs);
        uint256 executionGas = gasBefore - gasleft();
        assertEq(result.amountOut, 1 ether);
        assertEq(result.recoveryShareOutputs.length, RECOVERY_ASSET_COUNT);
        assertEq(healthyAsset.balanceOf(RECIPIENT), 1 ether);
        for (uint256 i; i < RECOVERY_ASSET_COUNT; ++i) {
            uint256 id = i + 1;
            assertEq(result.recoveryShareOutputs[i].id, id);
            assertEq(core.balanceOf(RECIPIENT, id), 1 ether);
            assertEq(core.balanceOf(address(router), id), 0);
        }
        assertLe(executionGas, MAX_EXECUTION_GAS, "64-output mixed execution exceeds gas ceiling");
    }
}
