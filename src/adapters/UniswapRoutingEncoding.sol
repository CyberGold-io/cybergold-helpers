// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IUniswapRoutingTypes} from "../interfaces/IUniswapRoutingTypes.sol";

/// @notice No-hook command encoding for the pinned Universal Router 2.2.0 ABI.
library UniswapRoutingEncoding {
    using SafeCast for uint256;

    /// @notice The mandatory upstream V4 hop tuple; hook fields are never caller-selected.
    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    /// @notice Pinned upstream multihop exact-input tuple.
    struct ExactInput {
        address currencyIn;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    /// @notice Pinned upstream multihop exact-output tuple.
    struct ExactOutput {
        address currencyOut;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountOut;
        uint128 amountInMaximum;
    }

    /// @notice Exact output retains one homogeneous ERC20 route only.
    error UnsupportedExactOutputRoute();

    /// @notice Encode one caller-funded V2 or V3 hop, returning output to the adapter.
    function exactInputHop(address input, uint256 amount, IUniswapRoutingTypes.Step memory step)
        internal
        view
        returns (bytes1 command, bytes memory payload)
    {
        if (step.kind == IUniswapRoutingTypes.StepKind.V2) {
            address[] memory path = new address[](2);
            path[0] = input;
            path[1] = step.currencyOut;
            return (0x08, abi.encode(address(this), amount, uint256(0), path, true, new uint256[](0)));
        }
        return (
            0x00,
            abi.encode(
                address(this),
                amount,
                uint256(0),
                abi.encodePacked(input, step.fee, step.currencyOut),
                true,
                new uint256[](0)
            )
        );
    }

    /// @notice Pre-settle a literal lot and consume its checked PoolManager credit in one V4 group.
    /// @dev Every currency is taken back before the whole-conversion remainder check, so upstream
    /// CurrencyNotSettled cannot obscure the accepted currency/amount error. Amount zero in the swap
    /// is intentional OPEN_DELTA; it is not the router's resting ERC20 balance.
    function exactInputV4(
        address input,
        uint256 amount,
        IUniswapRoutingTypes.Step[] memory steps,
        uint256 start,
        uint256 end
    ) internal view returns (bytes memory payload) {
        uint256 length = end - start;
        PathKey[] memory path = new PathKey[](length);
        for (uint256 i; i < length; ++i) {
            IUniswapRoutingTypes.Step memory step = steps[start + i];
            path[i] = PathKey(step.currencyOut, step.fee, step.tickSpacing, address(0), "");
        }
        bytes[] memory params = new bytes[](length + 3);
        bytes memory actions = new bytes(length + 3);
        actions[0] = 0x0b; // SETTLE
        actions[1] = 0x07; // SWAP_EXACT_IN
        params[0] = abi.encode(input, amount, true);
        params[1] = abi.encode(ExactInput(input, path, new uint256[](0), 0, 0));
        // Final output first, then input and all distinct intermediate credits.
        params[2] = abi.encode(steps[end - 1].currencyOut, address(this), uint256(0));
        params[3] = abi.encode(input, address(this), uint256(0));
        // TAKE each current-unlock credit back to adapter custody.
        for (uint256 i = 2; i < actions.length; ++i) {
            actions[i] = 0x0e;
        }
        for (uint256 i; i + 1 < length; ++i) {
            params[i + 4] = abi.encode(steps[start + i].currencyOut, address(this), uint256(0));
        }
        return abi.encode(actions, params);
    }

    /// @notice Preserve homogeneous V2/V3/V4 ERC20 exact-output execution and unused input.
    function exactOutput(address input, uint256 maximum, uint256 output, IUniswapRoutingTypes.Step[] memory steps)
        internal
        view
        returns (bytes1 command, bytes memory payload)
    {
        IUniswapRoutingTypes.StepKind kind = steps[0].kind;
        if (kind > IUniswapRoutingTypes.StepKind.V4) revert UnsupportedExactOutputRoute();
        for (uint256 i; i < steps.length; ++i) {
            if (steps[i].kind != kind || steps[i].currencyOut == address(0)) revert UnsupportedExactOutputRoute();
        }
        if (kind == IUniswapRoutingTypes.StepKind.V2) {
            address[] memory path = new address[](steps.length + 1);
            path[0] = input;
            for (uint256 i; i < steps.length; ++i) {
                path[i + 1] = steps[i].currencyOut;
            }
            return (0x09, abi.encode(address(this), output, maximum, path, true, new uint256[](0)));
        }
        if (kind == IUniswapRoutingTypes.StepKind.V3) {
            bytes memory path = abi.encodePacked(steps[steps.length - 1].currencyOut);
            for (uint256 i = steps.length; i > 0; --i) {
                path = abi.encodePacked(path, steps[i - 1].fee, i == 1 ? input : steps[i - 2].currencyOut);
            }
            return (0x01, abi.encode(address(this), output, maximum, path, true, new uint256[](0)));
        }
        PathKey[] memory keys = new PathKey[](steps.length);
        for (uint256 i; i < steps.length; ++i) {
            keys[i] =
                PathKey(i == 0 ? input : steps[i - 1].currencyOut, steps[i].fee, steps[i].tickSpacing, address(0), "");
        }
        address tokenOut = steps[steps.length - 1].currencyOut;
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactOutput(tokenOut, keys, new uint256[](0), output.toUint128(), maximum.toUint128()));
        params[1] = abi.encode(input, maximum);
        params[2] = abi.encode(tokenOut, uint256(0));
        return (0x10, abi.encode(hex"090c0f", params));
    }
}
