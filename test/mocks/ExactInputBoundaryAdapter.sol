// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapAdapter} from "../../src/interfaces/ISwapAdapter.sol";
import {INativeSwapAdapter} from "../../src/interfaces/INativeSwapAdapter.sol";
import {IUniswapRoutingTypes} from "../../src/interfaces/IUniswapRoutingTypes.sol";

/// @dev Boundary double: funding is actually pulled, current input is actually returned,
/// outputs are actually delivered, and the exact runtime adapter payload is decoded.
contract ExactInputBoundaryAdapter is ISwapAdapter, INativeSwapAdapter, IUniswapRoutingTypes {
    struct Rate {
        uint256 numerator;
        uint256 denominator;
        uint256 returned;
        uint256 extraReturn;
    }
    mapping(address => mapping(address => Rate)) private _rates;
    uint256 public calls;
    uint256 public lastAmount;
    uint256 public lastDeadline;
    uint256[] private _allocations;
    bool public fabricate;
    bool public fail;

    function setRate(address input, address output, uint256 numerator, uint256 denominator, uint256 returned) external {
        _rates[input][output] = Rate(numerator, denominator, returned, 0);
    }

    function setGain(address input, address output, uint256 gain) external {
        _rates[input][output].extraReturn = gain;
    }

    function setFault(bool fabricate_, bool fail_) external {
        fabricate = fabricate_;
        fail = fail_;
    }

    function allocations() external view returns (uint256[] memory) {
        return _allocations;
    }

    function swap(address input, address output, uint256 amount, bytes calldata data) external returns (uint256) {
        require(IERC20(input).transferFrom(msg.sender, address(this), amount), "pull");
        return _execute(input, output, amount, data);
    }

    function swapNative(address output, bytes calldata data) external payable returns (uint256) {
        return _execute(address(0), output, msg.value, data);
    }

    function _execute(address input, address output, uint256 amount, bytes calldata data)
        private
        returns (uint256 out)
    {
        require(!fail, "venue failed");
        SwapPlan memory plan = abi.decode(data, (SwapPlan));
        require(plan.exactIn, "exact input");
        ++calls;
        lastAmount = amount;
        lastDeadline = plan.deadline;
        delete _allocations;
        uint256 total;
        for (uint256 i; i < plan.branches.length; ++i) {
            total += plan.branches[i].amountIn;
            _allocations.push(plan.branches[i].amountIn);
            require(plan.branches[i].steps[plan.branches[i].steps.length - 1].currencyOut == output, "endpoint");
        }
        require(total == amount, "runtime allocation");
        Rate memory rate = _rates[input][output];
        require(rate.denominator != 0 && rate.returned <= amount, "rate");
        out = (amount - rate.returned) * rate.numerator / rate.denominator;
        _pay(input, rate.returned + rate.extraReturn);
        if (!fabricate) _pay(output, out);
    }

    function _pay(address currency, uint256 amount) private {
        if (amount == 0) return;
        if (currency == address(0)) {
            (bool sent,) = msg.sender.call{value: amount}("");
            require(sent, "native");
        } else {
            require(IERC20(currency).transfer(msg.sender, amount), "pay");
        }
    }

    receive() external payable {}
}

