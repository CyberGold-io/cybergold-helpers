// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {LibAppStorage} from "../diamond/LibAppStorage.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {RouterAuthorizationBase} from "./RouterAuthorizationBase.sol";

/// @notice Common authorization and configuration boundary for Helpers router facets.
abstract contract RouterBase is PausableUpgradeable, ReentrancyGuardTransient, RouterAuthorizationBase {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 internal constant PPM_DENOMINATOR = 1_000_000;
    uint256 internal constant MAX_HELPER_FEE_PPM_VALUE = 5_000; // 0.5%
    ISignatureTransfer private immutable ROUTER_PERMIT2;

    /// @notice Bind a routed facet implementation to the release-wide Permit2 identity.
    /// @param permit2_ Nonzero Permit2 SignatureTransfer contract shared by all routed facets.
    constructor(address permit2_) {
        if (permit2_ == address(0)) revert InvalidPermit2();
        ROUTER_PERMIT2 = ISignatureTransfer(permit2_);
    }

    modifier onlyOwner() {
        LibDiamond.enforceIsContractOwner();
        _;
    }

    /// @dev Return router storage.
    function _routerStorage() internal pure override returns (LibAppStorage.RouterStorage storage rs) {
        return LibAppStorage.routerStorage();
    }

    /// @dev Return the immutable Permit2 identity shared by every product facet.
    function _permit2() internal view override returns (ISignatureTransfer) {
        return ROUTER_PERMIT2;
    }

    /// @dev Return whether an adapter belongs to the canonical allowlist set.
    function _isAdapterApproved(LibAppStorage.RouterStorage storage rs, address adapter) internal view returns (bool) {
        return rs.approvedAdapters.contains(adapter);
    }

    /// @dev Return the current Helpers fee recipient.
    function _feeRecipient() internal view returns (address) {
        return LibDiamond.contractOwner();
    }

    /// @dev Convert an exact net amount into the minimum gross amount preserving floor-rounded fee economics.
    function _grossForNet(uint256 netCygldOut, uint256 feePpm)
        internal
        pure
        returns (uint256 grossCygldOut, uint256 helperFeeCygld)
    {
        if (netCygldOut == 0) revert ZeroInputAmount();
        if (feePpm > MAX_HELPER_FEE_PPM_VALUE) revert HelperFeeTooHigh(feePpm);

        uint256 maxNetCygldOut = type(uint256).max - Math.mulDiv(type(uint256).max, feePpm, PPM_DENOMINATOR);
        if (netCygldOut > maxNetCygldOut) revert GrossForNetOverflow(netCygldOut, feePpm);

        uint256 grossMinusOne = Math.mulDiv(netCygldOut - 1, PPM_DENOMINATOR, PPM_DENOMINATOR - feePpm);
        grossCygldOut = grossMinusOne + 1;
        helperFeeCygld = grossCygldOut - netCygldOut;
    }
}
