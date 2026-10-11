// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/interfaces/IAllowanceTransfer.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IMultiProtocolSwapTypes} from "../interfaces/IMultiProtocolSwapTypes.sol";
import {AdapterAccounting} from "./AdapterAccounting.sol";
import {UniswapRouterEncoding} from "./UniswapRouterEncoding.sol";
import {IUniversalRouter} from "./UniswapUniversalAdapter.sol";

/// @notice Fee-neutral V2/V3/V4 executor using measured per-hop exact-input custody.
contract UniswapMultiProtocolAdapter is ISwapAdapter, IMultiProtocolSwapTypes, ReentrancyGuard, AdapterAccounting {
    using SafeCast for uint256;
    /// @notice Release-pinned Permit2 AllowanceTransfer identity.
    address public immutable PERMIT2;
    /// @notice Sole Universal Router target, using the qualified 2.2.0 encoding.
    address public immutable UNIVERSAL_ROUTER;
    /// @notice A configured identity or endpoint is zero.
    error InvalidAddress();
    /// @notice An empty funded lot is not an already-paid swap sentinel.
    error InvalidAmount();
    /// @notice Measured final output does not satisfy the plan's aggregate bound.
    /// @param required Output floor or target.
    /// @param received Measured output.
    error InsufficientOutput(uint256 required, uint256 received);
    /// @notice Owner-accepted atomic failure for an uncovered current-operation intermediate.
    /// @param token Unsettled nonendpoint currency.
    /// @param amount Current-operation remainder, excluding old balances.
    error UnsettledIntermediateCurrency(address token, uint256 amount);
    /// @notice Router execution failed; upstream errors are retained in the payload.
    /// @param revertData Exact router failure.
    error UniversalRouterSwapFailed(bytes revertData);

    /// @notice Pre-operation custody baselines for one nonendpoint currency.
    struct Intermediate {
        address token;
        uint256 adapterBalance;
        uint256 routerBalance;
    }

    /// @notice Bind immutable recovery and venue identities.
    /// @param helpersDiamond_ Existing Helpers recovery authority.
    /// @param universalRouter_ Qualified Universal Router.
    /// @param permit2_ Release-wide Permit2.
    constructor(address helpersDiamond_, address universalRouter_, address permit2_)
        AdapterAccounting(helpersDiamond_)
    {
        if (universalRouter_ == address(0) || permit2_ == address(0)) {
            revert InvalidAddress();
        }
        UNIVERSAL_ROUTER = universalRouter_;
        PERMIT2 = permit2_;
    }

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert InvalidAddress();
        _rejectIdenticalTokens(tokenIn, tokenOut);
        if (amountIn == 0) revert InvalidAmount();
        uint256 firstWord;
        assembly ("memory-safe") { firstWord := calldataload(data.offset) }
        // The retained V3 tuple starts with its bytes offset; typed SwapPlan starts with a bool.
        if (firstWord == 128) return _swapLegacyV3(tokenIn, tokenOut, amountIn, data);
        SwapPlan memory plan = abi.decode(data, (SwapPlan));
        Intermediate[] memory intermediates = _snapshotIntermediates(tokenIn, tokenOut, plan.branches);
        SwapBalances memory beforeBalances = _pullAndSnapshotSwap(IERC20(tokenIn), IERC20(tokenOut), amountIn);
        uint256 deadline = plan.deadline == 0 ? block.timestamp : plan.deadline;
        if (plan.exactIn) {
            uint256 remaining = amountIn;
            for (uint256 b; b < plan.branches.length; ++b) {
                Branch memory branch = plan.branches[b];
                remaining -= branch.amountIn;
                uint256 lot = branch.amountIn;
                address input = tokenIn;
                for (uint256 h; h < branch.hops.length; ++h) {
                    // Zero cannot become V2 ALREADY_PAID or accidentally authorize router balances.
                    if (lot == 0) break;
                    Hop memory hop = branch.hops[h];
                    uint256 outputBefore = IERC20(hop.tokenOut).balanceOf(address(this));
                    (bytes1 command, bytes memory payload) = UniswapRouterEncoding.exactInput(input, lot, hop);
                    _execute(input, lot, command, payload, deadline);
                    lot = IERC20(hop.tokenOut).balanceOf(address(this)) - outputBefore;
                    input = hop.tokenOut;
                }
            }
        } else {
            if (plan.branches.length != 1) revert UniswapRouterEncoding.UnsupportedExactOutputRoute();
            (bytes1 command, bytes memory payload) =
                UniswapRouterEncoding.exactOutput(tokenIn, amountIn, plan.amountLimit, plan.branches[0].hops);
            _execute(tokenIn, amountIn, command, payload, deadline);
        }
        _settleIntermediates(intermediates);
        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - beforeBalances.output;
        if (received < plan.amountLimit) revert InsufficientOutput(plan.amountLimit, received);
        amountOut = _settleSwap(IERC20(tokenIn), IERC20(tokenOut), msg.sender, beforeBalances);
    }

    function _swapLegacyV3(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
        private
        returns (uint256 amountOut)
    {
        (bytes memory path, uint256 limit, uint256 deadline, bool exactIn) =
            abi.decode(data, (bytes, uint256, uint256, bool));
        Intermediate[] memory intermediates = _snapshotLegacyPath(tokenIn, tokenOut, path);
        SwapBalances memory beforeBalances = _pullAndSnapshotSwap(IERC20(tokenIn), IERC20(tokenOut), amountIn);
        bytes memory payload = exactIn
            ? abi.encode(address(this), amountIn, limit, path, true, new uint256[](0))
            : abi.encode(address(this), limit, amountIn, path, true, new uint256[](0));
        _execute(
            tokenIn,
            amountIn,
            exactIn ? bytes1(0x00) : bytes1(0x01),
            payload,
            deadline == 0 ? block.timestamp : deadline
        );
        _settleIntermediates(intermediates);
        amountOut = _settleSwap(IERC20(tokenIn), IERC20(tokenOut), msg.sender, beforeBalances);
    }

    function _snapshotLegacyPath(address input, address output, bytes memory path)
        private
        view
        returns (Intermediate[] memory)
    {
        uint256 tokens = (path.length - 20) / 23 + 1;
        Branch[] memory branches = new Branch[](1);
        branches[0].hops = new Hop[](tokens);
        for (uint256 i; i < tokens; ++i) {
            address token;
            uint256 offset = i * 23;
            assembly ("memory-safe") { token := shr(96, mload(add(add(path, 32), offset))) }
            branches[0].hops[i].tokenOut = token;
        }
        return _snapshotIntermediates(input, output, branches);
    }

    function _execute(address input, uint256 lot, bytes1 command, bytes memory payload, uint256 deadline) private {
        IERC20 token = IERC20(input);
        _setAllowance(token, PERMIT2, lot);
        IAllowanceTransfer(PERMIT2).approve(input, UNIVERSAL_ROUTER, lot.toUint160(), block.timestamp.toUint48());
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = payload;
        (bool ok, bytes memory reason) = UNIVERSAL_ROUTER.call(
            abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(command), inputs, deadline))
        );
        if (!ok) revert UniversalRouterSwapFailed(reason);
        _setAllowance(token, PERMIT2, 0);
    }

    function _snapshotIntermediates(address input, address output, Branch[] memory branches)
        private
        view
        returns (Intermediate[] memory snapshots)
    {
        uint256 count;
        for (uint256 b; b < branches.length; ++b) {
            count += branches[b].hops.length;
        }
        snapshots = new Intermediate[](count);
        uint256 used;
        for (uint256 b; b < branches.length; ++b) {
            for (uint256 h; h < branches[b].hops.length; ++h) {
                address token = branches[b].hops[h].tokenOut;
                if (token == input || token == output) continue;
                bool seen;
                for (uint256 i; i < used; ++i) {
                    if (snapshots[i].token == token) {
                        seen = true;
                        break;
                    }
                }
                if (seen) continue;
                snapshots[used++] = Intermediate(
                    token, IERC20(token).balanceOf(address(this)), IERC20(token).balanceOf(UNIVERSAL_ROUTER)
                );
            }
        }
        assembly ("memory-safe") { mstore(snapshots, used) }
    }

    function _settleIntermediates(Intermediate[] memory snapshots) private view {
        for (uint256 i; i < snapshots.length; ++i) {
            Intermediate memory s = snapshots[i];
            uint256 adapterAfter = IERC20(s.token).balanceOf(address(this));
            uint256 routerAfter = IERC20(s.token).balanceOf(UNIVERSAL_ROUTER);
            if (adapterAfter < s.adapterBalance) {
                revert PreExistingInputConsumed(s.token, s.adapterBalance, adapterAfter);
            }
            if (routerAfter < s.routerBalance) revert PreExistingInputConsumed(s.token, s.routerBalance, routerAfter);
            uint256 remainder = adapterAfter - s.adapterBalance + routerAfter - s.routerBalance;
            if (remainder != 0) revert UnsettledIntermediateCurrency(s.token, remainder);
        }
    }

    /// @notice Accept native currency solely for existing owner-mediated recovery.
    receive() external payable {}
}
