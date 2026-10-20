// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICyberGoldCore} from "cybergold-core/interfaces/ICyberGoldCore.sol";
import {IBasketRouterTypes} from "../interfaces/IBasketRouterTypes.sol";

/// @notice One measured Core issuance, shared by exact-input and retained exact-output settlement.
library CoreIssueExecution {
    using SafeERC20 for IERC20;

    /// @notice Execute the caller-bound Core target and prove its input debits/output credit.
    /// @param core Core Diamond and CYGLD token.
    /// @param assets Canonical ordered input assets.
    /// @param maxima Caller-owned bounded Core lots.
    /// @param target CYGLD amount to mint before the Helpers fee.
    /// @return protocolFee Core-reported CYGLD protocol fee.
    /// @return actual Measured and Core-reported per-asset consumption.
    function settle(address core, address[] memory assets, uint256[] memory maxima, uint256 target)
        public
        returns (uint256 protocolFee, uint256[] memory actual)
    {
        return settleInline(core, assets, maxima, target);
    }

    /// @dev The same settlement compiled inline for retained exact-output facets.
    /// Their existing deployment artifacts remain free of new library bindings.
    function settleInline(address core, address[] memory assets, uint256[] memory maxima, uint256 target)
        internal
        returns (uint256 protocolFee, uint256[] memory actual)
    {
        uint256 count = assets.length;
        if (maxima.length != count) revert IBasketRouterTypes.CoreAssetAmountsLengthMismatch(count, maxima.length);
        uint256[] memory beforeBalances = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            if (maxima[i] == 0) continue;
            beforeBalances[i] = IERC20(assets[i]).balanceOf(address(this));
            IERC20(assets[i]).forceApprove(core, maxima[i]);
        }
        uint256 cygldBefore = IERC20(core).balanceOf(address(this));
        (protocolFee, actual) = ICyberGoldCore(core).safeIssue(target, assets, maxima);
        requireBoundedDebits(assets, maxima, actual, beforeBalances);
        for (uint256 i; i < count; ++i) {
            if (maxima[i] != 0) IERC20(assets[i]).forceApprove(core, 0);
        }
        uint256 cygldAfter = IERC20(core).balanceOf(address(this));
        uint256 credit = cygldAfter >= cygldBefore ? cygldAfter - cygldBefore : 0;
        if (credit != target) revert IBasketRouterTypes.RouterTokenCreditMismatch(core, target, credit);
    }

    /// @dev Require complete bounded inputs and observed debits for a Core issuance.
    function requireBoundedDebits(
        address[] memory assets,
        uint256[] memory maxima,
        uint256[] memory actual,
        uint256[] memory beforeBalances
    ) internal view {
        uint256 count = assets.length;
        if (maxima.length != count) revert IBasketRouterTypes.CoreAssetAmountsLengthMismatch(count, maxima.length);
        if (actual.length != count) revert IBasketRouterTypes.CoreAssetAmountsLengthMismatch(count, actual.length);
        if (beforeBalances.length != count) {
            revert IBasketRouterTypes.CoreAssetAmountsLengthMismatch(count, beforeBalances.length);
        }
        for (uint256 i; i < count; ++i) {
            if (actual[i] > maxima[i]) {
                revert IBasketRouterTypes.CoreInputAboveMaximum(assets[i], actual[i], maxima[i]);
            }
            if (maxima[i] == 0) continue;
            uint256 afterBalance = IERC20(assets[i]).balanceOf(address(this));
            uint256 debit = beforeBalances[i] >= afterBalance ? beforeBalances[i] - afterBalance : 0;
            if (debit != actual[i]) revert IBasketRouterTypes.RouterTokenDebitMismatch(assets[i], actual[i], debit);
        }
    }
}
