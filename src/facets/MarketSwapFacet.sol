// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMarketSwap} from "../interfaces/IMarketSwap.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {RouterSettlementBase} from "./RouterSettlementBase.sol";

/// @notice Thin market entrypoint sharing Helpers funding, guards and measured settlement.
contract MarketSwapFacet is RouterSettlementBase {
    using SafeERC20 for IERC20;
    /// @notice Facet runtime namespace; no new persistent market storage is introduced.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.marketSwap");
    /// @notice Documentary source version; runtime generation follows the Diamond registry.
    uint64 public constant FACET_VERSION = 1;

    /// @notice Bind the existing release-wide Permit2 identity.
    /// @param permit2_ Permit2 SignatureTransfer contract.
    constructor(address permit2_) RouterSettlementBase(permit2_) {}

    /// @notice Deliver fixed net output with the retained exact-output funding and refund semantics.
    /// @param params Accepted economics and route.
    /// @param authorization Existing token funding authorization.
    /// @return result Measured venue spend, payouts, refunds and fee beneficiary.
    function swapExactOutput(
        IMarketSwap.MarketSwapParams calldata params,
        IMarketSwap.FundingAuthorization calldata authorization
    ) external whenNotPaused nonReentrant returns (IMarketSwap.MarketSwapResult memory result) {
        return _swapMarket(params, authorization);
    }

    /// @notice Derived endpoints, funding quantities and pre-operation custody baselines.
    struct MarketContext {
        address cygld;
        IERC20 input;
        address output;
        uint256 inputBaseline;
        uint256 outputBaseline;
        uint256 acquisition;
        uint256 swapCap;
        uint256 grossNeed;
        bool buy;
    }

    function _swapMarket(IMarketSwap.MarketSwapParams calldata p, IMarketSwap.FundingAuthorization calldata auth)
        private
        returns (IMarketSwap.MarketSwapResult memory r)
    {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        if (p.counterToken == address(0)) revert ZeroAddress();
        if (p.recipient == address(0)) revert InvalidRecipient();
        if (p.amount == 0) revert ZeroInputAmount();
        // forge-lint: disable-next-line(block-timestamp)
        if (p.deadline != 0 && p.deadline < block.timestamp) revert PermitExpired(p.deadline, block.timestamp);
        if (!_isAdapterApproved(rs, p.adapter)) revert AdapterNotApproved(p.adapter);
        MarketContext memory c;
        c.cygld = rs.coreDiamond;
        c.buy = p.side == IMarketSwap.MarketSide.BuyCygld;
        c.input = IERC20(c.buy ? p.counterToken : c.cygld);
        c.output = c.buy ? c.cygld : p.counterToken;
        c.acquisition = p.bound;
        // Subtraction retains the exact-output inclusive sale budget contract.
        c.swapCap = c.buy ? c.acquisition : c.acquisition - p.feeCygld;
        c.grossNeed = p.amount;
        if (c.buy) c.grossNeed += p.feeCygld;
        c.inputBaseline = c.input.balanceOf(address(this));
        c.outputBaseline = IERC20(c.output).balanceOf(address(this));
        _fund(msg.sender, c.input, c.acquisition, auth);
        uint256 inputBefore = c.input.balanceOf(address(this));
        c.input.forceApprove(p.adapter, c.swapCap);
        uint256 returned = ISwapAdapter(p.adapter).swap(address(c.input), c.output, c.swapCap, p.data);
        uint256 inputAfter = c.input.balanceOf(address(this));
        c.input.forceApprove(p.adapter, 0);
        _requireAdapterInputDebitAtMost(address(c.input), p.adapter, inputBefore, inputAfter, c.swapCap);
        uint256 received = IERC20(c.output).balanceOf(address(this)) - c.outputBaseline;
        if (returned != received) revert AdapterOutputMismatch(c.output, p.adapter, returned, received);
        if (received < c.grossNeed) revert InsufficientOutputForMinAmountOut(c.output, c.grossNeed, received);
        r.swapInput = inputBefore >= inputAfter ? inputBefore - inputAfter : 0;
        r.feeCygld = p.feeCygld;
        r.feeRecipient = _feeRecipient();
        r.amountOut = p.amount;
        _payoutTokenExact(r.feeRecipient, c.cygld, false, p.feeCygld);
        _payoutTokenExact(p.recipient, c.output, false, r.amountOut);
        r.outputRefund = _settleTokenSurplus(msg.sender, IERC20(c.output), c.output, false, c.outputBaseline);
        r.inputRefund = _settleTokenSurplus(msg.sender, c.input, address(c.input), false, c.inputBaseline);
        _emitResult(p, r);
    }

    function _emitResult(IMarketSwap.MarketSwapParams calldata p, IMarketSwap.MarketSwapResult memory r) private {
        emit IMarketSwap.MarketSwapExecuted(
            msg.sender,
            p.recipient,
            p.counterToken,
            p.side,
            false,
            r.swapInput,
            r.amountOut,
            r.inputRefund,
            r.outputRefund,
            r.feeCygld,
            r.feeRecipient
        );
    }

    function _fund(address payer, IERC20 token, uint256 amount, IMarketSwap.FundingAuthorization calldata auth)
        private
    {
        if (auth.mode == IMarketSwap.FundingMode.Allowance) {
            _acquireWithAllowance(payer, token, amount);
        } else if (auth.mode == IMarketSwap.FundingMode.NativePermit) {
            _acquireWithPermit(payer, token, amount, _copyPermit(auth.nativePermit));
        } else {
            _acquireWithPermit2(payer, token, amount, _copyPermit2(auth.permit2));
        }
    }
}
