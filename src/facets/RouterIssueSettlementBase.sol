// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {RouterSettlementBase} from "./RouterSettlementBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";

/// @notice Issue-only settlement, operation-local refund, and outcome rendering.
abstract contract RouterIssueSettlementBase is RouterSettlementBase {
    using SafeERC20 for IERC20;

    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) RouterSettlementBase(permit2_) {}

    /// @notice Snapshotted exact-output route state carried from Core preview to settlement.
    struct IssueContext {
        address payer;
        address recipient;
        IERC20 inputToken;
        address inputTokenForEvent;
        bool inputIsNative;
        uint256 inputBalanceBefore;
        address[] coreAssets;
        uint256[] assetBalancesBefore;
        uint256[] maximumCoreInputs;
        uint256 maximumInputAmount;
        uint256 coreNetCygldOut;
        uint256 helperFeeCygld;
    }

    /// @notice Checked values returned by one Core `safeIssue` settlement.
    struct IssueSettlementResult {
        uint256 protocolFeeCygld;
        uint256 netCygldOut;
        uint256[] actualAmountsIn;
    }

    /// @dev Preview Core exact-output issuance once and return one aligned, nonempty ordered input lot.
    function _previewCoreIssueExactOut(LibAppStorage.RouterStorage storage rs, uint256 coreNetCygldOut)
        internal
        view
        returns (uint256 protocolFeeCygld, uint256[] memory amountsInExact, address[] memory orderedCoreAssets)
    {
        (protocolFeeCygld, amountsInExact, orderedCoreAssets) =
            ICyberGoldCore(rs.coreDiamond).previewIssueFromBasketExactOut(coreNetCygldOut);
        _validateCoreBasketAmounts(orderedCoreAssets, amountsInExact);
    }

    /// @dev Count the compact swap legs required by one snapshotted exact-output Core input vector.
    function _countExactOutIssueLegs(
        address[] memory coreAssets,
        uint256[] memory requiredAmounts,
        address normalizedInputToken
    ) internal pure returns (uint256 count) {
        uint256 assetCount = coreAssets.length;
        for (uint256 i; i < assetCount; ++i) {
            if (requiredAmounts[i] != 0 && coreAssets[i] != normalizedInputToken) ++count;
        }
    }

    /// @dev Validate one compact exact-output route without invoking an adapter or quoter.
    function _validateExactOutIssueLegs(
        LibAppStorage.RouterStorage storage rs,
        address[] memory coreAssets,
        uint256[] memory requiredAmounts,
        address normalizedInputToken,
        uint256 maximumInputAmount,
        IssueSwapLeg[] calldata legs
    ) internal view {
        uint256 requiredLegs = _countExactOutIssueLegs(coreAssets, requiredAmounts, normalizedInputToken);
        if (legs.length != requiredLegs) revert QuoteLengthMismatch(legs.length, requiredLegs);

        uint256 remainingInput = maximumInputAmount;
        uint256 cursor;
        uint256 assetCount = coreAssets.length;
        for (uint256 i; i < assetCount; ++i) {
            uint256 requiredAmount = requiredAmounts[i];
            if (requiredAmount == 0) continue;

            if (coreAssets[i] == normalizedInputToken) {
                if (remainingInput < requiredAmount) revert InsufficientInput();
                remainingInput -= requiredAmount;
                continue;
            }

            IssueSwapLeg calldata leg = legs[cursor++];
            _validateIssueLeg(rs, leg, remainingInput, cursor - 1);
            if (leg.minimumAmountOut < requiredAmount) {
                revert InsufficientOutputForNeed(coreAssets[i], requiredAmount, leg.minimumAmountOut);
            }
            remainingInput -= leg.amountIn;
        }
    }

    /// @dev Build the conservative Core exact-input vector represented by compact caller-supplied legs.
    function _buildExactInCoreInputs(
        LibAppStorage.RouterStorage storage rs,
        address[] memory coreAssets,
        uint256[] memory coreTargetsPpm,
        address normalizedInputToken,
        uint256 inputAmount,
        IssueSwapLeg[] calldata legs
    ) internal view returns (uint256[] memory amountsIn) {
        uint256 requiredLegs;
        uint256 directIndex = type(uint256).max;
        uint256 assetCount = coreAssets.length;
        if (coreTargetsPpm.length != assetCount) {
            revert CoreBasketTargetsLengthMismatch(assetCount, coreTargetsPpm.length);
        }
        for (uint256 i; i < assetCount; ++i) {
            if (coreTargetsPpm[i] == 0) continue;
            if (coreAssets[i] == normalizedInputToken) directIndex = i;
            else ++requiredLegs;
        }
        if (legs.length != requiredLegs) revert QuoteLengthMismatch(legs.length, requiredLegs);

        amountsIn = new uint256[](assetCount);
        uint256 remainingInput = inputAmount;
        uint256 cursor;
        for (uint256 i; i < assetCount; ++i) {
            if (coreTargetsPpm[i] == 0) continue;
            if (i == directIndex) continue;
            IssueSwapLeg calldata leg = legs[cursor++];
            _validateIssueLeg(rs, leg, remainingInput, cursor - 1);
            amountsIn[i] = leg.minimumAmountOut;
            remainingInput -= leg.amountIn;
        }
        if (directIndex != type(uint256).max) amountsIn[directIndex] = remainingInput;
    }

    /// @dev Validate one active compact issuance leg.
    function _validateIssueLeg(
        LibAppStorage.RouterStorage storage rs,
        IssueSwapLeg calldata leg,
        uint256 remainingInput,
        uint256 index
    ) internal view {
        if (!_isAdapterApproved(rs, leg.adapter)) revert AdapterNotApproved(leg.adapter);
        if (leg.amountIn == 0 || leg.amountIn > remainingInput) {
            revert InvalidQuoteAmount(leg.amountIn, remainingInput);
        }
        if (leg.minimumAmountOut == 0) revert ZeroLegMinimum(index);
    }

    /// @dev Approve Core for the snapshotted maxima. Core may consume less when live requirements decrease.
    function _approveCoreInputs(
        LibAppStorage.RouterStorage storage rs,
        address[] memory assets,
        uint256[] memory maximumAmounts
    ) internal {
        uint256 assetCount = assets.length;
        for (uint256 i; i < assetCount;) {
            if (maximumAmounts[i] != 0) {
                IERC20(assets[i]).forceApprove(address(rs.coreDiamond), maximumAmounts[i]);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Snapshot only positive Core lots; zero-required canonical members are identity-only slots.
    function _snapshotRequiredCoreBalances(address[] memory assets, uint256[] memory requiredAmounts)
        internal
        view
        returns (uint256[] memory balances)
    {
        uint256 assetCount = assets.length;
        balances = new uint256[](assetCount);
        for (uint256 i; i < assetCount; ++i) {
            if (requiredAmounts[i] != 0) balances[i] = IERC20(assets[i]).balanceOf(address(this));
        }
    }

    /// @dev Settle one caller-bound Core issuance without re-previewing after any adapter call.
    function _issueToRecipient(LibAppStorage.RouterStorage storage rs, IssueContext memory ctx)
        internal
        returns (IssueSettlementResult memory settlement)
    {
        return _settleCoreIssue(
            rs, ctx.recipient, ctx.coreAssets, ctx.maximumCoreInputs, ctx.coreNetCygldOut, ctx.helperFeeCygld
        );
    }

    /// @dev Settle one direct or routed issuance against a complete caller-bound Core input vector.
    function _settleCoreIssue(
        LibAppStorage.RouterStorage storage rs,
        address recipient,
        address[] memory coreAssets,
        uint256[] memory maximumCoreInputs,
        uint256 coreNetCygldOut,
        uint256 helperFeeCygld
    ) internal returns (IssueSettlementResult memory settlement) {
        uint256[] memory balancesBefore = _snapshotRequiredCoreBalances(coreAssets, maximumCoreInputs);
        IERC20 cygldToken = IERC20(address(rs.coreDiamond));
        uint256 cygldBalanceBefore = cygldToken.balanceOf(address(this));

        (settlement.protocolFeeCygld, settlement.actualAmountsIn) =
            ICyberGoldCore(rs.coreDiamond).safeIssue(coreNetCygldOut, coreAssets, maximumCoreInputs);

        _requireBoundedCoreInputDebits(coreAssets, maximumCoreInputs, settlement.actualAmountsIn, balancesBefore);
        _requireExactTokenCredit(
            address(cygldToken), cygldBalanceBefore, cygldToken.balanceOf(address(this)), coreNetCygldOut
        );
        _clearCoreAllowances(rs, coreAssets, maximumCoreInputs);

        settlement.netCygldOut = coreNetCygldOut - helperFeeCygld;
        if (settlement.netCygldOut != 0) {
            _payoutTokenExact(recipient, address(cygldToken), false, settlement.netCygldOut);
        }
        if (helperFeeCygld != 0) {
            _payoutTokenExact(_feeRecipient(), address(cygldToken), false, helperFeeCygld);
        }
    }

    /// @dev Require Core's actual inputs to remain within the snapshotted maxima and match observed debits.
    function _requireBoundedCoreInputDebits(
        address[] memory coreAssets,
        uint256[] memory maximumAmountsIn,
        uint256[] memory actualAmountsIn,
        uint256[] memory balancesBefore
    ) internal view {
        uint256 assetCount = coreAssets.length;
        if (maximumAmountsIn.length != assetCount) {
            revert CoreAssetAmountsLengthMismatch(assetCount, maximumAmountsIn.length);
        }
        if (actualAmountsIn.length != assetCount) {
            revert CoreAssetAmountsLengthMismatch(assetCount, actualAmountsIn.length);
        }
        if (balancesBefore.length != assetCount) {
            revert CoreAssetAmountsLengthMismatch(assetCount, balancesBefore.length);
        }

        for (uint256 i; i < assetCount; ++i) {
            address asset = coreAssets[i];
            uint256 actualAmount = actualAmountsIn[i];
            uint256 maximumAmount = maximumAmountsIn[i];
            if (actualAmount > maximumAmount) {
                revert CoreInputAboveMaximum(asset, actualAmount, maximumAmount);
            }
            if (maximumAmount == 0) continue;
            _requireExactRouterDebit(asset, balancesBefore[i], IERC20(asset).balanceOf(address(this)), actualAmount);
        }
    }

    /// @dev Clear each allowance established for a positive Core lot after successful settlement.
    function _clearCoreAllowances(
        LibAppStorage.RouterStorage storage rs,
        address[] memory coreAssets,
        uint256[] memory maximumAmounts
    ) internal {
        uint256 assetCount = coreAssets.length;
        for (uint256 i; i < assetCount;) {
            if (maximumAmounts[i] != 0) IERC20(coreAssets[i]).forceApprove(address(rs.coreDiamond), 0);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Refund every positive operation-local input and Core-asset surplus to the payer.
    function _refundIssueDust(IssueContext memory ctx) internal returns (uint256 inputDustAmount) {
        inputDustAmount = _settleTokenSurplus(
            ctx.payer, ctx.inputToken, ctx.inputTokenForEvent, ctx.inputIsNative, ctx.inputBalanceBefore
        );
        _settleRemainingRequiredCoreAssets(
            ctx.payer, ctx.coreAssets, ctx.maximumCoreInputs, ctx.assetBalancesBefore, address(ctx.inputToken)
        );
    }

    /// @dev Refund operation-local surplus only for positive Core lots touched by this issuance.
    function _settleRemainingRequiredCoreAssets(
        address payer,
        address[] memory assets,
        uint256[] memory requiredAmounts,
        uint256[] memory balancesBefore,
        address excludedToken
    ) internal {
        uint256 assetCount = assets.length;
        for (uint256 i; i < assetCount; ++i) {
            if (requiredAmounts[i] == 0 || assets[i] == excludedToken) continue;
            _settleTokenSurplus(payer, IERC20(assets[i]), assets[i], false, balancesBefore[i]);
        }
    }

    /// @dev Refund route surplus and emit the sole issuance outcome event.
    function _finalizeIssue(IssueContext memory ctx, IssueSettlementResult memory settlement) internal {
        uint256 inputDustAmount = _refundIssueDust(ctx);
        uint256 inputUsed = ctx.maximumInputAmount - inputDustAmount;
        emit Issued(
            ctx.payer,
            ctx.recipient,
            ctx.inputTokenForEvent,
            inputUsed,
            settlement.netCygldOut,
            settlement.protocolFeeCygld,
            ctx.helperFeeCygld
        );
    }
}
