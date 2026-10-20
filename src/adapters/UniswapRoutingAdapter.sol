// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAllowanceTransfer} from "permit2/interfaces/IAllowanceTransfer.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {INativeSwapAdapter} from "../interfaces/INativeSwapAdapter.sol";
import {IUniswapRoutingTypes} from "../interfaces/IUniswapRoutingTypes.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IUniversalRouter} from "./UniswapUniversalAdapter.sol";
import {AdapterAccounting} from "./AdapterAccounting.sol";
import {UniswapRoutingEncoding} from "./UniswapRoutingEncoding.sol";

/// @notice Caller-funded, fee-neutral no-hook routing with native V4 currency and measured custody.
contract UniswapRoutingAdapter is
    ISwapAdapter,
    INativeSwapAdapter,
    IUniswapRoutingTypes,
    ReentrancyGuard,
    AdapterAccounting
{
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Release-pinned Universal Router target.
    address public immutable UNIVERSAL_ROUTER;
    /// @notice Release-pinned Permit2 payment identity.
    address public immutable PERMIT2;
    /// @notice Wrapped-native identity used by explicit conversions.
    address public immutable WETH;

    /// @notice The ERC20 funding entrypoint was given a native input endpoint.
    error InvalidAddress();
    /// @notice The configured Universal Router is zero.
    error InvalidRouter();
    /// @notice The configured Permit2 identity is zero.
    error InvalidPermit2();
    /// @notice The configured wrapped-native identity is zero.
    error InvalidWrappedNative();
    /// @notice An empty input lot cannot fund a swap.
    error InvalidAmount();
    /// @notice Final measured output does not satisfy the aggregate floor or target.
    /// @param required Requested floor or exact-output target.
    /// @param received Measured current-operation output.
    error InsufficientOutput(uint256 required, uint256 received);
    /// @notice The accepted whole-conversion intermediate settlement boundary failed.
    /// @param token Unsettled currency, or zero for native ETH.
    /// @param amount Current-operation remainder excluding historical balances.
    error UnsettledIntermediateCurrency(address token, uint256 amount);
    /// @notice Universal Router rejected the encoded operation.
    /// @param revertData Original upstream failure payload.
    error UniversalRouterSwapFailed(bytes revertData);
    /// @notice A native conversion names a currency it cannot consume or produce.
    /// @param kind Selected native conversion.
    /// @param currency Incompatible input currency.
    error InvalidConversionInput(StepKind kind, address currency);
    /// @notice A native conversion names an output other than its fixed actual currency.
    /// @param kind Selected native conversion.
    /// @param currency Incompatible output currency.
    error InvalidConversionOutput(StepKind kind, address currency);
    /// @notice Delivery of measured native output or input return failed.
    /// @param recipient Caller receiving the payout.
    /// @param amount Exact native amount being delivered.
    error NativePayoutFailed(address recipient, uint256 amount);

    /// @notice Historical custody baselines for one whole-conversion intermediate currency.
    struct Intermediate {
        address currency;
        uint256 adapterBalance;
        uint256 routerBalance;
    }

    /// @notice Current owned input and amount propagated to the next step.
    struct Lot {
        address currency;
        uint256 amount;
    }

    /// @notice Bind immutable recovery, routing, payment and native-conversion identities.
    /// @param helpersDiamond_ Helpers recovery authority.
    /// @param universalRouter_ Qualified Universal Router 2.2.0 target.
    /// @param permit2_ Existing release-wide Permit2 identity.
    /// @param wrappedNative_ Actual wrapped-native contract.
    constructor(address helpersDiamond_, address universalRouter_, address permit2_, address wrappedNative_)
        AdapterAccounting(helpersDiamond_)
    {
        if (universalRouter_ == address(0)) revert InvalidRouter();
        if (permit2_ == address(0)) revert InvalidPermit2();
        if (wrappedNative_ == address(0)) revert InvalidWrappedNative();
        UNIVERSAL_ROUTER = universalRouter_;
        PERMIT2 = permit2_;
        WETH = wrappedNative_;
    }

    /// @inheritdoc ISwapAdapter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0)) revert InvalidAddress();
        return _swap(tokenIn, tokenOut, amountIn, abi.decode(data, (SwapPlan)));
    }

    /// @inheritdoc INativeSwapAdapter
    function swapNative(address tokenOut, bytes calldata data)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        return _swap(address(0), tokenOut, msg.value, abi.decode(data, (SwapPlan)));
    }

    function _swap(address input, address output, uint256 amount, SwapPlan memory plan)
        private
        returns (uint256 amountOut)
    {
        _rejectIdenticalTokens(input, output);
        if (amount == 0) revert InvalidAmount();
        if (!plan.exactIn && (input == address(0) || output == address(0))) {
            revert UniswapRoutingEncoding.UnsupportedExactOutputRoute();
        }
        SwapBalances memory beforeBalances =
            SwapBalances(_balance(input, address(this)), _balance(output, address(this)));
        if (input == address(0)) beforeBalances.input -= msg.value;
        Intermediate[] memory snapshots = _snapshotIntermediates(input, output, plan.branches);
        if (input != address(0)) _pull(IERC20(input), amount, beforeBalances.input);
        uint256 deadline = plan.deadline == 0 ? block.timestamp : plan.deadline;
        if (plan.exactIn) {
            _exactInput(input, amount, plan.branches, deadline);
        } else {
            if (plan.branches.length != 1) revert UniswapRoutingEncoding.UnsupportedExactOutputRoute();
            (bytes1 command, bytes memory payload) =
                UniswapRoutingEncoding.exactOutput(input, amount, plan.amountLimit, plan.branches[0].steps);
            _execute(input, amount, command, payload, deadline);
        }
        _settleIntermediates(snapshots);
        uint256 inputAfter = _balance(input, address(this));
        if (inputAfter < beforeBalances.input) {
            revert PreExistingInputConsumed(input, beforeBalances.input, inputAfter);
        }
        amountOut = _balance(output, address(this)) - beforeBalances.output;
        if (amountOut < plan.amountLimit) revert InsufficientOutput(plan.amountLimit, amountOut);
        _payout(output, amountOut);
        // Return the complete input delta, including gains from a cyclic route, without a new cap.
        _payout(input, inputAfter - beforeBalances.input);
    }

    function _pull(IERC20 token, uint256 amount, uint256 beforeBalance) private {
        uint256 callerBefore = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 callerAfter = token.balanceOf(msg.sender);
        uint256 debit = callerAfter <= callerBefore ? callerBefore - callerAfter : 0;
        if (debit != amount) revert CallerTokenDebitMismatch(address(token), amount, debit);
        uint256 inputAfter = token.balanceOf(address(this));
        uint256 received = inputAfter >= beforeBalance ? inputAfter - beforeBalance : 0;
        if (received != amount) revert InputAmountMismatch(amount, received);
    }

    function _exactInput(address input, uint256 amount, Branch[] memory branches, uint256 deadline) private {
        uint256 remaining = amount;
        for (uint256 b; b < branches.length; ++b) {
            remaining -= branches[b].amountIn;
            _runBranch(input, branches[b], deadline);
        }
    }

    function _runBranch(address input, Branch memory branch, uint256 deadline) private {
        Lot memory lot = Lot(input, branch.amountIn);
        for (uint256 i; i < branch.steps.length;) {
            if (lot.amount == 0) break;
            uint256 end = branch.steps[i].kind == StepKind.V4 ? _v4End(lot.currency, branch.steps, i) : i + 1;
            address next = branch.steps[end - 1].currencyOut;
            uint256 outputBefore = _balance(next, address(this));
            _executeStep(lot, branch.steps, i, end, deadline);
            lot.amount = _balance(next, address(this)) - outputBefore;
            lot.currency = next;
            i = end;
        }
    }

    function _executeStep(Lot memory lot, Step[] memory steps, uint256 start, uint256 end, uint256 deadline) private {
        Step memory step = steps[start];
        if (step.kind == StepKind.WrapNative || step.kind == StepKind.UnwrapNative) {
            _convert(lot.currency, lot.amount, step);
        } else if (step.kind == StepKind.V4) {
            bytes memory payload = UniswapRoutingEncoding.exactInputV4(lot.currency, lot.amount, steps, start, end);
            _execute(lot.currency, lot.amount, 0x10, payload, deadline);
        } else {
            (bytes1 command, bytes memory payload) =
                UniswapRoutingEncoding.exactInputHop(lot.currency, lot.amount, step);
            _execute(lot.currency, lot.amount, command, payload, deadline);
        }
    }

    /// @dev A repetition partitions execution; it never rejects the route or merges an old residual into output.
    function _v4End(address input, Step[] memory steps, uint256 start) private pure returns (uint256 end) {
        address[] memory seen = new address[](steps.length - start + 1);
        seen[0] = input;
        uint256 used = 1;
        end = start;
        while (end < steps.length && steps[end].kind == StepKind.V4) {
            address next = steps[end].currencyOut;
            bool repeated;
            for (uint256 i; i < used; ++i) {
                if (seen[i] == next) {
                    repeated = true;
                    break;
                }
            }
            if (repeated) return end == start ? start + 1 : end;
            seen[used++] = next;
            ++end;
        }
    }

    function _convert(address input, uint256 amount, Step memory step) private {
        if (step.kind == StepKind.WrapNative) {
            if (input != address(0)) revert InvalidConversionInput(step.kind, input);
            if (step.currencyOut != WETH) revert InvalidConversionOutput(step.kind, step.currencyOut);
            IWETH(WETH).deposit{value: amount}();
        } else {
            if (input != WETH) revert InvalidConversionInput(step.kind, input);
            if (step.currencyOut != address(0)) revert InvalidConversionOutput(step.kind, step.currencyOut);
            IWETH(WETH).withdraw(amount);
        }
    }

    function _execute(address input, uint256 amount, bytes1 command, bytes memory payload, uint256 deadline) private {
        if (input != address(0)) {
            _setAllowance(IERC20(input), PERMIT2, amount);
            IAllowanceTransfer(PERMIT2).approve(input, UNIVERSAL_ROUTER, amount.toUint160(), block.timestamp.toUint48());
        }
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = payload;
        (bool ok, bytes memory reason) = UNIVERSAL_ROUTER.call{value: input == address(0) ? amount : 0}(
            abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(command), inputs, deadline))
        );
        if (!ok) revert UniversalRouterSwapFailed(reason);
        if (input != address(0)) _setAllowance(IERC20(input), PERMIT2, 0);
    }

    function _snapshotIntermediates(address input, address output, Branch[] memory branches)
        private
        view
        returns (Intermediate[] memory snapshots)
    {
        uint256 count;
        for (uint256 b; b < branches.length; ++b) {
            count += branches[b].steps.length;
        }
        snapshots = new Intermediate[](count);
        uint256 used;
        for (uint256 b; b < branches.length; ++b) {
            for (uint256 s; s < branches[b].steps.length; ++s) {
                address currency = branches[b].steps[s].currencyOut;
                if (currency == input || currency == output) continue;
                bool seen;
                for (uint256 i; i < used; ++i) {
                    if (snapshots[i].currency == currency) {
                        seen = true;
                        break;
                    }
                }
                if (seen) continue;
                snapshots[used++] =
                    Intermediate(currency, _balance(currency, address(this)), _balance(currency, UNIVERSAL_ROUTER));
            }
        }
        assembly ("memory-safe") { mstore(snapshots, used) }
    }

    function _settleIntermediates(Intermediate[] memory snapshots) private view {
        for (uint256 i; i < snapshots.length; ++i) {
            Intermediate memory s = snapshots[i];
            uint256 adapterAfter = _balance(s.currency, address(this));
            uint256 routerAfter = _balance(s.currency, UNIVERSAL_ROUTER);
            if (adapterAfter < s.adapterBalance) {
                revert PreExistingInputConsumed(s.currency, s.adapterBalance, adapterAfter);
            }
            if (routerAfter < s.routerBalance) {
                revert PreExistingInputConsumed(s.currency, s.routerBalance, routerAfter);
            }
            uint256 remainder = adapterAfter - s.adapterBalance + routerAfter - s.routerBalance;
            if (remainder != 0) revert UnsettledIntermediateCurrency(s.currency, remainder);
        }
    }

    function _balance(address currency, address account) private view returns (uint256) {
        return currency == address(0) ? account.balance : IERC20(currency).balanceOf(account);
    }

    function _payout(address currency, uint256 amount) private {
        if (amount == 0) return;
        if (currency == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            if (!ok) revert NativePayoutFailed(msg.sender, amount);
            return;
        }
        IERC20 token = IERC20(currency);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(msg.sender);
        token.safeTransfer(msg.sender, amount);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(msg.sender);
        uint256 debit = afterBalance <= beforeBalance ? beforeBalance - afterBalance : 0;
        if (debit != amount) revert AdapterTokenDebitMismatch(currency, amount, debit);
        uint256 credit = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (credit != amount) revert AdapterRecipientCreditMismatch(currency, msg.sender, amount, credit);
    }

    /// @notice Native router output, WETH withdrawals and recoverable donations share measured custody.
    receive() external payable {}
}
