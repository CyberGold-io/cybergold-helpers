// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @title ISwapAdapter
/// @notice Minimal interface that downstream helpers will use to interact with on-chain swap aggregators.
interface ISwapAdapter {
    /// @dev Executes a swap and returns the measured `tokenOut` amount settled to the caller.
    /// Implementations pull `amountIn` atomically from `msg.sender`; callers must approve
    /// the adapter for the current lot. Venue interaction remains limited to pinned routers.
    /// @param tokenIn Asset provided to the adapter.
    /// @param tokenOut Asset expected from the adapter.
    /// @param amountIn Input amount supplied to the swap.
    /// @param data Adapter-specific calldata forwarded to the aggregator.
    /// @return amountOut Exact measured output amount settled to `msg.sender`.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
        external
        returns (uint256 amountOut);
}
