// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ICyberGoldHelpers} from "../src/interfaces/ICyberGoldHelpers.sol";
import {DeploymentHelper} from "../src/deploy/DeploymentHelper.sol";
import {DeploymentTypes} from "../src/deploy/DeploymentTypes.sol";
import {RecoveryShareReceiverFacet} from "../src/facets/RecoveryShareReceiverFacet.sol";
import {RouterRecoveryBase} from "../src/facets/RouterRecoveryBase.sol";
import {RouterRedeemFacet} from "../src/facets/RouterRedeemFacet.sol";
import {RouterRedemptionCoreBase} from "../src/facets/RouterRedemptionCoreBase.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";
import {MintableToken, MockPermit2, MockSwapAdapterRouter, MockWETH} from "./mocks/BasketRouterMocks.sol";

/// @notice Typed mixed-output Core double with enough ERC-1155 behavior to exercise Helpers' exact callback.
contract MixedRedemptionCore is IERC20, IERC20Permit {
    string public constant name = "Mock CYGLD";
    string public constant symbol = "MCYGLD";
    uint8 public constant decimals = 18;
    mapping(address account => uint256 amount) private _erc20Balances;
    mapping(address owner => mapping(address spender => uint256 amount)) public override allowance;
    uint256 public override totalSupply;
    mapping(address account => uint256 nonce) public override nonces;
    mapping(uint256 id => mapping(address account => uint256 amount)) private _shareBalances;
    ICoreRedemption.TokenAmount[] private _outputs;

    uint256 public safeRedeemCallCount;
    bytes32 public lastExpectedOutputsHash;
    bool public skipShareMint;
    uint256 public shareMintDelta;
    bytes public callbackData;
    address public callbackOperator;
    address public callbackFrom;
    bool public doubleCallback;
    bool public driftOnPermit;
    uint256 public driftOutputIndex;
    uint256 public driftOutputAmount;
    bool public callbackAmountLengthMismatch;
    bool public callbackAmountExceedsCredit;
    bool public skipShareTransferDebit;
    bool public skipShareTransferCredit;
    bool public bypassExpectedBindings;
    uint8 public safeRedeemReturnFault;
    uint256 public safeRedeemReturnFaultIndex;
    uint256 public safeRedeemReturnFaultValue;
    uint256 public exactOutGrossCygldIn = 10 ether;

    function mint(address to, uint256 amount) external {
        _erc20Balances[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _erc20Balances[account];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(_erc20Balances[from] >= amount, "balance");
        _erc20Balances[from] -= amount;
        _erc20Balances[to] += amount;
        emit Transfer(from, to, amount);
    }

    function configureOutputs(ICoreRedemption.TokenAmount[] memory outputs) external {
        delete _outputs;
        for (uint256 i; i < outputs.length; ++i) {
            _outputs.push(outputs[i]);
        }
    }

    function setShareMintFault(bool skip, uint256 delta) external {
        skipShareMint = skip;
        shareMintDelta = delta;
    }

    function setCallbackFault(bytes calldata data, address operator, address from, bool twice) external {
        callbackData = data;
        callbackOperator = operator;
        callbackFrom = from;
        doubleCallback = twice;
    }

    function setPermitDrift(uint256 index, uint256 amount, bool enabled) external {
        driftOutputIndex = index;
        driftOutputAmount = amount;
        driftOnPermit = enabled;
    }

    function setShareCallbackShapeFault(bool lengthMismatch, bool amountExceedsCredit) external {
        callbackAmountLengthMismatch = lengthMismatch;
        callbackAmountExceedsCredit = amountExceedsCredit;
    }

    function setShareTransferFault(bool skipDebit, bool skipCredit) external {
        skipShareTransferDebit = skipDebit;
        skipShareTransferCredit = skipCredit;
    }

    /// @dev Fault codes: 1 resize outputs, 2 token, 3 amount, 4 gross, 5 net, 6 fee, 7 id.
    function setSafeRedeemReturnFault(uint8 fault, uint256 index, uint256 value, bool bypassBindings) external {
        safeRedeemReturnFault = fault;
        safeRedeemReturnFaultIndex = index;
        safeRedeemReturnFaultValue = value;
        bypassExpectedBindings = bypassBindings;
    }

    function primeShare(address account, uint256 id, uint256 amount) external {
        _shareBalances[id][account] += amount;
    }

    function invokeBatch(
        address receiver,
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bytes4) {
        return IERC1155Receiver(receiver).onERC1155BatchReceived(operator, from, ids, amounts, data);
    }

    function previewRedeemExactIn(uint256 grossCygldIn)
        external
        view
        returns (ICoreRedemption.RedemptionQuote memory quote)
    {
        return _quote(grossCygldIn);
    }

    function setExactOutGrossCygldIn(uint256 grossCygldIn) external {
        exactOutGrossCygldIn = grossCygldIn;
    }

    function previewRedeemExactOut(ICoreRedemption.TokenMinimum[] calldata minimumOutputs)
        external
        view
        returns (ICoreRedemption.RedemptionQuote memory quote)
    {
        quote = _quote(exactOutGrossCygldIn);
        if (minimumOutputs.length != quote.outputs.length) {
            revert ICoreRedemption.RedemptionOutputsLengthMismatch(minimumOutputs.length, quote.outputs.length);
        }
        for (uint256 i; i < quote.outputs.length; ++i) {
            ICoreRedemption.TokenMinimum calldata minimum = minimumOutputs[i];
            ICoreRedemption.TokenAmount memory output = quote.outputs[i];
            if (minimum.kind != output.kind || minimum.token != output.token || minimum.id != output.id) {
                revert ICoreRedemption.RedemptionOutputDescriptorMismatch(
                    i, minimum.kind, minimum.token, minimum.id, output.kind, output.token, output.id
                );
            }
            if (output.amount < minimum.minimumAmount) {
                revert ICoreRedemption.RedemptionOutputBelowMinimum(i, minimum.minimumAmount, output.amount);
            }
        }
    }

    function safeRedeem(uint256 grossCygldIn, ICoreRedemption.TokenMinimum[] calldata expectedOutputs)
        external
        returns (ICoreRedemption.RedemptionQuote memory quote)
    {
        quote = _quote(grossCygldIn);
        if (!bypassExpectedBindings) {
            if (expectedOutputs.length != quote.outputs.length) {
                revert ICoreRedemption.RedemptionOutputsLengthMismatch(expectedOutputs.length, quote.outputs.length);
            }
            for (uint256 i; i < quote.outputs.length; ++i) {
                ICoreRedemption.TokenMinimum calldata expected = expectedOutputs[i];
                ICoreRedemption.TokenAmount memory output = quote.outputs[i];
                if (expected.kind != output.kind || expected.token != output.token || expected.id != output.id) {
                    revert ICoreRedemption.RedemptionOutputDescriptorMismatch(
                        i, expected.kind, expected.token, expected.id, output.kind, output.token, output.id
                    );
                }
                if (output.amount < expected.minimumAmount) {
                    revert ICoreRedemption.RedemptionOutputBelowMinimum(i, expected.minimumAmount, output.amount);
                }
            }
        }
        lastExpectedOutputsHash = keccak256(abi.encode(expectedOutputs));
        ++safeRedeemCallCount;

        require(_erc20Balances[msg.sender] >= grossCygldIn, "balance");
        _erc20Balances[msg.sender] -= grossCygldIn;
        totalSupply -= grossCygldIn;
        emit Transfer(msg.sender, address(0), grossCygldIn);

        uint256 positiveShareCount;
        for (uint256 i; i < quote.outputs.length; ++i) {
            ICoreRedemption.TokenAmount memory output = quote.outputs[i];
            if (output.kind == ICoreRedemption.TokenKind.ERC20) {
                if (output.amount != 0) require(IERC20(output.token).transfer(msg.sender, output.amount), "transfer");
            } else if (output.amount != 0) {
                ++positiveShareCount;
            }
        }
        if (positiveShareCount != 0 && !skipShareMint) _mintShareBatch(msg.sender, quote.outputs, positiveShareCount);
        _applySafeRedeemReturnFault(quote);
    }

    function _mintShareBatch(
        address recipient,
        ICoreRedemption.TokenAmount[] memory outputs,
        uint256 positiveShareCount
    ) private {
        uint256[] memory ids = new uint256[](positiveShareCount);
        uint256[] memory amounts = new uint256[](positiveShareCount);
        uint256 cursor;
        for (uint256 i; i < outputs.length; ++i) {
            ICoreRedemption.TokenAmount memory output = outputs[i];
            if (output.kind != ICoreRedemption.TokenKind.ERC1155 || output.amount == 0) continue;
            ids[cursor] = output.id;
            amounts[cursor] = output.amount + shareMintDelta;
            _shareBalances[output.id][recipient] += amounts[cursor];
            ++cursor;
        }
        uint256[] memory callbackAmounts = amounts;
        if (callbackAmountLengthMismatch) {
            callbackAmounts = new uint256[](positiveShareCount - 1);
            for (uint256 i; i < callbackAmounts.length; ++i) {
                callbackAmounts[i] = amounts[i];
            }
        } else if (callbackAmountExceedsCredit) {
            callbackAmounts[0] += 1;
        }
        address operator = callbackOperator == address(0) ? address(this) : callbackOperator;
        address from = callbackFrom;
        bytes memory data = callbackData;
        bytes4 accepted = IERC1155Receiver(recipient).onERC1155BatchReceived(operator, from, ids, callbackAmounts, data);
        require(accepted == IERC1155Receiver.onERC1155BatchReceived.selector, "receiver");
        if (doubleCallback) {
            IERC1155Receiver(recipient).onERC1155BatchReceived(operator, from, ids, callbackAmounts, data);
        }
    }

    function _applySafeRedeemReturnFault(ICoreRedemption.RedemptionQuote memory quote) private view {
        uint8 fault = safeRedeemReturnFault;
        if (fault == 0) return;
        if (fault == 1) {
            ICoreRedemption.TokenAmount[] memory resized = new ICoreRedemption.TokenAmount[](safeRedeemReturnFaultValue);
            uint256 copyLength =
                safeRedeemReturnFaultValue < quote.outputs.length ? safeRedeemReturnFaultValue : quote.outputs.length;
            for (uint256 i; i < copyLength; ++i) {
                resized[i] = quote.outputs[i];
            }
            quote.outputs = resized;
        } else if (fault == 2) {
            // Test-only fault injection deliberately truncates an arbitrary fault word to an address.
            // forge-lint: disable-next-line(unsafe-typecast)
            quote.outputs[safeRedeemReturnFaultIndex].token = address(uint160(safeRedeemReturnFaultValue));
        } else if (fault == 3) {
            quote.outputs[safeRedeemReturnFaultIndex].amount = safeRedeemReturnFaultValue;
        } else if (fault == 4) {
            quote.grossCygldIn = safeRedeemReturnFaultValue;
        } else if (fault == 5) {
            quote.netCygldIn = safeRedeemReturnFaultValue;
        } else if (fault == 6) {
            quote.protocolFeeCygld = safeRedeemReturnFaultValue;
        } else if (fault == 7) {
            quote.outputs[safeRedeemReturnFaultIndex].id = safeRedeemReturnFaultValue;
        }
    }

    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return _shareBalances[id][account];
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        require(msg.sender == from, "operator");
        require(ids.length == amounts.length, "length");
        for (uint256 i; i < ids.length; ++i) {
            require(_shareBalances[ids[i]][from] >= amounts[i], "shares");
            if (!skipShareTransferDebit) _shareBalances[ids[i]][from] -= amounts[i];
            if (!skipShareTransferCredit) _shareBalances[ids[i]][to] += amounts[i];
        }
        if (to.code.length != 0) {
            bytes4 accepted = IERC1155Receiver(to).onERC1155BatchReceived(msg.sender, from, ids, amounts, data);
            require(accepted == IERC1155Receiver.onERC1155BatchReceived.selector, "receiver");
        }
    }

    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external pure {
        revert("single disabled");
    }

    function setApprovalForAll(address, bool) external pure {}

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory balances)
    {
        require(accounts.length == ids.length, "length");
        balances = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            balances[i] = _shareBalances[ids[i]][accounts[i]];
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155).interfaceId;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32)
        external
        override
    {
        // This test double mirrors ERC-2612 timestamp deadline semantics.
        // forge-lint: disable-next-line(block-timestamp)
        require(deadline >= block.timestamp, "expired");
        allowance[owner][spender] = value;
        ++nonces[owner];
        if (driftOnPermit) {
            require(driftOutputIndex < _outputs.length, "drift index");
            _outputs[driftOutputIndex].amount = driftOutputAmount;
        }
        emit Approval(owner, spender, value);
    }

    function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
        return bytes32(0);
    }

    function _quote(uint256 grossCygldIn) private view returns (ICoreRedemption.RedemptionQuote memory quote) {
        require(grossCygldIn != 0, "value");
        quote.grossCygldIn = grossCygldIn;
        quote.netCygldIn = grossCygldIn;
        quote.outputs = new ICoreRedemption.TokenAmount[](_outputs.length);
        for (uint256 i; i < _outputs.length; ++i) {
            quote.outputs[i] = _outputs[i];
        }
    }
}

    contract RecoveryReceiptHarness is RouterRecoveryBase {
        constructor(address permit2_) RouterRecoveryBase(permit2_) {}

        function arm(address core, address recipient, ICoreRedemption.TokenAmount[] memory outputs) external {
            _armRecoveryReceipt(core, recipient, outputs);
        }
    }

    contract RedemptionValidationHarness is RouterRedemptionCoreBase {
        constructor(address permit2_) RouterRedemptionCoreBase(permit2_) {}

        function validateSettled(
            address core,
            uint256 coreGrossCygldIn,
            ICoreRedemption.RedemptionQuote memory projected,
            ICoreRedemption.RedemptionQuote memory settled,
            ICoreRedemption.TokenMinimum[] memory expectedOutputs,
            uint256[] memory coreOutputBalancesBefore
        ) external view {
            _validateSettledRedemption(
                core, coreGrossCygldIn, projected, settled, expectedOutputs, coreOutputBalancesBefore
            );
        }
    }

    contract AcceptingShareRecipient is IERC1155Receiver {
        uint256 public callbackCount;

        function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
            return IERC1155Receiver.onERC1155Received.selector;
        }

        function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
            external
            returns (bytes4)
        {
            ++callbackCount;
            return IERC1155Receiver.onERC1155BatchReceived.selector;
        }

        function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
            return interfaceId == type(IERC1155Receiver).interfaceId;
        }
    }

    /// @notice The recipient owns credited shares and may forward them during its callback.
    contract ForwardingShareRecipient is IERC1155Receiver {
        address internal immutable _destination;
        address internal immutable _nestedTarget;
        bytes internal _nestedCall;
        bytes4 public nestedRevertSelector;

        constructor(address destination, address nestedTarget, bytes memory nestedCall) {
            _destination = destination;
            _nestedTarget = nestedTarget;
            _nestedCall = nestedCall;
        }

        function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
            return IERC1155Receiver.onERC1155Received.selector;
        }

        function onERC1155BatchReceived(
            address,
            address,
            uint256[] calldata ids,
            uint256[] calldata amounts,
            bytes calldata
        ) external returns (bytes4) {
            if (_nestedTarget != address(0)) {
                (bool success, bytes memory result) = _nestedTarget.call(_nestedCall);
                require(!success && result.length >= 4, "nested call unexpectedly accepted");
                nestedRevertSelector = bytes4(result);
            }
            IERC1155(msg.sender).safeBatchTransferFrom(address(this), _destination, ids, amounts, "");
            return IERC1155Receiver.onERC1155BatchReceived.selector;
        }

        function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
            return interfaceId == type(IERC1155Receiver).interfaceId;
        }
    }

    contract BasketRouterMixedRedeemTest is Test {
        address private constant OWNER = address(0xA11CE);
        address private constant USER = address(0xBEEF);
        address private constant RECIPIENT = address(0xCAFE);
        address private constant IMPAIRED_ASSET = address(0x1234);
        uint256 private constant SHARE_ID = uint256(uint160(IMPAIRED_ASSET));

        MixedRedemptionCore private core;
        MintableToken private tokenA;
        MintableToken private tokenB;
        MintableToken private tokenC;
        MockWETH private weth;
        MockPermit2 private permit2;
        MockSwapAdapterRouter private adapter;
        ICyberGoldHelpers private router;

        function setUp() public {
            core = new MixedRedemptionCore();
            tokenA = new MintableToken("Token A", "TKA");
            tokenB = new MintableToken("Token B", "TKB");
            tokenC = new MintableToken("Token C", "TKC");
            weth = new MockWETH();
            permit2 = new MockPermit2();
            adapter = new MockSwapAdapterRouter();

            DeploymentTypes.DeployConfig memory cfg;
            cfg.admin = OWNER;
            cfg.coreDiamond = address(core);
            cfg.permit2 = address(permit2);
            cfg.wrappedNative = address(weth);
            cfg.approvedAdapters = new address[](1);
            cfg.approvedAdapters[0] = address(adapter);
            DeploymentTypes.DeployArtifacts memory deployed = DeploymentHelper.deploy(cfg);
            router = ICyberGoldHelpers(address(deployed.diamond));

            core.mint(USER, 100 ether);
            vm.prank(USER);
            core.approve(address(router), type(uint256).max);
            tokenA.mint(address(core), 1_000 ether);
            tokenB.mint(address(core), 1_000 ether);
            tokenC.mint(address(adapter), 1_000 ether);
        }

        function testPreviewIsConstructionOnlyAndReturnsCompleteMixedVector() public {
            _configureMixed(4 ether, 3 ether, 2 ether);
            IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
            legs[0] = _leg(2 ether, abi.encode(address(tokenA), 2 ether));

            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 10 ether, outputToken: address(tokenA)}),
                legs
            );

            assertEq(preview.minimumAmountOut, 6 ether);
            assertEq(preview.projectedCoreOutputs.length, 3);
            assertEq(uint8(preview.projectedCoreOutputs[2].kind), uint8(ICoreRedemption.TokenKind.ERC1155));
            assertEq(adapter.swapCallCount(), 0, "preview called adapter");
        }

        function testMixedRedemptionAggregatesErc20AndForwardsPositiveShares() public {
            _configureMixed(4 ether, 3 ether, 2 ether);
            IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](2);
            legs[0] = _leg(4 ether, abi.encode(address(tokenC), 4 ether));
            legs[1] = _leg(3 ether, abi.encode(address(tokenC), 3 ether));
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 10 ether, outputToken: address(tokenC)}),
                legs
            );
            ICoreRedemption.TokenMinimum[] memory expected = _minimums(preview.projectedCoreOutputs);
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 10 ether,
                outputToken: address(tokenC),
                recipient: RECIPIENT,
                minimumAmountOut: 7 ether,
                expectedCoreOutputs: expected
            });

            vm.prank(USER);
            IBasketRouterTypes.AggregatedRedemptionResult memory result = router.redeemToTokenExactIn(request, legs);

            assertEq(result.amountOut, 7 ether);
            assertEq(tokenC.balanceOf(RECIPIENT), 7 ether);
            assertEq(result.recoveryShareOutputs.length, 1);
            assertEq(result.recoveryShareOutputs[0].id, SHARE_ID);
            assertEq(result.recoveryShareOutputs[0].amount, 2 ether);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 2 ether);
            assertEq(core.balanceOf(address(router), SHARE_ID), 0);
            assertEq(core.lastExpectedOutputsHash(), keccak256(abi.encode(expected)));
            assertEq(adapter.swapCallCount(), 2);
            assertEq(core.safeRedeemCallCount(), 1);
        }

        function testTransientGuardRejectsAdapterReentryAcrossRedeemAndIssueFacets() public {
            _configureMixed(4 ether, 3 ether, 2 ether);
            IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](2);
            legs[0] = _leg(4 ether, abi.encode(address(tokenC), 4 ether));
            legs[1] = _leg(3 ether, abi.encode(address(tokenC), 3 ether));

            address[] memory noExpectedAssets = new address[](0);
            IBasketRouterTypes.IssueSwapLeg[] memory noIssueLegs = new IBasketRouterTypes.IssueSwapLeg[](0);
            bytes memory reentryCall = abi.encodeCall(
                ICyberGoldHelpers.issueFromTokenExactOut,
                (
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA), maximumInputAmount: 1, netCygldOut: 1
                    }),
                    IBasketRouterTypes.IssueExecutionParams({
                        recipient: RECIPIENT, expectedOrderedCoreAssets: noExpectedAssets
                    }),
                    noIssueLegs
                )
            );
            adapter.setReentry(address(router), reentryCall);

            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 10 ether, outputToken: address(tokenC)}),
                legs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 10 ether,
                outputToken: address(tokenC),
                recipient: RECIPIENT,
                minimumAmountOut: 7 ether,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });

            vm.prank(USER);
            router.redeemToTokenExactIn(request, legs);

            assertTrue(adapter.reentryBlocked(), "cross-facet reentry was not rejected by transient guard");
        }

        function testShareOnlyRedemptionAllowsZeroAggregateMinimum() public {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = _shareOutput(5 ether);
            core.configureOutputs(outputs);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 8 ether, outputToken: address(tokenC)}),
                noLegs
            );
            assertEq(preview.minimumAmountOut, 0);
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 8 ether,
                outputToken: address(tokenC),
                recipient: RECIPIENT,
                minimumAmountOut: 0,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });

            vm.prank(USER);
            IBasketRouterTypes.AggregatedRedemptionResult memory result = router.redeemToTokenExactIn(request, noLegs);
            assertEq(result.amountOut, 0);
            assertEq(result.recoveryShareOutputs.length, 1);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 5 ether);
        }

        function testPositiveErc20OutputStillRequiresAggregateMinimum() public {
            _configureHealthy(4 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 5 ether, outputToken: address(tokenA)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 5 ether,
                outputToken: address(tokenA),
                recipient: RECIPIENT,
                minimumAmountOut: 0,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            vm.expectRevert(IBasketRouterTypes.ZeroFinalMinimum.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
        }

        function testCompactLegCountAndMinimaAreValidatedWithoutAdapterCalls() public {
            _configureHealthy(4 ether, 3 ether);
            IBasketRouterTypes.RedeemToTokenExactInParams memory params =
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 10 ether, outputToken: address(tokenC)});
            IBasketRouterTypes.RedemptionSwapLeg[] memory shortLegs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
            shortLegs[0] = _leg(1, "");
            vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.QuoteLengthMismatch.selector, 1, 2));
            router.previewRedeemToTokenExactIn(params, shortLegs);

            IBasketRouterTypes.RedemptionSwapLeg[] memory zeroMinimum = new IBasketRouterTypes.RedemptionSwapLeg[](2);
            zeroMinimum[0] = _leg(0, "");
            zeroMinimum[1] = _leg(1, "");
            vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.ZeroLegMinimum.selector, 0));
            router.previewRedeemToTokenExactIn(params, zeroMinimum);
            assertEq(adapter.swapCallCount(), 0);
        }

        function testDuplicateAndUnsortedCoreDescriptorsAreRejectedWhileStructuralZerosRemainValid() public {
            ICoreRedemption.TokenAmount[] memory duplicateErc20 = new ICoreRedemption.TokenAmount[](2);
            duplicateErc20[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: 1 ether
            });
            duplicateErc20[1] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: 0
            });
            core.configureOutputs(duplicateErc20);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 2 ether, outputToken: address(tokenA)}),
                noLegs
            );

            ICoreRedemption.TokenAmount[] memory unsortedShares = new ICoreRedemption.TokenAmount[](2);
            unsortedShares[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC1155, token: address(core), id: 2, amount: 1 ether
            });
            unsortedShares[1] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC1155, token: address(core), id: 1, amount: 0
            });
            core.configureOutputs(unsortedShares);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 2 ether, outputToken: address(tokenA)}),
                noLegs
            );
        }

        function testOperationLocalAdapterInputDustIsAlwaysRefundedToPayer() public {
            _configureHealthy(4 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
            legs[0] = _leg(2 ether, abi.encode(address(tokenC), 2 ether, 1 ether));
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 5 ether, outputToken: address(tokenC)}),
                legs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 5 ether,
                outputToken: address(tokenC),
                recipient: RECIPIENT,
                minimumAmountOut: 2 ether,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            vm.prank(USER);
            router.redeemToTokenExactIn(request, legs);
            assertEq(tokenA.balanceOf(USER), 1 ether);
            assertEq(tokenA.balanceOf(address(router)), 0);
        }

        function testNativeRouteUnwrapsWethAndUsesZeroOnlyAsOutcomeMarker() public {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(weth), id: 0, amount: 3 ether
            });
            core.configureOutputs(outputs);
            weth.mint(address(core), 3 ether);
            vm.deal(address(weth), 3 ether);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview =
                router.previewRedeemToNativeExactIn(5 ether, noLegs);
            IBasketRouterTypes.AggregatedNativeRedemptionRequest memory request =
                IBasketRouterTypes.AggregatedNativeRedemptionRequest({
                    grossCygldIn: 5 ether,
                    recipient: RECIPIENT,
                    minimumAmountOut: 3 ether,
                    expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
                });
            uint256 balanceBefore = RECIPIENT.balance;
            vm.prank(USER);
            IBasketRouterTypes.AggregatedRedemptionResult memory result = router.redeemToNativeExactIn(request, noLegs);
            assertEq(result.amountOut, 3 ether);
            assertEq(RECIPIENT.balance - balanceBefore, 3 ether);
        }

        function testTokenRouteRejectsZeroTokenAndBothRouteFamiliesAreNonpayable() public {
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            vm.expectRevert(IBasketRouterTypes.ZeroAddress.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 1 ether, outputToken: address(0)}), noLegs
            );

            vm.deal(USER, 2 wei);
            IBasketRouterTypes.AggregatedNativeRedemptionRequest memory nativeRequest;
            vm.prank(USER);
            (bool ok,) = address(router).call{value: 1}(
                abi.encodeCall(ICyberGoldHelpers.redeemToNativeExactIn, (nativeRequest, noLegs))
            );
            assertFalse(ok, "native redemption unexpectedly payable");
        }

        function testErc2612FreshAndAlreadyConsumedAuthorizationBothWork() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 4 ether, outputToken: address(tokenA)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 4 ether,
                outputToken: address(tokenA),
                recipient: RECIPIENT,
                minimumAmountOut: 1,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            IBasketRouterTypes.PermitParams memory permit;
            permit.value = 4 ether;
            permit.deadline = block.timestamp + 1 days;
            vm.prank(USER);
            core.approve(address(router), 0);
            vm.prank(USER);
            router.redeemToTokenExactInWithPermit(request, permit, noLegs);

            core.mint(USER, 4 ether);
            vm.prank(USER);
            core.permit(USER, address(router), 4 ether, permit.deadline, 0, bytes32(0), bytes32(0));
            vm.prank(USER);
            router.redeemToTokenExactInWithPermit(request, permit, noLegs);
            assertEq(core.nonces(USER), 2, "consumed route must skip a second permit attempt");
        }

        function testPermit2AuthorizationWorksForCygld() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 4 ether, outputToken: address(tokenA)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 4 ether,
                outputToken: address(tokenA),
                recipient: RECIPIENT,
                minimumAmountOut: 1,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            IBasketRouterTypes.Permit2Params memory permit;
            permit.permit = ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: address(core), amount: 4 ether}),
                nonce: 1,
                deadline: block.timestamp + 1 days
            });
            permit.signature = hex"01";
            vm.startPrank(USER);
            core.approve(address(router), 0);
            core.approve(address(permit2), type(uint256).max);
            router.redeemToTokenExactInWithPermit2(request, permit, noLegs);
            vm.stopPrank();
        }

        function testMissingOrMismatchedRecoveryCallbackRollsBackEntireOperation() public {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = _shareOutput(2 ether);
            core.configureOutputs(outputs);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 5 ether, outputToken: address(tokenC)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 5 ether,
                outputToken: address(tokenC),
                recipient: RECIPIENT,
                minimumAmountOut: 0,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });

            core.setShareMintFault(true, 0);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
            assertEq(core.balanceOf(USER), 100 ether);

            core.setShareMintFault(false, 1);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
            assertEq(core.balanceOf(USER), 100 ether);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 0);
        }

        function testReceiverRejectsSingleAndUnauthorizedBatchReceipts() public {
            vm.expectRevert(IBasketRouterTypes.RecoverySingleShareReceiptRejected.selector);
            RecoveryShareReceiverFacet(address(router)).onERC1155Received(address(0), address(0), SHARE_ID, 1, "");

            uint256[] memory ids = new uint256[](1);
            ids[0] = SHARE_ID;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1;
            vm.expectRevert();
            RecoveryShareReceiverFacet(address(router))
                .onERC1155BatchReceived(address(core), address(0), ids, amounts, "");

            vm.expectRevert();
            core.invokeBatch(address(router), address(core), address(0), ids, amounts, "");
        }

        function testRecoveryCallbackRejectsDataOperatorFromAndDoubleDeliveryThenReturnsToIdle() public {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = _shareOutput(2 ether);
            core.configureOutputs(outputs);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 5 ether, outputToken: address(tokenC)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 5 ether,
                outputToken: address(tokenC),
                recipient: RECIPIENT,
                minimumAmountOut: 0,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });

            core.setCallbackFault(hex"01", address(0), address(0), false);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            core.setCallbackFault("", address(0xBAD), address(0), false);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            core.setCallbackFault("", address(0), address(0xBAD), false);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            core.setCallbackFault("", address(0), address(0), true);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            // Every failed outer call rolls its Armed/Consumed mutation back to Idle. A clean retry proves it.
            core.setCallbackFault("", address(0), address(0), false);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 2 ether);
        }

        function testContractRecipientCanAcceptTheBoundRecoveryBatch() public {
            AcceptingShareRecipient contractRecipient = new AcceptingShareRecipient();
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = _shareOutput(2 ether);
            core.configureOutputs(outputs);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 5 ether, outputToken: address(tokenC)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 5 ether,
                outputToken: address(tokenC),
                recipient: address(contractRecipient),
                minimumAmountOut: 0,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
            assertEq(contractRecipient.callbackCount(), 1);
            assertEq(core.balanceOf(address(contractRecipient), SHARE_ID), 2 ether);
        }

        function testNativeShareAmountsAreForwardedWithoutScalingOrAutomaticBurn() public {
            uint256[4] memory amounts = [uint256(3e6), 3e8, 3 ether, 3e24];
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            for (uint256 i; i < amounts.length; ++i) {
                ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
                outputs[0] = _shareOutput(amounts[i]);
                core.configureOutputs(outputs);
                IBasketRouterTypes.AggregatedRedemptionRequest memory request =
                    IBasketRouterTypes.AggregatedRedemptionRequest({
                        grossCygldIn: 5 ether,
                        outputToken: address(tokenC),
                        recipient: RECIPIENT,
                        minimumAmountOut: 0,
                        expectedCoreOutputs: _minimums(outputs)
                    });
                uint256 balanceBefore = core.balanceOf(RECIPIENT, SHARE_ID);
                vm.prank(USER);
                IBasketRouterTypes.AggregatedRedemptionResult memory result = router.redeemToTokenExactIn(
                    request, noLegs
                );
                assertEq(result.recoveryShareOutputs[0].amount, amounts[i]);
                assertEq(core.balanceOf(RECIPIENT, SHARE_ID) - balanceBefore, amounts[i]);
                assertEq(core.balanceOf(address(router), SHARE_ID), 0);
                assertEq(result.amountOut, 0);
            }
            // The double exposes no recovery burn selector. Forwarding never depends on token transferability.
            assertEq(core.safeRedeemCallCount(), amounts.length);
        }

        function testContractRecipientMayForwardNativeSharesButCannotReenterHelpersSettlement() public {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = _shareOutput(2e6);
            core.configureOutputs(outputs);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 5 ether,
                outputToken: address(tokenC),
                recipient: RECIPIENT,
                minimumAmountOut: 0,
                expectedCoreOutputs: _minimums(outputs)
            });
            ForwardingShareRecipient recipient = new ForwardingShareRecipient(
                RECIPIENT, address(router), abi.encodeCall(ICyberGoldHelpers.redeemToTokenExactIn, (request, noLegs))
            );
            request.recipient = address(recipient);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
            assertEq(recipient.nestedRevertSelector(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
            assertEq(core.balanceOf(address(recipient), SHARE_ID), 0);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 2e6);
            assertEq(core.balanceOf(address(router), SHARE_ID), 0);
            assertEq(core.safeRedeemCallCount(), 1);
        }

        function testPreexistingErc20WethCygldAndRecoveryShareBalancesNeverLeak() public {
            core.mint(address(router), 11 ether);
            tokenA.mint(address(router), 9 ether);
            core.primeShare(address(router), SHARE_ID, 6 ether);
            _configureMixed(2 ether, 0, 3 ether);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 5 ether, outputToken: address(tokenA)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 5 ether,
                outputToken: address(tokenA),
                recipient: RECIPIENT,
                minimumAmountOut: 2 ether,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
            assertEq(tokenA.balanceOf(address(router)), 9 ether);
            assertEq(tokenA.balanceOf(RECIPIENT), 2 ether);
            assertEq(core.balanceOf(address(router)), 11 ether);
            assertEq(core.balanceOf(address(router), SHARE_ID), 6 ether);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 3 ether);

            // The same exact baseline rule applies when WETH is unwrapped for a native payout.
            ICoreRedemption.TokenAmount[] memory nativeOutputs = new ICoreRedemption.TokenAmount[](1);
            nativeOutputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(weth), id: 0, amount: 1 ether
            });
            core.configureOutputs(nativeOutputs);
            weth.mint(address(router), 7 ether);
            weth.mint(address(core), 1 ether);
            vm.deal(address(weth), 8 ether);
            IBasketRouterTypes.AggregatedRedemptionPreview memory nativePreview =
                router.previewRedeemToNativeExactIn(2 ether, noLegs);
            IBasketRouterTypes.AggregatedNativeRedemptionRequest memory nativeRequest =
                IBasketRouterTypes.AggregatedNativeRedemptionRequest({
                    grossCygldIn: 2 ether,
                    recipient: RECIPIENT,
                    minimumAmountOut: 1 ether,
                    expectedCoreOutputs: _minimums(nativePreview.projectedCoreOutputs)
                });
            vm.prank(USER);
            router.redeemToNativeExactIn(nativeRequest, noLegs);
            assertEq(weth.balanceOf(address(router)), 7 ether);
            assertEq(core.balanceOf(address(router)), 11 ether);
        }

        function testExpectedDescriptorMinimumAndPermitTimeStateDriftFailBeforeSettlement() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 4 ether, outputToken: address(tokenA)}),
                noLegs
            );
            ICoreRedemption.TokenMinimum[] memory expected = _minimums(preview.projectedCoreOutputs);
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 4 ether,
                outputToken: address(tokenA),
                recipient: RECIPIENT,
                minimumAmountOut: 1,
                expectedCoreOutputs: expected
            });

            request.expectedCoreOutputs[0].token = address(tokenB);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
            request.expectedCoreOutputs[0].token = address(tokenA);
            request.expectedCoreOutputs[0].minimumAmount = 3 ether;
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            request.expectedCoreOutputs[0].minimumAmount = 2 ether;
            IBasketRouterTypes.PermitParams memory permit;
            permit.value = 4 ether;
            permit.deadline = block.timestamp + 1 days;
            vm.prank(USER);
            core.approve(address(router), 0);
            core.setPermitDrift(0, 1 ether, true);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactInWithPermit(request, permit, noLegs);
            assertEq(core.balanceOf(USER), 100 ether);
            assertEq(core.nonces(USER), 0, "permit-time drift must roll back");
        }

        function testExpectedCoreOutputsRejectBeforeEveryAggregatedAuthorizationPath() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 4 ether, outputToken: address(tokenA)}),
                noLegs
            );
            ICoreRedemption.TokenMinimum[] memory expected = _minimums(preview.projectedCoreOutputs);
            expected[0].token = address(tokenB);
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 4 ether,
                outputToken: address(tokenA),
                recipient: RECIPIENT,
                minimumAmountOut: 1,
                expectedCoreOutputs: expected
            });
            bytes memory descriptorError = abi.encodeWithSelector(
                ICoreRedemption.RedemptionOutputDescriptorMismatch.selector,
                uint256(0),
                ICoreRedemption.TokenKind.ERC20,
                address(tokenB),
                uint256(0),
                ICoreRedemption.TokenKind.ERC20,
                address(tokenA),
                uint256(0)
            );

            vm.prank(USER);
            core.approve(address(router), 0);
            vm.expectRevert(descriptorError);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            vm.warp(10);
            IBasketRouterTypes.PermitParams memory expiredPermit;
            expiredPermit.value = 4 ether;
            expiredPermit.deadline = 9;
            vm.expectRevert(descriptorError);
            vm.prank(USER);
            router.redeemToTokenExactInWithPermit(request, expiredPermit, noLegs);

            IBasketRouterTypes.Permit2Params memory expiredPermit2;
            expiredPermit2.permit = ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: address(core), amount: 4 ether}),
                nonce: 88,
                deadline: 9
            });
            expiredPermit2.signature = hex"01";
            vm.expectRevert(descriptorError);
            vm.prank(USER);
            router.redeemToTokenExactInWithPermit2(request, expiredPermit2, noLegs);

            assertEq(core.nonces(USER), 0);
            assertFalse(permit2.usedNonces(USER, 88));
            assertEq(core.safeRedeemCallCount(), 0);
        }

        function testLongUnapprovedAndFabricatedAdapterRoutesRevertAtomically() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.RedeemToTokenExactInParams memory params =
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 4 ether, outputToken: address(tokenC)});
            IBasketRouterTypes.RedemptionSwapLeg[] memory longLegs = new IBasketRouterTypes.RedemptionSwapLeg[](2);
            longLegs[0] = _leg(1, "");
            longLegs[1] = _leg(1, "");
            vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.QuoteLengthMismatch.selector, 2, 1));
            router.previewRedeemToTokenExactIn(params, longLegs);

            IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
            legs[0] = IBasketRouterTypes.RedemptionSwapLeg({adapter: address(0xBAD), minimumAmountOut: 1, data: ""});
            vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.AdapterNotApproved.selector, address(0xBAD)));
            router.previewRedeemToTokenExactIn(params, legs);

            legs[0] = _leg(2 ether, abi.encode(address(tokenC), 2 ether));
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview =
                router.previewRedeemToTokenExactIn(params, legs);
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 4 ether,
                outputToken: address(tokenC),
                recipient: RECIPIENT,
                minimumAmountOut: 2 ether,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            adapter.setFabricateOutput(true);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToTokenExactIn(request, legs);
            assertEq(core.balanceOf(USER), 100 ether);
            assertEq(tokenA.balanceOf(address(core)), 1_000 ether);
        }

        function testRedeemedEventIsSingleGenericPositiveOnlyOutcome() public {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](3);
            outputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: 2 ether
            });
            outputs[1] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC1155,
                token: address(core),
                id: uint256(uint160(address(0x1111))),
                amount: 0
            });
            outputs[2] = _shareOutput(3 ether);
            core.configureOutputs(outputs);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 5 ether, outputToken: address(tokenA)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 5 ether,
                outputToken: address(tokenA),
                recipient: RECIPIENT,
                minimumAmountOut: 2 ether,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            vm.recordLogs();
            vm.prank(USER);
            IBasketRouterTypes.AggregatedRedemptionResult memory result = router.redeemToTokenExactIn(request, noLegs);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            bytes32 redeemedTopic =
                keccak256("Redeemed(address,address,address,uint256,uint256,address[],uint256[],uint256,uint256)");
            uint256 outcomeCount;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics.length == 0 || logs[i].topics[0] != redeemedTopic) continue;
                ++outcomeCount;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), USER);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), RECIPIENT);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(tokenA));
                (
                    uint256 gross,
                    uint256 amountOut,
                    address[] memory recoveryAssets,
                    uint256[] memory recoveryAmounts,
                    uint256 protocolFee,
                    uint256 helperFee
                ) = abi.decode(logs[i].data, (uint256, uint256, address[], uint256[], uint256, uint256));
                assertEq(gross, 5 ether);
                assertEq(amountOut, 2 ether);
                assertEq(recoveryAssets.length, 1);
                assertEq(recoveryAssets[0], IMPAIRED_ASSET);
                assertEq(recoveryAmounts[0], 3 ether);
                assertEq(protocolFee, result.fees.protocolFeeCygld);
                assertEq(helperFee, result.fees.helperFeeCygld);
            }
            assertEq(outcomeCount, 1);
            assertEq(result.recoveryShareOutputs.length, 1, "zero share leaked into result");
        }

        function testHelperFeeFollowsAcceptedOwnerTransfer() public {
            address newOwner = address(0xD00D);
            vm.prank(OWNER);
            router.transferOwnership(newOwner);
            vm.prank(newOwner);
            router.acceptOwnership();
            vm.prank(newOwner);
            router.setHelperFeePpm(0, 5_000);

            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 100 ether, outputToken: address(tokenA)}),
                noLegs
            );
            IBasketRouterTypes.AggregatedRedemptionRequest memory request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: 100 ether,
                outputToken: address(tokenA),
                recipient: RECIPIENT,
                minimumAmountOut: 1,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            vm.prank(USER);
            IBasketRouterTypes.AggregatedRedemptionResult memory result = router.redeemToTokenExactIn(request, noLegs);
            assertEq(result.fees.helperFeeCygld, 0.5 ether);
            assertEq(core.balanceOf(newOwner), 0.5 ether);
            assertEq(core.balanceOf(OWNER), 0);
        }

        function testNativeAllowancePermitPermitConsumedAndPermit2Families() public {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(weth), id: 0, amount: 1 ether
            });
            core.configureOutputs(outputs);
            weth.mint(address(core), 4 ether);
            vm.deal(address(weth), 4 ether);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview =
                router.previewRedeemToNativeExactIn(2 ether, noLegs);
            IBasketRouterTypes.AggregatedNativeRedemptionRequest memory request =
                IBasketRouterTypes.AggregatedNativeRedemptionRequest({
                    grossCygldIn: 2 ether,
                    recipient: RECIPIENT,
                    minimumAmountOut: 1 ether,
                    expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
                });

            vm.prank(USER);
            router.redeemToNativeExactIn(request, noLegs);

            IBasketRouterTypes.PermitParams memory permit;
            permit.value = 2 ether;
            permit.deadline = block.timestamp + 1 days;
            vm.prank(USER);
            core.approve(address(router), 0);
            vm.prank(USER);
            router.redeemToNativeExactInWithPermit(request, permit, noLegs);

            core.mint(USER, 2 ether);
            vm.prank(USER);
            core.permit(USER, address(router), 2 ether, permit.deadline, 0, bytes32(0), bytes32(0));
            vm.prank(USER);
            router.redeemToNativeExactInWithPermit(request, permit, noLegs);

            core.mint(USER, 2 ether);
            IBasketRouterTypes.Permit2Params memory permit2Params;
            permit2Params.permit = ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: address(core), amount: 2 ether}),
                nonce: 99,
                deadline: block.timestamp + 1 days
            });
            permit2Params.signature = hex"01";
            vm.startPrank(USER);
            core.approve(address(router), 0);
            core.approve(address(permit2), type(uint256).max);
            router.redeemToNativeExactInWithPermit2(request, permit2Params, noLegs);
            vm.stopPrank();
            assertEq(RECIPIENT.balance, 4 ether);
        }

        function testExecutionRejectsInvalidRecipientsZeroTokenZeroInputAndMissingWrappedNative() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionRequest memory request =
                _boundTokenRequest(4 ether, address(tokenA), RECIPIENT, 1, noLegs);

            request.recipient = address(0);
            vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            request.recipient = address(router);
            vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            request.recipient = RECIPIENT;
            request.outputToken = address(0);
            vm.expectRevert(IBasketRouterTypes.ZeroAddress.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 0, outputToken: address(tokenA)}), noLegs
            );

            RouterRedeemFacet uninitializedFacet = new RouterRedeemFacet(address(permit2));
            vm.expectRevert(IBasketRouterTypes.WrappedNativeNotSet.selector);
            uninitializedFacet.previewRedeemToNativeExactIn(1, noLegs);
        }

        function testFinalAggregateAndPerLegMinimumsRemainIndependentBackstops() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionRequest memory direct =
                _boundTokenRequest(4 ether, address(tokenA), RECIPIENT, 3 ether, noLegs);
            vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.InsufficientOutput.selector, 3 ether, 2 ether));
            vm.prank(USER);
            router.redeemToTokenExactIn(direct, noLegs);

            IBasketRouterTypes.RedemptionSwapLeg[] memory legs = new IBasketRouterTypes.RedemptionSwapLeg[](1);
            legs[0] = _leg(2 ether, abi.encode(address(tokenC), 1 ether));
            IBasketRouterTypes.AggregatedRedemptionRequest memory swapped =
                _boundTokenRequest(4 ether, address(tokenC), RECIPIENT, 1, legs);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IBasketRouterTypes.InsufficientOutputForMinAmountOut.selector, address(tokenA), 2 ether, 1 ether
                )
            );
            vm.prank(USER);
            router.redeemToTokenExactIn(swapped, legs);
        }

        function testMalformedCorePreviewVectorsAreRejectedBeforeAcquisition() public {
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](0);
            core.configureOutputs(outputs);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 2 ether, outputToken: address(tokenA)}),
                noLegs
            );

            outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: 0
            });
            core.configureOutputs(outputs);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 2 ether, outputToken: address(tokenA)}),
                noLegs
            );

            outputs[0] =
                ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(0), id: 0, amount: 1
            });
            core.configureOutputs(outputs);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 2 ether, outputToken: address(tokenA)}),
                noLegs
            );

            outputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 1, amount: 1
            });
            core.configureOutputs(outputs);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 2 ether, outputToken: address(tokenA)}),
                noLegs
            );

            outputs = new ICoreRedemption.TokenAmount[](2);
            outputs[0] = _shareOutput(1);
            outputs[1] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: 1
            });
            core.configureOutputs(outputs);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 2 ether, outputToken: address(tokenA)}),
                noLegs
            );
        }

        function testSettledValidationRejectsInternalProjectionLengthMismatch() public {
            RedemptionValidationHarness harness = new RedemptionValidationHarness(address(permit2));
            ICoreRedemption.RedemptionQuote memory settled;
            settled.grossCygldIn = 1 ether;
            settled.netCygldIn = 1 ether;
            settled.outputs = new ICoreRedemption.TokenAmount[](1);
            settled.outputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: 1 ether
            });
            ICoreRedemption.RedemptionQuote memory projected;
            projected.grossCygldIn = 1 ether;
            projected.netCygldIn = 1 ether;
            projected.outputs = new ICoreRedemption.TokenAmount[](0);
            ICoreRedemption.TokenMinimum[] memory expected = new ICoreRedemption.TokenMinimum[](1);
            expected[0] = ICoreRedemption.TokenMinimum({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, minimumAmount: 1 ether
            });
            uint256[] memory balances = new uint256[](1);

            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            harness.validateSettled(address(core), 1 ether, projected, settled, expected, balances);
        }

        function testMaliciousCoreSettledVectorMutationsAreRejectedAtomically() public {
            _configureHealthy(2 ether, 1 ether);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.RedemptionSwapLeg[] memory oneLeg = new IBasketRouterTypes.RedemptionSwapLeg[](1);
            oneLeg[0] = _leg(1, abi.encode(address(tokenA), 1 ether));
            IBasketRouterTypes.AggregatedRedemptionRequest memory request =
                _boundTokenRequest(4 ether, address(tokenA), RECIPIENT, 1, oneLeg);

            core.setSafeRedeemReturnFault(1, 0, 1, false);
            vm.expectRevert(
                abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(2), uint256(1))
            );
            vm.prank(USER);
            router.redeemToTokenExactIn(request, oneLeg);

            ICoreRedemption.TokenMinimum[] memory shortened = new ICoreRedemption.TokenMinimum[](1);
            shortened[0] = request.expectedCoreOutputs[0];
            request.expectedCoreOutputs = shortened;
            core.setSafeRedeemReturnFault(1, 0, 1, true);
            vm.expectRevert(
                abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(1), uint256(2))
            );
            vm.prank(USER);
            router.redeemToTokenExactIn(request, oneLeg);

            request = _boundTokenRequest(4 ether, address(tokenA), RECIPIENT, 1, oneLeg);
            core.setSafeRedeemReturnFault(2, 0, uint256(uint160(address(tokenC))), false);
            vm.expectPartialRevert(ICoreRedemption.RedemptionOutputDescriptorMismatch.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, oneLeg);

            core.setSafeRedeemReturnFault(3, 0, 1 ether, false);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICoreRedemption.RedemptionOutputBelowMinimum.selector, uint256(0), 2 ether, 1 ether
                )
            );
            vm.prank(USER);
            router.redeemToTokenExactIn(request, oneLeg);

            core.setSafeRedeemReturnFault(4, 0, 99 ether, false);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, oneLeg);

            ICoreRedemption.TokenAmount[] memory shareOnly = new ICoreRedemption.TokenAmount[](1);
            shareOnly[0] = _shareOutput(2 ether);
            core.configureOutputs(shareOnly);
            request = _boundTokenRequest(4 ether, address(tokenA), RECIPIENT, 0, noLegs);
            core.setSafeRedeemReturnFault(3, 0, 3 ether, false);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            assertEq(core.balanceOf(USER), 100 ether, "malicious Core return must roll back payer debit");
            assertEq(tokenA.balanceOf(RECIPIENT), 0, "malicious Core return must roll back payout");
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 0, "malicious Core return must roll back shares");
        }

        function testMaliciousRecoveryMintAndForwardingAccountingIsRejected() public {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = _shareOutput(2 ether);
            core.configureOutputs(outputs);
            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionRequest memory request =
                _boundTokenRequest(4 ether, address(tokenA), RECIPIENT, 0, noLegs);

            core.setShareCallbackShapeFault(true, false);
            vm.expectPartialRevert(IBasketRouterTypes.RecoveryShareBatchMismatch.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            core.setShareCallbackShapeFault(false, true);
            vm.expectPartialRevert(IBasketRouterTypes.RecoveryShareBatchMismatch.selector);
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            core.setShareCallbackShapeFault(false, false);
            core.setShareTransferFault(true, false);
            vm.expectRevert(
                abi.encodeWithSelector(IBasketRouterTypes.RecoveryShareDebitMismatch.selector, SHARE_ID, 0, 2 ether)
            );
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);

            core.setShareTransferFault(false, true);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IBasketRouterTypes.RecoveryShareRecipientCreditMismatch.selector, SHARE_ID, RECIPIENT, 2 ether, 0
                )
            );
            vm.prank(USER);
            router.redeemToTokenExactIn(request, noLegs);
        }

        function testRecoveryReceiptCannotBeArmedOverAnExistingContext() public {
            RecoveryReceiptHarness harness = new RecoveryReceiptHarness(address(permit2));
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](1);
            outputs[0] = _shareOutput(2 ether);
            harness.arm(address(core), RECIPIENT, outputs);

            vm.expectRevert(
                abi.encodeWithSelector(IBasketRouterTypes.RecoveryShareReceiptStateInvalid.selector, uint8(0), uint8(1))
            );
            harness.arm(address(core), RECIPIENT, outputs);
        }

        function testDirectBasketExactInDeliversCompleteMixedVectorAndEmitsOnce() public {
            _configureMixed(4 ether, 3 ether, 2 ether);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory preview =
                router.previewRedeemToBasketExactIn(10 ether);
            assertEq(preview.projectedCoreOutputs.length, 3);
            assertEq(preview.projectedCoreOutputs[0].amount, 4 ether);
            assertEq(preview.projectedCoreOutputs[1].amount, 3 ether);
            assertEq(preview.projectedCoreOutputs[2].amount, 2 ether);

            IBasketRouterTypes.BasketRedemptionRequest memory request = IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: 10 ether,
                recipient: RECIPIENT,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            vm.recordLogs();
            vm.prank(USER);
            IBasketRouterTypes.BasketRedemptionResult memory result = router.redeemToBasketExactIn(request);

            assertEq(result.outputs.length, 3);
            assertEq(tokenA.balanceOf(RECIPIENT), 4 ether);
            assertEq(tokenB.balanceOf(RECIPIENT), 3 ether);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 2 ether);
            assertEq(tokenA.balanceOf(address(router)), 0);
            assertEq(tokenB.balanceOf(address(router)), 0);
            assertEq(core.balanceOf(address(router), SHARE_ID), 0);
            _assertOneRedeemedToBasket(vm.getRecordedLogs(), result, 10 ether);
        }

        function testDirectBasketExactOutPreviewConstructsExactInExecution() public {
            vm.prank(OWNER);
            router.setHelperFeePpm(0, 5_000);
            _configureMixed(2 ether, 0, 3 ether);
            core.setExactOutGrossCygldIn(8 ether);

            ICoreRedemption.TokenMinimum[] memory desired = new ICoreRedemption.TokenMinimum[](3);
            desired[0] = ICoreRedemption.TokenMinimum({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, minimumAmount: 1 ether
            });
            desired[1] = ICoreRedemption.TokenMinimum({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenB), id: 0, minimumAmount: 0
            });
            desired[2] = ICoreRedemption.TokenMinimum({
                kind: ICoreRedemption.TokenKind.ERC1155, token: address(core), id: SHARE_ID, minimumAmount: 2 ether
            });
            IBasketRouterTypes.BasketRedemptionExactOutPreview memory preview =
                router.previewRedeemToBasketExactOut(desired);
            assertGt(preview.grossCygldIn, 8 ether);
            assertEq(preview.grossCygldIn - preview.fees.helperFeeCygld, 8 ether);
            assertEq(preview.projectedCoreOutputs.length, 3);

            IBasketRouterTypes.BasketRedemptionExactInPreview memory exactIn =
                router.previewRedeemToBasketExactIn(preview.grossCygldIn);
            assertEq(
                keccak256(abi.encode(exactIn.projectedCoreOutputs)), keccak256(abi.encode(preview.projectedCoreOutputs))
            );
            assertEq(exactIn.fees.helperFeeCygld, preview.fees.helperFeeCygld);

            uint256 payerBefore = core.balanceOf(USER);
            vm.prank(USER);
            IBasketRouterTypes.BasketRedemptionResult memory result = router.redeemToBasketExactIn(
                IBasketRouterTypes.BasketRedemptionRequest({
                    grossCygldIn: preview.grossCygldIn,
                    recipient: RECIPIENT,
                    expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
                })
            );
            assertEq(payerBefore - core.balanceOf(USER), preview.grossCygldIn);
            assertEq(core.balanceOf(OWNER), preview.fees.helperFeeCygld);
            assertEq(result.outputs[0].amount, 2 ether);
            assertEq(result.outputs[1].amount, 0);
            assertEq(result.outputs[2].amount, 3 ether);
        }

        function testDirectBasketSupportsAllowanceFreshAndConsumedPermitAndPermit2() public {
            _configureHealthy(1 ether, 0);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory preview = router.previewRedeemToBasketExactIn(
                2 ether
            );
            IBasketRouterTypes.BasketRedemptionRequest memory request = IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: 2 ether,
                recipient: RECIPIENT,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });

            vm.prank(USER);
            router.redeemToBasketExactIn(request);

            IBasketRouterTypes.PermitParams memory permit;
            permit.value = 2 ether;
            permit.deadline = block.timestamp + 1 days;
            vm.prank(USER);
            core.approve(address(router), 0);
            vm.prank(USER);
            router.redeemToBasketExactInWithPermit(request, permit);
            assertEq(core.nonces(USER), 1);

            vm.prank(USER);
            core.permit(USER, address(router), 2 ether, permit.deadline, 0, bytes32(0), bytes32(0));
            uint256 consumedNonce = core.nonces(USER);
            vm.prank(USER);
            router.redeemToBasketExactInWithPermit(request, permit);
            assertEq(core.nonces(USER), consumedNonce, "pre-consumed permit should use its live allowance");

            IBasketRouterTypes.Permit2Params memory permit2Params;
            permit2Params.permit = ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({token: address(core), amount: 2 ether}),
                nonce: 77,
                deadline: block.timestamp + 1 days
            });
            permit2Params.signature = hex"01";
            vm.startPrank(USER);
            core.approve(address(router), 0);
            core.approve(address(permit2), type(uint256).max);
            router.redeemToBasketExactInWithPermit2(request, permit2Params);
            vm.stopPrank();

            assertEq(tokenA.balanceOf(RECIPIENT), 4 ether);
            assertEq(core.balanceOf(USER), 92 ether);
            assertTrue(permit2.usedNonces(USER, 77));
        }

        function testDirectBasketRequiresCompleteDescriptorAndMinimumBindingBeforePull() public {
            _configureHealthy(2 ether, 1 ether);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory preview = router.previewRedeemToBasketExactIn(
                4 ether
            );
            IBasketRouterTypes.BasketRedemptionRequest memory request = IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: 4 ether,
                recipient: RECIPIENT,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            uint256 payerBefore = core.balanceOf(USER);

            ICoreRedemption.TokenMinimum[] memory shortened = new ICoreRedemption.TokenMinimum[](1);
            shortened[0] = request.expectedCoreOutputs[0];
            request.expectedCoreOutputs = shortened;
            vm.expectRevert(
                abi.encodeWithSelector(ICoreRedemption.RedemptionOutputsLengthMismatch.selector, uint256(1), uint256(2))
            );
            vm.prank(USER);
            router.redeemToBasketExactIn(request);

            request.expectedCoreOutputs = _minimums(preview.projectedCoreOutputs);
            request.expectedCoreOutputs[0].token = address(tokenB);
            vm.expectPartialRevert(ICoreRedemption.RedemptionOutputDescriptorMismatch.selector);
            vm.prank(USER);
            router.redeemToBasketExactIn(request);

            request.expectedCoreOutputs[0].token = address(tokenA);
            request.expectedCoreOutputs[0].minimumAmount = 3 ether;
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICoreRedemption.RedemptionOutputBelowMinimum.selector, uint256(0), 3 ether, 2 ether
                )
            );
            vm.prank(USER);
            router.redeemToBasketExactIn(request);

            assertEq(core.balanceOf(USER), payerBefore);
            assertEq(core.safeRedeemCallCount(), 0);
        }

        function testDirectBasketStructuralZeroUnreadableAndAllZeroBehavior() public {
            address unreadableToken = address(0xBADD);
            ICoreRedemption.TokenAmount[] memory zeroUnreadable = new ICoreRedemption.TokenAmount[](2);
            zeroUnreadable[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: 2 ether
            });
            zeroUnreadable[1] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: unreadableToken, id: 0, amount: 0
            });
            core.configureOutputs(zeroUnreadable);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory valid = router.previewRedeemToBasketExactIn(
                4 ether
            );
            assertEq(valid.projectedCoreOutputs[1].amount, 0, "structural zero must remain in the vector");
            IBasketRouterTypes.BasketRedemptionRequest memory directRequest = IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: 4 ether, recipient: RECIPIENT, expectedCoreOutputs: _minimums(valid.projectedCoreOutputs)
            });
            vm.prank(USER);
            router.redeemToBasketExactIn(directRequest);

            IBasketRouterTypes.RedemptionSwapLeg[] memory noLegs = new IBasketRouterTypes.RedemptionSwapLeg[](0);
            IBasketRouterTypes.AggregatedRedemptionPreview memory aggregated = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: 4 ether, outputToken: address(tokenA)}),
                noLegs
            );
            vm.prank(USER);
            router.redeemToTokenExactIn(
                IBasketRouterTypes.AggregatedRedemptionRequest({
                    grossCygldIn: 4 ether,
                    outputToken: address(tokenA),
                    recipient: RECIPIENT,
                    minimumAmountOut: 2 ether,
                    expectedCoreOutputs: _minimums(aggregated.projectedCoreOutputs)
                }),
                noLegs
            );
            assertEq(tokenA.balanceOf(RECIPIENT), 4 ether, "zero unreadable leg blocked a valid payout");

            directRequest.expectedCoreOutputs[1].minimumAmount = 1;
            uint256 payerBeforeMinimumFailure = core.balanceOf(USER);
            vm.expectRevert(
                abi.encodeWithSelector(
                    ICoreRedemption.RedemptionOutputBelowMinimum.selector, uint256(1), uint256(1), uint256(0)
                )
            );
            vm.prank(USER);
            router.redeemToBasketExactIn(directRequest);
            vm.expectPartialRevert(ICoreRedemption.RedemptionOutputBelowMinimum.selector);
            router.previewRedeemToBasketExactOut(directRequest.expectedCoreOutputs);
            assertEq(core.balanceOf(USER), payerBeforeMinimumFailure);

            ICoreRedemption.TokenAmount[] memory allZero = new ICoreRedemption.TokenAmount[](1);
            allZero[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: 0
            });
            core.configureOutputs(allZero);
            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            router.previewRedeemToBasketExactIn(4 ether);

            ICoreRedemption.TokenAmount[] memory unreadable = new ICoreRedemption.TokenAmount[](1);
            unreadable[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: unreadableToken, id: 0, amount: 1 ether
            });
            core.configureOutputs(unreadable);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory unreadablePreview =
                router.previewRedeemToBasketExactIn(4 ether);
            IBasketRouterTypes.BasketRedemptionRequest memory request = IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: 4 ether,
                recipient: RECIPIENT,
                expectedCoreOutputs: _minimums(unreadablePreview.projectedCoreOutputs)
            });
            uint256 payerBefore = core.balanceOf(USER);
            uint256 callsBefore = core.safeRedeemCallCount();
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToBasketExactIn(request);
            assertEq(core.balanceOf(USER), payerBefore, "unreadable output must roll back CYGLD ingress");
            assertEq(core.safeRedeemCallCount(), callsBefore);
        }

        function testDirectBasketRejectsZeroToPositiveErc20DriftWithoutAStoredBaseline() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory preview = router.previewRedeemToBasketExactIn(
                4 ether
            );
            IBasketRouterTypes.BasketRedemptionRequest memory request = IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: 4 ether,
                recipient: RECIPIENT,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            IBasketRouterTypes.PermitParams memory permit;
            permit.value = 4 ether;
            permit.deadline = block.timestamp + 1 days;
            vm.prank(USER);
            core.approve(address(router), 0);
            core.setPermitDrift(1, 1 ether, true);

            vm.expectRevert(IBasketRouterTypes.CoreRedemptionResultMismatch.selector);
            vm.prank(USER);
            router.redeemToBasketExactInWithPermit(request, permit);
            assertEq(core.balanceOf(USER), 100 ether);
            assertEq(tokenB.balanceOf(address(core)), 1_000 ether);
            assertEq(tokenB.balanceOf(address(router)), 0);
            assertEq(core.nonces(USER), 0);
        }

        function testDirectBasketPermitTimeDriftAndMissingOrDoubleCallbackRollback() public {
            _configureHealthy(2 ether, 0);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory preview = router.previewRedeemToBasketExactIn(
                4 ether
            );
            IBasketRouterTypes.BasketRedemptionRequest memory request = IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: 4 ether,
                recipient: RECIPIENT,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            IBasketRouterTypes.PermitParams memory permit;
            permit.value = 4 ether;
            permit.deadline = block.timestamp + 1 days;
            vm.prank(USER);
            core.approve(address(router), 0);
            core.setPermitDrift(0, 1 ether, true);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToBasketExactInWithPermit(request, permit);
            assertEq(core.balanceOf(USER), 100 ether);
            assertEq(core.nonces(USER), 0);

            core.setPermitDrift(0, 0, false);
            ICoreRedemption.TokenAmount[] memory shareOnly = new ICoreRedemption.TokenAmount[](1);
            shareOnly[0] = _shareOutput(2 ether);
            core.configureOutputs(shareOnly);
            preview = router.previewRedeemToBasketExactIn(4 ether);
            request.expectedCoreOutputs = _minimums(preview.projectedCoreOutputs);
            vm.prank(USER);
            core.approve(address(router), type(uint256).max);

            core.setShareMintFault(true, 0);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToBasketExactIn(request);

            core.setShareMintFault(false, 0);
            core.setCallbackFault("", address(0), address(0), true);
            vm.expectRevert();
            vm.prank(USER);
            router.redeemToBasketExactIn(request);
            assertEq(core.balanceOf(USER), 100 ether);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 0);
        }

        function testDirectBasketPreservesPreexistingCygldErc20AndShareBalances() public {
            core.mint(address(router), 11 ether);
            tokenA.mint(address(router), 9 ether);
            tokenB.mint(address(router), 7 ether);
            core.primeShare(address(router), SHARE_ID, 6 ether);
            _configureMixed(2 ether, 1 ether, 3 ether);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory preview = router.previewRedeemToBasketExactIn(
                5 ether
            );
            vm.prank(USER);
            router.redeemToBasketExactIn(
                IBasketRouterTypes.BasketRedemptionRequest({
                    grossCygldIn: 5 ether,
                    recipient: RECIPIENT,
                    expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
                })
            );

            assertEq(core.balanceOf(address(router)), 11 ether);
            assertEq(tokenA.balanceOf(address(router)), 9 ether);
            assertEq(tokenB.balanceOf(address(router)), 7 ether);
            assertEq(core.balanceOf(address(router), SHARE_ID), 6 ether);
            assertEq(tokenA.balanceOf(RECIPIENT), 2 ether);
            assertEq(tokenB.balanceOf(RECIPIENT), 1 ether);
            assertEq(core.balanceOf(RECIPIENT, SHARE_ID), 3 ether);
        }

        function testDirectBasketRejectsUnsupportedRecipientsAndZeroInput() public {
            _configureHealthy(1 ether, 0);
            IBasketRouterTypes.BasketRedemptionExactInPreview memory preview = router.previewRedeemToBasketExactIn(
                2 ether
            );
            IBasketRouterTypes.BasketRedemptionRequest memory request = IBasketRouterTypes.BasketRedemptionRequest({
                grossCygldIn: 2 ether,
                recipient: address(0),
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
            vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
            vm.prank(USER);
            router.redeemToBasketExactIn(request);

            request.recipient = address(router);
            vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
            vm.prank(USER);
            router.redeemToBasketExactIn(request);

            request.recipient = RECIPIENT;
            request.grossCygldIn = 0;
            vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
            vm.prank(USER);
            router.redeemToBasketExactIn(request);
            vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
            router.previewRedeemToBasketExactIn(0);
        }

        function _configureHealthy(uint256 amountA, uint256 amountB) private {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](2);
            outputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: amountA
            });
            outputs[1] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenB), id: 0, amount: amountB
            });
            core.configureOutputs(outputs);
        }

        function _boundTokenRequest(
            uint256 grossCygldIn,
            address outputToken,
            address recipient,
            uint256 minimumAmountOut,
            IBasketRouterTypes.RedemptionSwapLeg[] memory legs
        ) private view returns (IBasketRouterTypes.AggregatedRedemptionRequest memory request) {
            IBasketRouterTypes.AggregatedRedemptionPreview memory preview = router.previewRedeemToTokenExactIn(
                IBasketRouterTypes.RedeemToTokenExactInParams({grossCygldIn: grossCygldIn, outputToken: outputToken}),
                legs
            );
            request = IBasketRouterTypes.AggregatedRedemptionRequest({
                grossCygldIn: grossCygldIn,
                outputToken: outputToken,
                recipient: recipient,
                minimumAmountOut: minimumAmountOut,
                expectedCoreOutputs: _minimums(preview.projectedCoreOutputs)
            });
        }

        function _configureMixed(uint256 amountA, uint256 amountB, uint256 shareAmount) private {
            ICoreRedemption.TokenAmount[] memory outputs = new ICoreRedemption.TokenAmount[](3);
            outputs[0] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenA), id: 0, amount: amountA
            });
            outputs[1] = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC20, token: address(tokenB), id: 0, amount: amountB
            });
            outputs[2] = _shareOutput(shareAmount);
            core.configureOutputs(outputs);
        }

        function _shareOutput(uint256 amount) private view returns (ICoreRedemption.TokenAmount memory output) {
            output = ICoreRedemption.TokenAmount({
                kind: ICoreRedemption.TokenKind.ERC1155, token: address(core), id: SHARE_ID, amount: amount
            });
        }

        function _minimums(ICoreRedemption.TokenAmount[] memory outputs)
            private
            pure
            returns (ICoreRedemption.TokenMinimum[] memory minimums)
        {
            minimums = new ICoreRedemption.TokenMinimum[](outputs.length);
            for (uint256 i; i < outputs.length; ++i) {
                minimums[i] = ICoreRedemption.TokenMinimum({
                    kind: outputs[i].kind, token: outputs[i].token, id: outputs[i].id, minimumAmount: outputs[i].amount
                });
            }
        }

        function _leg(uint256 minimumAmountOut, bytes memory data)
            private
            view
            returns (IBasketRouterTypes.RedemptionSwapLeg memory leg)
        {
            leg = IBasketRouterTypes.RedemptionSwapLeg({
                adapter: address(adapter), minimumAmountOut: minimumAmountOut, data: data
            });
        }

        function _assertOneRedeemedToBasket(
            Vm.Log[] memory logs,
            IBasketRouterTypes.BasketRedemptionResult memory result,
            uint256 expectedGrossCygldIn
        ) private pure {
            bytes32 eventTopic = keccak256(
                "RedeemedToBasket(address,address,uint256,uint8[],address[],uint256[],uint256[],uint256,uint256)"
            );
            uint256 count;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics.length != 3 || logs[i].topics[0] != eventTopic) continue;
                ++count;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), USER);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), RECIPIENT);
                (
                    uint256 grossCygldIn,
                    ICoreRedemption.TokenKind[] memory kinds,
                    address[] memory tokens,
                    uint256[] memory ids,
                    uint256[] memory amounts,
                    uint256 protocolFeeCygld,
                    uint256 helperFeeCygld
                ) = abi.decode(
                    logs[i].data,
                    (uint256, ICoreRedemption.TokenKind[], address[], uint256[], uint256[], uint256, uint256)
                );
                assertEq(grossCygldIn, expectedGrossCygldIn);
                assertEq(kinds.length, result.outputs.length);
                for (uint256 j; j < kinds.length; ++j) {
                    assertEq(uint8(kinds[j]), uint8(result.outputs[j].kind));
                    assertEq(tokens[j], result.outputs[j].token);
                    assertEq(ids[j], result.outputs[j].id);
                    assertEq(amounts[j], result.outputs[j].amount);
                }
                assertEq(protocolFeeCygld, result.fees.protocolFeeCygld);
                assertEq(helperFeeCygld, result.fees.helperFeeCygld);
            }
            assertEq(count, 1);
        }
    }
