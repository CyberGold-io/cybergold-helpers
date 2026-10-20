// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITradeExactInput} from "../interfaces/ITradeExactInput.sol";
import {IUniswapRoutingTypes} from "../interfaces/IUniswapRoutingTypes.sol";

/// @notice Fixed linked pure compiler keeps route encoding outside the custody facet's runtime.
library TradeRouteEncoding {
    /// @notice Allocate a runtime owned lot and encode the successor's exact-input payload.
    /// @param amount Actual branch-owned input, not a stale quote amount.
    /// @param route Typed route template with deterministic final-path remainder placement.
    /// @param deadline Parent trade deadline; zero retains current-timestamp router semantics.
    /// @return payload ABI-encoded successor SwapPlan.
    function encode(uint256 amount, ITradeExactInput.AmmTemplate memory route, uint256 deadline)
        public
        pure
        returns (bytes memory payload)
    {
        IUniswapRoutingTypes.Branch[] memory branches = new IUniswapRoutingTypes.Branch[](route.routes.length);
        uint256 remaining = amount;
        for (uint256 i; i < branches.length; ++i) {
            uint256 allocation =
                i + 1 == branches.length ? remaining : Math.mulDiv(amount, route.routes[i].sharePpm, 1_000_000);
            remaining -= allocation;
            branches[i] = IUniswapRoutingTypes.Branch(allocation, route.routes[i].steps);
        }
        return abi.encode(IUniswapRoutingTypes.SwapPlan(true, route.minimumOutput, deadline, branches));
    }
}
