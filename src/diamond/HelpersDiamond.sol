// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

/*
   _____      _                _____       _     _
  / ____|    | |              / ____|     | |   | |
 | |    _   _| |__   ___ _ __| |  __  ___ | | __| |
 | |   | | | | '_ \ / _ \ '__| | |_ |/ _ \| |/ _` |
 | |___| |_| | |_) |  __/ |  | |__| | (_) | | (_| |
  \_____\__, |_.__/ \___|_|   \_____|\___/|_|\__,_|
         __/ |
        |___/

  Helpers Diamond


  בְּחָנַנִי כַּזָּהָב אֵצֵא
    -- Job 23:10

*/

import {Diamond as MudgenDiamond, DiamondArgs} from "diamond-1/Diamond.sol";
import {IDiamondCut} from "diamond-1/interfaces/IDiamondCut.sol";

/// @custom:security-contact security@cybergold.io
/// @notice Thin wrapper around mudgen's diamond-1 implementation for helpers.
contract HelpersDiamond is MudgenDiamond {
    /// @notice Deploy the HelpersDiamond contract.
    /// @param _diamondCut Diamond facet cuts or diamond cut facet address supplied during initialization.
    /// @param _args ABI-encoded initializer arguments supplied to the diamond constructor.
    constructor(IDiamondCut.FacetCut[] memory _diamondCut, DiamondArgs memory _args)
        MudgenDiamond(_diamondCut, _args)
    {}
}
