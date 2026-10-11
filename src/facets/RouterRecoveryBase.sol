// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {RouterRedeemSettlementBase} from "./RouterRedeemSettlementBase.sol";
import {LibRecoveryShareReceiverStorage} from "../diamond/LibRecoveryShareReceiverStorage.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Exact one-shot ERC-1155 receipt binding for generic Core redemptions.
abstract contract RouterRecoveryBase is RouterRedeemSettlementBase {
    constructor(address permit2_) RouterRedeemSettlementBase(permit2_) {}

    /// @dev Arm the receiver for the exact positive ERC-1155 batch projected by Core.
    function _armRecoveryReceipt(address core, address recipient, ICoreRedemption.TokenAmount[] memory projectedOutputs)
        internal
    {
        LibRecoveryShareReceiverStorage.Layout storage receipt = LibRecoveryShareReceiverStorage.layout();
        if (receipt.state != LibRecoveryShareReceiverStorage.ReceiptState.Idle) {
            revert RecoveryShareReceiptStateInvalid(
                uint8(LibRecoveryShareReceiverStorage.ReceiptState.Idle), uint8(receipt.state)
            );
        }

        uint256 positiveShareCount = _countPositiveRecoveryOutputs(projectedOutputs);
        if (positiveShareCount == 0) return;

        uint256[] memory ids = new uint256[](positiveShareCount);
        uint256[] memory amounts = new uint256[](positiveShareCount);
        uint256[] memory helperBaselines = new uint256[](positiveShareCount);
        IERC1155 shares = IERC1155(core);
        uint256 shareIndex;
        for (uint256 i; i < projectedOutputs.length;) {
            ICoreRedemption.TokenAmount memory output = projectedOutputs[i];
            if (output.kind == ICoreRedemption.TokenKind.ERC1155 && output.amount != 0) {
                ids[shareIndex] = output.id;
                amounts[shareIndex] = output.amount;
                helperBaselines[shareIndex] = shares.balanceOf(address(this), output.id);
                ++shareIndex;
            }
            unchecked {
                ++i;
            }
        }

        receipt.recipient = recipient;
        receipt.expectedBatchHash = keccak256(abi.encode(ids, amounts, helperBaselines));
        receipt.state = LibRecoveryShareReceiverStorage.ReceiptState.Armed;
    }

    /// @dev Require the callback iff Core projected at least one positive share and restore Idle.
    function _completeRecoveryReceipt(ICoreRedemption.TokenAmount[] memory projectedOutputs) internal {
        LibRecoveryShareReceiverStorage.Layout storage receipt = LibRecoveryShareReceiverStorage.layout();
        LibRecoveryShareReceiverStorage.ReceiptState expected = _countPositiveRecoveryOutputs(projectedOutputs) == 0
            ? LibRecoveryShareReceiverStorage.ReceiptState.Idle
            : LibRecoveryShareReceiverStorage.ReceiptState.Consumed;
        if (receipt.state != expected) {
            revert RecoveryShareReceiptStateInvalid(uint8(expected), uint8(receipt.state));
        }
        delete receipt.recipient;
        delete receipt.expectedBatchHash;
        receipt.state = LibRecoveryShareReceiverStorage.ReceiptState.Idle;
    }

    /// @dev Build the positive-only recovery result while preserving Core order.
    function _positiveRecoveryOutputs(ICoreRedemption.TokenAmount[] memory outputs)
        internal
        pure
        returns (ICoreRedemption.TokenAmount[] memory recoveryOutputs)
    {
        uint256 positiveShareCount = _countPositiveRecoveryOutputs(outputs);
        recoveryOutputs = new ICoreRedemption.TokenAmount[](positiveShareCount);
        uint256 shareIndex;
        for (uint256 i; i < outputs.length;) {
            ICoreRedemption.TokenAmount memory output = outputs[i];
            if (output.kind == ICoreRedemption.TokenKind.ERC1155) {
                if (output.amount != 0) {
                    recoveryOutputs[shareIndex] = output;
                    ++shareIndex;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _countPositiveRecoveryOutputs(ICoreRedemption.TokenAmount[] memory outputs)
        private
        pure
        returns (uint256 count)
    {
        for (uint256 i; i < outputs.length;) {
            if (outputs[i].kind == ICoreRedemption.TokenKind.ERC1155 && outputs[i].amount != 0) ++count;
            unchecked {
                ++i;
            }
        }
    }
}
