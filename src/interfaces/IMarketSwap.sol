// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IBasketRouterTypes} from "./IBasketRouterTypes.sol";

/// @notice Standalone liquidity swaps of existing CYGLD, without Core issuance or redemption.
interface IMarketSwap {
    /// @notice Which endpoint is the configured CYGLD token.
    enum MarketSide {
        BuyCygld,
        SellCygld
    }
    /// @notice Existing funding paths; the transaction sender is always the payer.
    enum FundingMode {
        Allowance,
        NativePermit,
        Permit2
    }

    /// @notice User-authorized market economics and fee-neutral adapter route.
    /// @param side Direction relative to CYGLD.
    /// @param counterToken Non-CYGLD endpoint.
    /// @param amount Inclusive input budget for exact-input, net output target for exact-output.
    /// @param bound Net output minimum for exact-input, inclusive input maximum for exact-output.
    /// @param routedInput Explicit routed input for exact-input sales; ignored in the other modes.
    /// @param feeCygld Frozen quote-derived application fee; this interface authenticates no rate policy.
    /// @param recipient Recipient of net output; input and output excess return to the payer.
    /// @param deadline Last execution timestamp; zero uses the current transaction timestamp.
    /// @param adapter Existing approved swap adapter.
    /// @param data Typed adapter-specific route payload.
    struct MarketSwapParams {
        MarketSide side;
        address counterToken;
        uint256 amount;
        uint256 bound;
        uint256 routedInput;
        uint256 feeCygld;
        address recipient;
        uint256 deadline;
        address adapter;
        bytes data;
    }

    /// @notice Authorization consumed only through the selected funding path.
    /// @param mode Allowance, native ERC-2612, or Permit2 SignatureTransfer.
    /// @param nativePermit Standard permit naming the Helpers Diamond as spender.
    /// @param permit2 Existing SignatureTransfer authorization naming the input token.
    struct FundingAuthorization {
        FundingMode mode;
        IBasketRouterTypes.PermitParams nativePermit;
        IBasketRouterTypes.Permit2Params permit2;
    }

    /// @notice Measured economic result, with refunds distinct from user net output.
    /// @param swapInput Input consumed by the venue, excluding the CYGLD application fee.
    /// @param amountOut Net output delivered to the selected recipient.
    /// @param inputRefund Original-input amount returned to the payer.
    /// @param outputRefund Exact-output excess returned to the payer.
    /// @param feeCygld Literal accepted fee paid in CYGLD.
    /// @param feeRecipient Actual Helpers owner at fee settlement.
    struct MarketSwapResult {
        uint256 swapInput;
        uint256 amountOut;
        uint256 inputRefund;
        uint256 outputRefund;
        uint256 feeCygld;
        address feeRecipient;
    }

    /// @notice Emitted after all current-operation payouts complete.
    /// @param payer Transaction sender who funded the operation and receives refunds.
    /// @param recipient Net output recipient.
    /// @param counterToken Non-CYGLD endpoint.
    /// @param side Buy or sell CYGLD.
    /// @param exactInput Whether the input budget rather than net output was fixed.
    /// @param swapInput Venue input excluding application fee.
    /// @param amountOut Net output delivered.
    /// @param inputRefund Original-input refund.
    /// @param outputRefund Exact-output excess refund.
    /// @param feeCygld Application fee paid.
    /// @param feeRecipient Actual application fee beneficiary.
    event MarketSwapExecuted(
        address indexed payer,
        address indexed recipient,
        address indexed counterToken,
        MarketSide side,
        bool exactInput,
        uint256 swapInput,
        uint256 amountOut,
        uint256 inputRefund,
        uint256 outputRefund,
        uint256 feeCygld,
        address feeRecipient
    );

    /// @notice Swap a fixed inclusive input budget, preserving a net output floor.
    /// @param params Accepted economics and route.
    /// @param authorization Existing token funding authorization.
    /// @return result Measured venue spend, payouts, refunds and fee beneficiary.
    function swapExactInput(MarketSwapParams calldata params, FundingAuthorization calldata authorization)
        external
        returns (MarketSwapResult memory result);

    /// @notice Deliver a fixed net output, preserving an inclusive input ceiling.
    /// @param params Accepted economics and route.
    /// @param authorization Existing token funding authorization.
    /// @return result Measured venue spend, payouts, refunds and fee beneficiary.
    function swapExactOutput(MarketSwapParams calldata params, FundingAuthorization calldata authorization)
        external
        returns (MarketSwapResult memory result);
}
