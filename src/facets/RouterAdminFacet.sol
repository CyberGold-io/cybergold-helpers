// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {InitContext} from "diamond-infra/helpers/InitContext.sol";

import {RouterBase} from "./RouterBase.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {IRecoverableSwapAdapter} from "../interfaces/IRecoverableSwapAdapter.sol";

/// @notice Admin/config facet for the helpers diamond.
contract RouterAdminFacet is RouterBase, InitContext {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Facet version used by the init-version registry.
    uint64 public constant FACET_VERSION = 1;
    /// @notice Facet namespace used by the init-version registry.
    bytes32 public constant FACET_NAMESPACE = keccak256("cybergold.helpers.admin");

    /// @notice Bind this facet implementation to the release-wide immutable Permit2 identity.
    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) RouterBase(permit2_) {}

    /// @notice Initialize router.
    /// @param coreDiamond_ Core diamond controller configured for the router.
    /// @param wrappedNative_ Wrapped native token configured for router ETH routes.
    /// @param helperFeePpm_ Helper Fee Ppm used for fee accounting.
    /// @param approvedAdapters_ Initial adapter allowlist for router swaps.
    function initRouter(
        address coreDiamond_,
        address wrappedNative_,
        uint256 helperFeePpm_,
        address[] calldata approvedAdapters_
    ) external onlyInit {
        if (coreDiamond_ == address(0) || wrappedNative_ == address(0)) {
            revert InvalidRecipient();
        }
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        rs.coreDiamond = coreDiamond_;
        rs.wrappedNative = wrappedNative_;

        _setHelperFeePpm(rs, helperFeePpm_);
        uint256 len = approvedAdapters_.length;
        for (uint256 i; i < len; ++i) {
            _setAdapterApproval(rs, approvedAdapters_[i], false, true);
        }
    }

    /// @notice Return the immutable-in-practice Core diamond used for basket quotes and settlement.
    /// @return Core diamond controller used by router operations.
    function coreDiamond() external view returns (address) {
        return _routerStorage().coreDiamond;
    }

    /// @notice Return the Permit2 SignatureTransfer contract used by permit-based entrypoints.
    /// @return Permit2 signature-transfer contract configured for the router.
    function permit2() external view returns (address) {
        return address(_permit2());
    }

    /// @notice Return the wrapped-native token used to bridge native input and output routes.
    /// @return Wrapped native token address used for ETH routes.
    function wrappedNative() external view returns (address) {
        return _routerStorage().wrappedNative;
    }

    /// @notice Check whether governance currently permits an adapter in user-supplied routes.
    /// @param adapter Swap adapter address checked or configured for routed swaps.
    /// @return Whether the swap adapter is approved for routed operations.
    function isAdapterApproved(address adapter) external view returns (bool) {
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        return _isAdapterApproved(rs, adapter);
    }

    /// @notice Return the complete current adapter allowlist in enumerable-set order.
    /// @return Current swap adapter allowlist.
    function approvedAdapters() external view returns (address[] memory) {
        return _routerStorage().approvedAdapters.values();
    }

    /// @notice Return the Helpers service fee charged on routed operations.
    /// @return Current helper fee rate in parts per million.
    function helperFeePpm() external view returns (uint256) {
        return _routerStorage().helperFeePpm;
    }

    /// @notice Add or remove a swap adapter from the route allowlist.
    /// @param adapter Swap adapter address checked or configured for routed swaps.
    /// @param currentApproval Expected current approval state.
    /// @param newApproval New approval state.
    function setAdapterApproval(address adapter, bool currentApproval, bool newApproval) external onlyOwner {
        _setAdapterApproval(_routerStorage(), adapter, currentApproval, newApproval);
    }

    /// @notice Recover stranded adapter balances to the current Helpers owner.
    /// @param adapter Intended adapter identity; current allowlist membership is not required.
    /// @param token Token to recover, or zero for native currency.
    function recoverAdapter(address adapter, address token) external onlyOwner {
        IRecoverableSwapAdapter(adapter).recover(token);
    }

    /// @dev Set adapter approval.
    /// @param rs Router storage pointer containing helper config, fees, and adapter approvals.
    /// @param adapter Swap adapter address checked or configured for routed swaps.
    /// @param currentApproval Expected current approval state.
    /// @param newApproval New approval state.
    function _setAdapterApproval(
        LibAppStorage.RouterStorage storage rs,
        address adapter,
        bool currentApproval,
        bool newApproval
    ) private {
        if (currentApproval == newApproval) revert AdapterApprovalChangeNoop();
        bool actualApproval = rs.approvedAdapters.contains(adapter);
        if (actualApproval != currentApproval) {
            revert AdapterApprovalCurrentMismatch(currentApproval, actualApproval);
        }
        if (newApproval) {
            rs.approvedAdapters.add(adapter);
        } else {
            rs.approvedAdapters.remove(adapter);
        }
        emit AdapterApprovalUpdated(adapter, newApproval);
    }

    /// @notice Atomically replace the Helpers fee if storage still matches the expected current value.
    /// @param currentHelperFeePpm Caller-supplied current helper fee used as a change guard.
    /// @param newHelperFeePpm Replacement helper fee rate in parts per million.
    function setHelperFeePpm(uint256 currentHelperFeePpm, uint256 newHelperFeePpm) external onlyOwner {
        if (currentHelperFeePpm == newHelperFeePpm) revert HelperFeeChangeNoop();
        LibAppStorage.RouterStorage storage rs = _routerStorage();
        uint256 actualHelperFeePpm = rs.helperFeePpm;
        if (currentHelperFeePpm != actualHelperFeePpm) {
            revert HelperFeeCurrentMismatch(currentHelperFeePpm, actualHelperFeePpm);
        }
        _setHelperFeePpm(rs, newHelperFeePpm);
    }

    /// @dev Set helper fee.
    /// @param rs Router storage pointer containing helper config, fees, and adapter approvals.
    /// @param feePpm Fee Ppm used for fee accounting.
    function _setHelperFeePpm(LibAppStorage.RouterStorage storage rs, uint256 feePpm) private {
        if (feePpm > MAX_HELPER_FEE_PPM_VALUE) revert HelperFeeTooHigh(feePpm);
        uint256 previousFeePpm = rs.helperFeePpm;
        if (previousFeePpm == feePpm) return;
        rs.helperFeePpm = feePpm;
        emit HelperFeeUpdated(previousFeePpm, feePpm);
    }

    /// @notice Sweep.
    /// @param token ERC20 token address involved in the transfer, balance check, or recovery.
    /// @param to Recipient address for a transfer, mint, or swap output.
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        if (token == address(0)) {
            uint256 nativeBalance = address(this).balance;
            if (nativeBalance == 0) return;
            (bool nativeSent, bytes memory returnData) = to.call{value: nativeBalance}("");
            if (!nativeSent) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
            return;
        }
        IERC20(token).safeTransfer(to, IERC20(token).balanceOf(address(this)));
    }
}
