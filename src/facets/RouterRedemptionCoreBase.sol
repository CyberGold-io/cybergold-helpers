// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RouterRecoveryBase} from "./RouterRecoveryBase.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Shared preview, binding, and balance checks for every generic Core redemption route.
abstract contract RouterRedemptionCoreBase is RouterRecoveryBase {
    constructor(address permit2_) RouterRecoveryBase(permit2_) {}

    /// @dev Apply the Helpers fee to an exact outer gross input and validate Core's full preview.
    function _previewCoreRedemption(address core, uint256 helperFeePpm, uint256 grossCygldIn)
        internal
        view
        returns (uint256 coreGrossCygldIn, uint256 helperFeeCygld, ICoreRedemption.RedemptionQuote memory preview)
    {
        if (grossCygldIn == 0) {
            revert ZeroInputAmount();
        }
        helperFeeCygld = Math.mulDiv(grossCygldIn, helperFeePpm, PPM_DENOMINATOR);
        coreGrossCygldIn = grossCygldIn - helperFeeCygld;
        preview = ICoreRedemption(core).previewRedeemExactIn(coreGrossCygldIn);
        _validateCoreQuote(core, coreGrossCygldIn, preview);
    }

    /// @dev Validate Core's bound settlement and prove every ERC-20 credit exactly.
    function _validateSettledRedemption(
        address core,
        uint256 coreGrossCygldIn,
        ICoreRedemption.RedemptionQuote memory projected,
        ICoreRedemption.RedemptionQuote memory settled,
        ICoreRedemption.TokenMinimum[] memory expectedOutputs,
        uint256[] memory coreOutputBalancesBefore
    ) internal view {
        _validateCoreQuote(core, coreGrossCygldIn, settled);
        uint256 outputCount = settled.outputs.length;
        if (expectedOutputs.length != outputCount) {
            revert ICoreRedemption.RedemptionOutputsLengthMismatch(expectedOutputs.length, outputCount);
        }
        if (projected.outputs.length != outputCount || coreOutputBalancesBefore.length != outputCount) {
            revert CoreRedemptionResultMismatch();
        }

        for (uint256 i; i < outputCount;) {
            ICoreRedemption.TokenAmount memory output = settled.outputs[i];
            ICoreRedemption.TokenAmount memory previewOutput = projected.outputs[i];
            ICoreRedemption.TokenMinimum memory expected = expectedOutputs[i];
            if (
                output.kind != expected.kind || output.token != expected.token || output.id != expected.id
                    || output.kind != previewOutput.kind || output.token != previewOutput.token
                    || output.id != previewOutput.id
            ) {
                revert ICoreRedemption.RedemptionOutputDescriptorMismatch(
                    i, expected.kind, expected.token, expected.id, output.kind, output.token, output.id
                );
            }
            if (output.amount < expected.minimumAmount) {
                revert ICoreRedemption.RedemptionOutputBelowMinimum(i, expected.minimumAmount, output.amount);
            }
            if (output.kind == ICoreRedemption.TokenKind.ERC20) {
                // A projected zero leg may be an unreadable or unavailable current-state asset.
                // Never probe it, and conservatively reject any zero-to-positive settlement drift
                // because no pre-settlement balance baseline exists for that token.
                if (previewOutput.amount == 0) {
                    if (output.amount != 0) revert CoreRedemptionResultMismatch();
                } else {
                    _requireExactTokenCredit(
                        output.token,
                        coreOutputBalancesBefore[i],
                        IERC20(output.token).balanceOf(address(this)),
                        output.amount
                    );
                }
            } else if (output.amount != previewOutput.amount) {
                // Exact receiver arming necessarily freezes the ERC-1155 batch amount.
                revert CoreRedemptionResultMismatch();
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Validate Core fee arithmetic and canonical ERC-20-then-ERC-1155 output structure.
    function _validateCoreQuote(
        address core,
        uint256 expectedGrossCygldIn,
        ICoreRedemption.RedemptionQuote memory quote
    ) internal pure {
        if (
            quote.grossCygldIn != expectedGrossCygldIn || quote.protocolFeeCygld > expectedGrossCygldIn
                || quote.netCygldIn != expectedGrossCygldIn - quote.protocolFeeCygld || quote.outputs.length == 0
        ) revert CoreRedemptionResultMismatch();

        bool recoveryTail;
        bool positiveOutput;
        uint256 previousRecoveryId;
        for (uint256 i; i < quote.outputs.length;) {
            ICoreRedemption.TokenAmount memory output = quote.outputs[i];
            if (output.kind == ICoreRedemption.TokenKind.ERC20) {
                if (recoveryTail || output.token == address(0) || output.id != 0) {
                    revert CoreRedemptionResultMismatch();
                }
                for (uint256 j; j < i;) {
                    if (quote.outputs[j].token == output.token) revert CoreRedemptionResultMismatch();
                    unchecked {
                        ++j;
                    }
                }
            } else {
                recoveryTail = true;
                if (
                    output.token != core || output.id == 0 || output.id > type(uint160).max
                        || output.id <= previousRecoveryId
                ) {
                    revert CoreRedemptionResultMismatch();
                }
                previousRecoveryId = output.id;
            }
            if (output.amount != 0) positiveOutput = true;
            unchecked {
                ++i;
            }
        }
        if (!positiveOutput) revert CoreRedemptionResultMismatch();
    }

    /// @dev Require one complete caller vector to match every descriptor and floor in a Core quote.
    function _validateQuoteMinimums(
        ICoreRedemption.TokenAmount[] memory outputs,
        ICoreRedemption.TokenMinimum[] memory minimumOutputs
    ) internal pure {
        uint256 outputCount = outputs.length;
        if (minimumOutputs.length != outputCount) {
            revert ICoreRedemption.RedemptionOutputsLengthMismatch(minimumOutputs.length, outputCount);
        }
        for (uint256 i; i < outputCount;) {
            ICoreRedemption.TokenAmount memory output = outputs[i];
            ICoreRedemption.TokenMinimum memory minimum = minimumOutputs[i];
            if (output.kind != minimum.kind || output.token != minimum.token || output.id != minimum.id) {
                revert ICoreRedemption.RedemptionOutputDescriptorMismatch(
                    i, minimum.kind, minimum.token, minimum.id, output.kind, output.token, output.id
                );
            }
            if (output.amount < minimum.minimumAmount) {
                revert ICoreRedemption.RedemptionOutputBelowMinimum(i, minimum.minimumAmount, output.amount);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Snapshot positive ERC-20 positions; zero ERC-20 and ERC-1155 positions retain placeholders.
    function _snapshotCoreOutputBalances(ICoreRedemption.TokenAmount[] memory outputs)
        internal
        view
        returns (uint256[] memory balances)
    {
        balances = new uint256[](outputs.length);
        for (uint256 i; i < outputs.length;) {
            if (outputs[i].kind == ICoreRedemption.TokenKind.ERC20 && outputs[i].amount != 0) {
                balances[i] = IERC20(outputs[i].token).balanceOf(address(this));
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Preserve the historical share-only zero-floor exception; positive ERC20 outputs need a floor.
    function _requireAggregateMinimum(ICoreRedemption.TokenAmount[] memory outputs, uint256 minimumAmountOut)
        internal
        pure
    {
        if (minimumAmountOut != 0) return;
        for (uint256 i; i < outputs.length;) {
            if (outputs[i].kind == ICoreRedemption.TokenKind.ERC20 && outputs[i].amount != 0) {
                revert ZeroFinalMinimum();
            }
            unchecked {
                ++i;
            }
        }
    }
}
