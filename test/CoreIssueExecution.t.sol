// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CoreIssueExecution} from "../src/libraries/CoreIssueExecution.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {MintableToken, MockCoreController} from "./mocks/BasketRouterMocks.sol";

contract CoreIssueExecutionTest is Test {
    function testMalformedLotAndDishonestCoreCreditRollbackApprovalsAndInputs() public {
        MintableToken a = new MintableToken("A", "A");
        MintableToken b = new MintableToken("B", "B");
        address[] memory assets = new address[](2);
        assets[0] = address(a);
        assets[1] = address(b);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 500_000;
        weights[1] = 500_000;
        uint256[] memory units = new uint256[](2);
        units[0] = 1 ether;
        units[1] = 1 ether;
        MockCoreController core = new MockCoreController(assets, weights, units);
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.CoreAssetAmountsLengthMismatch.selector, 2, 1));
        CoreIssueExecution.settle(address(core), assets, new uint256[](1), 100);
        a.mint(address(this), 50);
        b.mint(address(this), 50);
        uint256[] memory maxima = new uint256[](2);
        maxima[0] = 50;
        maxima[1] = 50;
        vm.mockCall(address(core), abi.encodeCall(IERC20.balanceOf, (address(this))), abi.encode(uint256(0)));
        vm.expectRevert(
            abi.encodeWithSelector(IBasketRouterTypes.RouterTokenCreditMismatch.selector, address(core), 100, 0)
        );
        CoreIssueExecution.settle(address(core), assets, maxima, 100);
        vm.clearMockedCalls();
        assertEq(a.balanceOf(address(this)), 50);
        assertEq(b.balanceOf(address(this)), 50);
        assertEq(a.allowance(address(this), address(core)), 0);
        assertEq(core.safeIssueCallCount(), 0);
    }
}
