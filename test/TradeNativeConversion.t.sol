// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {TradeConversionBase} from "../src/facets/TradeConversionBase.sol";
import {ITradeExactInput as T} from "../src/interfaces/ITradeExactInput.sol";
import {IUniswapRoutingTypes as U} from "../src/interfaces/IUniswapRoutingTypes.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {ExactInputBoundaryAdapter} from "./mocks/ExactInputBoundaryAdapter.sol";
import {MintableToken, MockWETH} from "./mocks/BasketRouterMocks.sol";

/// @dev Exercises the same conversion module with the legacy compiler's precise branch instrumentation.
/// The complete entrypoint is independently exercised with its production IR profile.
contract TradeConversionHarness is TradeConversionBase {
    using EnumerableSet for EnumerableSet.AddressSet;

    constructor(address permit2, address adapter, address weth) TradeConversionBase(permit2, adapter) {
        LibAppStorage.routerStorage().wrappedNative = weth;
        LibAppStorage.routerStorage().approvedAdapters.add(adapter);
    }

    function convert(address source, uint256 amount, address normalizedInput, address output)
        external
        returns (uint256)
    {
        T.AmmTemplate memory route;
        route.inputCurrency = normalizedInput;
        route.outputCurrency = output;
        if (normalizedInput != output) {
            route.routes = new T.WeightedRoute[](1);
            route.routes[0].steps = new U.Step[](1);
            route.routes[0].steps[0] = U.Step(U.StepKind.V4, output, 500, 10);
        }
        Execution memory ex;
        return _convert(source, amount, route, output, ex);
    }

    receive() external payable {}
}

contract TradeNativeConversionTest is Test {
    function testDishonestWrappedNativeDebitCannotConsumeTheOwnedLot() public {
        MockWETH weth = new MockWETH();
        ExactInputBoundaryAdapter adapter = new ExactInputBoundaryAdapter();
        TradeConversionHarness harness = new TradeConversionHarness(address(1), address(adapter), address(weth));
        weth.mint(address(harness), 100);
        vm.deal(address(weth), 1 ether);
        bytes[] memory reported = new bytes[](2);
        reported[0] = abi.encode(uint256(100));
        reported[1] = abi.encode(uint256(1));
        vm.mockCalls(address(weth), abi.encodeWithSignature("balanceOf(address)", address(harness)), reported);
        vm.expectRevert(
            abi.encodeWithSignature("RouterTokenDebitMismatch(address,uint256,uint256)", address(weth), 100, 99)
        );
        harness.convert(address(weth), 100, address(0), address(0));
        vm.clearMockedCalls();
        assertEq(weth.balanceOf(address(harness)), 100);
        assertEq(address(harness).balance, 0);
    }

    function testSharedModuleNativeWrappingAndBothAmmFundingPaths() public {
        MockWETH weth = new MockWETH();
        MintableToken asset = new MintableToken("Output", "OUT");
        ExactInputBoundaryAdapter adapter = new ExactInputBoundaryAdapter();
        TradeConversionHarness harness = new TradeConversionHarness(address(1), address(adapter), address(weth));
        vm.deal(address(harness), 1 ether);
        vm.deal(address(weth), 1 ether);
        asset.mint(address(adapter), 1_000);
        adapter.setRate(address(0), address(asset), 2, 1, 0);
        adapter.setRate(address(weth), address(asset), 2, 1, 0);
        assertEq(harness.convert(address(0), 100, address(weth), address(weth)), 100);
        assertEq(harness.convert(address(weth), 100, address(0), address(0)), 100);
        assertEq(harness.convert(address(0), 100, address(0), address(asset)), 200);
        assertEq(harness.convert(address(0), 100, address(weth), address(asset)), 200);
        assertEq(weth.allowance(address(harness), address(adapter)), 0);
        assertEq(asset.balanceOf(address(harness)), 400);
    }
}
