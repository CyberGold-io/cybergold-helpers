// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IDiamond} from "diamond-1/interfaces/IDiamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "diamond-1/interfaces/IDiamondLoupe.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";

import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {
    HelpersEnsPrimaryNameInit,
    HelpersEnsPrimaryNameInitBase,
    IHelpersEnsDefaultReverseRegistrar
} from "../src/ens/HelpersEnsPrimaryNameInit.sol";

interface IFacetGeneration {
    function facetGeneration(bytes32 namespace) external view returns (uint64);
}

contract MockHelpersEnsDefaultReverseRegistrar is IHelpersEnsDefaultReverseRegistrar {
    mapping(address addr => string name) private _names;
    bool public persistSetName = true;

    function nameForAddr(address addr) external view returns (string memory) {
        return _names[addr];
    }

    function setName(string calldata name) external {
        if (persistSetName) _names[msg.sender] = name;
    }

    function setNameFor(address addr, string calldata name) external {
        _names[addr] = name;
    }

    function setPersistSetName(bool persist) external {
        persistSetName = persist;
    }
}

/// @dev Binds the production logic to a test registrar without delegatecall-visible configuration.
contract HelpersEnsPrimaryNameInitHarness is HelpersEnsPrimaryNameInitBase {
    address internal constant TEST_REGISTRAR = address(0xE115);

    function _expectedChainId() internal pure override returns (uint256) {
        return 1;
    }

    function _registrar() internal pure override returns (IHelpersEnsDefaultReverseRegistrar) {
        return IHelpersEnsDefaultReverseRegistrar(TEST_REGISTRAR);
    }

    function _expectedRegistrarCodeHash() internal pure virtual override returns (bytes32) {
        return keccak256(type(MockHelpersEnsDefaultReverseRegistrar).runtimeCode);
    }

    function _primaryName() internal pure override returns (string memory) {
        return "helpers.cybergold.eth";
    }
}

contract HelpersEnsPrimaryNameWrongCodeHashHarness is HelpersEnsPrimaryNameInitHarness {
    function _expectedRegistrarCodeHash() internal pure override returns (bytes32) {
        return bytes32(0);
    }
}

contract HelpersEnsPrimaryNameBindingsProbe is HelpersEnsPrimaryNameInit {
    function expectedChainId() external pure returns (uint256) {
        return _expectedChainId();
    }

    function registrar() external pure returns (address) {
        return address(_registrar());
    }

    function registrarCodeHash() external pure returns (bytes32) {
        return _expectedRegistrarCodeHash();
    }

    function primaryName() external pure returns (string memory) {
        return _primaryName();
    }
}

contract HelpersEnsPrimaryNameInitTest is Test {
    bytes32 private constant VALIDATED_DIAMOND_CUT_STATE_SLOT =
        0xfef9e0d4830ecb9885f5f0122b2da44d5685ac964d58d6fbe52ef636cf84be43;
    bytes32 private constant COORDINATOR_NAMESPACE = keccak256("cybergold.upgrade.coordinator.owner");
    address private constant OWNER = address(0xA11CE);
    address private constant TEST_REGISTRAR = address(0xE115);

    MockHelpersEnsDefaultReverseRegistrar private registrar;
    address private diamond;
    address private initializer;

    function setUp() public {
        vm.chainId(1);
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = OWNER;
        cfg.coreDiamond = address(0xC0FE);
        cfg.permit2 = address(0xA11CE2);
        cfg.wrappedNative = address(0xE7);
        cfg.approvedAdapters = new address[](0);
        diamond = address(DeploymentHelper.deploy(cfg).diamond);

        vm.etch(TEST_REGISTRAR, type(MockHelpersEnsDefaultReverseRegistrar).runtimeCode);
        registrar = MockHelpersEnsDefaultReverseRegistrar(TEST_REGISTRAR);
        registrar.setPersistSetName(true);
        initializer = address(new HelpersEnsPrimaryNameInitHarness());
    }

    function testProductionBindingsAreFixed() public {
        HelpersEnsPrimaryNameBindingsProbe probe = new HelpersEnsPrimaryNameBindingsProbe();

        assertEq(probe.expectedChainId(), 1);
        assertEq(probe.registrar(), 0x283F227c4Bd38ecE252C4Ae7ECE650B0e913f1f9);
        assertEq(probe.registrarCodeHash(), 0xa4a48e9075735d1fb6b129422b58ae17af671351ef382107c9386138b4dfd68c);
        assertEq(probe.primaryName(), "helpers.cybergold.eth");
    }

    function testEmptyCutSetsPrimaryNameAndPreservesHelpersState() public {
        bytes32 topologyBefore = _topologyHash();
        address ownerBefore = IERC173(diamond).owner();
        uint64 generationBefore = IFacetGeneration(diamond).facetGeneration(COORDINATOR_NAMESPACE);

        vm.record();
        _executeEmptyCut();
        (, bytes32[] memory writes) = vm.accesses(diamond);

        assertEq(registrar.nameForAddr(diamond), "helpers.cybergold.eth");
        assertEq(_topologyHash(), topologyBefore, "selector topology changed");
        assertEq(IERC173(diamond).owner(), ownerBefore, "owner changed");
        assertEq(
            IFacetGeneration(diamond).facetGeneration(COORDINATOR_NAMESPACE), generationBefore, "generation changed"
        );
        assertEq(uint256(vm.load(diamond, VALIDATED_DIAMOND_CUT_STATE_SLOT)), 0, "coordinator latch uncleared");
        _assertOnlyCoordinatorLatchWasWritten(writes);
    }

    function testExistingExpectedNameIsSafeToReplay() public {
        registrar.setNameFor(diamond, "helpers.cybergold.eth");

        _executeEmptyCut();

        assertEq(registrar.nameForAddr(diamond), "helpers.cybergold.eth");
    }

    function testRejectsConflictingExistingName() public {
        registrar.setNameFor(diamond, "another-name.eth");

        vm.expectRevert(
            abi.encodeWithSelector(
                HelpersEnsPrimaryNameInitBase.EnsPrimaryNameUnexpectedCurrent.selector, keccak256("another-name.eth")
            )
        );
        _executeEmptyCut();
    }

    function testRejectsWrongChain() public {
        vm.chainId(11_155_111);

        vm.expectRevert(
            abi.encodeWithSelector(HelpersEnsPrimaryNameInitBase.EnsPrimaryNameWrongChain.selector, uint256(11_155_111))
        );
        _executeEmptyCut();
    }

    function testRejectsRegistrarRuntimeMismatch() public {
        initializer = address(new HelpersEnsPrimaryNameWrongCodeHashHarness());

        vm.expectRevert(
            abi.encodeWithSelector(
                HelpersEnsPrimaryNameInitBase.EnsPrimaryNameRegistrarRuntimeMismatch.selector,
                address(registrar).codehash
            )
        );
        _executeEmptyCut();
    }

    function testRejectsWhenRegistrarDoesNotPersistName() public {
        registrar.setPersistSetName(false);

        vm.expectRevert(
            abi.encodeWithSelector(
                HelpersEnsPrimaryNameInitBase.EnsPrimaryNamePostconditionFailed.selector, keccak256("")
            )
        );
        _executeEmptyCut();
    }

    function _executeEmptyCut() private {
        vm.prank(OWNER);
        IDiamondCut(diamond)
            .diamondCut(
                new IDiamond.FacetCut[](0), address(initializer), abi.encodeCall(HelpersEnsPrimaryNameInitBase.init, ())
            );
    }

    function _topologyHash() private view returns (bytes32 topologyHash) {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address[] memory facets = loupe.facetAddresses();
        topologyHash = keccak256(abi.encode(facets));
        for (uint256 i; i < facets.length; ++i) {
            topologyHash = keccak256(abi.encode(topologyHash, facets[i], loupe.facetFunctionSelectors(facets[i])));
        }
    }

    function _assertOnlyCoordinatorLatchWasWritten(bytes32[] memory writes) private pure {
        require(writes.length != 0, "expected coordinator latch write");
        for (uint256 i; i < writes.length; ++i) {
            require(writes[i] == VALIDATED_DIAMOND_CUT_STATE_SLOT, "unexpected Helpers storage write");
        }
    }
}
