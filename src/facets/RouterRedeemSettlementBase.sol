// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RouterSettlementBase} from "./RouterSettlementBase.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

/// @notice Settlement helpers shared by the generic mixed-output redemption route.
abstract contract RouterRedeemSettlementBase is RouterSettlementBase {
    constructor(address permit2_) RouterSettlementBase(permit2_) {}

    /// @dev Return every operation-local ERC-20 remainder to the payer.
    /// The selected aggregate output is excluded because it is settled as one exact payout.
    function _refundRedeemDust(
        address payer,
        address outputToken,
        ICoreRedemption.TokenAmount[] memory coreOutputs,
        uint256[] memory balancesBefore
    ) internal {
        uint256 outputCount = coreOutputs.length;
        for (uint256 i; i < outputCount;) {
            ICoreRedemption.TokenAmount memory output = coreOutputs[i];
            if (output.kind == ICoreRedemption.TokenKind.ERC20 && output.amount != 0 && output.token != outputToken) {
                _settleTokenSurplus(payer, IERC20(output.token), output.token, false, balancesBefore[i]);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Emit the sole Helpers redemption outcome from the measured aggregate payout and
    /// the positive-only recovery-share vector that was forwarded to the same recipient.
    function _emitRedeemed(
        address payer,
        address recipient,
        address outputToken,
        uint256 grossCygldIn,
        uint256 amountOut,
        ICoreRedemption.TokenAmount[] memory recoveryShareOutputs,
        uint256 protocolFeeCygld,
        uint256 helperFeeCygld
    ) internal {
        uint256 recoveryCount = recoveryShareOutputs.length;
        address[] memory recoveryAssets = new address[](recoveryCount);
        uint256[] memory recoveryShareAmounts = new uint256[](recoveryCount);
        for (uint256 i; i < recoveryCount;) {
            ICoreRedemption.TokenAmount memory output = recoveryShareOutputs[i];
            recoveryAssets[i] = address(uint160(output.id));
            recoveryShareAmounts[i] = output.amount;
            unchecked {
                ++i;
            }
        }
        emit Redeemed(
            payer,
            recipient,
            outputToken,
            grossCygldIn,
            amountOut,
            recoveryAssets,
            recoveryShareAmounts,
            protocolFeeCygld,
            helperFeeCygld
        );
    }
}
