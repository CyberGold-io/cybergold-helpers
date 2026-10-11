// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibRecoveryShareReceiverStorage} from "../diamond/LibRecoveryShareReceiverStorage.sol";
import {IBasketRouterTypes} from "../interfaces/IBasketRouterTypes.sol";

/// @notice Receives exactly one bound Core recovery-share mint and forwards it unchanged.
/// @dev This callback intentionally does not acquire Helpers' shared reentrancy guard: it is
///      invoked while the guarded outer recovery-redemption route is still executing.
contract RecoveryShareReceiverFacet is IBasketRouterTypes {
    /// @notice Facet version registered during Helpers initialization.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace registered during Helpers initialization.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.recovery-share-receiver");

    /// @notice Reject every single-ID ERC-1155 receipt; Core recovery shares arrive only as a bound batch.
    /// @return selector This function always reverts before returning a selector.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert RecoverySingleShareReceiptRejected();
    }

    /// @notice Accept and forward exactly one batch mint matching the armed Core recovery context.
    /// @param operator ERC-1155 operator, which must be the configured Core diamond.
    /// @param from ERC-1155 source, which must be the zero address for a Core mint.
    /// @param ids Strictly bound asset-derived recovery-share identifiers credited by Core.
    /// @param amounts Strictly bound recovery-share amounts credited by Core.
    /// @param data Callback data, which must be empty for Core recovery-share mints.
    /// @return selector ERC-1155 batch-receiver acceptance selector.
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bytes4) {
        LibRecoveryShareReceiverStorage.Layout storage receipt = LibRecoveryShareReceiverStorage.layout();
        IERC1155 shares = IERC1155(_requireAuthorizedReceipt(operator, from));
        _receiveBatch(receipt, shares, ids, amounts, data);
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function _receiveBatch(
        LibRecoveryShareReceiverStorage.Layout storage receipt,
        IERC1155 shares,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) private {
        if (receipt.state != LibRecoveryShareReceiverStorage.ReceiptState.Armed) {
            revert RecoveryShareReceiptStateInvalid(
                uint8(LibRecoveryShareReceiverStorage.ReceiptState.Armed), uint8(receipt.state)
            );
        }
        bytes32 expectedBatchHash = receipt.expectedBatchHash;
        if (data.length != 0) {
            revert RecoveryShareBatchMismatch(expectedBatchHash, keccak256(abi.encode(ids, amounts, data)));
        }
        uint256[] memory helperBaselines = _deriveHelperBaselines(shares, ids, amounts, expectedBatchHash);
        bytes32 actualBatchHash = keccak256(abi.encode(ids, amounts, helperBaselines));
        if (actualBatchHash != expectedBatchHash) {
            revert RecoveryShareBatchMismatch(expectedBatchHash, actualBatchHash);
        }

        address recipient = receipt.recipient;
        bool verifyRecipientCredit = recipient.code.length == 0;
        uint256[] memory recipientBaselines = _recipientBaselines(shares, recipient, ids, verifyRecipientCredit);

        // Effects precede the recipient callback. A contract recipient may legitimately transfer
        // the credited shares during its own callback, so its post-callback balance is not pinned.
        receipt.state = LibRecoveryShareReceiverStorage.ReceiptState.Consumed;
        shares.safeBatchTransferFrom(address(this), recipient, ids, amounts, "");

        _validateForwarding(shares, recipient, ids, amounts, helperBaselines, recipientBaselines);
    }

    function _requireAuthorizedReceipt(address operator, address from) private view returns (address configuredCore) {
        configuredCore = LibAppStorage.routerStorage().coreDiamond;
        if (msg.sender != configuredCore || operator != configuredCore || from != address(0)) {
            revert RecoveryShareReceiptUnauthorized(msg.sender, operator, from);
        }
    }

    function _deriveHelperBaselines(
        IERC1155 shares,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes32 expectedBatchHash
    ) private view returns (uint256[] memory baselines) {
        uint256 count = ids.length;
        baselines = new uint256[](count);
        if (amounts.length != count) {
            revert RecoveryShareBatchMismatch(expectedBatchHash, keccak256(abi.encode(ids, amounts, baselines)));
        }
        for (uint256 i; i < count; ++i) {
            uint256 postMintBalance = shares.balanceOf(address(this), ids[i]);
            if (postMintBalance < amounts[i]) {
                revert RecoveryShareBatchMismatch(expectedBatchHash, keccak256(abi.encode(ids, amounts, baselines)));
            }
            baselines[i] = postMintBalance - amounts[i];
        }
    }

    function _recipientBaselines(IERC1155 shares, address recipient, uint256[] calldata ids, bool required)
        private
        view
        returns (uint256[] memory baselines)
    {
        if (!required) return baselines;
        baselines = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            baselines[i] = shares.balanceOf(recipient, ids[i]);
        }
    }

    function _validateForwarding(
        IERC1155 shares,
        address recipient,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        uint256[] memory helperBaselines,
        uint256[] memory recipientBaselines
    ) private view {
        uint256 count = ids.length;
        for (uint256 i; i < count; ++i) {
            uint256 id = ids[i];
            uint256 helperAfterForward = shares.balanceOf(address(this), id);
            if (helperAfterForward != helperBaselines[i]) {
                revert RecoveryShareDebitMismatch(id, helperBaselines[i], helperAfterForward);
            }
            if (recipientBaselines.length != 0) {
                uint256 actual = shares.balanceOf(recipient, id);
                uint256 expected = recipientBaselines[i] + amounts[i];
                if (actual != expected) revert RecoveryShareRecipientCreditMismatch(id, recipient, expected, actual);
            }
        }
    }
}
