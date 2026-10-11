// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @dev ERC-20 Permit token that charges a 10% burn only when a configured account sends.
contract ConditionalSenderSurchargeToken is ERC20Permit {
    address public surchargedSender;

    constructor() ERC20("Conditional Surcharge", "CSUR") ERC20Permit("Conditional Surcharge") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setSurchargedSender(address sender) external {
        surchargedSender = sender;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && from == surchargedSender) {
            super._update(from, address(0), value / 10);
        }
        super._update(from, to, value);
    }
}
