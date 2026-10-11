// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {OneInchAdapter} from "src/adapters/OneInchAdapter.sol";
import {AdapterAccounting} from "src/adapters/AdapterAccounting.sol";
import {IRecoverableSwapAdapter} from "src/interfaces/IRecoverableSwapAdapter.sol";
import {MockERC20Adapter} from "./mocks/MockERC20Adapter.sol";

contract MockHelpersOwner {
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

contract RejectingRecoveryRecipient {
    receive() external payable {
        revert("native rejected");
    }
}

contract AdapterRecoveryTest is Test {
    OneInchAdapter internal adapter;
    MockHelpersOwner internal helpers;
    MockERC20Adapter internal token;
    address internal safe = address(0xA11CE);

    function setUp() public {
        helpers = new MockHelpersOwner(safe);
        adapter = new OneInchAdapter(address(helpers), address(0x1234));
        token = new MockERC20Adapter("Stranded", "STK");
    }

    function test_recoveryPaysOnlyCurrentHelpersOwner() public {
        token.mint(address(adapter), 5 ether);
        helpers.recover(address(adapter), address(token));
        assertEq(token.balanceOf(safe), 5 ether);
        assertEq(token.balanceOf(address(adapter)), 0);

        address nextSafe = address(0xB0B);
        helpers.setOwner(nextSafe);
        token.mint(address(adapter), 2 ether);
        helpers.recover(address(adapter), address(token));
        assertEq(token.balanceOf(nextSafe), 2 ether);
    }

    function test_nativeRecoveryPaysOnlyCurrentHelpersOwner() public {
        vm.deal(address(adapter), 1 ether);
        helpers.recover(address(adapter), address(0));
        assertEq(safe.balance, 1 ether);
        assertEq(address(adapter).balance, 0);
    }

    function test_recoveryRejectsDirectCallerAndAuthorityIsImmutable() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AdapterAccounting.UnauthorizedRecoveryCaller.selector, address(this), address(helpers)
            )
        );
        adapter.recover(address(token));

        (bool rebound,) = address(adapter).call(abi.encodeWithSignature("bindHelpersDiamond(address)", address(this)));
        assertFalse(rebound);
        assertEq(adapter.helpersDiamond(), address(helpers));
    }

    function test_constructorRejectsInvalidAuthorities() public {
        vm.expectRevert(abi.encodeWithSelector(AdapterAccounting.InvalidRecoveryAuthority.selector, address(0)));
        new OneInchAdapter(address(0), address(0x1234));
        vm.expectRevert(abi.encodeWithSelector(AdapterAccounting.InvalidRecoveryAuthority.selector, address(0xBEEF)));
        new OneInchAdapter(address(0xBEEF), address(0x1234));
    }

    function test_recoveryRejectsZeroOwnerAndFailedNativeRecipient() public {
        helpers.setOwner(address(0));
        vm.expectRevert(abi.encodeWithSelector(AdapterAccounting.InvalidRecoveryAuthority.selector, address(0)));
        helpers.recover(address(adapter), address(token));

        RejectingRecoveryRecipient rejecting = new RejectingRecoveryRecipient();
        helpers.setOwner(address(rejecting));
        vm.deal(address(adapter), 1 ether);
        vm.expectRevert(AdapterAccounting.NativeRecoveryFailed.selector);
        helpers.recover(address(adapter), address(0));
    }
}
