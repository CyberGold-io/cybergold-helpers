// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Owner-mediated recovery surface shared by venue adapters.
interface IRecoverableSwapAdapter {
    /// @notice Return the Helpers diamond authorized to mediate recovery.
    /// @return authority Immutable Helpers diamond authority.
    function helpersDiamond() external view returns (address);
    /// @notice Recover all of one stranded asset to the current Helpers owner.
    /// @param token Token to recover, or zero for native currency.
    function recover(address token) external;
}
