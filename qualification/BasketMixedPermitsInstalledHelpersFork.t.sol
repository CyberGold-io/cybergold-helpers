// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";

/// @notice Mixed basket qualification on the actual installed Helpers after the owned Anvil basket cut.
/// @dev No substitute Helpers, Core, token or Permit2 is deployed. Direct basket issuance uses no swap venue.
contract BasketMixedPermitsInstalledHelpersForkTest is Test {
    address private constant CORE = 0x601da021cAF3DB5AA63e700D239b5935C370601d;
    address private constant HELPERS = 0x30e9aFD21A30B2629BE33508A131AC890368f534;
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address private constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant POOL = 0xc756BBA710d45647715079cE50aa16aab36deD42;
    uint256 private constant TARGET_CYGLD = 1 ether;
    bytes32 private constant BASKET_NAMESPACE = keccak256("cybergold.helpers.issue.basket");
    bytes32 private constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.owner");
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 private constant BATCH_TYPEHASH = keccak256(
        "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    struct EconomicSnapshot {
        uint256[2] payerTokens;
        uint256[2] helperTokens;
        uint256[2] coreReserves;
        uint256[2] poolTokens;
        uint256[2] nativeNonces;
        uint256[2] helperAllowances;
        uint256[2] permit2Allowances;
        uint256[2] helperCoreAllowances;
        uint256 payerCygld;
        uint256 helperCygld;
        uint256 treasuryCygld;
        uint256 totalSupply;
        uint256 permit2NonceBitmap;
    }

    ICyberGoldCore private core = ICyberGoldCore(CORE);
    ICyberGoldHelpers private helpers = ICyberGoldHelpers(HELPERS);
    address private payer;
    uint256 private payerKey;
    address private treasury;
    address private owner;
    address private basketFacet;
    address private coordinator;

    function setUp() public {
        payerKey = vm.randomUint();
        payer = vm.addr(payerKey);
        treasury = core.treasury();
        owner = helpers.owner();
        basketFacet = helpers.facetAddress(ICyberGoldHelpers.issueFromBasketExactOutWithMixedPermits.selector);
        coordinator = helpers.facetAddress(ICyberGoldHelpers.diamondCut.selector);
        assertTrue(basketFacet != address(0), "owned Anvil must install mixed basket selectors first");
        assertEq(helpers.coreDiamond(), CORE);
        assertEq(helpers.permit2(), PERMIT2);
        assertEq(helpers.helperFeePpm(), 0, "actual installed fee");
        assertFalse(helpers.paused());
        assertFalse(core.paused());
        _assertRouting();
        (, uint256[] memory required, address[] memory assets) = core.previewIssueFromBasketExactOut(TARGET_CYGLD);
        assertEq(assets.length, 2);
        assertEq(assets[0], PAXG);
        assertEq(assets[1], XAUT);
        deal(PAXG, payer, required[0] * 20 + 1 ether);
        deal(XAUT, payer, required[1] * 20 + 1 ether);
        emit log_named_address("installedHelpers", HELPERS);
        emit log_named_address("installedCore", CORE);
        emit log_named_bytes32("installedCoreRuntimeHash", CORE.codehash);
        emit log_named_address("installedBasketFacet", basketFacet);
        emit log_named_bytes32("installedBasketRuntimeHash", basketFacet.codehash);
        emit log_named_bytes32("actualPaxgRuntimeHash", PAXG.codehash);
        emit log_named_bytes32("actualXautRuntimeHash", XAUT.codehash);
        emit log_named_bytes32("actualPermit2RuntimeHash", PERMIT2.codehash);
    }

    function testInstalledAllNativeFirstAndRepeatUseExactCurrentLots() public {
        for (uint256 iteration; iteration < 2; ++iteration) {
            (uint256 fee, IBasketRouterTypes.BasketIssueInput[] memory inputs) = _inputs(1, 1, 0);
            EconomicSnapshot memory beforePurchase = _snapshot();
            IBasketRouterTypes.BasketIssueResult memory result = _out(inputs, _emptyBatch());
            _assertPurchase(beforePurchase, result, TARGET_CYGLD, fee);
            EconomicSnapshot memory afterPurchase = _snapshot();
            assertEq(afterPurchase.nativeNonces[0], beforePurchase.nativeNonces[0] + 1);
            assertEq(afterPurchase.nativeNonces[1], beforePurchase.nativeNonces[1] + 1);
            assertEq(afterPurchase.helperAllowances[0], 0);
            assertEq(afterPurchase.helperAllowances[1], 0);
            assertEq(afterPurchase.permit2Allowances[0], 0);
            assertEq(afterPurchase.permit2Allowances[1], 0);
            assertEq(afterPurchase.permit2NonceBitmap, 0);
        }
    }

    /// @dev XAUt is native-qualified; selecting Permit2 here tests the mixed acquisition mechanism only.
    function testInstalledMixedPaxgNativeXautPermit2UsesActualBatchSignature() public {
        _approvePermit2(false, true);
        (uint256 fee, IBasketRouterTypes.BasketIssueInput[] memory inputs) = _inputs(1, 2, 0);
        EconomicSnapshot memory beforePurchase = _snapshot();
        IBasketRouterTypes.BasketIssueResult memory result = _out(inputs, _batch(inputs, 1));
        _assertPurchase(beforePurchase, result, TARGET_CYGLD, fee);
        EconomicSnapshot memory afterPurchase = _snapshot();
        assertEq(afterPurchase.nativeNonces[0], beforePurchase.nativeNonces[0] + 1);
        assertEq(afterPurchase.nativeNonces[1], beforePurchase.nativeNonces[1]);
        assertEq(afterPurchase.helperAllowances[0], 0);
        assertEq(afterPurchase.helperAllowances[1], 0);
        assertEq(afterPurchase.permit2Allowances[0], 0);
        assertEq(afterPurchase.permit2Allowances[1], beforePurchase.permit2Allowances[1] - result.actualAmountsIn[1]);
        assertEq(afterPurchase.permit2NonceBitmap, uint256(1) << 1);
    }

    function testInstalledAllPermit2ColdSetupAndWarmRepeatUseFreshOneTimeBatches() public {
        assertEq(IERC20(PAXG).allowance(payer, PERMIT2), 0);
        assertEq(IERC20(XAUT).allowance(payer, PERMIT2), 0);
        _approvePermit2(true, true);
        for (uint256 nonce = 2; nonce < 4; ++nonce) {
            (uint256 fee, IBasketRouterTypes.BasketIssueInput[] memory inputs) = _inputs(2, 2, 0);
            EconomicSnapshot memory beforePurchase = _snapshot();
            IBasketRouterTypes.BasketIssueResult memory result = _out(inputs, _batch(inputs, nonce));
            _assertPurchase(beforePurchase, result, TARGET_CYGLD, fee);
            EconomicSnapshot memory afterPurchase = _snapshot();
            assertEq(afterPurchase.nativeNonces[0], beforePurchase.nativeNonces[0]);
            assertEq(afterPurchase.nativeNonces[1], beforePurchase.nativeNonces[1]);
            assertEq(afterPurchase.helperAllowances[0], 0);
            assertEq(afterPurchase.helperAllowances[1], 0);
            // These actual token implementations decrement even a MAX setup approval.
            assertEq(afterPurchase.permit2Allowances[0], beforePurchase.permit2Allowances[0] - result.actualAmountsIn[0]);
            assertEq(afterPurchase.permit2Allowances[1], beforePurchase.permit2Allowances[1] - result.actualAmountsIn[1]);
            assertGt(afterPurchase.permit2Allowances[0], 0, "warm setup remains sufficient");
            assertGt(afterPurchase.permit2Allowances[1], 0, "warm setup remains sufficient");
            assertEq(afterPurchase.permit2NonceBitmap, beforePurchase.permit2NonceBitmap | (uint256(1) << nonce));
        }
    }

    function testInstalledExactOrdinaryAllowancesNeedNoTypedSignatures() public {
        (uint256 fee, IBasketRouterTypes.BasketIssueInput[] memory inputs) = _inputs(0, 0, 0);
        vm.startPrank(payer);
        assertTrue(IERC20(PAXG).approve(HELPERS, inputs[0].maximumInputAmount));
        assertTrue(IERC20(XAUT).approve(HELPERS, inputs[1].maximumInputAmount));
        vm.stopPrank();
        EconomicSnapshot memory beforePurchase = _snapshot();
        IBasketRouterTypes.BasketIssueResult memory result = _out(inputs, _emptyBatch());
        _assertPurchase(beforePurchase, result, TARGET_CYGLD, fee);
        EconomicSnapshot memory afterPurchase = _snapshot();
        assertEq(afterPurchase.nativeNonces[0], beforePurchase.nativeNonces[0]);
        assertEq(afterPurchase.nativeNonces[1], beforePurchase.nativeNonces[1]);
        assertEq(afterPurchase.helperAllowances[0], 0);
        assertEq(afterPurchase.helperAllowances[1], 0);
        assertEq(afterPurchase.permit2NonceBitmap, 0);
    }

    function testInstalledBadPermit2SignatureRollsBackEarlierNativePermitAndEconomics() public {
        _approvePermit2(false, true);
        (, IBasketRouterTypes.BasketIssueInput[] memory inputs) = _inputs(1, 2, 0);
        IBasketRouterTypes.Permit2BatchParams memory batch = _batch(inputs, 4);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(vm.randomUint(), _batchDigest(batch));
        batch.signature = abi.encodePacked(r, s, v);
        _assertRollback(inputs, batch, bytes4(keccak256("InvalidSigner()")));
    }

    function testInstalledBadSecondNativeSignatureRollsBackFirstPermitAndEconomics() public {
        (, IBasketRouterTypes.BasketIssueInput[] memory inputs) = _inputs(1, 1, 0);
        inputs[1].permit = _nativePermit(XAUT, inputs[1].maximumInputAmount, vm.randomUint());
        _assertRollback(inputs, _emptyBatch(), bytes4(0));
    }

    function testInstalledPermit2ReplayRollsBackFreshNativePermitAndEconomicState() public {
        _approvePermit2(false, true);
        (uint256 fee, IBasketRouterTypes.BasketIssueInput[] memory inputs) = _inputs(1, 2, 1e9);
        IBasketRouterTypes.Permit2BatchParams memory batch = _batch(inputs, 5);
        EconomicSnapshot memory beforePurchase = _snapshot();
        _assertPurchase(beforePurchase, _out(inputs, batch), TARGET_CYGLD, fee);
        (, inputs) = _inputs(1, 2, 0);
        // The replayed finite signed permission still covers the next fresh lot; the real nonce rejects it.
        assertGe(batch.permit.permitted[0].amount, inputs[1].maximumInputAmount);
        _assertRollback(inputs, batch, bytes4(keccak256("InvalidNonce()")));
    }

    function testInstalledAllNativeExactInSettlesFreshPreviewWithinFiniteBudgets() public {
        (, uint256[] memory budgets,) = core.previewIssueFromBasketExactOut(TARGET_CYGLD);
        budgets[0] += 1e9;
        budgets[1] += 1e9;
        (uint256 net, uint256 fee, uint256[] memory required, address[] memory assets) =
            core.previewIssueFromBasketExactIn(budgets);
        IBasketRouterTypes.BasketIssueInput[] memory inputs = new IBasketRouterTypes.BasketIssueInput[](2);
        for (uint256 i; i < 2; ++i) {
            inputs[i] = IBasketRouterTypes.BasketIssueInput(
                assets[i], budgets[i], IBasketRouterTypes.BasketInputAuthorization.TokenPermit,
                _nativePermit(assets[i], budgets[i], payerKey)
            );
        }
        EconomicSnapshot memory beforePurchase = _snapshot();
        vm.prank(payer);
        IBasketRouterTypes.BasketIssueResult memory result = helpers.issueFromBasketExactInWithMixedPermits(
            IBasketRouterTypes.BasketIssueExactInRequest(payer, net), inputs, _emptyBatch()
        );
        _assertPurchase(beforePurchase, result, net, fee);
        EconomicSnapshot memory afterPurchase = _snapshot();
        for (uint256 i; i < 2; ++i) {
            assertEq(result.actualAmountsIn[i], required[i]);
            assertEq(afterPurchase.helperAllowances[i], budgets[i] - required[i], "finite unused trade budget");
            assertEq(afterPurchase.nativeNonces[i], beforePurchase.nativeNonces[i] + 1);
            assertEq(afterPurchase.permit2Allowances[i], 0);
        }
    }

    function _inputs(uint8 modeA, uint8 modeB, uint256 extra)
        private view returns (uint256 fee, IBasketRouterTypes.BasketIssueInput[] memory inputs)
    {
        uint256[] memory required;
        address[] memory assets;
        (fee, required, assets) = core.previewIssueFromBasketExactOut(TARGET_CYGLD);
        inputs = new IBasketRouterTypes.BasketIssueInput[](2);
        for (uint256 i; i < 2; ++i) {
            uint8 mode = i == 0 ? modeA : modeB;
            uint256 ceiling = required[i] + extra;
            inputs[i].token = assets[i];
            inputs[i].maximumInputAmount = ceiling;
            inputs[i].authorization = IBasketRouterTypes.BasketInputAuthorization(mode);
            if (mode == 1) inputs[i].permit = _nativePermit(assets[i], ceiling, payerKey);
        }
    }

    function _nativePermit(address token, uint256 value, uint256 key)
        private view returns (IBasketRouterTypes.PermitParams memory permit)
    {
        permit.value = value;
        permit.deadline = block.timestamp + 1 days;
        bytes32 message = keccak256(
            abi.encode(PERMIT_TYPEHASH, payer, HELPERS, value, IERC20Permit(token).nonces(payer), permit.deadline)
        );
        (permit.v, permit.r, permit.s) =
            vm.sign(key, keccak256(abi.encodePacked(hex"1901", IERC20Permit(token).DOMAIN_SEPARATOR(), message)));
    }

    function _batch(IBasketRouterTypes.BasketIssueInput[] memory inputs, uint256 nonce)
        private view returns (IBasketRouterTypes.Permit2BatchParams memory batch)
    {
        uint256 count;
        for (uint256 i; i < inputs.length; ++i) {
            if (inputs[i].authorization == IBasketRouterTypes.BasketInputAuthorization.Permit2) ++count;
        }
        batch.permit.permitted = new ISignatureTransfer.TokenPermissions[](count);
        uint256 cursor;
        for (uint256 i; i < inputs.length; ++i) {
            if (inputs[i].authorization == IBasketRouterTypes.BasketInputAuthorization.Permit2) {
                batch.permit.permitted[cursor++] =
                    ISignatureTransfer.TokenPermissions(inputs[i].token, inputs[i].maximumInputAmount);
            }
        }
        batch.permit.nonce = nonce;
        batch.permit.deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(payerKey, _batchDigest(batch));
        batch.signature = abi.encodePacked(r, s, v);
    }

    function _batchDigest(IBasketRouterTypes.Permit2BatchParams memory batch) private view returns (bytes32) {
        bytes32[] memory tokens = new bytes32[](batch.permit.permitted.length);
        for (uint256 i; i < tokens.length; ++i) {
            ISignatureTransfer.TokenPermissions memory permission = batch.permit.permitted[i];
            tokens[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permission.token, permission.amount));
        }
        bytes32 message = keccak256(abi.encode(
            BATCH_TYPEHASH, keccak256(abi.encodePacked(tokens)), HELPERS, batch.permit.nonce, batch.permit.deadline
        ));
        return keccak256(abi.encodePacked(hex"1901", ISignatureTransfer(PERMIT2).DOMAIN_SEPARATOR(), message));
    }

    function _emptyBatch() private pure returns (IBasketRouterTypes.Permit2BatchParams memory batch) {
        batch.permit.permitted = new ISignatureTransfer.TokenPermissions[](0);
    }

    function _approvePermit2(bool paxg, bool xaut) private {
        vm.startPrank(payer);
        if (paxg) assertTrue(IERC20(PAXG).approve(PERMIT2, type(uint256).max));
        if (xaut) assertTrue(IERC20(XAUT).approve(PERMIT2, type(uint256).max));
        vm.stopPrank();
    }

    function _out(IBasketRouterTypes.BasketIssueInput[] memory inputs, IBasketRouterTypes.Permit2BatchParams memory batch)
        private returns (IBasketRouterTypes.BasketIssueResult memory)
    {
        vm.prank(payer);
        return helpers.issueFromBasketExactOutWithMixedPermits(
            IBasketRouterTypes.BasketIssueExactOutRequest(TARGET_CYGLD, payer), inputs, batch
        );
    }

    function _assertRollback(IBasketRouterTypes.BasketIssueInput[] memory inputs,
        IBasketRouterTypes.Permit2BatchParams memory batch, bytes4 expectedSelector) private
    {
        EconomicSnapshot memory beforePurchase = _snapshot();
        vm.prank(payer);
        (bool success, bytes memory reason) = HELPERS.call(abi.encodeCall(
            ICyberGoldHelpers.issueFromBasketExactOutWithMixedPermits,
            (IBasketRouterTypes.BasketIssueExactOutRequest(TARGET_CYGLD, payer), inputs, batch)
        ));
        assertFalse(success);
        assertGe(reason.length, 4, "real token/Permit2 failure retained");
        if (expectedSelector != bytes4(0)) assertEq(bytes4(reason), expectedSelector);
        assertEq(keccak256(abi.encode(_snapshot())), keccak256(abi.encode(beforePurchase)));
        _assertRouting();
        emit log_named_bytes("actualAuthorizationFailure", reason);
    }

    function _snapshot() private view returns (EconomicSnapshot memory value) {
        for (uint256 i; i < 2; ++i) {
            address token = i == 0 ? PAXG : XAUT;
            value.payerTokens[i] = IERC20(token).balanceOf(payer);
            value.helperTokens[i] = IERC20(token).balanceOf(HELPERS);
            value.coreReserves[i] = IERC20(token).balanceOf(CORE);
            value.poolTokens[i] = IERC20(token).balanceOf(POOL);
            value.nativeNonces[i] = IERC20Permit(token).nonces(payer);
            value.helperAllowances[i] = IERC20(token).allowance(payer, HELPERS);
            value.permit2Allowances[i] = IERC20(token).allowance(payer, PERMIT2);
            value.helperCoreAllowances[i] = IERC20(token).allowance(HELPERS, CORE);
        }
        value.payerCygld = core.balanceOf(payer);
        value.helperCygld = core.balanceOf(HELPERS);
        value.treasuryCygld = core.balanceOf(treasury);
        value.totalSupply = core.totalSupply();
        value.permit2NonceBitmap = ISignatureTransfer(PERMIT2).nonceBitmap(payer, 0);
    }

    function _assertPurchase(EconomicSnapshot memory beforePurchase, IBasketRouterTypes.BasketIssueResult memory result,
        uint256 net, uint256 fee) private view
    {
        EconomicSnapshot memory afterPurchase = _snapshot();
        assertEq(result.netCygldOut, net);
        assertEq(result.fees.protocolFeeCygld, fee);
        assertEq(result.fees.helperFeeCygld, 0);
        assertEq(afterPurchase.payerCygld - beforePurchase.payerCygld, net);
        assertEq(afterPurchase.treasuryCygld - beforePurchase.treasuryCygld, fee);
        assertEq(afterPurchase.totalSupply - beforePurchase.totalSupply, net + fee);
        assertEq(afterPurchase.helperCygld, beforePurchase.helperCygld);
        assertEq(result.actualAmountsIn.length, 2);
        for (uint256 i; i < 2; ++i) {
            assertEq(beforePurchase.payerTokens[i] - afterPurchase.payerTokens[i], result.actualAmountsIn[i]);
            assertEq(afterPurchase.coreReserves[i] - beforePurchase.coreReserves[i], result.actualAmountsIn[i]);
            assertEq(afterPurchase.helperTokens[i], beforePurchase.helperTokens[i], "existing custody preserved");
            assertEq(afterPurchase.poolTokens[i], beforePurchase.poolTokens[i], "direct basket uses no venue");
            assertEq(afterPurchase.helperCoreAllowances[i], 0, "temporary Core approval cleared");
        }
        _assertRouting();
    }

    function _assertRouting() private view {
        assertEq(helpers.owner(), owner);
        assertEq(helpers.facetAddress(ICyberGoldHelpers.diamondCut.selector), coordinator);
        assertEq(helpers.facetGeneration(COORDINATOR_NAMESPACE), 2);
        assertEq(helpers.facetGeneration(BASKET_NAMESPACE), 2);
        assertEq(helpers.facetAddress(ICyberGoldHelpers.issueFromBasketExactInWithMixedPermits.selector), basketFacet);
        assertEq(helpers.facetAddress(ICyberGoldHelpers.issueFromBasketExactOutWithMixedPermits.selector), basketFacet);
        assertEq(helpers.facetAddress(ICyberGoldHelpers.issueFromBasketExactInWithPermit2.selector), basketFacet);
        assertEq(helpers.facetAddress(ICyberGoldHelpers.issueFromBasketExactOutWithPermit2.selector), basketFacet);
    }
}
