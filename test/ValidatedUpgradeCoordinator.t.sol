// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC165} from "diamond-1/interfaces/IERC165.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {LiveValidatedDiamondCut} from "diamond-infra/helpers/LiveValidatedDiamondCut.sol";
import {InterfaceRetirementInit} from "diamond-infra/helpers/InterfaceRetirementInit.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";

import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";

interface IFacetGeneration {
    function facetGeneration(bytes32 namespace) external view returns (uint64);
}

contract HelpersUpgradeProbeFacet {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.test.upgrade.probe");

    function upgradeProbe() external pure returns (bytes32) {
        return keccak256("validated");
    }
}

contract HelpersUpgradeProbeFacetV2 {
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.test.upgrade.probe");

    function upgradeProbe() external pure returns (bytes32) {
        return keccak256("validated-v2");
    }
}

contract HelpersLiveUpgradeInit {
    bytes32 private constant FACET_VERSION_REGISTRY_SLOT =
        0x719ab1798b7437cf2b0a642d6beb72f1485a260ffbc7817c2b7c41ec779b30e8;

    function noop() external pure {}

    function mutateGeneration(bytes32 namespace, uint64 generation) external {
        bytes32 slot = keccak256(abi.encode(namespace, FACET_VERSION_REGISTRY_SLOT));
        assembly {
            sstore(slot, generation)
        }
    }

    function setOwner(address owner) external {
        LibDiamond.diamondStorage().contractOwner = owner;
    }
}

contract ValidatedUpgradeCoordinatorTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant OUTSIDER = address(0xBEEF);

    address internal diamond;
    bytes32 internal constant PROBE_NAMESPACE = keccak256("cybergold.helpers.test.upgrade.probe");

    function setUp() public {
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = OWNER;
        cfg.coreDiamond = address(0xC0FE);
        cfg.permit2 = address(0xA11CE2);
        cfg.wrappedNative = address(0xE7);
        cfg.approvedAdapters = new address[](0);
        diamond = address(DeploymentHelper.deploy(cfg).diamond);
    }

    function test_ownerCanInstallFacetAndCoordinatorCommitsGeneration() public {
        HelpersUpgradeProbeFacet facet = new HelpersUpgradeProbeFacet();
        HelpersLiveUpgradeInit init = new HelpersLiveUpgradeInit();

        vm.prank(OWNER);
        IDiamondCut(diamond)
            .diamondCut(
                _probeCut(address(facet), IDiamond.FacetCutAction.Add),
                address(init),
                abi.encodeCall(HelpersLiveUpgradeInit.noop, ())
            );

        assertEq(HelpersUpgradeProbeFacet(diamond).upgradeProbe(), keccak256("validated"));
        assertEq(IFacetGeneration(diamond).facetGeneration(PROBE_NAMESPACE), 1);
    }

    function test_upgradeAdvancesInstalledGenerationWithoutFacetVersionMetadata() public {
        HelpersUpgradeProbeFacet v1 = new HelpersUpgradeProbeFacet();
        HelpersUpgradeProbeFacetV2 v2 = new HelpersUpgradeProbeFacetV2();
        HelpersLiveUpgradeInit init = new HelpersLiveUpgradeInit();

        vm.startPrank(OWNER);
        IDiamondCut(diamond)
            .diamondCut(
                _probeCut(address(v1), IDiamond.FacetCutAction.Add),
                address(init),
                abi.encodeCall(HelpersLiveUpgradeInit.noop, ())
            );
        IDiamondCut(diamond)
            .diamondCut(
                _probeCut(address(v2), IDiamond.FacetCutAction.Replace),
                address(init),
                abi.encodeCall(HelpersLiveUpgradeInit.noop, ())
            );
        vm.stopPrank();

        assertEq(HelpersUpgradeProbeFacetV2(diamond).upgradeProbe(), keccak256("validated-v2"));
        assertEq(IFacetGeneration(diamond).facetGeneration(PROBE_NAMESPACE), 2);
    }

    function test_sameLiveRuntimeAtAnotherAddressIsRejected() public {
        HelpersUpgradeProbeFacet incumbent = new HelpersUpgradeProbeFacet();
        HelpersUpgradeProbeFacet identical = new HelpersUpgradeProbeFacet();
        HelpersLiveUpgradeInit init = new HelpersLiveUpgradeInit();

        vm.startPrank(OWNER);
        IDiamondCut(diamond)
            .diamondCut(
                _probeCut(address(incumbent), IDiamond.FacetCutAction.Add),
                address(init),
                abi.encodeCall(HelpersLiveUpgradeInit.noop, ())
            );
        vm.expectPartialRevert(LiveValidatedDiamondCut.DiamondCutFacetRuntimeUnchanged.selector);
        IDiamondCut(diamond)
            .diamondCut(
                _probeCut(address(identical), IDiamond.FacetCutAction.Replace),
                address(init),
                abi.encodeCall(HelpersLiveUpgradeInit.noop, ())
            );
        vm.stopPrank();
    }

    function test_addReplaceAndRemoveWithoutInitializerCommitGenerations() public {
        HelpersUpgradeProbeFacet facet = new HelpersUpgradeProbeFacet();
        HelpersUpgradeProbeFacetV2 replacement = new HelpersUpgradeProbeFacetV2();

        vm.startPrank(OWNER);
        IDiamondCut(diamond).diamondCut(_probeCut(address(facet), IDiamond.FacetCutAction.Add), address(0), "");
        assertEq(HelpersUpgradeProbeFacet(diamond).upgradeProbe(), keccak256("validated"));
        assertEq(IFacetGeneration(diamond).facetGeneration(PROBE_NAMESPACE), 1);
        IDiamondCut(diamond)
            .diamondCut(_probeCut(address(replacement), IDiamond.FacetCutAction.Replace), address(0), "");
        assertEq(HelpersUpgradeProbeFacetV2(diamond).upgradeProbe(), keccak256("validated-v2"));
        assertEq(IFacetGeneration(diamond).facetGeneration(PROBE_NAMESPACE), 2);
        IDiamondCut(diamond).diamondCut(_removeCut(HelpersUpgradeProbeFacet.upgradeProbe.selector), address(0), "");
        assertEq(IDiamondLoupe(diamond).facetAddress(HelpersUpgradeProbeFacet.upgradeProbe.selector), address(0));
        assertEq(IFacetGeneration(diamond).facetGeneration(PROBE_NAMESPACE), 0);
        vm.stopPrank();
    }

    function test_optionalInitializerRetainsMalformedCalldataRejection() public {
        HelpersUpgradeProbeFacet facet = new HelpersUpgradeProbeFacet();
        HelpersLiveUpgradeInit init = new HelpersLiveUpgradeInit();
        vm.startPrank(OWNER);
        vm.expectRevert(LiveValidatedDiamondCut.DiamondCutUnexpectedInitializerCalldata.selector);
        IDiamondCut(diamond)
            .diamondCut(_probeCut(address(facet), IDiamond.FacetCutAction.Add), address(0), hex"12345678");
        vm.expectRevert(LiveValidatedDiamondCut.DiamondCutInitializerCalldataTooShort.selector);
        IDiamondCut(diamond)
            .diamondCut(_probeCut(address(facet), IDiamond.FacetCutAction.Add), address(init), hex"1234");
        vm.stopPrank();
        assertEq(IDiamondLoupe(diamond).facetAddress(HelpersUpgradeProbeFacet.upgradeProbe.selector), address(0));
        assertEq(IFacetGeneration(diamond).facetGeneration(PROBE_NAMESPACE), 0);
    }

    function test_initializerCannotMutateCoordinatorOwnedGeneration() public {
        HelpersUpgradeProbeFacet facet = new HelpersUpgradeProbeFacet();
        HelpersLiveUpgradeInit init = new HelpersLiveUpgradeInit();

        vm.prank(OWNER);
        vm.expectPartialRevert(LiveValidatedDiamondCut.DiamondCutFacetGenerationChangedDuringInitialization.selector);
        IDiamondCut(diamond)
            .diamondCut(
                _probeCut(address(facet), IDiamond.FacetCutAction.Add),
                address(init),
                abi.encodeCall(HelpersLiveUpgradeInit.mutateGeneration, (PROBE_NAMESPACE, uint64(7)))
            );
    }

    function test_diamondCutAndGenerationGetterCannotBeReplacedOrRemoved() public {
        HelpersUpgradeProbeFacet facet = new HelpersUpgradeProbeFacet();
        bytes4[] memory replaceSelectors = new bytes4[](1);
        replaceSelectors[0] = IDiamondCut.diamondCut.selector;
        IDiamond.FacetCut[] memory replaceCut = new IDiamond.FacetCut[](1);
        replaceCut[0] = IDiamond.FacetCut({
            facetAddress: address(facet), action: IDiamond.FacetCutAction.Replace, functionSelectors: replaceSelectors
        });

        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutCoordinatorImmutable.selector, IDiamondCut.diamondCut.selector
            )
        );
        IDiamondCut(diamond).diamondCut(replaceCut, address(0), "");

        bytes4 getter = IFacetGeneration.facetGeneration.selector;
        vm.expectRevert(abi.encodeWithSelector(LiveValidatedDiamondCut.DiamondCutCoordinatorImmutable.selector, getter));
        IDiamondCut(diamond).diamondCut(_removeCut(getter), address(0), "");
        vm.stopPrank();
    }

    function test_cutCannotRemoveOwnerRecoverySurface() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IERC173.owner.selector
            )
        );
        IDiamondCut(diamond).diamondCut(_removeCut(IERC173.owner.selector), address(0), "");
        assertEq(IERC173(diamond).owner(), OWNER);
    }

    function test_cutRejectsZeroOwner() public {
        HelpersUpgradeProbeFacet facet = new HelpersUpgradeProbeFacet();
        HelpersLiveUpgradeInit init = new HelpersLiveUpgradeInit();
        IDiamond.FacetCut[] memory cut = _probeCut(address(facet), IDiamond.FacetCutAction.Add);

        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiveValidatedDiamondCut.DiamondCutRecoveryInvariantFailed.selector, IERC173.owner.selector
            )
        );
        IDiamondCut(diamond)
            .diamondCut(cut, address(init), abi.encodeCall(HelpersLiveUpgradeInit.setOwner, (address(0))));
    }

    function test_nonAdvertisedProductSelectorCanBeRemoved() public {
        bytes4 selector = ICyberGoldHelpers.helperFeePpm.selector;

        assertFalse(IERC165(diamond).supportsInterface(type(ICyberGoldHelpers).interfaceId));
        vm.prank(OWNER);
        IDiamondCut(diamond).diamondCut(_removeCut(selector), address(0), "");
        assertEq(IDiamondLoupe(diamond).facetAddress(selector), address(0));
    }

    function test_receiverInterfaceCanBeRetiredAtomicallyWithSelectorRemoval() public {
        bytes4 selector = IERC1155Receiver.onERC1155Received.selector;
        bytes4[] memory interfaceIds = new bytes4[](1);
        interfaceIds[0] = type(IERC1155Receiver).interfaceId;
        InterfaceRetirementInit init = new InterfaceRetirementInit();

        vm.prank(OWNER);
        IDiamondCut(diamond)
            .diamondCut(
                _removeCut(selector),
                address(init),
                abi.encodeCall(InterfaceRetirementInit.retireInterfaces, (interfaceIds))
            );

        assertFalse(IERC165(diamond).supportsInterface(type(IERC1155Receiver).interfaceId));
        assertEq(IDiamondLoupe(diamond).facetAddress(selector), address(0));
    }

    function test_nonOwnerCannotReachCoordinatorValidation() public {
        vm.prank(OUTSIDER);
        vm.expectRevert();
        IDiamondCut(diamond).diamondCut(new IDiamond.FacetCut[](0), address(0), "");
    }

    function _probeCut(address facet, IDiamond.FacetCutAction action)
        private
        pure
        returns (IDiamond.FacetCut[] memory cut)
    {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = HelpersUpgradeProbeFacet.upgradeProbe.selector;
        cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({facetAddress: facet, action: action, functionSelectors: selectors});
    }

    function _removeCut(bytes4 selector) private pure returns (IDiamond.FacetCut[] memory cut) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        cut = new IDiamond.FacetCut[](1);
        cut[0] = IDiamond.FacetCut({
            facetAddress: address(0), action: IDiamond.FacetCutAction.Remove, functionSelectors: selectors
        });
    }
}
