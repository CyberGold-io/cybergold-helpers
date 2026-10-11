// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Wrapped-native token operations used by the Helpers router.
interface IWETH is IERC20 {
    /// @notice Wrap `msg.value` native currency and mint the same amount of wrapped tokens to the caller.
    function deposit() external payable;
    /// @notice Burn wrapped tokens held by the caller and return the same amount of native currency.
    /// @param amount Amount of wrapped-native tokens to unwrap, in the token's smallest unit.
    function withdraw(uint256 amount) external;
}
