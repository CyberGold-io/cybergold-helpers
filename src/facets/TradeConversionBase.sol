// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TradeRouteEncoding} from "../libraries/TradeRouteEncoding.sol";
import {ITradeExactInput as T} from "../interfaces/ITradeExactInput.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {INativeSwapAdapter} from "../interfaces/INativeSwapAdapter.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {RouterRedemptionCoreBase} from "./RouterRedemptionCoreBase.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Owned-lot conversions and measured stage accounting, independent of the public funding ABI.
abstract contract TradeConversionBase is RouterRedemptionCoreBase {
    using SafeERC20 for IERC20;
    /// @notice Successor bound to this execution runtime; plans cannot retarget it.
    address public immutable ROUTING_ADAPTER;

    /// @notice Operation-local accounting and branch/stage ownership, never persistent user credit.
    struct Execution {
        T.TradeResult result;
        uint256 branch;
        uint256 stage;
        uint256 deadline;
        uint256 minimumOutput;
        uint256 netOutput;
    }

    /// @notice Bind immutable funding and routing identities.
    /// @param permit2_ Release-wide SignatureTransfer identity.
    /// @param adapter_ Release-bound no-hook routing adapter.
    constructor(address permit2_, address adapter_) RouterRedemptionCoreBase(permit2_) {
        ROUTING_ADAPTER = adapter_;
    }

    function _currencyBalance(address currency) internal view returns (uint256) {
        return currency == address(0) ? address(this).balance : IERC20(currency).balanceOf(address(this));
    }

    function _appendStage(Execution memory ex, T.StageResult memory stage) internal pure {
        T.StageResult[] memory old = ex.result.stages;
        T.StageResult[] memory next = new T.StageResult[](old.length + 1);
        for (uint256 i; i < old.length; ++i) {
            next[i] = old[i];
        }
        stage.branch = ex.branch;
        stage.stage = ex.stage++;
        next[old.length] = stage;
        ex.result.stages = next;
    }

    function _retain(Execution memory ex, address currency, uint256 amount) internal pure {
        if (amount == 0) return;
        T.RetainedInputCharge[] memory old = ex.result.retainedInputs;
        T.RetainedInputCharge[] memory next = new T.RetainedInputCharge[](old.length + 1);
        for (uint256 i; i < old.length; ++i) {
            next[i] = old[i];
        }
        next[old.length] = T.RetainedInputCharge(ex.branch, ex.stage, currency, amount);
        ex.result.retainedInputs = next;
    }

    function _appendRecovery(Execution memory ex, ICoreRedemption.TokenAmount[] memory outputs) internal pure {
        ICoreRedemption.TokenAmount[] memory positive = _positiveRecoveryOutputs(outputs);
        uint256 offset = ex.result.recoveryShares.length;
        ICoreRedemption.TokenAmount[] memory next = new ICoreRedemption.TokenAmount[](offset + positive.length);
        for (uint256 i; i < offset; ++i) {
            next[i] = ex.result.recoveryShares[i];
        }
        for (uint256 i; i < positive.length; ++i) {
            next[offset + i] = positive[i];
        }
        ex.result.recoveryShares = next;
    }

    /// @dev Convert only the leading owned funding representation; internal connectors stay in the adapter.
    function _normalizeLot(address source, address destination, uint256 amount, Execution memory ex)
        internal
        returns (uint256 normalized)
    {
        normalized = amount;
        if (source == destination || amount == 0) return normalized;
        address weth = _routerStorage().wrappedNative;
        uint256 beforeInput = _currencyBalance(source);
        uint256 beforeOutput = _currencyBalance(destination);
        if (source == address(0)) {
            if (destination != weth) revert T.RouteCurrencyMismatch(source, destination);
            IWETH(weth).deposit{value: amount}();
        } else if (source == weth) {
            if (destination != address(0)) revert T.RouteCurrencyMismatch(source, destination);
            IWETH(weth).withdraw(amount);
        } else {
            revert T.RouteCurrencyMismatch(source, destination);
        }
        _requireExactRouterDebit(source, beforeInput, _currencyBalance(source), amount);
        _requireExactTokenCredit(destination, beforeOutput, _currencyBalance(destination), amount);
        _appendStage(ex, T.StageResult(0, 0, source, destination, amount, 0, amount, 0, amount));
    }

    function _convert(address source, uint256 amount, T.AmmTemplate memory route, address desired, Execution memory ex)
        internal
        returns (uint256 output)
    {
        if (amount == 0) return 0;
        // Direct identity and funding conversions do not need artificial swap payloads.
        if (source == desired) return amount;
        amount = _normalizeLot(source, route.inputCurrency, amount, ex);
        if (route.inputCurrency == route.outputCurrency) {
            output = amount;
            if (output < route.minimumOutput) revert InsufficientOutput(route.minimumOutput, output);
        } else {
            output = _executeAmm(amount, route, ex);
        }
        return _normalizeLot(route.outputCurrency, desired, output, ex);
    }

    function _executeAmm(uint256 amount, T.AmmTemplate memory route, Execution memory ex)
        private
        returns (uint256 output)
    {
        address adapter = ROUTING_ADAPTER;
        if (!_isAdapterApproved(_routerStorage(), adapter)) revert AdapterNotApproved(adapter);
        bytes memory payload = TradeRouteEncoding.encode(amount, route, ex.deadline);
        T.StageResult memory measured;
        measured.inputCurrency = route.inputCurrency;
        measured.outputCurrency = route.outputCurrency;
        measured.fundedInput = amount;
        uint256 beforeInput = _currencyBalance(route.inputCurrency);
        uint256 beforeOutput = _currencyBalance(route.outputCurrency);
        uint256 reported;
        if (route.inputCurrency == address(0)) {
            reported = INativeSwapAdapter(adapter).swapNative{value: amount}(route.outputCurrency, payload);
        } else {
            IERC20(route.inputCurrency).forceApprove(adapter, amount);
            reported = ISwapAdapter(adapter).swap(route.inputCurrency, route.outputCurrency, amount, payload);
            IERC20(route.inputCurrency).forceApprove(adapter, 0);
        }
        uint256 afterInput = _currencyBalance(route.inputCurrency);
        _requireAdapterInputDebitAtMost(route.inputCurrency, adapter, beforeInput, afterInput, amount);
        measured.returnedInput = afterInput - (beforeInput - amount);
        output = _currencyBalance(route.outputCurrency) - beforeOutput;
        if (reported != output) revert AdapterOutputMismatch(route.outputCurrency, adapter, reported, output);
        if (output < route.minimumOutput) revert InsufficientOutput(route.minimumOutput, output);
        measured.amountOut = output;
        if (amount > measured.returnedInput) measured.consumedInput = amount - measured.returnedInput;
        else measured.inputGain = measured.returnedInput - amount;
        _retain(ex, route.inputCurrency, measured.returnedInput);
        _appendStage(ex, measured);
    }
}
