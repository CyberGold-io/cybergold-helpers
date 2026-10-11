// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {NotContractOwner} from "diamond-1/libraries/LibDiamond.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {DiamondCutOwnerLiveFacet} from "../src/facets/DiamondCutOwnerLiveFacet.sol";
import {ProtocolDiamondLoupeFacet} from "diamond-infra/facets/ProtocolDiamondLoupeFacet.sol";
import {OwnershipFacet} from "../src/facets/OwnershipFacet.sol";
import {OwnerPausableFacet} from "../src/facets/OwnerPausableFacet.sol";
import {RouterAdminFacet} from "../src/facets/RouterAdminFacet.sol";
import {RouterIssueFacet} from "../src/facets/RouterIssueFacet.sol";
import {RouterIssuePreviewFacet} from "../src/facets/RouterIssuePreviewFacet.sol";
import {RouterIssueBasketFacet} from "../src/facets/RouterIssueBasketFacet.sol";
import {RouterRedeemFacet} from "../src/facets/RouterRedeemFacet.sol";
import {RouterRedeemBasketFacet} from "../src/facets/RouterRedeemBasketFacet.sol";
import {RecoveryShareReceiverFacet} from "../src/facets/RecoveryShareReceiverFacet.sol";
import {OneInchAdapter} from "../src/adapters/OneInchAdapter.sol";
import {MintableToken, MockPermit2, MockSwapAdapterRouter, MockWETH} from "./mocks/BasketRouterMocks.sol";

contract AdminDummyCore {}

contract AdminRejectNative {
    error NativeRejected();

    receive() external payable {
        revert NativeRejected();
    }
}

contract AdminFalseTransferToken {
    mapping(address account => uint256 balance) public balanceOf;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract BasketRouterAdminTest is Test {
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;

    address private constant OWNER = address(0xA11CE);
    address private constant NEXT_OWNER = address(0xB0B);
    address private constant OUTSIDER = address(0xBAD);

    MockPermit2 private permit2;
    MockWETH private wrappedNative;
    AdminDummyCore private core;
    MockSwapAdapterRouter private initialAdapter;
    ICyberGoldHelpers private router;

    function setUp() public {
        permit2 = new MockPermit2();
        wrappedNative = new MockWETH();
        core = new AdminDummyCore();
        initialAdapter = new MockSwapAdapterRouter();

        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = OWNER;
        cfg.coreDiamond = address(core);
        cfg.permit2 = address(permit2);
        cfg.wrappedNative = address(wrappedNative);
        cfg.helperFeePpm = 100;
        cfg.approvedAdapters = new address[](1);
        cfg.approvedAdapters[0] = address(initialAdapter);
        router = ICyberGoldHelpers(address(DeploymentHelper.deploy(cfg).diamond));
    }

    function testDeploymentInitializesFrozenTopologyAndConfiguration() public view {
        assertEq(router.owner(), OWNER);
        assertEq(router.coreDiamond(), address(core));
        assertEq(router.permit2(), address(permit2));
        assertEq(router.wrappedNative(), address(wrappedNative));
        assertEq(router.helperFeePpm(), 100);
        assertTrue(router.isAdapterApproved(address(initialAdapter)));
        assertFalse(router.supportsInterface(type(ICyberGoldHelpers).interfaceId));
        assertTrue(router.supportsInterface(type(IERC165).interfaceId));
        assertTrue(router.supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(router.supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(router.supportsInterface(type(IERC173).interfaceId));
        assertTrue(router.supportsInterface(type(IERC1155Receiver).interfaceId));
        assertFalse(router.supportsInterface(0xffffffff));
        assertEq(vm.load(address(router), INITIALIZABLE_STORAGE), bytes32(0));
        assertEq(IDiamondLoupe(address(router)).facetAddress(bytes4(keccak256("initReentrancyGuard()"))), address(0));
        bytes32 legacyGuardVersionSlot =
            keccak256(abi.encode(keccak256("openzeppelin.storage.ReentrancyGuard"), FACET_VERSION_REGISTRY_SLOT));
        assertEq(vm.load(address(router), legacyGuardVersionSlot), bytes32(0));

        address[] memory adapters = router.approvedAdapters();
        assertEq(adapters.length, 1);
        assertEq(adapters[0], address(initialAdapter));
    }

    function testAdapterSetterBindsCurrentStateAndRejectsNoop() public {
        address second = address(0xA11CE);

        vm.expectRevert(IBasketRouterTypes.AdapterApprovalChangeNoop.selector);
        vm.prank(OWNER);
        router.setAdapterApproval(second, false, false);

        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.AdapterApprovalCurrentMismatch.selector, true, false));
        vm.prank(OWNER);
        router.setAdapterApproval(second, true, false);

        vm.prank(OWNER);
        router.setAdapterApproval(second, false, true);
        assertTrue(router.isAdapterApproved(second));

        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.AdapterApprovalCurrentMismatch.selector, false, true));
        vm.prank(OWNER);
        router.setAdapterApproval(second, false, true);

        vm.prank(OWNER);
        router.setAdapterApproval(second, true, false);
        assertFalse(router.isAdapterApproved(second));
    }

    function testAdapterRecoveryWorksAfterDeapprovalAndPaysCurrentOwner() public {
        OneInchAdapter recoverable = new OneInchAdapter(address(router), address(0x1234));
        MintableToken token = new MintableToken("Recovery", "RCV");

        vm.prank(OWNER);
        router.setAdapterApproval(address(recoverable), false, true);
        vm.prank(OWNER);
        router.setAdapterApproval(address(recoverable), true, false);

        vm.prank(OWNER);
        router.transferOwnership(NEXT_OWNER);
        vm.prank(NEXT_OWNER);
        router.acceptOwnership();

        token.mint(address(recoverable), 5 ether);
        vm.prank(NEXT_OWNER);
        router.recoverAdapter(address(recoverable), address(token));
        assertEq(token.balanceOf(NEXT_OWNER), 5 ether);
        assertEq(token.balanceOf(address(recoverable)), 0);
    }

    function testFeeSetterIsOwnerOnlyCurrentBoundAndCapped() public {
        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, OUTSIDER, OWNER));
        vm.prank(OUTSIDER);
        router.setHelperFeePpm(100, 200);

        vm.expectRevert(IBasketRouterTypes.HelperFeeChangeNoop.selector);
        vm.prank(OWNER);
        router.setHelperFeePpm(100, 100);

        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.HelperFeeCurrentMismatch.selector, 99, 100));
        vm.prank(OWNER);
        router.setHelperFeePpm(99, 200);

        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.HelperFeeTooHigh.selector, 5_001));
        vm.prank(OWNER);
        router.setHelperFeePpm(100, 5_001);

        vm.prank(OWNER);
        router.setHelperFeePpm(100, 200);
        assertEq(router.helperFeePpm(), 200);
    }

    function testOwnershipIsTwoStepCancelableAndRejectsInvalidNominees() public {
        vm.expectRevert(abi.encodeWithSelector(OwnershipFacet.InvalidOwnershipTransfer.selector, OWNER, address(0)));
        vm.prank(OWNER);
        router.transferOwnership(address(0));

        vm.expectRevert(abi.encodeWithSelector(OwnershipFacet.InvalidOwnershipTransfer.selector, OWNER, OWNER));
        vm.prank(OWNER);
        router.transferOwnership(OWNER);

        vm.prank(OWNER);
        router.transferOwnership(NEXT_OWNER);
        vm.expectRevert(abi.encodeWithSelector(OwnershipFacet.NotPendingOwner.selector, OUTSIDER, NEXT_OWNER));
        vm.prank(OUTSIDER);
        router.acceptOwnership();

        vm.prank(OWNER);
        router.cancelOwnershipTransfer();
        assertEq(router.pendingOwner(), address(0));

        vm.expectRevert(OwnershipFacet.NoPendingOwnershipTransfer.selector);
        vm.prank(OWNER);
        router.cancelOwnershipTransfer();
    }

    function testPauseAndUnpauseRemainOwnerGated() public {
        vm.prank(OWNER);
        router.pause();
        assertTrue(router.paused());

        vm.expectRevert(abi.encodeWithSelector(NotContractOwner.selector, OUTSIDER, OWNER));
        vm.prank(OUTSIDER);
        router.unpause();

        vm.prank(OWNER);
        router.unpause();
        assertFalse(router.paused());
    }

    function testSweepTokenAndNativeWithoutLeakingOlderBalances() public {
        MintableToken token = new MintableToken("Dust", "DST");
        address recipient = address(0xD1557);
        token.mint(address(router), 3 ether);
        vm.deal(address(router), 2 ether);

        vm.prank(OWNER);
        router.sweep(address(token), recipient);
        vm.prank(OWNER);
        router.sweep(address(0), recipient);
        assertEq(token.balanceOf(recipient), 3 ether);
        assertEq(recipient.balance, 2 ether);

        vm.prank(OWNER);
        router.sweep(address(token), recipient);
        vm.prank(OWNER);
        router.sweep(address(0), recipient);
    }

    function testSweepRejectsInvalidRecipientAndBubblesTransferFailures() public {
        vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
        vm.prank(OWNER);
        router.sweep(address(0), address(0));

        AdminRejectNative rejecting = new AdminRejectNative();
        vm.deal(address(router), 1 ether);
        vm.expectRevert(AdminRejectNative.NativeRejected.selector);
        vm.prank(OWNER);
        router.sweep(address(0), address(rejecting));

        AdminFalseTransferToken falseToken = new AdminFalseTransferToken();
        falseToken.setBalance(address(router), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falseToken)));
        vm.prank(OWNER);
        router.sweep(address(falseToken), address(0xD1557));
    }

    function testInvalidDeploymentConfigurationAndFacetConstructorsRevert() public {
        vm.expectRevert(IBasketRouterTypes.InvalidPermit2.selector);
        new RouterAdminFacet(address(0));

        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = OWNER;
        cfg.coreDiamond = address(core);
        cfg.permit2 = address(permit2);
        cfg.wrappedNative = address(wrappedNative);
        cfg.helperFeePpm = 5_001;
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.HelperFeeTooHigh.selector, 5_001));
        this.deployExternal(cfg);

        cfg.helperFeePpm = 0;
        cfg.coreDiamond = address(0);
        vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
        this.deployExternal(cfg);

        cfg.coreDiamond = address(core);
        cfg.wrappedNative = address(0);
        vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
        this.deployExternal(cfg);
    }

    function testProductionFacetGenerationsStartAtOneAndRetiredRegistryStaysZero() public {
        DiamondCutOwnerLiveFacet liveCoordinator = new DiamondCutOwnerLiveFacet();
        assertEq(liveCoordinator.FACET_NAMESPACE(), keccak256("cybergold.upgrade.coordinator.owner"));
        (bool hasIntrinsicVersion,) = address(liveCoordinator).staticcall(abi.encodeWithSignature("FACET_VERSION()"));
        assertFalse(hasIntrinsicVersion);
        assertEq(new ProtocolDiamondLoupeFacet().FACET_VERSION(), 1);
        assertEq(new OwnershipFacet().FACET_VERSION(), 1);
        assertEq(new OwnerPausableFacet().FACET_VERSION(), 1);
        assertEq(new RouterAdminFacet(address(permit2)).FACET_VERSION(), 1);
        assertEq(new RouterIssuePreviewFacet(address(permit2)).FACET_VERSION(), 1);
        assertEq(new RouterIssueFacet(address(permit2)).FACET_VERSION(), 1);
        assertEq(new RouterIssueBasketFacet(address(permit2)).FACET_VERSION(), 1);
        assertEq(new RouterRedeemFacet(address(permit2)).FACET_VERSION(), 1);
        assertEq(new RouterRedeemBasketFacet(address(permit2)).FACET_VERSION(), 1);
        assertEq(new RecoveryShareReceiverFacet().FACET_VERSION(), 1);

        _assertFacetGeneration("cybergold.upgrade.coordinator.owner");
        _assertFacetGeneration("cybergold.shared.diamond.loupe");
        _assertFacetGeneration("cybergold.helpers.ownership");
        _assertFacetGeneration("cybergold.helpers.owner.pausable");
        _assertFacetGeneration("cybergold.helpers.admin");
        _assertFacetGeneration("cybergold.helpers.issue.preview");
        _assertFacetGeneration("cybergold.helpers.issue");
        _assertFacetGeneration("cybergold.helpers.issue.basket");
        _assertFacetGeneration("cybergold.helpers.redeem");
        _assertFacetGeneration("cybergold.helpers.redeem.basket");
        _assertFacetGeneration("cybergold.helpers.recovery-share-receiver");

        IDiamondLoupe loupe = IDiamondLoupe(address(router));
        address[] memory installed = loupe.facetAddresses();
        bytes32[] memory namespaces = new bytes32[](11);
        uint256 namespacedFacetCount;
        assertEq(installed.length, 11);
        for (uint256 i; i < installed.length; ++i) {
            (bool namespaceOk, bytes memory namespaceData) =
                installed[i].staticcall(abi.encodeWithSignature("FACET_NAMESPACE()"));
            assertTrue(namespaceOk && namespaceData.length >= 32);
            bytes32 namespace = abi.decode(namespaceData, (bytes32));
            assertTrue(namespace != bytes32(0));
            for (uint256 j; j < namespacedFacetCount; ++j) {
                assertTrue(namespace != namespaces[j]);
            }
            namespaces[namespacedFacetCount++] = namespace;
        }
        assertEq(namespacedFacetCount, 11);
    }

    function deployExternal(DeploymentTypes.DeployConfig calldata cfg) external {
        DeploymentHelper.deploy(cfg);
    }

    function _assertFacetGeneration(string memory namespaceLabel) private view {
        bytes32 namespace = keccak256(bytes(namespaceLabel));
        bytes32 slot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        assertEq(uint64(uint256(vm.load(address(router), slot))), 1);
        (bool ok, bytes memory data) =
            address(router).staticcall(abi.encodeWithSignature("facetGeneration(bytes32)", namespace));
        assertTrue(ok);
        assertEq(abi.decode(data, (uint64)), 1);
        for (uint256 offset = 1; offset <= 4; ++offset) {
            bytes32 retired = keccak256(abi.encode(namespace, bytes32(uint256(FACET_VERSION_REGISTRY_SLOT) + offset)));
            assertEq(vm.load(address(router), retired), bytes32(0));
        }
    }
}
