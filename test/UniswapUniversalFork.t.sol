// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UniswapUniversalAdapter} from "../src/adapters/UniswapUniversalAdapter.sol";

interface IUniswapQuoterV2Fork {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);

    function quoteExactOutput(bytes memory path, uint256 amountOut)
        external
        returns (uint256 amountIn, uint160[] memory, uint32[] memory, uint256);
}

contract UniswapUniversalForkTest is Test {
    address constant UNIVERSAL_ROUTER = 0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint24 constant FEE = 500;

    UniswapUniversalAdapter internal adapter;
    bool internal hasFork;

    function setUp() public {
        string memory rpc;
        try vm.envString("MAINNET_RPC_URL") returns (string memory envRpc) {
            rpc = envRpc;
        } catch {
            revert("MAINNET_RPC_URL missing");
        }
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        uint256 forkId = forkBlock == 0 ? vm.createFork(rpc) : vm.createFork(rpc, forkBlock);
        vm.selectFork(forkId);
        if (
            WETH.code.length == 0 || USDC.code.length == 0 || QUOTER_V2.code.length == 0
                || UNIVERSAL_ROUTER.code.length == 0
        ) {
            revert("fork is not mainnet-like (missing canonical contracts)");
        }
        hasFork = true;
        adapter = new UniswapUniversalAdapter(address(this), UNIVERSAL_ROUTER, PERMIT2);
    }

    function testQuoteExactIn() public {
        if (!hasFork) return;
        bytes memory path = _pathExactIn();
        (uint256 quoted,,,) = IUniswapQuoterV2Fork(QUOTER_V2).quoteExactInput(path, 0.01 ether);
        assertGt(quoted, 0);
    }

    function testQuoteExactOut() public {
        if (!hasFork) return;
        bytes memory path = _pathExactOut();
        (uint256 quoted,,,) = IUniswapQuoterV2Fork(QUOTER_V2).quoteExactOutput(path, 100e6);
        assertGt(quoted, 0);
    }

    function testSwapExactIn() public {
        if (!hasFork) return;
        uint256 amountIn = 0.01 ether;
        deal(WETH, address(this), amountIn);
        IERC20(WETH).approve(address(adapter), amountIn);

        bytes memory path = _pathExactIn();
        bytes memory data = abi.encode(path, uint256(1), block.timestamp + 30 minutes, true);

        uint256 amountOut = adapter.swap(WETH, USDC, amountIn, data);
        assertGt(amountOut, 0);
        assertEq(IERC20(USDC).balanceOf(address(this)), amountOut);
    }

    function testSwapExactOut() public {
        if (!hasFork) return;
        uint256 amountOut = 100e6;
        uint256 amountInMax = 0.5 ether;
        deal(WETH, address(this), amountInMax);
        IERC20(WETH).approve(address(adapter), amountInMax);

        bytes memory path = _pathExactOut();
        bytes memory data = abi.encode(path, amountOut, block.timestamp + 30 minutes, false);

        uint256 received = adapter.swap(WETH, USDC, amountInMax, data);
        assertEq(received, amountOut);
        assertEq(IERC20(USDC).balanceOf(address(this)), amountOut);
    }

    function _pathExactIn() internal pure returns (bytes memory path) {
        path = abi.encodePacked(WETH, FEE, USDC);
    }

    function _pathExactOut() internal pure returns (bytes memory path) {
        path = abi.encodePacked(USDC, FEE, WETH);
    }
}
