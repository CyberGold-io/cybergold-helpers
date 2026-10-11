// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {IssueTestToken, IssueTestCore, IssueTestAdapter} from "../test/BasketRouterIssue.t.sol";

/// @notice Actual deployed-token permits consumed by a full candidate Helpers diamond on a disposable fork.
/// @dev Core and swap accounting are test doubles. This is not live venue, production Core, or wallet evidence.
contract TokenNativePermitForkTest is Test {
    address private constant PAXG = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    address private constant XAUT = 0x68749665FF8D2d112Fa859AA293F07A622782F38;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    address private user;
    uint256 private userKey;
    IssueTestToken private assetA;
    IssueTestToken private assetB;
    IssueTestCore private core;
    IssueTestAdapter private adapter;
    ICyberGoldHelpers private router;

    function setUp() public {
        userKey = vm.randomUint();
        user = vm.addr(userKey);
        assetA = new IssueTestToken("Reserve A", "A");
        assetB = new IssueTestToken("Reserve B", "B");
        core = new IssueTestCore(address(assetA), address(assetB));
        adapter = new IssueTestAdapter();
        DeploymentTypes.DeployConfig memory cfg;
        cfg.admin = address(this);
        cfg.coreDiamond = address(core);
        cfg.permit2 = PERMIT2;
        cfg.wrappedNative = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        cfg.approvedAdapters = new address[](1);
        cfg.approvedAdapters[0] = address(adapter);
        router = ICyberGoldHelpers(address(DeploymentHelper.deploy(cfg).diamond));
        assetA.mint(address(adapter), 100 ether);
        assetB.mint(address(adapter), 100 ether);
    }

    function testPaxgFirstPurchaseWithActualTokenPermit() public {
        _purchase(PAXG, 1 ether, "Paxos Gold", "1");
    }

    function testXautFirstPurchaseWithActualTokenPermit() public {
        _purchase(XAUT, 1 ether, "Tether Gold", "1");
    }

    function testUsdcFirstPurchaseWithActualTokenPermit() public {
        _purchase(USDC, 1e6, "USD Coin", "2");
    }

    function testUsdcPurchaseRevertRollsBackActualPermitNonceAndAllowance() public {
        uint256 unit = 1e6;
        deal(USDC, user, 100 * unit);
        IBasketRouterTypes.PermitParams memory permit = _permit(USDC, 12 * unit);
        uint256 nonceBefore = IERC20Permit(USDC).nonces(user);
        IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(unit);
        legs[1].data = abi.encode(4 ether, unit);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasketRouterTypes.InsufficientOutputForNeed.selector, address(assetB), 5 ether, 4 ether
            )
        );
        vm.prank(user);
        router.issueFromTokenExactOutWithPermit(_params(USDC, unit), _execution(), permit, legs);
        assertEq(IERC20Permit(USDC).nonces(user), nonceBefore);
        assertEq(IERC20(USDC).allowance(user, address(router)), 0);
        assertEq(IERC20(USDC).balanceOf(user), 100 * unit);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(core.balanceOf(user), 0);
        assertEq(adapter.swapCallCount(), 0);
    }

    function _purchase(address token, uint256 unit, string memory name, string memory version) private {
        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                block.chainid,
                token
            )
        );
        assertEq(IERC20Permit(token).DOMAIN_SEPARATOR(), expectedDomain, "qualified deployed signing domain");
        deal(token, user, 100 * unit);
        uint256 nonceBefore = IERC20Permit(token).nonces(user);
        assertEq(IERC20(token).allowance(user, address(router)), 0);
        assertEq(IERC20(token).allowance(user, PERMIT2), 0);
        IBasketRouterTypes.PermitParams memory permit = _permit(token, 12 * unit);
        vm.prank(user);
        router.issueFromTokenExactOutWithPermit(_params(token, unit), _execution(), permit, _legs(unit));
        assertEq(IERC20Permit(token).nonces(user), nonceBefore + 1);
        assertEq(IERC20(token).allowance(user, address(router)), 0);
        assertEq(IERC20(token).allowance(user, PERMIT2), 0);
        assertEq(IERC20(token).balanceOf(user), 90 * unit);
        assertEq(core.balanceOf(user), 10 ether);
        assertEq(IERC20(token).balanceOf(address(router)), 0);
        assertEq(IERC20(token).allowance(address(router), address(adapter)), 0);
    }

    function _permit(address token, uint256 value)
        private
        view
        returns (IBasketRouterTypes.PermitParams memory permit)
    {
        permit.value = value;
        permit.deadline = block.timestamp + 1 days;
        bytes32 message = keccak256(
            abi.encode(PERMIT_TYPEHASH, user, address(router), value, IERC20Permit(token).nonces(user), permit.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", IERC20Permit(token).DOMAIN_SEPARATOR(), message));
        (permit.v, permit.r, permit.s) = vm.sign(userKey, digest);
    }

    function _params(address token, uint256 unit)
        private
        pure
        returns (IBasketRouterTypes.IssueFromTokenExactOutParams memory)
    {
        return IBasketRouterTypes.IssueFromTokenExactOutParams({
            inputToken: token, maximumInputAmount: 12 * unit, netCygldOut: 10 ether
        });
    }

    function _execution() private view returns (IBasketRouterTypes.IssueExecutionParams memory) {
        address[] memory assets = new address[](2);
        assets[0] = address(assetA);
        assets[1] = address(assetB);
        return IBasketRouterTypes.IssueExecutionParams({recipient: user, expectedOrderedCoreAssets: assets});
    }

    function _legs(uint256 unit) private view returns (IBasketRouterTypes.IssueSwapLeg[] memory legs) {
        legs = new IBasketRouterTypes.IssueSwapLeg[](2);
        for (uint256 i; i < legs.length; ++i) {
            legs[i] = IBasketRouterTypes.IssueSwapLeg({
                adapter: address(adapter),
                amountIn: 6 * unit,
                minimumAmountOut: 5 ether,
                data: abi.encode(5 ether, unit)
            });
        }
    }
}
