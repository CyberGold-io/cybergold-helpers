// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AdapterAccounting} from "./AdapterAccounting.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @title OneInchAdapter
/// @notice Executes caller-supplied 1inch router calldata while isolating each caller's swap balances.
/// @dev The adapter grants only a per-call input allowance and settles output from measured balance deltas.
contract OneInchAdapter is ISwapAdapter, ReentrancyGuard, AdapterAccounting {
    /// @notice Immutable 1inch Aggregation Router that receives swap calldata.
    address public immutable AGGREGATION_ROUTER;

    /// @notice The configured router or one of the swap token addresses is zero.
    error InvalidAddress();
    /// @notice The caller requested a zero-input swap.
    error InvalidAmount();
    /// @notice The 1inch router call failed, including when no calldata was supplied.
    /// @param revertData Raw router revert payload, or `"empty-data"` when calldata was empty.
    error OneInchSwapFailed(bytes revertData);

    /// @notice Configure the sole 1inch Aggregation Router this adapter may call.
    /// @param helpersDiamond_ Immutable Helpers diamond recovery authority.
    /// @param aggregationRouter_ Nonzero 1inch Aggregation Router address.
    constructor(address helpersDiamond_, address aggregationRouter_) AdapterAccounting(helpersDiamond_) {
        if (aggregationRouter_ == address(0)) revert InvalidAddress();
        AGGREGATION_ROUTER = aggregationRouter_;
    }

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidAddress();
        _rejectIdenticalTokens(tokenIn, tokenOut);
        if (amountIn == 0) revert InvalidAmount();
        if (data.length == 0) revert OneInchSwapFailed(bytes("empty-data"));

        IERC20 inToken = IERC20(tokenIn);
        IERC20 outToken = IERC20(tokenOut);

        SwapBalances memory beforeBalances = _pullAndSnapshotSwap(inToken, outToken, amountIn);
        _setAllowance(inToken, AGGREGATION_ROUTER, amountIn);

        (bool ok, bytes memory revertData) = AGGREGATION_ROUTER.call(data);
        if (!ok) revert OneInchSwapFailed(revertData);

        _setAllowance(inToken, AGGREGATION_ROUTER, 0);
        amountOut = _settleSwap(inToken, outToken, msg.sender, beforeBalances);
    }

    /// @notice Accept native ETH sent directly to this contract for owner-mediated recovery only.
    receive() external payable {}
}
