// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockERC20Adapter} from "./mocks/MockERC20Adapter.sol";
import {OneInchAdapter} from "../src/adapters/OneInchAdapter.sol";
import {AdapterAccounting} from "../src/adapters/AdapterAccounting.sol";
import {SenderSurchargeToken} from "./mocks/SenderSurchargeToken.sol";
import {TransferTaxToken} from "./mocks/TransferTaxToken.sol";
import {ConditionalSenderSurchargeToken} from "./mocks/ConditionalSenderSurchargeToken.sol";

contract OneInchAdapterTest is Test {
    MockERC20Adapter internal tokenIn;
    MockERC20Adapter internal tokenOut;
    MockOneInchRouter internal router;
    OneInchAdapter internal adapter;

    function setUp() public {
        tokenIn = new MockERC20Adapter("TokenIn", "TIN");
        tokenOut = new MockERC20Adapter("TokenOut", "TOUT");
        router = new MockOneInchRouter();
        adapter = new OneInchAdapter(address(this), address(router));
        tokenIn.mint(address(this), 100 ether);
        tokenIn.approve(address(adapter), type(uint256).max);
    }

    function testConstructorRejectsZeroRouter() public {
        assertEq(adapter.helpersDiamond(), address(this));
        vm.expectRevert(OneInchAdapter.InvalidAddress.selector);
        new OneInchAdapter(address(this), address(0));
    }

    function testSwapRejectsInvalidAddressAndAmount() public {
        vm.expectRevert(OneInchAdapter.InvalidAddress.selector);
        adapter.swap(address(0), address(tokenOut), 1, hex"01");

        vm.expectRevert(OneInchAdapter.InvalidAddress.selector);
        adapter.swap(address(tokenIn), address(0), 1, hex"01");

        vm.expectRevert(abi.encodeWithSignature("IdenticalSwapTokens(address)", address(tokenIn)));
        adapter.swap(address(tokenIn), address(tokenIn), 1, hex"01");

        vm.expectRevert(OneInchAdapter.InvalidAmount.selector);
        adapter.swap(address(tokenIn), address(tokenOut), 0, hex"01");
    }

    function testSwapUsesBalanceDeltaWhenNoReturnData() public {
        uint256 amountIn = 1e18;
        uint256 amountOut = 2e18;

        tokenIn.mint(address(adapter), amountIn);
        tokenOut.mint(address(router), amountOut);
        router.setResult(address(tokenOut), amountOut);
        router.setReturnData(bytes(""));

        uint256 received = adapter.swap(address(tokenIn), address(tokenOut), amountIn, hex"01");
        assertEq(received, amountOut, "should emit balance delta");
        assertEq(tokenOut.balanceOf(address(this)), amountOut);
    }

    function testSwapUsesMeasuredOutputWhenRouterReturnDataDisagrees() public {
        uint256 amountIn = 4e17;
        uint256 amountOut = 7e17;

        tokenIn.mint(address(adapter), amountIn);
        tokenOut.mint(address(router), amountOut);

        router.setResult(address(tokenOut), amountOut);
        router.setReturnData(abi.encode(amountOut + 1, amountIn, uint256(0)));

        uint256 received = adapter.swap(address(tokenIn), address(tokenOut), amountIn, hex"1234");
        assertEq(received, amountOut);
        assertEq(tokenOut.balanceOf(address(this)), amountOut);
        assertEq(tokenIn.allowance(address(adapter), address(router)), 0);
    }

    function testSwapIsNonpayable() public {
        vm.deal(address(this), 1 wei);
        (bool ok,) = address(adapter).call{value: 1 wei}(
            abi.encodeCall(adapter.swap, (address(tokenIn), address(tokenOut), 1, hex"01"))
        );
        assertFalse(ok);
        assertEq(router.lastCallValue(), 0);
    }

    function testSwapRevertsWhenRouterReverts() public {
        tokenIn.mint(address(adapter), 1 ether);
        bytes memory revertData = bytes("boom");
        router.setShouldRevert(true, revertData);

        vm.expectRevert(abi.encodeWithSelector(OneInchAdapter.OneInchSwapFailed.selector, revertData));
        adapter.swap(address(tokenIn), address(tokenOut), 1 ether, hex"00");
    }

    function testSwapRejectsEmptyCallData() public {
        tokenIn.mint(address(adapter), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(OneInchAdapter.OneInchSwapFailed.selector, bytes("empty-data")));
        adapter.swap(address(tokenIn), address(tokenOut), 1 ether, bytes(""));
    }

    function testSwapRejectsUnderfundedInputWithoutTouchingStrandedBalance() public {
        address caller = address(0xBAD);
        tokenIn.mint(address(adapter), 0.5 ether);

        vm.prank(caller);
        vm.expectRevert();
        adapter.swap(address(tokenIn), address(tokenOut), 1 ether, hex"01");

        assertEq(tokenIn.balanceOf(address(adapter)), 0.5 ether);
    }

    function testSwapRejectsTransferTaxedInput() public {
        TransferTaxToken taxedInput = new TransferTaxToken();
        taxedInput.mint(address(this), 1 ether);
        taxedInput.approve(address(adapter), 1 ether);

        vm.expectRevert(abi.encodeWithSelector(AdapterAccounting.InputAmountMismatch.selector, 1 ether, 0.9 ether));
        adapter.swap(address(taxedInput), address(tokenOut), 1 ether, hex"01");

        assertEq(taxedInput.balanceOf(address(adapter)), 0);
        assertEq(taxedInput.balanceOf(address(this)), 1 ether);
    }

    function testSwapRejectsSenderSurchargedInput() public {
        SenderSurchargeToken surchargedInput = new SenderSurchargeToken();
        surchargedInput.mint(address(this), 1.1 ether);
        surchargedInput.approve(address(adapter), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                AdapterAccounting.CallerTokenDebitMismatch.selector, address(surchargedInput), 1 ether, 1.1 ether
            )
        );
        adapter.swap(address(surchargedInput), address(tokenOut), 1 ether, hex"01");

        assertEq(surchargedInput.balanceOf(address(adapter)), 0);
        assertEq(surchargedInput.balanceOf(address(this)), 1.1 ether);
    }

    function testSwapRejectsVenueConsumptionOfPreExistingInput() public {
        ConditionalSenderSurchargeToken conditionalInput = new ConditionalSenderSurchargeToken();
        conditionalInput.mint(address(this), 1 ether);
        conditionalInput.mint(address(adapter), 0.1 ether);
        conditionalInput.setSurchargedSender(address(adapter));
        conditionalInput.approve(address(adapter), 1 ether);
        tokenOut.mint(address(router), 2 ether);
        router.setTokenInPull(address(conditionalInput), 1 ether);
        router.setResult(address(tokenOut), 2 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                AdapterAccounting.PreExistingInputConsumed.selector, address(conditionalInput), 0.1 ether, 0
            )
        );
        adapter.swap(address(conditionalInput), address(tokenOut), 1 ether, hex"01");

        assertEq(conditionalInput.balanceOf(address(adapter)), 0.1 ether);
        assertEq(conditionalInput.balanceOf(address(this)), 1 ether);
    }

    function testSwapRejectsTransferTaxedOutput() public {
        TransferTaxToken taxedOutput = new TransferTaxToken();
        taxedOutput.mint(address(router), 1 ether);
        router.setResult(address(taxedOutput), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                AdapterAccounting.AdapterRecipientCreditMismatch.selector,
                address(taxedOutput),
                address(this),
                0.9 ether,
                0.81 ether
            )
        );
        adapter.swap(address(tokenIn), address(taxedOutput), 1 ether, hex"01");

        assertEq(taxedOutput.balanceOf(address(this)), 0);
        assertEq(taxedOutput.balanceOf(address(adapter)), 0);
    }

    function testSwapRejectsSenderSurchargedOutputWithoutConsumingAdapterDust() public {
        SenderSurchargeToken surchargedOutput = new SenderSurchargeToken();
        surchargedOutput.mint(address(router), 1.1 ether);
        surchargedOutput.mint(address(adapter), 0.1 ether);
        router.setResult(address(surchargedOutput), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                AdapterAccounting.AdapterTokenDebitMismatch.selector, address(surchargedOutput), 1 ether, 1.1 ether
            )
        );
        adapter.swap(address(tokenIn), address(surchargedOutput), 1 ether, hex"01");

        assertEq(surchargedOutput.balanceOf(address(this)), 0);
        assertEq(surchargedOutput.balanceOf(address(adapter)), 0.1 ether);
    }

    function testSwapRefundsUnusedTokenIn() public {
        uint256 amountIn = 1 ether;
        uint256 consumed = 0.4 ether;
        uint256 amountOut = 0.5 ether;
        uint256 stranded = 3 ether;

        tokenIn.mint(address(adapter), stranded);
        tokenOut.mint(address(router), amountOut);
        router.setResult(address(tokenOut), amountOut);
        router.setTokenInPull(address(tokenIn), consumed);

        uint256 beforeCaller = tokenIn.balanceOf(address(this));
        uint256 received = adapter.swap(address(tokenIn), address(tokenOut), amountIn, hex"abcd");

        assertEq(received, amountOut);
        assertEq(tokenOut.balanceOf(address(this)), amountOut);
        assertEq(tokenIn.balanceOf(address(adapter)), stranded);
        assertEq(tokenIn.balanceOf(address(router)), consumed);
        assertEq(beforeCaller - tokenIn.balanceOf(address(this)), consumed);
    }

    receive() external payable {}
}

contract MockOneInchRouter {
    using SafeERC20 for IERC20;

    IERC20 public tokenOut;
    uint256 public amountOut;
    bool public shouldRevert;
    bytes public revertPayload;
    bytes public returnPayload;
    uint256 public lastCallValue;
    bytes public lastCallData;
    uint256 public refundAmount;
    IERC20 public pullTokenIn;
    uint256 public pullAmountIn;

    function setResult(address tokenOut_, uint256 amountOut_) external {
        tokenOut = IERC20(tokenOut_);
        amountOut = amountOut_;
    }

    function setShouldRevert(bool shouldRevert_, bytes memory revertPayload_) external {
        shouldRevert = shouldRevert_;
        revertPayload = revertPayload_;
    }

    function setReturnData(bytes memory payload) external {
        returnPayload = payload;
    }

    function setRefund(uint256 refundAmount_) external {
        refundAmount = refundAmount_;
    }

    function setTokenInPull(address token, uint256 amount) external {
        pullTokenIn = IERC20(token);
        pullAmountIn = amount;
    }

    fallback(bytes calldata data) external payable returns (bytes memory) {
        lastCallValue = msg.value;
        lastCallData = data;

        if (shouldRevert) {
            bytes memory payload = revertPayload;
            assembly {
                revert(add(payload, 32), mload(payload))
            }
        }

        if (address(pullTokenIn) != address(0) && pullAmountIn != 0) {
            pullTokenIn.safeTransferFrom(msg.sender, address(this), pullAmountIn);
            pullTokenIn = IERC20(address(0));
            pullAmountIn = 0;
        }

        if (address(tokenOut) != address(0) && amountOut != 0) {
            tokenOut.safeTransfer(msg.sender, amountOut);
        }

        if (refundAmount != 0) {
            uint256 value = refundAmount;
            refundAmount = 0;
            (bool success,) = msg.sender.call{value: value}("");
            require(success, "refund failed");
        }

        bytes memory responsePayload = returnPayload.length == 0 ? abi.encode(amountOut) : returnPayload;
        assembly {
            return(add(responsePayload, 32), mload(responsePayload))
        }
    }

    receive() external payable {}
}
