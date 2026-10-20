// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Caller-funded exact-input native execution alongside ISwapAdapter.
interface INativeSwapAdapter {
    /// @notice Execute a native-input route using exactly msg.value as the input lot.
    /// @param tokenOut Output currency; native currency is represented by address zero.
    /// @param data Adapter-specific typed route payload.
    /// @return amountOut Measured output settled to msg.sender; unused native input returns there too.
    function swapNative(address tokenOut, bytes calldata data) external payable returns (uint256 amountOut);
}
