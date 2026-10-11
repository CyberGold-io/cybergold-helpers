// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {OneInchAdapter} from "../adapters/OneInchAdapter.sol";
import {UniswapUniversalAdapter} from "../adapters/UniswapUniversalAdapter.sol";
import {DeployParams} from "./DeployParams.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice Adapter deployer helpers for the helpers diamond.
library AdapterDeployer {
    /// @notice Addresses of the venue adapters deployed for the Phase 1 Helpers release.
    struct AdapterDeployment {
        address oneInchAdapter;
        address uniswapAdapter;
    }

    /// @dev Deploy operation state.
    /// @param params Deployment parameters for helper adapters and router wiring.
    /// @param helpersDiamond Existing Helpers shell bound as each adapter's immutable recovery authority.
    /// @return deployed Deployed adapter addresses.
    function deploy(DeployParams.Params memory params, address helpersDiamond)
        internal
        returns (AdapterDeployment memory deployed)
    {
        require(helpersDiamond != address(0), "AdapterDeployer: Helpers diamond missing");
        deployed.oneInchAdapter = address(new OneInchAdapter(helpersDiamond, params.oneInchRouter));
        deployed.uniswapAdapter =
            address(new UniswapUniversalAdapter(helpersDiamond, params.uniswapRouter, params.permit2));
    }

    /// @dev Return apply to config.
    /// @param cfg Initializer or deployment config consumed by this function.
    /// @param adapters Adapter deployment addresses used to build helper config.
    /// @return Deployment configuration assembled by the helper.
    function applyToConfig(DeploymentTypes.DeployConfig memory cfg, AdapterDeployment memory adapters)
        internal
        pure
        returns (DeploymentTypes.DeployConfig memory)
    {
        cfg.approvedAdapters = new address[](2);
        cfg.approvedAdapters[0] = adapters.oneInchAdapter;
        cfg.approvedAdapters[1] = adapters.uniswapAdapter;
        return cfg;
    }
}
