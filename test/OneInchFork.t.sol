// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {OneInchAdapter} from "../src/adapters/OneInchAdapter.sol";

interface IAggregationRouterV6 {
    function unoswap(uint256 srcToken, uint256 amount, uint256 minReturn, uint256 dex)
        external
        returns (uint256 returnAmount);
}

contract OneInchForkTest is Test {
    address constant AGG_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant UNIV2_USDC_WETH = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;

    uint32 constant UNISWAP_V2_NUMERATOR = 997_000_000; // 0.3% Uniswap V2 fee in 1inch unoswap encoding
    uint256 constant AMOUNT_IN_WETH = 1e12; // 0.000001 WETH (~$0.003)
    uint256 constant AMOUNT_IN_USDC = 1e6; // 1 USDC

    OneInchAdapter internal adapter;
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
            AGG_ROUTER.code.length == 0 || WETH.code.length == 0 || USDC.code.length == 0
                || UNIV2_USDC_WETH.code.length == 0
        ) {
            revert("fork is not mainnet-like (missing canonical contracts)");
        }
        hasFork = true;
        adapter = new OneInchAdapter(address(this), AGG_ROUTER);
    }

    function testOneInchUnoswapFork() external {
        if (!hasFork) return;

        deal(WETH, address(this), AMOUNT_IN_WETH);
        IERC20(WETH).approve(address(adapter), AMOUNT_IN_WETH);

        uint256 dex = encodeUnoPool(UNIV2_USDC_WETH, false);
        bytes memory data = abi.encodeWithSelector(
            IAggregationRouterV6.unoswap.selector, uint256(uint160(WETH)), AMOUNT_IN_WETH, 1, dex
        );

        uint256 beforeUsdc = IERC20(USDC).balanceOf(address(this));
        uint256 amountOut = adapter.swap(WETH, USDC, AMOUNT_IN_WETH, data);
        uint256 afterUsdc = IERC20(USDC).balanceOf(address(this));

        uint256 delta = afterUsdc - beforeUsdc;
        assertGt(delta, 0, "no usdc");
        if (amountOut != 0) {
            assertEq(delta, amountOut);
        }
    }

    function testOneInchUnoswapForkReverse() external {
        if (!hasFork) return;

        deal(USDC, address(this), AMOUNT_IN_USDC);
        IERC20(USDC).approve(address(adapter), AMOUNT_IN_USDC);

        uint256 dex = encodeUnoPool(UNIV2_USDC_WETH, true);
        bytes memory data = abi.encodeWithSelector(
            IAggregationRouterV6.unoswap.selector, uint256(uint160(USDC)), AMOUNT_IN_USDC, 1, dex
        );

        uint256 beforeWeth = IERC20(WETH).balanceOf(address(this));
        uint256 amountOut = adapter.swap(USDC, WETH, AMOUNT_IN_USDC, data);
        uint256 afterWeth = IERC20(WETH).balanceOf(address(this));

        uint256 delta = afterWeth - beforeWeth;
        assertGt(delta, 0, "no weth");
        if (amountOut != 0) {
            assertEq(delta, amountOut);
        }
    }

    function encodeUnoPool(address pair, bool zeroForOne) internal pure returns (uint256) {
        uint256 word = uint256(uint160(pair));
        word |= uint256(UNISWAP_V2_NUMERATOR) << 160;
        if (zeroForOne) {
            word |= (uint256(1) << 247);
        }
        return word;
    }
}
