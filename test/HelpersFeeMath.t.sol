// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RouterIssueSettlementBase} from "../src/facets/RouterIssueSettlementBase.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";

contract HelpersFeeMathHarness is RouterIssueSettlementBase {
    constructor(address permit2_) RouterIssueSettlementBase(permit2_) {}

    function grossForNet(uint256 netCygldOut, uint256 feePpm)
        external
        pure
        returns (uint256 grossCygldOut, uint256 helperFeeCygld)
    {
        return _grossForNet(netCygldOut, feePpm);
    }
}

contract HelpersFeeMathTest is Test {
    uint256 internal constant PPM_DENOMINATOR = 1_000_000;
    uint256 internal constant MAX_HELPER_FEE_PPM = 5_000;

    // `parseJson` encodes object members alphabetically, so the struct mirrors that order.
    struct GrossForNetVector {
        uint256 feePpm;
        uint256 grossCygldOut;
        string name;
        uint256 netCygldOut;
        uint256 protocolFeeCygld;
    }

    HelpersFeeMathHarness internal harness;

    function setUp() public {
        harness = new HelpersFeeMathHarness(address(this));
    }

    function testGrossForNetMatchesSharedVectors() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/gross-for-net-vectors.json"));
        GrossForNetVector[] memory vectors = abi.decode(vm.parseJson(json, ".success"), (GrossForNetVector[]));

        uint256 checked;
        for (uint256 i; i < vectors.length; ++i) {
            GrossForNetVector memory vector = vectors[i];
            if (vector.feePpm > MAX_HELPER_FEE_PPM) continue;

            (uint256 grossCygldOut, uint256 helperFeeCygld) = harness.grossForNet(vector.netCygldOut, vector.feePpm);
            assertEq(grossCygldOut, vector.grossCygldOut, vector.name);
            assertEq(helperFeeCygld, vector.protocolFeeCygld, vector.name);
            ++checked;
        }

        assertGt(checked, 0, "no helper-compatible shared vectors");
    }

    function testFuzzGrossForNetIsMinimalAndExact(uint256 netSeed, uint256 feeSeed) public view {
        uint256 feePpm = bound(feeSeed, 0, MAX_HELPER_FEE_PPM);
        uint256 maxNetCygldOut = type(uint256).max - Math.mulDiv(type(uint256).max, feePpm, PPM_DENOMINATOR);
        uint256 netCygldOut = bound(netSeed, 1, maxNetCygldOut);

        (uint256 grossCygldOut, uint256 helperFeeCygld) = harness.grossForNet(netCygldOut, feePpm);
        uint256 feeFromGross = Math.mulDiv(grossCygldOut, feePpm, PPM_DENOMINATOR);
        assertEq(helperFeeCygld, grossCygldOut - netCygldOut);
        assertEq(feeFromGross, helperFeeCygld);
        assertEq(grossCygldOut - feeFromGross, netCygldOut);

        uint256 precedingGross = grossCygldOut - 1;
        uint256 precedingNet = precedingGross - Math.mulDiv(precedingGross, feePpm, PPM_DENOMINATOR);
        assertLt(precedingNet, netCygldOut);
    }

    function testGrossForNetRejectsZeroNet() public {
        vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
        harness.grossForNet(0, 1_000);
    }

    function testGrossForNetRejectsFeeAboveHelpersCap() public {
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.HelperFeeTooHigh.selector, 5_001));
        harness.grossForNet(1 ether, 5_001);
    }

    function testGrossForNetRejectsOverflow() public {
        vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.GrossForNetOverflow.selector, type(uint256).max, 1));
        harness.grossForNet(type(uint256).max, 1);
    }

    function testGrossForNetMaximumNetAtHelpersFeeCap() public {
        uint256 maximumNetCygldOut =
            type(uint256).max - Math.mulDiv(type(uint256).max, MAX_HELPER_FEE_PPM, PPM_DENOMINATOR);

        (uint256 grossCygldOut, uint256 helperFeeCygld) = harness.grossForNet(maximumNetCygldOut, MAX_HELPER_FEE_PPM);
        assertEq(grossCygldOut, type(uint256).max);
        assertEq(helperFeeCygld, type(uint256).max - maximumNetCygldOut);

        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.GrossForNetOverflow.selector, maximumNetCygldOut + 1, MAX_HELPER_FEE_PPM
            )
        );
        harness.grossForNet(maximumNetCygldOut + 1, MAX_HELPER_FEE_PPM);
    }

    function testFuzzGrossForNetIsMonotonicInNet(uint256 netSeedA, uint256 netSeedB, uint256 feeSeed) public view {
        uint256 feePpm = bound(feeSeed, 0, MAX_HELPER_FEE_PPM);
        uint256 maximumNetCygldOut = type(uint256).max - Math.mulDiv(type(uint256).max, feePpm, PPM_DENOMINATOR);
        uint256 netA = bound(netSeedA, 1, maximumNetCygldOut);
        uint256 netB = bound(netSeedB, 1, maximumNetCygldOut);
        if (netA > netB) (netA, netB) = (netB, netA);

        (uint256 grossA,) = harness.grossForNet(netA, feePpm);
        (uint256 grossB,) = harness.grossForNet(netB, feePpm);
        assertLe(grossA, grossB);
    }

    function testFuzzGrossForNetIsMonotonicInFee(uint256 netSeed, uint256 feeSeedA, uint256 feeSeedB) public view {
        uint256 feeA = bound(feeSeedA, 0, MAX_HELPER_FEE_PPM);
        uint256 feeB = bound(feeSeedB, 0, MAX_HELPER_FEE_PPM);
        if (feeA > feeB) (feeA, feeB) = (feeB, feeA);
        uint256 maximumNetAtHigherFee = type(uint256).max - Math.mulDiv(type(uint256).max, feeB, PPM_DENOMINATOR);
        uint256 netCygldOut = bound(netSeed, 1, maximumNetAtHigherFee);

        (uint256 grossA,) = harness.grossForNet(netCygldOut, feeA);
        (uint256 grossB,) = harness.grossForNet(netCygldOut, feeB);
        assertLe(grossA, grossB);
    }
}
