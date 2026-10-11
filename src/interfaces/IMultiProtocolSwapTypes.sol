// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Typed, swap-only routes for the pinned Universal Router encoding.
interface IMultiProtocolSwapTypes {
    /// @notice Canonical AMM protocol; no arbitrary venue command is accepted.
    enum Protocol {
        V2,
        V3,
        V4
    }

    /// @notice One AMM hop; input is the preceding output or swap endpoint.
    /// @param protocol AMM protocol.
    /// @param tokenOut Output currency.
    /// @param fee V3 fee tier or V4 PoolKey fee.
    /// @param tickSpacing V4 PoolKey tick spacing.
    /// @param hooks V4 PoolKey hook address.
    /// @param hookData V4 swap hook data.
    struct Hop {
        Protocol protocol;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    /// @notice Complete input allocation, executed in declared order.
    /// @param amountIn Literal exact-input allocation; ignored for homogeneous exact-output.
    /// @param hops Ordered complete route.
    struct Branch {
        uint256 amountIn;
        Hop[] hops;
    }

    /// @notice Adapter payload ABI-encoded as this tuple.
    /// @param exactIn Whether to execute exact-input branches or one homogeneous exact-output branch.
    /// @param amountLimit Aggregate output minimum or exact output target.
    /// @param deadline Last timestamp; zero uses current transaction timestamp.
    /// @param branches Integer allocations; mixed/split exact-output is unsupported.
    struct SwapPlan {
        bool exactIn;
        uint256 amountLimit;
        uint256 deadline;
        Branch[] branches;
    }
}
