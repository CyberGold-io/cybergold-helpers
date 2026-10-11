// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC173} from "diamond-1/interfaces/IERC173.sol";

/// @notice Shared measured-balance settlement for concrete swap venues.
abstract contract AdapterAccounting {
    using SafeERC20 for IERC20;

    /// @notice Input-token and output-token balances captured before venue execution.
    struct SwapBalances {
        uint256 input;
        uint256 output;
    }

    /// @notice Reverts when caller funding does not deliver the declared exact input amount.
    /// @param expected Exact input amount declared for the current swap.
    /// @param received Input-token balance delta received from the caller.
    error InputAmountMismatch(uint256 expected, uint256 received);
    /// @notice Reverts when caller funding debits more or less than the declared input amount.
    /// @param token Input token whose caller-side debit was measured.
    /// @param expected Exact input amount declared for the current swap.
    /// @param actual Caller balance decrease observed across the transfer.
    error CallerTokenDebitMismatch(address token, uint256 expected, uint256 actual);
    /// @notice Reverts when an adapter payout debits more or less than the promised amount.
    /// @param token Token whose adapter-side debit was measured.
    /// @param expected Exact output or refund amount promised by the adapter.
    /// @param actual Adapter balance decrease observed across the transfer.
    error AdapterTokenDebitMismatch(address token, uint256 expected, uint256 actual);
    /// @notice Reverts when an adapter payout credits the recipient by a non-exact amount.
    /// @param token Token whose recipient-side credit was measured.
    /// @param recipient Account that should receive the exact output or refund.
    /// @param expected Exact output or refund amount promised by the adapter.
    /// @param actual Recipient balance increase observed across the transfer.
    error AdapterRecipientCreditMismatch(address token, address recipient, uint256 expected, uint256 actual);
    /// @notice Reverts when venue execution consumes input held before the current swap.
    /// @param token Input token whose protected baseline was crossed.
    /// @param baseline Adapter input balance before the current caller lot was pulled.
    /// @param actual Adapter input balance remaining after venue execution.
    error PreExistingInputConsumed(address token, uint256 baseline, uint256 actual);
    /// @notice Reverts when a swap needlessly names the same input and output token.
    /// @param token Token supplied as both input and output.
    error IdenticalSwapTokens(address token);
    /// @notice Reverts when the Helpers authority or its recovery recipient is invalid.
    /// @param authority Rejected authority or recipient.
    error InvalidRecoveryAuthority(address authority);
    /// @notice Reverts when an account outside the sealed recovery path calls recovery logic.
    /// @param caller Account that attempted the operation.
    /// @param expected Account authorized to perform the operation.
    error UnauthorizedRecoveryCaller(address caller, address expected);
    /// @notice Reverts when native-currency recovery to the Helpers owner fails.
    error NativeRecoveryFailed();

    /// @notice Helpers diamond whose current owner receives recovered balances.
    address public immutable helpersDiamond;

    /// @notice Emitted after an adapter balance is recovered to the Helpers owner.
    /// @param token Recovered token, or zero for native currency.
    /// @param recipient Current Helpers owner that received the balance.
    /// @param amount Amount recovered.
    event AdapterBalanceRecovered(address indexed token, address indexed recipient, uint256 amount);

    constructor(address helpersDiamond_) {
        if (helpersDiamond_ == address(0) || helpersDiamond_.code.length == 0) {
            revert InvalidRecoveryAuthority(helpersDiamond_);
        }
        helpersDiamond = helpersDiamond_;
    }

    /// @dev Reject an identity swap, whose input-refund and output-delta accounting would overlap.
    function _rejectIdenticalTokens(address tokenIn, address tokenOut) internal pure {
        if (tokenIn == tokenOut) revert IdenticalSwapTokens(tokenIn);
    }

    /// @notice Recover stranded ERC-20 or native balances only through the Helpers owner.
    /// @param token Token to recover, or zero for native currency.
    function recover(address token) external {
        address authority = helpersDiamond;
        if (msg.sender != authority) revert UnauthorizedRecoveryCaller(msg.sender, authority);
        address recipient = IERC173(authority).owner();
        if (recipient == address(0)) revert InvalidRecoveryAuthority(recipient);
        if (token == address(0)) {
            uint256 nativeAmount = address(this).balance;
            if (nativeAmount != 0) {
                (bool sent,) = recipient.call{value: nativeAmount}("");
                if (!sent) revert NativeRecoveryFailed();
            }
            emit AdapterBalanceRecovered(token, recipient, nativeAmount);
            return;
        }
        uint256 tokenAmount = IERC20(token).balanceOf(address(this));
        if (tokenAmount != 0) IERC20(token).safeTransfer(recipient, tokenAmount);
        emit AdapterBalanceRecovered(token, recipient, tokenAmount);
    }

    /// @dev Pull the current swap lot atomically so pre-existing balances cannot fund callers.
    function _pullAndSnapshotSwap(IERC20 inputToken, IERC20 outputToken, uint256 amountIn)
        internal
        returns (SwapBalances memory balances)
    {
        balances.input = inputToken.balanceOf(address(this));
        balances.output = outputToken.balanceOf(address(this));

        uint256 callerBalanceBefore = inputToken.balanceOf(msg.sender);
        inputToken.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 inputBalanceAfter = inputToken.balanceOf(address(this));
        uint256 callerBalanceAfter = inputToken.balanceOf(msg.sender);

        uint256 debited = callerBalanceAfter <= callerBalanceBefore ? callerBalanceBefore - callerBalanceAfter : 0;
        if (debited != amountIn) revert CallerTokenDebitMismatch(address(inputToken), amountIn, debited);

        uint256 received = inputBalanceAfter >= balances.input ? inputBalanceAfter - balances.input : 0;
        if (received != amountIn) revert InputAmountMismatch(amountIn, received);
    }

    /// @dev Replace `spender`'s allowance, supporting tokens that require zeroing before approval.
    /// @param token ERC-20 whose allowance is changed.
    /// @param spender Venue or approval router authorized to pull the current swap lot.
    /// @param amount New allowance in the token's smallest unit.
    function _setAllowance(IERC20 token, address spender, uint256 amount) internal {
        token.forceApprove(spender, amount);
    }

    /// @dev Settle only balances created by the current venue call, preserving any pre-existing adapter funds.
    /// @param inputToken Token whose unspent current-lot remainder is refunded.
    /// @param outputToken Token whose positive current-call balance delta is paid out.
    /// @param recipient Account receiving output and residual input.
    /// @param beforeBalances Snapshot captured before the caller's input was pulled.
    /// @return amountOut Measured output-token delta transferred to `recipient`.
    function _settleSwap(IERC20 inputToken, IERC20 outputToken, address recipient, SwapBalances memory beforeBalances)
        internal
        returns (uint256 amountOut)
    {
        uint256 inputBalanceAfter = inputToken.balanceOf(address(this));
        if (inputBalanceAfter < beforeBalances.input) {
            revert PreExistingInputConsumed(address(inputToken), beforeBalances.input, inputBalanceAfter);
        }

        amountOut = outputToken.balanceOf(address(this)) - beforeBalances.output;
        if (amountOut != 0) _transferExact(outputToken, recipient, amountOut);

        uint256 residualInput = inputBalanceAfter - beforeBalances.input;
        if (residualInput != 0) _transferExact(inputToken, recipient, residualInput);
    }

    /// @dev Transfer an exact adapter-owned token amount without consuming older balances or underpaying the caller.
    function _transferExact(IERC20 token, address recipient, uint256 amount) private {
        uint256 adapterBalanceBefore = token.balanceOf(address(this));
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        token.safeTransfer(recipient, amount);
        uint256 adapterBalanceAfter = token.balanceOf(address(this));
        uint256 recipientBalanceAfter = token.balanceOf(recipient);

        uint256 debited = adapterBalanceAfter <= adapterBalanceBefore ? adapterBalanceBefore - adapterBalanceAfter : 0;
        if (debited != amount) revert AdapterTokenDebitMismatch(address(token), amount, debited);

        uint256 credited =
            recipientBalanceAfter >= recipientBalanceBefore ? recipientBalanceAfter - recipientBalanceBefore : 0;
        if (credited != amount) {
            revert AdapterRecipientCreditMismatch(address(token), recipient, amount, credited);
        }
    }
}
