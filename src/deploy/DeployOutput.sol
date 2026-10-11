// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Vm} from "forge-std/Vm.sol";

/// @notice Deploy output helpers for the helpers diamond.
library DeployOutput {
    string internal constant MISSING_STRING = "__missing__";

    /// @dev Return out path.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param filename Deployment artifact filename being read or written.
    /// @return String value selected, loaded, or rendered by the helper.
    function outPath(Vm vm_, string memory filename) internal view returns (string memory) {
        string memory explicitPath = _explicitOutPath(vm_, filename);
        if (bytes(explicitPath).length != 0) {
            return explicitPath;
        }
        return string.concat(vm_.envOr("DEPLOY_OUTPUT_DIR", string.concat(vm_.projectRoot(), "/out")), "/", filename);
    }

    /// @dev Return explicit out path.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param filename Deployment artifact filename being read or written.
    /// @return String value selected, loaded, or rendered by the helper.
    function _explicitOutPath(Vm vm_, string memory filename) private view returns (string memory) {
        if (_eq(filename, "deploy-helpers.json")) {
            return _envPath(vm_, "DEPLOY_HELPERS_PATH");
        }
        if (_eq(filename, "deploy-helpers-shell.json")) {
            return _envPath(vm_, "DEPLOY_HELPERS_SHELL_PATH");
        }
        if (_eq(filename, "verify-helpers.json")) {
            return _envPath(vm_, "VERIFY_HELPERS_PATH");
        }
        return "";
    }

    /// @dev Return env path.
    /// @param vm_ Forge VM cheatcode interface used for env and filesystem access.
    /// @param key JSON key or environment key being rendered.
    /// @return String value selected, loaded, or rendered by the helper.
    function _envPath(Vm vm_, string memory key) private view returns (string memory) {
        string memory value = vm_.envOr(key, MISSING_STRING);
        return _eq(value, MISSING_STRING) ? "" : value;
    }

    /// @dev Return eq.
    /// @param a First array or string segment being combined.
    /// @param b Second array or string segment being combined.
    /// @return Whether the queried condition holds.
    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
