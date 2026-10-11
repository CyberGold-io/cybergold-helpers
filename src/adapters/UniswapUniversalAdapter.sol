// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/interfaces/IAllowanceTransfer.sol";

import {AdapterAccounting} from "./AdapterAccounting.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";

/// @notice Minimal execution surface of Uniswap's Universal Router.
interface IUniversalRouter {
    /// @notice Execute a swap through the configured router.
    /// @param commands Universal Router command stream executed by the adapter.
    /// @param inputs Universal Router input payloads paired with the command stream.
    /// @param deadline Last timestamp at which the router may execute the command stream.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @title UniswapUniversalAdapter
/// @notice Routes a single Uniswap V3 exact-input or exact-output swap through Universal Router.
/// @dev Input is pulled atomically from the caller and exposed to Universal Router through Permit2 only for
/// the current transaction. Output and unused input are settled from measured balance deltas.
contract UniswapUniversalAdapter is ISwapAdapter, ReentrancyGuard, AdapterAccounting {
    using SafeCast for uint256;

    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant V3_SWAP_EXACT_OUT = 0x01;
    /// @notice Immutable Permit2 shared with the Helpers diamond.
    address public immutable PERMIT2;

    /// @notice Immutable Universal Router allowed to execute swaps.
    address public immutable UNIVERSAL_ROUTER;

    /// @notice Decoded constraints for one Uniswap V3 Universal Router command.
    /// @param path Packed V3 path; token order must match the selected swap direction.
    /// @param amountLimit Minimum output for exact-input, or exact output requested for exact-output.
    /// @param deadline Last execution timestamp; zero substitutes the current block timestamp.
    /// @param exactIn Whether to execute `V3_SWAP_EXACT_IN` instead of `V3_SWAP_EXACT_OUT`.
    struct SwapData {
        bytes path;
        uint256 amountLimit;
        uint256 deadline;
        bool exactIn;
    }

    /// @notice The configured router or one of the swap token addresses is zero.
    error InvalidAddress();
    /// @notice Input is zero or cannot fit Permit2's `uint160` allowance field.
    error InvalidAmount();
    /// @notice Adapter-specific swap data is empty or cannot be ABI-decoded as `SwapData`.
    error InvalidSwapData();
    /// @notice Universal Router rejected or failed the encoded V3 command.
    /// @param revertData Raw revert payload returned by Universal Router.
    error UniversalRouterSwapFailed(bytes revertData);

    /// @notice Configure the sole Universal Router this adapter may call.
    /// @param helpersDiamond_ Immutable Helpers diamond recovery authority.
    /// @param universalRouter_ Nonzero Uniswap Universal Router address.
    /// @param permit2_ Nonzero Permit2 identity shared with Helpers.
    constructor(address helpersDiamond_, address universalRouter_, address permit2_)
        AdapterAccounting(helpersDiamond_)
    {
        if (universalRouter_ == address(0) || permit2_ == address(0)) {
            revert InvalidAddress();
        }
        UNIVERSAL_ROUTER = universalRouter_;
        PERMIT2 = permit2_;
    }

    /// @notice Execute one V3 swap using an exact caller-funded input lot.
    /// @param tokenIn ERC-20 pulled from `msg.sender` and authorized through Permit2.
    /// @param tokenOut ERC-20 whose positive balance delta is returned as output.
    /// @param amountIn Exact maximum input lot, in `tokenIn`'s smallest unit.
    /// @param data ABI-encoded `SwapData` containing path, amount bound, deadline, and direction.
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
        if (amountIn > type(uint160).max) revert InvalidAmount();

        SwapData memory swapData = _decodeSwapData(data);
        IERC20 inToken = IERC20(tokenIn);
        IERC20 outToken = IERC20(tokenOut);

        SwapBalances memory beforeBalances = _pullAndSnapshotSwap(inToken, outToken, amountIn);
        // Universal Router pulls ERC20s via Permit2 when payerIsUser=true.
        _setAllowance(inToken, PERMIT2, amountIn);
        IAllowanceTransfer(PERMIT2).approve(tokenIn, UNIVERSAL_ROUTER, amountIn.toUint160(), block.timestamp.toUint48());

        bytes memory commands = abi.encodePacked(swapData.exactIn ? V3_SWAP_EXACT_IN : V3_SWAP_EXACT_OUT);
        bytes[] memory inputs = new bytes[](1);
        uint256[] memory minHopPriceX36 = new uint256[](0);
        if (swapData.exactIn) {
            // `payerIsUser=true` makes Universal Router pull tokens from `msg.sender` (this adapter),
            // which has just approved the router and currently holds the input tokens.
            inputs[0] = abi.encode(address(this), amountIn, swapData.amountLimit, swapData.path, true, minHopPriceX36);
        } else {
            inputs[0] = abi.encode(address(this), swapData.amountLimit, amountIn, swapData.path, true, minHopPriceX36);
        }

        uint256 deadline = swapData.deadline == 0 ? block.timestamp : swapData.deadline;
        (bool ok, bytes memory revertData) =
            UNIVERSAL_ROUTER.call(abi.encodeWithSelector(IUniversalRouter.execute.selector, commands, inputs, deadline));
        if (!ok) revert UniversalRouterSwapFailed(revertData);

        _setAllowance(inToken, PERMIT2, 0);
        amountOut = _settleSwap(inToken, outToken, msg.sender, beforeBalances);
    }

    /// @dev Decode and minimally validate the adapter-specific swap constraints.
    /// @param data ABI encoding of `(bytes path, uint256 amountLimit, uint256 deadline, bool exactIn)`.
    /// @return swapData Decoded V3 swap constraints.
    function _decodeSwapData(bytes calldata data) internal pure returns (SwapData memory swapData) {
        if (data.length == 0) revert InvalidSwapData();
        (swapData.path, swapData.amountLimit, swapData.deadline, swapData.exactIn) =
            abi.decode(data, (bytes, uint256, uint256, bool));
    }

    /// @notice Accept native ETH sent directly to this contract for owner-mediated recovery only.
    receive() external payable {}
}
