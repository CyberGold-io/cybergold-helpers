// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice No-hook routes for the release-pinned Uniswap Universal Router.
interface IUniswapRoutingTypes {
    /// @notice AMM hops and explicit conversions of the current owned lot.
    enum StepKind {
        V2,
        V3,
        V4,
        WrapNative,
        UnwrapNative
    }

    /// @notice Input currency is the preceding output, or the branch input.
    /// @param kind Protocol or native conversion.
    /// @param currencyOut Actual output currency; zero denotes native ETH.
    /// @param fee V3 pool fee or V4 PoolKey fee; unused for V2 and conversions.
    /// @param tickSpacing V4 PoolKey tick spacing; unused for other steps.
    struct Step {
        StepKind kind;
        address currencyOut;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @notice One ordered route with a literal exact-input allocation.
    /// @param amountIn Funded allocation; ignored for homogeneous exact-output.
    /// @param steps Connected AMM/conversion steps.
    struct Branch {
        uint256 amountIn;
        Step[] steps;
    }

    /// @notice ABI-encoded adapter payload, bound to the successor adapter identity.
    /// @param exactIn Execute split/mixed exact input or one homogeneous ERC20 exact output.
    /// @param amountLimit Aggregate output floor or exact output target.
    /// @param deadline Last execution timestamp; zero uses the current transaction timestamp.
    /// @param branches Routes in their execution order.
    struct SwapPlan {
        bool exactIn;
        uint256 amountLimit;
        uint256 deadline;
        Branch[] branches;
    }
}
