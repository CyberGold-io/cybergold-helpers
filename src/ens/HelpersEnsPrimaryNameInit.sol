// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/// @notice Minimal ENS DefaultReverseRegistrar surface used by the one-shot initializer.
interface IHelpersEnsDefaultReverseRegistrar {
    /// @notice Return the primary name recorded for an address.
    /// @param addr Address whose reverse record is queried.
    /// @return name Primary name, or an empty string when none is recorded.
    function nameForAddr(address addr) external view returns (string memory);

    /// @notice Set the caller's primary name.
    /// @param name Forward-resolving ENS name to record for the caller.
    function setName(string calldata name) external;
}

/// @notice One-shot initializer which binds the Helpers address to its fixed ENS primary name.
/// @dev Intended solely as the initializer target of an empty Helpers diamond cut. The concrete
/// deployment fixes the Mainnet registrar identity, chain id, and name; it has no configurable
/// target, name, or authority.
abstract contract HelpersEnsPrimaryNameInitBase {
    /// @notice Reverts when this initializer is not executed on the chain it was compiled for.
    /// @param actualChainId Observed chain identifier.
    error EnsPrimaryNameWrongChain(uint256 actualChainId);
    /// @notice Reverts when the configured registrar does not have its expected runtime identity.
    /// @param actualCodeHash Runtime code hash observed at the configured registrar address.
    error EnsPrimaryNameRegistrarRuntimeMismatch(bytes32 actualCodeHash);
    /// @notice Reverts when an existing primary name would be overwritten.
    /// @param actualNameHash Hash of the conflicting existing primary name.
    error EnsPrimaryNameUnexpectedCurrent(bytes32 actualNameHash);
    /// @notice Reverts when the registrar did not persist the required primary name.
    /// @param actualNameHash Hash of the primary name observed after the registrar call.
    error EnsPrimaryNamePostconditionFailed(bytes32 actualNameHash);

    /// @notice Set the fixed ENS primary name for the calling diamond address.
    /// @dev `address(this)` is the Helpers diamond under `delegatecall`; consequently, the
    /// registrar records Helpers rather than this disposable initializer deployment.
    function init() external {
        if (block.chainid != _expectedChainId()) revert EnsPrimaryNameWrongChain(block.chainid);

        IHelpersEnsDefaultReverseRegistrar registrar = _registrar();
        if (address(registrar).codehash != _expectedRegistrarCodeHash()) {
            revert EnsPrimaryNameRegistrarRuntimeMismatch(address(registrar).codehash);
        }

        bytes32 expectedNameHash = keccak256(bytes(_primaryName()));
        string memory currentName = registrar.nameForAddr(address(this));
        bytes32 currentNameHash = keccak256(bytes(currentName));
        if (bytes(currentName).length != 0 && currentNameHash != expectedNameHash) {
            revert EnsPrimaryNameUnexpectedCurrent(currentNameHash);
        }

        registrar.setName(_primaryName());

        bytes32 resultingNameHash = keccak256(bytes(registrar.nameForAddr(address(this))));
        if (resultingNameHash != expectedNameHash) {
            revert EnsPrimaryNamePostconditionFailed(resultingNameHash);
        }
    }

    function _expectedChainId() internal view virtual returns (uint256);

    function _registrar() internal view virtual returns (IHelpersEnsDefaultReverseRegistrar);

    function _expectedRegistrarCodeHash() internal view virtual returns (bytes32);

    function _primaryName() internal view virtual returns (string memory);
}

/// @notice Mainnet-only, constructorless initializer for Helpers' `helpers.cybergold.eth` primary name.
contract HelpersEnsPrimaryNameInit is HelpersEnsPrimaryNameInitBase {
    uint256 internal constant ETHEREUM_MAINNET_CHAIN_ID = 1;
    address internal constant DEFAULT_REVERSE_REGISTRAR = 0x283F227c4Bd38ecE252C4Ae7ECE650B0e913f1f9;
    bytes32 internal constant DEFAULT_REVERSE_REGISTRAR_CODEHASH =
        0xa4a48e9075735d1fb6b129422b58ae17af671351ef382107c9386138b4dfd68c;

    function _expectedChainId() internal pure override returns (uint256) {
        return ETHEREUM_MAINNET_CHAIN_ID;
    }

    function _registrar() internal pure override returns (IHelpersEnsDefaultReverseRegistrar) {
        return IHelpersEnsDefaultReverseRegistrar(DEFAULT_REVERSE_REGISTRAR);
    }

    function _expectedRegistrarCodeHash() internal pure override returns (bytes32) {
        return DEFAULT_REVERSE_REGISTRAR_CODEHASH;
    }

    function _primaryName() internal pure override returns (string memory) {
        return "helpers.cybergold.eth";
    }
}
