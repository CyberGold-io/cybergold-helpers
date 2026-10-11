// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AdapterAccounting} from "./AdapterAccounting.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @title 0x Swap Adapter
/// @notice Executes caller-supplied 0x Exchange Proxy calldata while isolating each caller's swap balances.
/// @dev The adapter pulls exactly `amountIn`, grants only a per-call allowance, returns both output and
/// unspent input to the caller, and clears the allowance after a successful venue call.
contract ZeroExAdapter is ISwapAdapter, ReentrancyGuard, AdapterAccounting {
    /// @notice Immutable 0x Exchange Proxy that receives swap calldata.
    address public immutable EXCHANGE_PROXY;

    /// @notice The configured proxy or one of the swap token addresses is zero.
    error InvalidAddress();
    /// @notice The caller requested a zero-input swap.
    error InvalidAmount();
    /// @notice The 0x Exchange Proxy call reverted or otherwise failed.
    /// @param revertData Raw revert payload returned by the proxy.
    error ZeroExSwapFailed(bytes revertData);

    /// @notice Configure the sole 0x Exchange Proxy this adapter may call.
    /// @param helpersDiamond_ Immutable Helpers diamond recovery authority.
    /// @param exchangeProxy_ Nonzero 0x Exchange Proxy address.
    constructor(address helpersDiamond_, address exchangeProxy_) AdapterAccounting(helpersDiamond_) {
        if (exchangeProxy_ == address(0)) revert InvalidAddress();
        EXCHANGE_PROXY = exchangeProxy_;
    }

    /// @notice Swap an exact input lot through the configured 0x Exchange Proxy.
    /// @dev `data` is trusted venue calldata supplied by the Helpers router. Output is measured by balance
    /// delta rather than decoded from the proxy response. Any unspent input is returned to `msg.sender`.
    /// @param tokenIn ERC-20 pulled from `msg.sender` as swap input.
    /// @param tokenOut ERC-20 whose positive balance delta is treated as swap output.
    /// @param amountIn Exact `tokenIn` amount to pull, in its smallest unit.
    /// @param data Complete calldata forwarded to the immutable Exchange Proxy.
    /// @return amountOut Measured `tokenOut` amount transferred to `msg.sender`.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidAddress();
        _rejectIdenticalTokens(tokenIn, tokenOut);
        if (amountIn == 0) revert InvalidAmount();

        IERC20 inToken = IERC20(tokenIn);
        IERC20 outToken = IERC20(tokenOut);

        SwapBalances memory beforeBalances = _pullAndSnapshotSwap(inToken, outToken, amountIn);
        _setAllowance(inToken, EXCHANGE_PROXY, amountIn);

        (bool ok, bytes memory revertData) = EXCHANGE_PROXY.call(data);
        if (!ok) revert ZeroExSwapFailed(revertData);

        _setAllowance(inToken, EXCHANGE_PROXY, 0);
        amountOut = _settleSwap(inToken, outToken, msg.sender, beforeBalances);
    }

    /// @notice Accept native ETH sent directly to this contract for owner-mediated recovery only.
    receive() external payable {}
}
