// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketSwap} from "../../src/interfaces/IMarketSwap.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {MarketFacetHarness} from "../MarketSwapFacet.t.sol";
import {MockERC20Adapter} from "../mocks/MockERC20Adapter.sol";

/// @notice Venue model with independent input consumption and gross output.
/// @dev Token creation models venue output, not the production token supply behavior.
contract SymbolicMarketVenue is ISwapAdapter {
    function swap(address tokenIn, address tokenOut, uint256, bytes calldata data)
        external
        returns (uint256 amountOut)
    {
        (uint256 spent, uint256 grossOutput) = abi.decode(data, (uint256, uint256));
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), spent), "venue transfer");
        MockERC20Adapter(tokenOut).mint(msg.sender, grossOutput);
        return grossOutput;
    }
}

/// @notice Actual market-facet settlement conservation under bounded symbolic venue outcomes.
/// @dev Uses uint96 economic components, exact ERC20s, allowance funding and distinct fixed roles.
/// Permit signatures, owner changes, production token supply and venue pricing are outside scope.
contract MarketSwapSymbolicTest is Test {
    address private constant PAYER = address(0xF00D);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant OWNER = address(0xBEEF);
    MarketFacetHarness private market;
    SymbolicMarketVenue private venue;
    MockERC20Adapter private cygld;
    MockERC20Adapter private counter;

    function setUp() public {
        cygld = new MockERC20Adapter("CYGLD", "CYGLD");
        counter = new MockERC20Adapter("Counter", "CTR");
        venue = new SymbolicMarketVenue();
        market = new MarketFacetHarness(address(0x1234));
        market.configure(address(cygld), address(venue), OWNER);
    }

    function checkBuyExactInputConservesFeeAndCurrentLot(
        uint96 budget,
        uint96 spent,
        uint96 grossOutput,
        uint96 fee,
        uint96 oldInput,
        uint96 oldOutput
    ) public {
        vm.assume(budget > 0);
        vm.assume(spent <= budget);
        vm.assume(grossOutput > fee);
        counter.mint(PAYER, budget);
        counter.mint(address(market), oldInput);
        cygld.mint(address(market), oldOutput);
        vm.prank(PAYER);
        counter.approve(address(market), budget);

        IMarketSwap.MarketSwapParams memory p = IMarketSwap.MarketSwapParams(
            IMarketSwap.MarketSide.BuyCygld,
            address(counter),
            budget,
            1,
            0,
            fee,
            RECIPIENT,
            0,
            address(venue),
            abi.encode(uint256(spent), uint256(grossOutput))
        );
        IMarketSwap.FundingAuthorization memory auth;
        vm.prank(PAYER);
        IMarketSwap.MarketSwapResult memory result = market.swapExactInput(p, auth);
        assertEq(counter.balanceOf(PAYER), uint256(budget) - spent);
        assertEq(counter.balanceOf(address(venue)), spent);
        assertEq(cygld.balanceOf(OWNER), fee);
        assertEq(cygld.balanceOf(RECIPIENT), uint256(grossOutput) - fee);
        assertEq(counter.balanceOf(address(market)), oldInput);
        assertEq(cygld.balanceOf(address(market)), oldOutput);
        assertEq(counter.allowance(address(market), address(venue)), 0);
        assertEq(result.swapInput, spent);
        assertEq(result.amountOut, uint256(grossOutput) - fee);
        assertEq(result.inputRefund, uint256(budget) - spent);
        assertEq(result.outputRefund, 0);
        assertEq(result.feeCygld, fee);
        assertEq(result.feeRecipient, OWNER);
    }

    function checkSellExactOutputConservesInclusiveBudgetAndSurplus(
        uint96 spent,
        uint96 inputRefund,
        uint96 target,
        uint96 outputRefund,
        uint96 fee,
        uint96 oldInput,
        uint96 oldOutput
    ) public {
        vm.assume(target > 0);
        // Independent nonnegative economic components generate successful venue outcomes.
        uint256 budget = uint256(spent) + fee + inputRefund;
        uint256 grossOutput = uint256(target) + outputRefund;
        cygld.mint(PAYER, budget);
        cygld.mint(address(market), oldInput);
        counter.mint(address(market), oldOutput);
        vm.prank(PAYER);
        cygld.approve(address(market), budget);

        IMarketSwap.MarketSwapParams memory p = IMarketSwap.MarketSwapParams(
            IMarketSwap.MarketSide.SellCygld,
            address(counter),
            target,
            budget,
            0,
            fee,
            RECIPIENT,
            0,
            address(venue),
            abi.encode(uint256(spent), uint256(grossOutput))
        );
        IMarketSwap.FundingAuthorization memory auth;
        vm.prank(PAYER);
        IMarketSwap.MarketSwapResult memory result = market.swapExactOutput(p, auth);
        assertEq(cygld.balanceOf(PAYER), inputRefund);
        assertEq(cygld.balanceOf(address(venue)), spent);
        assertEq(cygld.balanceOf(OWNER), fee);
        assertEq(counter.balanceOf(RECIPIENT), target);
        assertEq(counter.balanceOf(PAYER), outputRefund);
        assertEq(cygld.balanceOf(address(market)), oldInput);
        assertEq(counter.balanceOf(address(market)), oldOutput);
        assertEq(cygld.allowance(address(market), address(venue)), 0);
        assertEq(result.swapInput, spent);
        assertEq(result.amountOut, target);
        assertEq(result.inputRefund, inputRefund);
        assertEq(result.outputRefund, outputRefund);
        assertEq(result.feeCygld, fee);
        assertEq(result.feeRecipient, OWNER);
    }
}
