// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {HelpersDiamond} from "../src/diamond/HelpersDiamond.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {UniswapUniversalAdapter} from "../src/adapters/UniswapUniversalAdapter.sol";

interface ILiveCorePermitQuoter {
    function quoteExactOutput(bytes calldata path, uint256 amountOut)
        external
        returns (uint256 amountIn, uint160[] memory, uint32[] memory, uint256);
}

/// @notice Native PAXG permits, real Uniswap execution, and actual deployed Core settlement on a disposable fork.
/// @dev New Helpers/adapter contracts and input funding exist only inside the local test fork.
contract TokenNativePermitLiveCoreForkTest is Test {
    address private constant CORE = 0x601da021cAF3DB5AA63e700D239b5935C370601d;
    address private constant EXISTING_HELPERS = 0x30e9aFD21A30B2629BE33508A131AC890368f534;
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address private constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address private constant POOL = 0xc756BBA710d45647715079cE50aa16aab36deD42;
    address private constant UNIVERSAL_ROUTER = 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA;
    address private constant QUOTER = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 private constant TARGET_CYGLD = 1 ether;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct EconomicSnapshot {
        uint256 userPaxg;
        uint256 helperPaxg;
        uint256 adapterPaxg;
        uint256 reservePaxg;
        uint256 reserveXaut;
        uint256 poolPaxg;
        uint256 poolXaut;
        uint256 userCygld;
        uint256 treasuryCygld;
        uint256 totalCygldSupply;
        uint256 nonce;
        uint256 allowance;
    }

    ICyberGoldCore private core = ICyberGoldCore(CORE);
    ICyberGoldHelpers private helpers;
    UniswapUniversalAdapter private adapter;
    address private user;
    uint256 private userKey;
    address private reserve;
    address private treasury;
    address private deployedIssueFacet;
    address private existingIssueFacet;
    address private existingPermitIssueFacet;
    uint256 private expectedProtocolFee;
    uint256[] private requiredInputs;
    IBasketRouterTypes.IssueFromTokenExactOutParams private params;
    IBasketRouterTypes.IssueExecutionParams private execution;
    IBasketRouterTypes.IssueSwapLeg[] private legs;

    function setUp() public {
        userKey = vm.randomUint();
        user = vm.addr(userKey);
        reserve = CORE;
        treasury = core.treasury();
        existingIssueFacet =
            ICyberGoldHelpers(EXISTING_HELPERS).facetAddress(ICyberGoldHelpers.issueFromTokenExactOut.selector);
        existingPermitIssueFacet = ICyberGoldHelpers(EXISTING_HELPERS)
            .facetAddress(ICyberGoldHelpers.issueFromTokenExactOutWithPermit.selector);

        (HelpersDiamond shell,) =
            DeploymentHelper.deployHelpersShell(address(this), keccak256("helpers.native-permit.live-core.fork"));
        adapter = new UniswapUniversalAdapter(address(shell), UNIVERSAL_ROUTER, PERMIT2);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = CORE;
        cfg.permit2 = PERMIT2;
        cfg.wrappedNative = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        cfg.helperFeePpm = ICyberGoldHelpers(EXISTING_HELPERS).helperFeePpm();
        cfg.approvedAdapters = new address[](1);
        cfg.approvedAdapters[0] = address(adapter);
        DeploymentTypes.DeployArtifacts memory candidate = DeploymentHelper.finalizeExisting(shell, cfg);
        helpers = ICyberGoldHelpers(address(shell));
        deployedIssueFacet = address(candidate.facets.issue);

        address[] memory assets;
        (expectedProtocolFee, requiredInputs, assets) = core.previewIssueFromBasketExactOut(TARGET_CYGLD);
        assertFalse(core.paused(), "observed Core must support an ordinary purchase");
        assertEq(assets.length, 2);
        assertEq(assets[0], PAXG);
        assertEq(assets[1], XAUT);
        assertEq(helpers.helperFeePpm(), 0, "qualification uses the observed live Helpers fee");

        bytes memory exactOutputPath = abi.encodePacked(XAUT, uint24(100), PAXG);
        (uint256 quotedInput,,,) = ILiveCorePermitQuoter(QUOTER).quoteExactOutput(exactOutputPath, requiredInputs[1]);
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
                data: abi.encode(exactOutputPath, requiredInputs[1], block.timestamp + 30 minutes, false)
            })
        );
        deal(PAXG, user, params.maximumInputAmount);
        _logRuntimeIdentities();
    }

    function testPaxgPermitPurchaseSettlesThroughActualCoreAndUniswap() public {
        EconomicSnapshot memory beforePurchase = _snapshot();
        IBasketRouterTypes.PermitParams memory permit = _signPermit();
        IBasketRouterTypes.IssueExactOutPreview memory preview = helpers.previewIssueFromTokenExactOut(params, legs);
        assertEq(beforePurchase.allowance, 0);
        assertEq(IERC20(PAXG).allowance(user, PERMIT2), 0);
        vm.prank(user);
        IBasketRouterTypes.Fees memory fees = helpers.issueFromTokenExactOutWithPermit(params, execution, permit, legs);
        EconomicSnapshot memory afterPurchase = _snapshot();

        assertEq(afterPurchase.nonce, beforePurchase.nonce + 1);
        assertEq(afterPurchase.allowance, 0);
        assertEq(IERC20(PAXG).allowance(user, PERMIT2), 0);
        assertEq(afterPurchase.userCygld - beforePurchase.userCygld, TARGET_CYGLD);
        assertEq(fees.protocolFeeCygld, expectedProtocolFee);
        assertEq(fees.protocolFeeCygld, preview.fees.protocolFeeCygld);
        assertEq(fees.helperFeeCygld, 0);
        assertEq(afterPurchase.treasuryCygld - beforePurchase.treasuryCygld, fees.protocolFeeCygld);
        assertEq(afterPurchase.totalCygldSupply - beforePurchase.totalCygldSupply, TARGET_CYGLD + fees.protocolFeeCygld);
        assertEq(afterPurchase.reservePaxg - beforePurchase.reservePaxg, requiredInputs[0]);
        assertEq(afterPurchase.reserveXaut - beforePurchase.reserveXaut, requiredInputs[1]);
        assertGt(afterPurchase.userPaxg, 0, "unused input ceiling refunded");
        assertEq(
            afterPurchase.poolPaxg - beforePurchase.poolPaxg,
            beforePurchase.userPaxg - afterPurchase.userPaxg - requiredInputs[0]
        );
        assertEq(beforePurchase.poolXaut - afterPurchase.poolXaut, requiredInputs[1]);
        _assertCustodyAndApprovalsClear();
        _assertExistingInstallationUnchanged();

        emit log_named_uint("permitCeilingPaxg", params.maximumInputAmount);
        emit log_named_uint("actualInputPaxg", beforePurchase.userPaxg - afterPurchase.userPaxg);
        emit log_named_uint("refundPaxg", afterPurchase.userPaxg);
        emit log_named_uint("deliveredCygld", afterPurchase.userCygld - beforePurchase.userCygld);
        emit log_named_uint("protocolFeeCygld", fees.protocolFeeCygld);
        emit log_named_uint("helperFeeCygld", fees.helperFeeCygld);
        emit log_named_uint("permitNonceBefore", beforePurchase.nonce);
        emit log_named_uint("permitNonceAfter", afterPurchase.nonce);
        emit log_named_uint("payerHelpersAllowanceAfter", afterPurchase.allowance);
    }

    function testRealVenueFailureRollsBackPermitAndActualCorePoolBalances() public {
        EconomicSnapshot memory beforePurchase = _snapshot();
        IBasketRouterTypes.PermitParams memory permit = _signPermit();
        legs[0].data =
            abi.encode(abi.encodePacked(XAUT, uint24(100), PAXG), requiredInputs[1], block.timestamp - 1, false);
        bytes memory callData =
            abi.encodeCall(ICyberGoldHelpers.issueFromTokenExactOutWithPermit, (params, execution, permit, legs));
        vm.prank(user);
        (bool success, bytes memory reason) = address(helpers).call(callData);
        assertFalse(success, "expired actual venue command must fail");
        bytes4 selector;
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
        assertEq(selector, UniswapUniversalAdapter.UniversalRouterSwapFailed.selector);
        assertEq(keccak256(abi.encode(_snapshot())), keccak256(abi.encode(beforePurchase)));
        _assertCustodyAndApprovalsClear();
        _assertExistingInstallationUnchanged();
        emit log_named_bytes("actualVenueFailure", reason);
        emit log_named_uint("rolledBackPermitNonce", beforePurchase.nonce);
        emit log_named_uint("rolledBackHelpersAllowance", beforePurchase.allowance);
    }

    function _signPermit() private view returns (IBasketRouterTypes.PermitParams memory permit) {
        permit.value = params.maximumInputAmount;
        permit.deadline = block.timestamp + 1 days;
        bytes32 message = keccak256(
            abi.encode(
                PERMIT_TYPEHASH, user, address(helpers), permit.value, IERC20Permit(PAXG).nonces(user), permit.deadline
            )
        );
        (permit.v, permit.r, permit.s) =
            vm.sign(userKey, keccak256(abi.encodePacked(hex"1901", IERC20Permit(PAXG).DOMAIN_SEPARATOR(), message)));
    }

    function _snapshot() private view returns (EconomicSnapshot memory observed) {
        observed.userPaxg = IERC20(PAXG).balanceOf(user);
        observed.helperPaxg = IERC20(PAXG).balanceOf(address(helpers));
        observed.adapterPaxg = IERC20(PAXG).balanceOf(address(adapter));
        observed.reservePaxg = IERC20(PAXG).balanceOf(reserve);
        observed.reserveXaut = IERC20(XAUT).balanceOf(reserve);
        observed.poolPaxg = IERC20(PAXG).balanceOf(POOL);
        observed.poolXaut = IERC20(XAUT).balanceOf(POOL);
        observed.userCygld = core.balanceOf(user);
        observed.treasuryCygld = core.balanceOf(treasury);
        observed.totalCygldSupply = core.totalSupply();
        observed.nonce = IERC20Permit(PAXG).nonces(user);
        observed.allowance = IERC20(PAXG).allowance(user, address(helpers));
    }

    function _assertCustodyAndApprovalsClear() private view {
        assertEq(IERC20(PAXG).balanceOf(address(helpers)), 0);
        assertEq(IERC20(XAUT).balanceOf(address(helpers)), 0);
        assertEq(core.balanceOf(address(helpers)), 0);
        assertEq(IERC20(PAXG).balanceOf(address(adapter)), 0);
        assertEq(IERC20(XAUT).balanceOf(address(adapter)), 0);
        assertEq(IERC20(PAXG).allowance(address(helpers), address(adapter)), 0);
        assertEq(IERC20(PAXG).allowance(address(helpers), CORE), 0);
        assertEq(IERC20(XAUT).allowance(address(helpers), CORE), 0);
        assertEq(IERC20(PAXG).allowance(address(adapter), PERMIT2), 0);
    }

    function _assertExistingInstallationUnchanged() private view {
        assertEq(
            ICyberGoldHelpers(EXISTING_HELPERS).facetAddress(ICyberGoldHelpers.issueFromTokenExactOut.selector),
            existingIssueFacet
        );
        assertEq(
            ICyberGoldHelpers(EXISTING_HELPERS)
                .facetAddress(ICyberGoldHelpers.issueFromTokenExactOutWithPermit.selector),
            existingPermitIssueFacet
        );
        assertFalse(core.paused());
    }

    function _logRuntimeIdentities() private {
        emit log_named_uint("qualificationBlock", block.number);
        emit log_named_address("actualCore", CORE);
        emit log_named_bytes32("actualCoreShellCodeHash", CORE.codehash);
        address issueFacet = core.facetAddress(ICyberGoldCore.safeIssue.selector);
        emit log_named_address("actualCoreIssueFacet", issueFacet);
        emit log_named_bytes32("actualCoreIssueFacetCodeHash", issueFacet.codehash);
        emit log_named_address("actualCoreReserve", reserve);
        emit log_named_address("actualCoreTreasury", treasury);
        emit log_named_address("actualUniswapPool", POOL);
        emit log_named_bytes32("actualUniswapPoolCodeHash", POOL.codehash);
        emit log_named_address("actualUniversalRouter", UNIVERSAL_ROUTER);
        emit log_named_bytes32("actualUniversalRouterCodeHash", UNIVERSAL_ROUTER.codehash);
        emit log_named_address("actualPermit2", PERMIT2);
        emit log_named_bytes32("actualPermit2CodeHash", PERMIT2.codehash);
        emit log_named_address("candidateHelpers", address(helpers));
        emit log_named_address("candidateAdapter", address(adapter));
        emit log_named_address("candidateIssueFacet", deployedIssueFacet);
        emit log_named_bytes32("candidateIssueFacetCodeHash", deployedIssueFacet.codehash);
    }
}
