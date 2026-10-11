// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {RouterBase} from "./RouterBase.sol";

/// @notice Generic payout, balance snapshot, and surplus settlement mechanics.
abstract contract RouterSettlementBase is RouterBase {
    using SafeERC20 for IERC20;

    constructor(address permit2_) RouterBase(permit2_) {}

    /// @dev Load basket assets.
    /// @return assets Ordered basket asset addresses.
    function _loadBasketAssets() internal view returns (address[] memory assets) {
        assets = ICyberGoldCore(_routerStorage().coreDiamond).basketAssets();
        if (assets.length == 0) revert CoreAssetsEmpty();
    }

    /// @dev Require a caller or tentative ordered basket list to equal Core's authoritative preview list.
    function _validateOrderedBasketAssets(address[] memory provided, address[] memory actual) internal pure {
        uint256 assetCount = actual.length;
        if (provided.length != assetCount) {
            revert ExpectedOrderedCoreAssetsLengthMismatch(provided.length, assetCount);
        }
        for (uint256 i; i < assetCount;) {
            if (provided[i] != actual[i]) revert CoreAssetMismatch(i, provided[i], actual[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Require Core's authoritative ordered list and positional amount vector to be nonempty and aligned.
    function _validateCoreBasketAmounts(address[] memory orderedBasketAssets, uint256[] memory amounts) internal pure {
        uint256 assetCount = orderedBasketAssets.length;
        if (assetCount == 0) revert CoreAssetsEmpty();
        if (amounts.length != assetCount) revert CoreAssetAmountsLengthMismatch(assetCount, amounts.length);
    }

    /// @dev Pay out native currency after unwrapping the exact wrapped-native amount.
    /// @param to Recipient address for a transfer, mint, or swap output.
    /// @param wrappedNative Wrapped-native token address used for the native payout.
    /// @param amount Token, asset, share, or native amount moved by the operation.
    function _payoutNative(address to, address wrappedNative, uint256 amount) internal {
        if (amount == 0) return;
        IWETH(wrappedNative).withdraw(amount);
        (bool success,) = to.call{value: amount}("");
        if (!success) revert EthRefundFailed();
    }

    /// @dev Pay an output while rejecting transfer-taxed and rebasing ERC20 semantics.
    /// Native ETH is delivered by value and does not have ERC20 balance-delta semantics.
    function _payoutTokenExact(address to, address tokenNormalized, bool isNative, uint256 amount) internal {
        if (amount == 0) return;
        if (isNative) {
            _payoutNative(to, tokenNormalized, amount);
            return;
        }

        IERC20 token = IERC20(tokenNormalized);
        uint256 routerBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 routerAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(to);

        uint256 debited = routerAfter <= routerBefore ? routerBefore - routerAfter : 0;
        if (debited != amount) revert RouterTokenDebitMismatch(tokenNormalized, amount, debited);

        uint256 delivered = recipientAfter >= recipientBefore ? recipientAfter - recipientBefore : 0;
        if (delivered != amount) revert RecipientAmountOutMismatch(tokenNormalized, to, delivered, amount);
    }

    /// @dev Refund one token surplus measured against a pre-operation balance.
    function _settleTokenSurplus(address payer, IERC20 token, address eventToken, bool isNative, uint256 balanceBefore)
        internal
        returns (uint256 amount)
    {
        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter <= balanceBefore) return 0;
        amount = balanceAfter - balanceBefore;
        _payoutTokenExact(payer, address(token), isNative, amount);
        emit DustRefunded(payer, eventToken, amount);
    }
}
