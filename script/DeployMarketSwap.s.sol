// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";
import {MarketSwapDeployment} from "src/deploy/MarketSwapDeployment.sol";
import {MarketSwapFacet} from "src/facets/MarketSwapFacet.sol";
import {UniswapMultiProtocolAdapter} from "src/adapters/UniswapMultiProtocolAdapter.sol";
import {RouterAdminFacet} from "src/facets/RouterAdminFacet.sol";

/// @notice Local simulation utility; prints simulated addresses and cut/approval calldata.
contract DeployMarketSwap is Script {
    /// @notice Simulate scoped implementation creation using explicit reviewed release bindings.
    function run() external {
        address helpers = vm.envAddress("HELPERS_DIAMOND_ADDRESS");
        address router = vm.envAddress("MARKET_UNISWAP_ROUTER");
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        (MarketSwapFacet facet, UniswapMultiProtocolAdapter adapter) =
            MarketSwapDeployment.deploy(helpers, router, permit2);
        console2.log("Local simulation only; these addresses and calldata are not live deployment carriers.");
        console2.log("MarketSwapFacet", address(facet));
        console2.log("UniswapMultiProtocolAdapter", address(adapter));
        console2.log("Helpers target", helpers);
        console2.log("Universal Router target", router);
        console2.log("Permit2 target", permit2);
        console2.log("Local simulation diamondCut calldata:");
        console2.logBytes(
            abi.encodeCall(
                IDiamondCut.diamondCut, (MarketSwapDeployment.facetCut(address(facet)), address(0), bytes(""))
            )
        );
        console2.log("Local simulation adapter approval calldata:");
        console2.logBytes(abi.encodeCall(RouterAdminFacet.setAdapterApproval, (address(adapter), false, true)));
    }
}
