// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {IBasketRouterTypes} from "../interfaces/IBasketRouterTypes.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";

/// @notice Caller binding and token authorization shared by router flows.
abstract contract RouterAuthorizationBase is IBasketRouterTypes {
    using SafeERC20 for IERC20;

    function _routerStorage() internal pure virtual returns (LibAppStorage.RouterStorage storage rs);

    /// @dev Return the immutable Permit2 identity shared by all routed facets.
    function _permit2() internal view virtual returns (ISignatureTransfer);

    /// @dev Pull an exact token lot through ordinary ERC-20 allowance.
    function _acquireWithAllowance(address owner, IERC20 token, uint256 requiredAmount) internal {
        _transferFromExact(owner, token, requiredAmount);
    }

    /// @dev Apply one standard token ERC-2612 permit when needed, then pull the exact lot.
    function _acquireWithPermit(address owner, IERC20 token, uint256 requiredAmount, PermitParams memory permit)
        internal
    {
        _applyPermit(owner, address(token), requiredAmount, permit);
        _transferFromExact(owner, token, requiredAmount);
    }

    /// @dev Pull an exact token lot through immutable Permit2.
    function _acquireWithPermit2(address owner, IERC20 token, uint256 requiredAmount, Permit2Params memory permit)
        internal
    {
        _transferWithPermit2(owner, address(token), requiredAmount, permit);
    }

    /// @dev Pull through ERC-20 allowance and prove exact payer debit and Helpers credit.
    function _transferFromExact(address owner, IERC20 token, uint256 requiredAmount) private {
        uint256 payerBalanceBefore = token.balanceOf(owner);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(owner, address(this), requiredAmount);
        _requireExactPayerDebit(address(token), owner, payerBalanceBefore, token.balanceOf(owner), requiredAmount);
        _requireExactTokenCredit(address(token), balanceBefore, token.balanceOf(address(this)), requiredAmount);
    }

    function _transferWithPermit2(address owner, address token, uint256 requiredAmount, Permit2Params memory permit)
        internal
    {
        ISignatureTransfer signatureTransfer = _permit2();
        if (permit.permit.permitted.token != token) {
            revert InvalidPermit2Token(permit.permit.permitted.token, token);
        }
        if (permit.permit.permitted.amount < requiredAmount) {
            revert Permit2AmountTooLow(permit.permit.permitted.amount, requiredAmount);
        }
        // Permit2 defines its signed deadline against the block timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        if (permit.permit.deadline == 0 || permit.permit.deadline < block.timestamp) {
            revert PermitExpired(permit.permit.deadline, block.timestamp);
        }

        ISignatureTransfer.SignatureTransferDetails memory details =
            ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: requiredAmount});
        uint256 payerBalanceBefore = IERC20(token).balanceOf(owner);
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        signatureTransfer.permitTransferFrom(permit.permit, details, owner, permit.signature);
        _requireExactPayerDebit(token, owner, payerBalanceBefore, IERC20(token).balanceOf(owner), requiredAmount);
        _requireExactTokenCredit(token, balanceBefore, IERC20(token).balanceOf(address(this)), requiredAmount);
    }

    /// @dev Require the payer's token balance to decrease by exactly the authorized amount.
    function _requireExactPayerDebit(
        address token,
        address payer,
        uint256 balanceBefore,
        uint256 balanceAfter,
        uint256 expected
    ) internal pure {
        uint256 actual = balanceAfter <= balanceBefore ? balanceBefore - balanceAfter : 0;
        if (actual != expected) revert PayerTokenDebitMismatch(token, payer, expected, actual);
    }

    /// @dev Require an exact positive balance delta for an ERC20 acquisition into Helpers.
    function _requireExactTokenCredit(address token, uint256 balanceBefore, uint256 balanceAfter, uint256 expected)
        internal
        pure
    {
        uint256 actual = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (actual != expected) revert RouterTokenCreditMismatch(token, expected, actual);
    }

    /// @dev Require Helpers to debit exactly the current operation's token lot.
    function _requireExactRouterDebit(address token, uint256 balanceBefore, uint256 balanceAfter, uint256 expected)
        internal
        pure
    {
        uint256 actual = balanceAfter <= balanceBefore ? balanceBefore - balanceAfter : 0;
        if (actual != expected) revert RouterTokenDebitMismatch(token, expected, actual);
    }

    /// @dev Reject an approved adapter that consumes more Router input than its quoted maximum lot.
    /// Bundled adapters may return venue-unused input, so the observable net debit can be below the maximum.
    function _requireAdapterInputDebitAtMost(
        address asset,
        address adapter,
        uint256 balanceBefore,
        uint256 balanceAfter,
        uint256 maximum
    ) internal pure {
        uint256 actual = balanceAfter <= balanceBefore ? balanceBefore - balanceAfter : 0;
        if (actual > maximum) revert AdapterInputDebitExceeded(asset, adapter, maximum, actual);
    }

    function _applyPermit(address owner, address token, uint256 requiredAmount, PermitParams memory permit) private {
        uint256 currentAllowance = IERC20(token).allowance(owner, address(this));

        // ERC-2612 signatures are public and can be submitted before the routed transaction. A consumed
        // nonce is therefore not fatal when the resulting allowance already authorizes this exact pull.
        // Permit `value` is the final allowance (not a delta), so any permit we do attempt must cover the
        // full required amount even when a smaller allowance already exists.
        if (currentAllowance >= requiredAmount) return;

        // ERC-2612 defines its signed deadline against the block timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        if (permit.deadline == 0 || permit.deadline < block.timestamp) {
            revert PermitExpired(permit.deadline, block.timestamp);
        }
        if (permit.value < requiredAmount) revert PermitAmountTooLow(permit.value, requiredAmount);
        try IERC20Permit(token)
            .permit(owner, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s) {}
        catch (bytes memory reason) {
            if (reason.length == 0) revert PermitAllowanceTooLow(currentAllowance, requiredAmount);
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }

        currentAllowance = IERC20(token).allowance(owner, address(this));
        if (currentAllowance < requiredAmount) {
            revert PermitAllowanceTooLow(currentAllowance, requiredAmount);
        }
    }

    function _copyPermit(PermitParams calldata permit) internal pure returns (PermitParams memory copied) {
        copied.value = permit.value;
        copied.deadline = permit.deadline;
        copied.v = permit.v;
        copied.r = permit.r;
        copied.s = permit.s;
    }

    function _copyPermit2(Permit2Params calldata permit) internal pure returns (Permit2Params memory copied) {
        copied.permit = permit.permit;
        copied.signature = permit.signature;
    }
}
