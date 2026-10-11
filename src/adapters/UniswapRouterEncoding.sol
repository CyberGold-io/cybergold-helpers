// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMultiProtocolSwapTypes} from "../interfaces/IMultiProtocolSwapTypes.sol";

/// @notice Swap-only encoding for Universal Router 2.2.0 and its pinned V4 periphery.
library UniswapRouterEncoding {
    using SafeCast for uint256;

    /// @notice Canonical V4 PoolKey ABI fields, with ERC-20 currency addresses.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @notice Canonical V4 PathKey ABI fields.
    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    /// @notice Pinned V4 exact-input single-hop tuple, including per-hop price field.
    struct ExactInputSingle {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    /// @notice Pinned V4 multihop exact-output tuple, with forward-indexed reverse inputs.
    struct ExactOutput {
        address currencyOut;
        PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountOut;
        uint128 amountInMaximum;
    }
    /// @notice Mixed or split exact-output needs a different live funding executor.
    error UnsupportedExactOutputRoute();

    /// @notice Encode one literal-funded exact-input hop with adapter output custody.
    /// @param input Hop input currency.
    /// @param amount Current measured input lot.
    /// @param hop Typed protocol parameters.
    /// @return command Sole router command.
    /// @return payload Command input.
    function exactInput(address input, uint256 amount, IMultiProtocolSwapTypes.Hop memory hop)
        internal
        view
        returns (bytes1 command, bytes memory payload)
    {
        if (hop.protocol == IMultiProtocolSwapTypes.Protocol.V2) {
            address[] memory path = new address[](2);
            path[0] = input;
            path[1] = hop.tokenOut;
            return (0x08, abi.encode(address(this), amount, uint256(0), path, true, new uint256[](0)));
        }
        if (hop.protocol == IMultiProtocolSwapTypes.Protocol.V3) {
            return (
                0x00,
                abi.encode(
                    address(this),
                    amount,
                    uint256(0),
                    abi.encodePacked(input, hop.fee, hop.tokenOut),
                    true,
                    new uint256[](0)
                )
            );
        }
        PoolKey memory key = input < hop.tokenOut
            ? PoolKey(input, hop.tokenOut, hop.fee, hop.tickSpacing, hop.hooks)
            : PoolKey(hop.tokenOut, input, hop.fee, hop.tickSpacing, hop.hooks);
        bytes[] memory params = new bytes[](4);
        // Settle the literal uint256 lot first. OPEN_DELTA then uses upstream checked credit conversion.
        params[0] = abi.encode(input, amount, true);
        params[1] = abi.encode(ExactInputSingle(key, input < hop.tokenOut, 0, 0, 0, hop.hookData));
        params[2] = abi.encode(hop.tokenOut, address(this), uint256(0));
        params[3] = abi.encode(input, address(this), uint256(0));
        return (0x10, abi.encode(hex"0b060e0e", params));
    }

    /// @notice Encode one homogeneous exact-output path, with bounded adapter payment.
    /// @param input Declared input endpoint.
    /// @param maximum Maximum venue input.
    /// @param output Target output amount.
    /// @param hops Complete homogeneous path.
    /// @return command Sole router command.
    /// @return payload Command input.
    function exactOutput(address input, uint256 maximum, uint256 output, IMultiProtocolSwapTypes.Hop[] memory hops)
        internal
        view
        returns (bytes1 command, bytes memory payload)
    {
        IMultiProtocolSwapTypes.Protocol protocol = hops[0].protocol;
        for (uint256 i = 1; i < hops.length; ++i) {
            if (hops[i].protocol != protocol) revert UnsupportedExactOutputRoute();
        }
        if (protocol == IMultiProtocolSwapTypes.Protocol.V2) {
            address[] memory path = new address[](hops.length + 1);
            path[0] = input;
            for (uint256 i; i < hops.length; ++i) {
                path[i + 1] = hops[i].tokenOut;
            }
            return (0x09, abi.encode(address(this), output, maximum, path, true, new uint256[](0)));
        }
        if (protocol == IMultiProtocolSwapTypes.Protocol.V3) {
            bytes memory path = abi.encodePacked(hops[hops.length - 1].tokenOut);
            for (uint256 i = hops.length; i > 0; --i) {
                path = abi.encodePacked(path, hops[i - 1].fee, i == 1 ? input : hops[i - 2].tokenOut);
            }
            return (0x01, abi.encode(address(this), output, maximum, path, true, new uint256[](0)));
        }
        PathKey[] memory pathKeys = new PathKey[](hops.length);
        for (uint256 i; i < hops.length; ++i) {
            IMultiProtocolSwapTypes.Hop memory hop = hops[i];
            pathKeys[i] =
                PathKey(i == 0 ? input : hops[i - 1].tokenOut, hop.fee, hop.tickSpacing, hop.hooks, hop.hookData);
        }
        address tokenOut = hops[hops.length - 1].tokenOut;
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(ExactOutput(tokenOut, pathKeys, new uint256[](0), output.toUint128(), maximum.toUint128()));
        params[1] = abi.encode(input, maximum);
        params[2] = abi.encode(tokenOut, uint256(0));
        return (0x10, abi.encode(hex"090c0f", params));
    }
}
