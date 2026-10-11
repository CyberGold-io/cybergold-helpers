// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {UniswapUniversalAdapter} from "../src/adapters/UniswapUniversalAdapter.sol";

interface IInstalledHelpersPermitQuoter {
    function quoteExactOutput(bytes calldata path, uint256 amountOut)
        external
        returns (uint256 amountIn, uint160[] memory, uint32[] memory, uint256);
}

/// @notice Purchase qualification of the actual Helpers after the scripted local coordinator and issuance cuts.
/// @dev Fork the owned Anvil's latest state AFTER both cuts. This suite deploys no substitute Helpers,
/// adapter, Core or venue. Disposable payer funding/signatures exist only in each isolated test fork.
contract TokenNativePermitInstalledHelpersForkTest is Test {
    address private constant CORE = 0x601da021cAF3DB5AA63e700D239b5935C370601d;
    address private constant HELPERS = 0x30e9aFD21A30B2629BE33508A131AC890368f534;
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address private constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address private constant POOL = 0xc756BBA710d45647715079cE50aa16aab36deD42;
    address private constant UNIVERSAL_ROUTER = 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA;
    address private constant QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 private constant TARGET_CYGLD = 1 ether;
    bytes32 private constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.owner");
    bytes32 private constant MIGRATION_NAMESPACE = keccak256("cybergold.helpers.optional-initializer-migration");
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct EconomicSnapshot {
        uint256 userPaxg;
        uint256 helperPaxg;
        uint256 helperXaut;
        uint256 helperCygld;
        uint256 adapterPaxg;
        uint256 adapterXaut;
        uint256 reservePaxg;
        uint256 reserveXaut;
        uint256 poolPaxg;
        uint256 poolXaut;
        uint256 userCygld;
        uint256 treasuryCygld;
        uint256 totalCygldSupply;
        uint256 nonce;
        uint256 payerAllowance;
        uint256 helperAdapterAllowance;
        uint256 helperCorePaxgAllowance;
        uint256 helperCoreXautAllowance;
        uint256 adapterPermit2Allowance;
    }

    ICyberGoldCore private core = ICyberGoldCore(CORE);
    ICyberGoldHelpers private helpers = ICyberGoldHelpers(HELPERS);
    UniswapUniversalAdapter private adapter;
    address private user;
    uint256 private userKey;
    address private treasury;
    address private issueFacet;
    address private coordinator;
    address private owner;
    uint256 private expectedProtocolFee;
    uint256[] private requiredInputs;
    IBasketRouterTypes.IssueFromTokenExactOutParams private params;
    IBasketRouterTypes.IssueExecutionParams private execution;
    IBasketRouterTypes.IssueSwapLeg[] private legs;

    function setUp() public {
        userKey = vm.randomUint();
        user = vm.addr(userKey);
        treasury = core.treasury();
        owner = helpers.owner();
        coordinator = helpers.facetAddress(ICyberGoldHelpers.diamondCut.selector);
        issueFacet = helpers.facetAddress(ICyberGoldHelpers.issueFromTokenExactOutWithPermit.selector);
        assertTrue(issueFacet != address(0), "scripted cut must install native issuance before this suite");
        assertEq(helpers.facetAddress(ICyberGoldHelpers.issueFromTokenExactOut.selector), issueFacet);
        assertEq(helpers.coreDiamond(), CORE);
        assertEq(helpers.permit2(), PERMIT2);
        assertEq(helpers.helperFeePpm(), 0, "pinned installed Helpers fee");
        assertFalse(helpers.paused());
        assertFalse(core.paused());
        _assertUpgradeRetained();
        adapter = _installedAdapter();

        address[] memory assets;
        (expectedProtocolFee, requiredInputs, assets) = core.previewIssueFromBasketExactOut(TARGET_CYGLD);
        assertEq(assets.length, 2);
        assertEq(assets[0], PAXG);
        assertEq(assets[1], XAUT);
        bytes memory path = abi.encodePacked(XAUT, uint24(100), PAXG);
        (uint256 quotedInput,,,) = IInstalledHelpersPermitQuoter(QUOTER).quoteExactOutput(path, requiredInputs[1]);
        uint256 swapCeiling = quotedInput * 101 / 100 + 1;
        params = IBasketRouterTypes.IssueFromTokenExactOutParams({
            inputToken: PAXG, maximumInputAmount: requiredInputs[0] + swapCeiling + 1e12, netCygldOut: TARGET_CYGLD
        });
        execution = IBasketRouterTypes.IssueExecutionParams({recipient: user, expectedOrderedCoreAssets: assets});
        legs.push(
            IBasketRouterTypes.IssueSwapLeg({
                adapter: address(adapter),
                amountIn: swapCeiling,
                minimumAmountOut: requiredInputs[1],
                data: abi.encode(path, requiredInputs[1], block.timestamp + 30 minutes, false)
            })
        );
        deal(PAXG, user, params.maximumInputAmount);
        emit log_named_address("installedHelpers", HELPERS);
        emit log_named_address("installedAdapter", address(adapter));
        emit log_named_address("installedIssueFacet", issueFacet);
        emit log_named_bytes32("installedIssueRuntimeHash", issueFacet.codehash);
        emit log_named_address("installedCoordinator", coordinator);
        emit log_named_bytes32("installedCoordinatorRuntimeHash", coordinator.codehash);
    }

    function testInstalledHelpersNativePermitPurchaseSettlesThroughActualCoreAndUniswap() public {
        EconomicSnapshot memory beforePurchase = _snapshot();
        assertEq(beforePurchase.payerAllowance, 0);
        assertEq(IERC20(PAXG).allowance(user, PERMIT2), 0);
        IBasketRouterTypes.PermitParams memory permit = _signPermit();
        vm.prank(user);
        IBasketRouterTypes.Fees memory fees = helpers.issueFromTokenExactOutWithPermit(params, execution, permit, legs);
        EconomicSnapshot memory afterPurchase = _snapshot();
        assertEq(afterPurchase.nonce, beforePurchase.nonce + 1);
        _assertSuccessfulPurchase(beforePurchase, afterPurchase, fees);
        emit log_named_uint("nativeNonceBefore", beforePurchase.nonce);
        emit log_named_uint("nativeNonceAfter", afterPurchase.nonce);
    }

    function testInstalledHelpersExactOrdinaryAllowancePurchaseSettlesThroughActualCoreAndUniswap() public {
        vm.prank(user);
        assertTrue(IERC20(PAXG).approve(HELPERS, params.maximumInputAmount));
        EconomicSnapshot memory beforePurchase = _snapshot();
        assertEq(beforePurchase.payerAllowance, params.maximumInputAmount);
        assertEq(IERC20(PAXG).allowance(user, PERMIT2), 0);
        vm.prank(user);
        IBasketRouterTypes.Fees memory fees = helpers.issueFromTokenExactOut(params, execution, legs);
        EconomicSnapshot memory afterPurchase = _snapshot();
        assertEq(afterPurchase.nonce, beforePurchase.nonce, "ordinary executor uses no permit");
        _assertSuccessfulPurchase(beforePurchase, afterPurchase, fees);
        emit log_named_uint("ordinaryApprovalCeiling", beforePurchase.payerAllowance);
        emit log_named_uint("ordinaryAllowanceAfter", afterPurchase.payerAllowance);
    }

    function testInstalledHelpersRealVenueFailureRollsBackPermitAndEconomicState() public {
        EconomicSnapshot memory beforePurchase = _snapshot();
        IBasketRouterTypes.PermitParams memory permit = _signPermit();
        legs[0].data =
            abi.encode(abi.encodePacked(XAUT, uint24(100), PAXG), requiredInputs[1], block.timestamp - 1, false);
        vm.prank(user);
        (bool success, bytes memory reason) = HELPERS.call(
            abi.encodeCall(ICyberGoldHelpers.issueFromTokenExactOutWithPermit, (params, execution, permit, legs))
        );
        assertFalse(success, "actual expired venue command must fail");
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
        assertEq(selector, UniswapUniversalAdapter.UniversalRouterSwapFailed.selector);
        assertEq(keccak256(abi.encode(_snapshot())), keccak256(abi.encode(beforePurchase)));
        _assertUpgradeRetained();
        emit log_named_bytes("installedActualVenueFailure", reason);
    }

    function _installedAdapter() private view returns (UniswapUniversalAdapter selected) {
        address[] memory approved = helpers.approvedAdapters();
        for (uint256 i; i < approved.length; ++i) {
            try UniswapUniversalAdapter(payable(approved[i])).UNIVERSAL_ROUTER() returns (address router) {
                if (router != UNIVERSAL_ROUTER) continue;
                selected = UniswapUniversalAdapter(payable(approved[i]));
                assertEq(selected.PERMIT2(), PERMIT2);
                assertEq(selected.helpersDiamond(), HELPERS);
                return selected;
            } catch {}
        }
        revert("installed approved Universal Router adapter unavailable");
    }

    function _signPermit() private view returns (IBasketRouterTypes.PermitParams memory permit) {
        permit.value = params.maximumInputAmount;
        permit.deadline = block.timestamp + 1 days;
        bytes32 message = keccak256(
            abi.encode(PERMIT_TYPEHASH, user, HELPERS, permit.value, IERC20Permit(PAXG).nonces(user), permit.deadline)
        );
        (permit.v, permit.r, permit.s) =
            vm.sign(userKey, keccak256(abi.encodePacked(hex"1901", IERC20Permit(PAXG).DOMAIN_SEPARATOR(), message)));
    }

    function _snapshot() private view returns (EconomicSnapshot memory value) {
        value.userPaxg = IERC20(PAXG).balanceOf(user);
        value.helperPaxg = IERC20(PAXG).balanceOf(HELPERS);
        value.helperXaut = IERC20(XAUT).balanceOf(HELPERS);
        value.helperCygld = core.balanceOf(HELPERS);
        value.adapterPaxg = IERC20(PAXG).balanceOf(address(adapter));
        value.adapterXaut = IERC20(XAUT).balanceOf(address(adapter));
        value.reservePaxg = IERC20(PAXG).balanceOf(CORE);
        value.reserveXaut = IERC20(XAUT).balanceOf(CORE);
        value.poolPaxg = IERC20(PAXG).balanceOf(POOL);
        value.poolXaut = IERC20(XAUT).balanceOf(POOL);
        value.userCygld = core.balanceOf(user);
        value.treasuryCygld = core.balanceOf(treasury);
        value.totalCygldSupply = core.totalSupply();
        value.nonce = IERC20Permit(PAXG).nonces(user);
        value.payerAllowance = IERC20(PAXG).allowance(user, HELPERS);
        value.helperAdapterAllowance = IERC20(PAXG).allowance(HELPERS, address(adapter));
        value.helperCorePaxgAllowance = IERC20(PAXG).allowance(HELPERS, CORE);
        value.helperCoreXautAllowance = IERC20(XAUT).allowance(HELPERS, CORE);
        value.adapterPermit2Allowance = IERC20(PAXG).allowance(address(adapter), PERMIT2);
    }

    function _assertSuccessfulPurchase(
        EconomicSnapshot memory beforePurchase,
        EconomicSnapshot memory afterPurchase,
        IBasketRouterTypes.Fees memory fees
    ) private {
        assertEq(afterPurchase.payerAllowance, 0);
        assertEq(IERC20(PAXG).allowance(user, PERMIT2), 0);
        assertEq(afterPurchase.userCygld - beforePurchase.userCygld, TARGET_CYGLD);
        assertEq(fees.protocolFeeCygld, expectedProtocolFee);
        assertEq(fees.helperFeeCygld, 0);
        assertEq(afterPurchase.treasuryCygld - beforePurchase.treasuryCygld, fees.protocolFeeCygld);
        assertEq(afterPurchase.totalCygldSupply - beforePurchase.totalCygldSupply, TARGET_CYGLD + fees.protocolFeeCygld);
        assertEq(afterPurchase.reservePaxg - beforePurchase.reservePaxg, requiredInputs[0]);
        assertEq(afterPurchase.reserveXaut - beforePurchase.reserveXaut, requiredInputs[1]);
        assertGt(afterPurchase.userPaxg, 0, "unused purchase ceiling refunded");
        assertEq(
            afterPurchase.poolPaxg - beforePurchase.poolPaxg,
            beforePurchase.userPaxg - afterPurchase.userPaxg - requiredInputs[0]
        );
        assertEq(beforePurchase.poolXaut - afterPurchase.poolXaut, requiredInputs[1]);
        assertEq(afterPurchase.helperPaxg, beforePurchase.helperPaxg, "pre-existing custody preserved");
        assertEq(afterPurchase.helperXaut, beforePurchase.helperXaut);
        assertEq(afterPurchase.helperCygld, beforePurchase.helperCygld);
        assertEq(afterPurchase.adapterPaxg, beforePurchase.adapterPaxg);
        assertEq(afterPurchase.adapterXaut, beforePurchase.adapterXaut);
        assertEq(afterPurchase.helperAdapterAllowance, 0);
        assertEq(afterPurchase.helperCorePaxgAllowance, 0);
        assertEq(afterPurchase.helperCoreXautAllowance, 0);
        assertEq(afterPurchase.adapterPermit2Allowance, 0);
        _assertUpgradeRetained();
        emit log_named_uint("installedInputCeiling", params.maximumInputAmount);
        emit log_named_uint("installedActualInput", beforePurchase.userPaxg - afterPurchase.userPaxg);
        emit log_named_uint("installedRefund", afterPurchase.userPaxg);
        emit log_named_uint("installedNetCygld", afterPurchase.userCygld - beforePurchase.userCygld);
        emit log_named_uint("installedProtocolFee", fees.protocolFeeCygld);
    }

    function _assertUpgradeRetained() private view {
        assertEq(helpers.owner(), owner);
        assertEq(helpers.facetAddress(ICyberGoldHelpers.diamondCut.selector), coordinator);
        assertEq(helpers.facetAddress(ICyberGoldHelpers.facetGeneration.selector), coordinator);
        assertEq(helpers.facetGeneration(COORDINATOR_NAMESPACE), 2);
        assertEq(helpers.facetGeneration(MIGRATION_NAMESPACE), 0);
        assertEq(
            helpers.facetAddress(bytes4(keccak256("executeHelpersOptionalInitializerMigration(bytes)"))), address(0)
        );
        assertEq(helpers.facetAddress(ICyberGoldHelpers.issueFromTokenExactOutWithPermit.selector), issueFacet);
        assertEq(helpers.facetAddress(ICyberGoldHelpers.issueFromTokenExactOut.selector), issueFacet);
        assertFalse(helpers.paused());
        assertFalse(core.paused());
    }
}
