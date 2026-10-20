// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {ITradeExactInput} from "../interfaces/ITradeExactInput.sol";
import {TradeConversionBase} from "./TradeConversionBase.sol";

/// @notice Exact original-input funding and payout for the universal execution engine.
abstract contract TradeExactInputBase is TradeConversionBase, ITradeExactInput {
    using SafeERC20 for IERC20;

    /// @notice Bind release-wide funding and successor routing identities.
    /// @param permit2_ Existing release-wide Permit2 identity.
    /// @param adapter_ Immutable no-hook successor adapter.
    constructor(address permit2_, address adapter_) TradeConversionBase(permit2_, adapter_) {}

    function _acquireInputs(ExactInputPlan calldata plan, FundingBundle calldata funding) internal {
        uint256 count = plan.inputs.length;
        if (funding.authorizations.length != count) {
            revert CoreAssetAmountsLengthMismatch(count, funding.authorizations.length);
        }
        uint256 nativeAmount;
        uint256 batchCount;
        for (uint256 i; i < count; ++i) {
            if (plan.inputs[i].currency == address(0)) {
                nativeAmount += plan.inputs[i].amount;
            } else if (plan.inputs[i].amount != 0 && funding.authorizations[i].kind == BasketInputAuthorization.Permit2)
            {
                ++batchCount;
            }
        }
        if (msg.value != nativeAmount) revert NativeValueMismatch(nativeAmount, msg.value);
        for (uint256 i; i < count; ++i) {
            AssetAmount calldata input = plan.inputs[i];
            if (input.currency == address(0) || input.amount == 0) continue;
            FundingAuthorization calldata auth = funding.authorizations[i];
            if (auth.kind == BasketInputAuthorization.Allowance) {
                _acquireWithAllowance(msg.sender, IERC20(input.currency), input.amount);
            } else if (auth.kind == BasketInputAuthorization.TokenPermit) {
                _acquireWithPermit(msg.sender, IERC20(input.currency), input.amount, auth.permit);
            }
        }
        if (batchCount != 0) _acquireBatch(plan.inputs, funding, batchCount);
    }

    function _acquireBatch(AssetAmount[] calldata inputs, FundingBundle calldata funding, uint256 count) private {
        if (funding.permit2.permit.permitted.length != count) {
            revert Permit2BatchLengthMismatch(funding.permit2.permit.permitted.length, count);
        }
        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](count);
        uint256[] memory helpersBefore = new uint256[](count);
        uint256[] memory payerBefore = new uint256[](count);
        uint256[] memory indices = new uint256[](count);
        uint256 cursor;
        for (uint256 i; i < inputs.length; ++i) {
            AssetAmount calldata input = inputs[i];
            if (
                input.currency == address(0) || input.amount == 0
                    || funding.authorizations[i].kind != BasketInputAuthorization.Permit2
            ) continue;
            ISignatureTransfer.TokenPermissions calldata permission = funding.permit2.permit.permitted[cursor];
            if (permission.token != input.currency) revert InvalidPermit2Token(permission.token, input.currency);
            if (permission.amount < input.amount) revert Permit2AmountTooLow(permission.amount, input.amount);
            helpersBefore[cursor] = IERC20(input.currency).balanceOf(address(this));
            payerBefore[cursor] = IERC20(input.currency).balanceOf(msg.sender);
            indices[cursor] = i;
            details[cursor++] = ISignatureTransfer.SignatureTransferDetails(address(this), input.amount);
        }
        _permit2().permitTransferFrom(funding.permit2.permit, details, msg.sender, funding.permit2.signature);
        for (uint256 i; i < count; ++i) {
            AssetAmount calldata input = inputs[indices[i]];
            _requireExactTokenCredit(
                input.currency, helpersBefore[i], IERC20(input.currency).balanceOf(address(this)), input.amount
            );
            _requireExactPayerDebit(
                input.currency, msg.sender, payerBefore[i], IERC20(input.currency).balanceOf(msg.sender), input.amount
            );
        }
    }

    function _payCurrency(address recipient, address currency, uint256 amount) internal {
        if (amount == 0) return;
        if (currency != address(0)) {
            _payoutTokenExact(recipient, currency, false, amount);
        } else {
            (bool success,) = recipient.call{value: amount}("");
            if (!success) revert EthRefundFailed();
        }
    }
}
