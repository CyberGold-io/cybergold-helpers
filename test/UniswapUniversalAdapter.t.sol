// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {UniswapUniversalAdapter} from "../src/adapters/UniswapUniversalAdapter.sol";
import {AdapterAccounting} from "../src/adapters/AdapterAccounting.sol";
import {MockERC20Adapter} from "./mocks/MockERC20Adapter.sol";
import {ConditionalSenderSurchargeToken} from "./mocks/ConditionalSenderSurchargeToken.sol";

contract UniswapUniversalAdapterTest is Test {
    using SafeCast for uint256;

    MockERC20Adapter internal tokenIn;
    MockERC20Adapter internal tokenOut;
    MockPermit2Allowance internal permit2;
    MockUniversalRouter internal router;
    UniswapUniversalAdapter internal adapter;

    function setUp() public {
        tokenIn = new MockERC20Adapter("TokenIn", "TIN");
        tokenOut = new MockERC20Adapter("TokenOut", "TOUT");
        permit2 = new MockPermit2Allowance();
        router = new MockUniversalRouter(address(permit2));
        adapter = new UniswapUniversalAdapter(address(this), address(router), address(permit2));
        tokenIn.mint(address(this), 100 ether);
        tokenIn.approve(address(adapter), type(uint256).max);
    }

    function testConstructorRejectsZeroRouter() public {
        assertEq(adapter.helpersDiamond(), address(this));
        assertEq(adapter.PERMIT2(), address(permit2));
        vm.expectRevert(UniswapUniversalAdapter.InvalidAddress.selector);
        new UniswapUniversalAdapter(address(this), address(0), address(permit2));

        vm.expectRevert(UniswapUniversalAdapter.InvalidAddress.selector);
        new UniswapUniversalAdapter(address(this), address(router), address(0));
    }

    function testSwapRejectsInvalidAddressAmountAndData() public {
        vm.expectRevert(UniswapUniversalAdapter.InvalidAddress.selector);
        adapter.swap(address(0), address(tokenOut), 1, hex"01");

        vm.expectRevert(UniswapUniversalAdapter.InvalidAddress.selector);
        adapter.swap(address(tokenIn), address(0), 1, hex"01");

        vm.expectRevert(abi.encodeWithSignature("IdenticalSwapTokens(address)", address(tokenIn)));
        adapter.swap(address(tokenIn), address(tokenIn), 1, hex"01");

        vm.expectRevert(UniswapUniversalAdapter.InvalidAmount.selector);
        adapter.swap(address(tokenIn), address(tokenOut), 0, hex"01");

        vm.expectRevert(UniswapUniversalAdapter.InvalidAmount.selector);
        adapter.swap(address(tokenIn), address(tokenOut), type(uint256).max, hex"01");

        vm.expectRevert(UniswapUniversalAdapter.InvalidSwapData.selector);
        adapter.swap(address(tokenIn), address(tokenOut), 1, bytes(""));
    }

    function testSwapBubblesUniversalRouterRevertData() public {
        uint256 amountIn = 1 ether;
        tokenIn.mint(address(adapter), amountIn);
        bytes memory path = abi.encode(address(tokenIn), address(tokenOut));
        bytes memory data = abi.encode(path, uint256(1), block.timestamp + 30 minutes, true);

        bytes memory routerRevert = abi.encodeWithSignature("Error(string)", "tokenIn");
        vm.expectRevert(
            abi.encodeWithSelector(UniswapUniversalAdapter.UniversalRouterSwapFailed.selector, routerRevert)
        );
        adapter.swap(address(tokenIn), address(tokenOut), amountIn, data);
    }

    function testSwapExactOutUsesCurrentBlockPermit2Expiration() public {
        uint256 amountInMax = 1 ether;
        uint256 amountInConsumed = 0.4 ether;
        uint256 amountOut = 2 ether;
        uint256 stranded = 3 ether;

        tokenIn.mint(address(adapter), stranded);
        tokenOut.mint(address(router), amountOut);
        router.setExactOutResult(address(tokenIn), address(tokenOut), amountInConsumed, amountOut);

        bytes memory path = abi.encode(address(tokenIn), address(tokenOut));
        bytes memory data = abi.encode(path, amountOut, block.timestamp + 30 minutes, false);

        uint256 callerBalanceBefore = tokenIn.balanceOf(address(this));
        uint256 received = adapter.swap(address(tokenIn), address(tokenOut), amountInMax, data);

        assertEq(received, amountOut);
        assertEq(tokenOut.balanceOf(address(this)), amountOut);
        assertEq(tokenIn.balanceOf(address(adapter)), stranded);
        assertEq(tokenIn.balanceOf(address(router)), amountInConsumed);
        assertEq(callerBalanceBefore - tokenIn.balanceOf(address(this)), amountInConsumed);
        assertEq(tokenIn.allowance(address(adapter), address(permit2)), 0);

        (uint160 permitAmount, uint48 permitExpiration,) =
            permit2.allowance(address(adapter), address(tokenIn), address(router));
        assertEq(permitAmount, (amountInMax - amountInConsumed).toUint160());
        assertEq(permitExpiration, block.timestamp.toUint48());

        vm.warp(block.timestamp + 1);
        assertFalse(permit2.canTransfer(address(adapter), address(tokenIn), address(router)));
    }

    function testSwapIsNonpayable() public {
        vm.deal(address(this), 1 wei);
        (bool ok,) = address(adapter).call{value: 1 wei}(
            abi.encodeCall(adapter.swap, (address(tokenIn), address(tokenOut), 1, hex"01"))
        );
        assertFalse(ok);
    }

    function testSwapExactInConsumesPermit2Allowance() public {
        uint256 amountIn = 1 ether;
        uint256 amountOut = 2 ether;

        tokenOut.mint(address(router), amountOut);
        router.setExactInResult(address(tokenIn), address(tokenOut), amountOut);

        bytes memory path = abi.encode(address(tokenIn), address(tokenOut));
        bytes memory data = abi.encode(path, uint256(1), block.timestamp + 30 minutes, true);

        uint256 received = adapter.swap(address(tokenIn), address(tokenOut), amountIn, data);

        assertEq(received, amountOut);
        (uint160 permitAmount, uint48 permitExpiration,) =
            permit2.allowance(address(adapter), address(tokenIn), address(router));
        assertEq(permitAmount, 0);
        assertEq(permitExpiration, block.timestamp.toUint48());
    }

    function testSwapRejectsVenueConsumptionOfPreExistingInput() public {
        ConditionalSenderSurchargeToken conditionalInput = new ConditionalSenderSurchargeToken();
        conditionalInput.mint(address(this), 1 ether);
        conditionalInput.mint(address(adapter), 0.1 ether);
        conditionalInput.setSurchargedSender(address(adapter));
        conditionalInput.approve(address(adapter), 1 ether);
        tokenOut.mint(address(router), 2 ether);
        router.setExactInResult(address(conditionalInput), address(tokenOut), 2 ether);
        bytes memory path = abi.encode(address(conditionalInput), address(tokenOut));
        bytes memory data = abi.encode(path, uint256(1), block.timestamp + 30 minutes, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                AdapterAccounting.PreExistingInputConsumed.selector, address(conditionalInput), 0.1 ether, 0
            )
        );
        adapter.swap(address(conditionalInput), address(tokenOut), 1 ether, data);

        assertEq(conditionalInput.balanceOf(address(adapter)), 0.1 ether);
        assertEq(conditionalInput.balanceOf(address(this)), 1 ether);
    }

    receive() external payable {}
}

contract MockUniversalRouter {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address internal immutable PERMIT2_MOCK;

    address public tokenIn;
    address public tokenOut;
    uint256 public exactInAmountOut;
    uint256 public exactOutAmountIn;
    uint256 public exactOutAmountOut;

    constructor(address permit2_) {
        PERMIT2_MOCK = permit2_;
    }

    function setExactInResult(address tokenIn_, address tokenOut_, uint256 amountOut_) external {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        exactInAmountOut = amountOut_;
    }

    function setExactOutResult(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOut_) external {
        tokenIn = tokenIn_;
        tokenOut = tokenOut_;
        exactOutAmountIn = amountIn_;
        exactOutAmountOut = amountOut_;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        // This router mock mirrors Universal Router timestamp deadline semantics.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp <= deadline, "deadline");
        require(commands.length == 1, "commands");
        require(inputs.length == 1, "inputs");

        (address pathTokenIn, address pathTokenOut) = abi.decode(_path(commands[0], inputs[0]), (address, address));
        require(pathTokenIn == tokenIn, "tokenIn");
        require(pathTokenOut == tokenOut, "tokenOut");

        if (commands[0] == 0x00) {
            (, uint256 amountIn,,,, uint256[] memory minHopPriceX36) =
                abi.decode(inputs[0], (address, uint256, uint256, bytes, bool, uint256[]));
            require(minHopPriceX36.length == 0, "minHopPriceX36");
            MockPermit2Allowance(PERMIT2_MOCK).transferFrom(msg.sender, address(this), amountIn.toUint160(), tokenIn);
            IERC20(tokenOut).safeTransfer(msg.sender, exactInAmountOut);
            _refundEth();
            return;
        }

        if (commands[0] == 0x01) {
            (address recipient, uint256 amountOut,,,, uint256[] memory minHopPriceX36) =
                abi.decode(inputs[0], (address, uint256, uint256, bytes, bool, uint256[]));
            require(recipient == msg.sender, "recipient");
            require(amountOut == exactOutAmountOut, "amountOut");
            require(minHopPriceX36.length == 0, "minHopPriceX36");
            MockPermit2Allowance(PERMIT2_MOCK)
                .transferFrom(msg.sender, address(this), exactOutAmountIn.toUint160(), tokenIn);
            IERC20(tokenOut).safeTransfer(msg.sender, exactOutAmountOut);
            _refundEth();
            return;
        }

        revert("command");
    }

    function _refundEth() private {
        if (msg.value == 0) return;
        (bool sent,) = msg.sender.call{value: msg.value}("");
        require(sent, "refund");
    }

    function _path(bytes1 command, bytes calldata input) private pure returns (bytes memory path) {
        if (command == 0x00) {
            (,,, path,,) = abi.decode(input, (address, uint256, uint256, bytes, bool, uint256[]));
            return path;
        }
        if (command == 0x01) {
            (,,, path,,) = abi.decode(input, (address, uint256, uint256, bytes, bool, uint256[]));
            return path;
        }
        revert("command");
    }

    receive() external payable {}
}

contract MockPermit2Allowance {
    using SafeERC20 for IERC20;

    struct PackedAllowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    mapping(address => mapping(address => mapping(address => PackedAllowance))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender].amount = amount;
        allowance[msg.sender][token][spender].expiration = expiration;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        PackedAllowance storage allowed = allowance[from][token][msg.sender];
        // This mock mirrors Permit2 allowance expiration in timestamp seconds.
        // forge-lint: disable-next-line(block-timestamp)
        require(block.timestamp <= allowed.expiration, "expired");
        require(amount <= allowed.amount, "allowance");
        allowed.amount -= amount;
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function canTransfer(address from, address token, address spender) external view returns (bool) {
        PackedAllowance storage allowed = allowance[from][token][spender];
        // This mock mirrors Permit2 allowance expiration in timestamp seconds.
        // forge-lint: disable-next-line(block-timestamp)
        return allowed.amount > 0 && block.timestamp <= allowed.expiration;
    }
}
