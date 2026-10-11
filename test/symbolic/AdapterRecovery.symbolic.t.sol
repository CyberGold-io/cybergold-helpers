// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {OneInchAdapter} from "../../src/adapters/OneInchAdapter.sol";
import {IRecoverableSwapAdapter} from "../../src/interfaces/IRecoverableSwapAdapter.sol";
import {MockERC20Adapter} from "../mocks/MockERC20Adapter.sol";

contract SymbolicHelpersOwner {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function recover(address adapter, address token) external {
        IRecoverableSwapAdapter(adapter).recover(token);
    }
}

/// @notice Halmos properties for the narrowly controlled adapter recovery path.
contract AdapterRecoverySymbolicTest is Test {
    OneInchAdapter internal adapter;
    SymbolicHelpersOwner internal helpers;
    MockERC20Adapter internal token;

    function setUp() public {
        helpers = new SymbolicHelpersOwner(address(0xA11CE));
        adapter = new OneInchAdapter(address(helpers), address(0x1234));
        token = new MockERC20Adapter("Symbolic", "SYM");
    }

    function checkUnauthorizedCallerCannotRecover(address caller, uint96 amount) public {
        vm.assume(caller != address(helpers));
        token.mint(address(adapter), amount);
        vm.prank(caller);
        (bool ok,) = address(adapter).call(abi.encodeCall(adapter.recover, (address(token))));
        assertFalse(ok);
        assertEq(token.balanceOf(address(adapter)), amount);
    }

    function checkRecoveryPaysCurrentOwner(address currentOwner, uint96 amount) public {
        vm.assume(currentOwner > address(10));
        vm.assume(currentOwner != address(adapter) && currentOwner != address(token));
        helpers.setOwner(currentOwner);
        token.mint(address(adapter), amount);
        helpers.recover(address(adapter), address(token));
        assertEq(token.balanceOf(currentOwner), amount);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function checkRecoveryAuthorityCannotBeRebound(address replacement) public {
        (bool ok,) = address(adapter).call(abi.encodeWithSignature("bindHelpersDiamond(address)", replacement));
        assertFalse(ok);
        assertEq(adapter.helpersDiamond(), address(helpers));
    }
}
