// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";

import {IBasketRouterTypes} from "../src/interfaces/IBasketRouterTypes.sol";
import {ISwapAdapter} from "../src/interfaces/ISwapAdapter.sol";
import {LibAppStorage} from "../src/diamond/LibAppStorage.sol";
import {LibDiamond} from "diamond-1/libraries/LibDiamond.sol";
import {RouterIssueFacet} from "../src/facets/RouterIssueFacet.sol";
import {RouterIssueBasketFacet} from "../src/facets/RouterIssueBasketFacet.sol";
import {RouterIssuePreviewFacet} from "../src/facets/RouterIssuePreviewFacet.sol";

contract IssueTestToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) public {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "burn balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

    contract IssuePermitToken is IssueTestToken, IERC20Permit {
        enum PermitBehavior {
            Success,
            EmptyRevert,
            ReasonRevert,
            NoAllowance
        }

        PermitBehavior public permitBehavior;
        mapping(address => uint256) public override nonces;

        constructor() IssueTestToken("Permit token", "PERMIT") {}

        function setPermitBehavior(PermitBehavior behavior) external {
            permitBehavior = behavior;
        }

        function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32)
            external
            override
        {
            if (permitBehavior == PermitBehavior.EmptyRevert) {
                assembly ("memory-safe") {
                    revert(0, 0)
                }
            }
            if (permitBehavior == PermitBehavior.ReasonRevert) revert("permit failure");
            if (permitBehavior == PermitBehavior.NoAllowance) return;
            allowance[owner][spender] = value;
            ++nonces[owner];
            emit Approval(owner, spender, value);
        }

        function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
            return keccak256("IssuePermitToken");
        }
    }

        contract IssueMalformedToken is IssueTestToken {
            enum TransferMode {
                Standard,
                CreditWithoutPayerDebit,
                PayerDebitAndRouterLoss,
                CreditWithoutRouterDebit,
                RouterDebitWithoutCredit
            }

            TransferMode public transferMode;

            constructor() IssueTestToken("Malformed token", "MAL") {}

            function setTransferMode(TransferMode mode) external {
                transferMode = mode;
            }

            function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
                if (transferMode == TransferMode.Standard) return super.transferFrom(from, to, amount);
                uint256 allowed = allowance[from][msg.sender];
                require(allowed >= amount, "allowance");
                if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

                if (transferMode == TransferMode.CreditWithoutPayerDebit) {
                    balanceOf[to] += amount;
                    emit Transfer(from, to, amount);
                    return true;
                }
                if (transferMode == TransferMode.PayerDebitAndRouterLoss) {
                    require(balanceOf[from] >= amount && balanceOf[to] != 0, "balance");
                    balanceOf[from] -= amount;
                    balanceOf[to] -= 1;
                    emit Transfer(from, address(0), amount);
                    emit Transfer(to, address(0), 1);
                    return true;
                }
                return super.transferFrom(from, to, amount);
            }

            function transfer(address to, uint256 amount) public override returns (bool) {
                if (transferMode == TransferMode.CreditWithoutRouterDebit) {
                    balanceOf[to] += amount;
                    emit Transfer(msg.sender, to, amount);
                    return true;
                }
                if (transferMode == TransferMode.RouterDebitWithoutCredit) {
                    require(balanceOf[msg.sender] >= amount, "balance");
                    balanceOf[msg.sender] -= amount;
                    emit Transfer(msg.sender, address(0), amount);
                    return true;
                }
                return super.transfer(to, amount);
            }
        }

        contract IssueRejectNative {
            receive() external payable {
                revert("reject native");
            }
        }

        contract IssueTestWeth is IssueTestToken {
            constructor() IssueTestToken("Wrapped native", "WNATIVE") {}

            function deposit() external payable {
                mint(msg.sender, msg.value);
            }

            function withdraw(uint256 amount) external {
                require(balanceOf[msg.sender] >= amount, "balance");
                balanceOf[msg.sender] -= amount;
                totalSupply -= amount;
                emit Transfer(msg.sender, address(0), amount);
                (bool sent,) = msg.sender.call{value: amount}("");
                require(sent, "native");
            }

            receive() external payable {}
        }

        contract IssueTestPermit2 is ISignatureTransfer {
            using SafeERC20 for IERC20;

            mapping(address => mapping(uint256 => bool)) public used;
            IssueTestCore public batchDriftCore;
            uint256 public batchDriftFirst;
            uint256 public batchDriftSecond;
            bool public batchDriftEnabled;

            function setBatchDrift(IssueTestCore core, uint256 first, uint256 second) external {
                batchDriftCore = core;
                batchDriftFirst = first;
                batchDriftSecond = second;
                batchDriftEnabled = true;
            }

            function clearBatchDrift() external {
                batchDriftEnabled = false;
            }

            function permitTransferFrom(
                PermitTransferFrom memory permit,
                SignatureTransferDetails calldata details,
                address owner,
                bytes calldata
            ) external override {
                require(!used[owner][permit.nonce], "nonce");
                // forge-lint: disable-next-line(block-timestamp)
                require(permit.deadline >= block.timestamp, "expired");
                require(permit.permitted.amount >= details.requestedAmount, "amount");
                used[owner][permit.nonce] = true;
                IERC20(permit.permitted.token).safeTransferFrom(owner, details.to, details.requestedAmount);
            }

            function permitWitnessTransferFrom(
                PermitTransferFrom memory,
                SignatureTransferDetails calldata,
                address,
                bytes32,
                string calldata,
                bytes calldata
            ) external pure override {
                revert("unused");
            }

            function permitTransferFrom(
                PermitBatchTransferFrom memory permit,
                SignatureTransferDetails[] calldata details,
                address owner,
                bytes calldata
            ) external override {
                require(!used[owner][permit.nonce], "nonce");
                // forge-lint: disable-next-line(block-timestamp)
                require(permit.deadline >= block.timestamp, "expired");
                require(permit.permitted.length == details.length, "length");
                used[owner][permit.nonce] = true;
                for (uint256 i; i < permit.permitted.length; ++i) {
                    require(permit.permitted[i].amount >= details[i].requestedAmount, "amount");
                    IERC20(permit.permitted[i].token).safeTransferFrom(owner, details[i].to, details[i].requestedAmount);
                }
                if (batchDriftEnabled) batchDriftCore.setCurrentInputs(batchDriftFirst, batchDriftSecond);
            }

            function permitWitnessTransferFrom(
                PermitBatchTransferFrom memory,
                SignatureTransferDetails[] calldata,
                address,
                bytes32,
                string calldata,
                bytes calldata
            ) external pure override {
                revert("unused");
            }

            function nonceBitmap(address, uint256) external pure override returns (uint256) {
                return 0;
            }

            function invalidateUnorderedNonces(uint256, uint256) external pure override {}

            function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
                return keccak256("IssueTestPermit2");
            }
        }

        contract IssueTestCore is IssueTestToken {
            using SafeERC20 for IERC20;

            address[] private _assets;
            uint256[] private _targetsPpm;
            uint256[] private _currentInputs;
            uint256 public protocolFeeCygld = 0.2 ether;
            address public protocolTreasury = address(0xC011EC7);
            uint256 public safeIssueCallCount;
            uint256[] private _lastMaximumInputs;
            uint8 public returnMode;
            bool public forceExactInZero;
            bool public safeProtocolFeeOverrideEnabled;
            uint256 public safeProtocolFeeOverride;

            constructor(address assetA, address assetB) IssueTestToken("CyberGold", "CYGLD") {
                _assets.push(assetA);
                _assets.push(assetB);
                _targetsPpm.push(500_000);
                _targetsPpm.push(500_000);
                _currentInputs.push(5 ether);
                _currentInputs.push(5 ether);
            }

            function basketAssets() external view returns (address[] memory) {
                return _assets;
            }

            function basketTargetsPpm() external view returns (uint256[] memory) {
                return _targetsPpm;
            }

            function setTargetsPpm(uint256 first, uint256 second) external {
                _targetsPpm[0] = first;
                _targetsPpm[1] = second;
            }

            function clearTargetsPpm() external {
                delete _targetsPpm;
            }

            function setCurrentInputs(uint256 first, uint256 second) external {
                _currentInputs[0] = first;
                _currentInputs[1] = second;
            }

            function clearAssets() external {
                delete _assets;
            }

            function setForceExactInZero(bool force) external {
                forceExactInZero = force;
            }

            function currentInputs() external view returns (uint256[] memory) {
                return _currentInputs;
            }

            function lastMaximumInputs() external view returns (uint256[] memory) {
                return _lastMaximumInputs;
            }

            function setReturnMode(uint8 mode) external {
                returnMode = mode;
            }

            function setSafeProtocolFeeOverride(uint256 fee, bool enabled) external {
                safeProtocolFeeOverride = fee;
                safeProtocolFeeOverrideEnabled = enabled;
            }

            function previewIssueFromBasketExactOut(uint256 netCygldOut)
                external
                view
                returns (uint256, uint256[] memory amountsIn, address[] memory assets)
            {
                require(netCygldOut != 0, "zero");
                return (protocolFeeCygld, _currentInputs, _assets);
            }

            function previewIssueFromBasketExactIn(uint256[] calldata maximumInputs)
                external
                view
                returns (uint256 netCygldOut, uint256, uint256[] memory amountsIn, address[] memory assets)
            {
                require(maximumInputs.length == 2, "length");
                netCygldOut = type(uint256).max;
                for (uint256 i; i < 2; ++i) {
                    uint256 targetPpm = _targetsPpm[i];
                    if (targetPpm == 0) continue;
                    uint256 candidate = maximumInputs[i] * 1_000_000 / targetPpm;
                    if (candidate < netCygldOut) netCygldOut = candidate;
                }
                if (netCygldOut == type(uint256).max) netCygldOut = 0;
                if (forceExactInZero) netCygldOut = 0;
                amountsIn = new uint256[](2);
                amountsIn[0] = netCygldOut * _targetsPpm[0] / 1_000_000;
                amountsIn[1] = netCygldOut * _targetsPpm[1] / 1_000_000;
                return (netCygldOut, protocolFeeCygld, amountsIn, _assets);
            }

            function safeIssue(uint256 netCygldOut, address[] calldata expectedAssets, uint256[] calldata maximumInputs)
                external
                returns (uint256, uint256[] memory amountsIn)
            {
                require(expectedAssets.length == 2 && maximumInputs.length == 2, "length");
                for (uint256 i; i < 2; ++i) {
                    require(expectedAssets[i] == _assets[i], "asset");
                    require(_currentInputs[i] <= maximumInputs[i], "max");
                    IERC20(_assets[i]).safeTransferFrom(msg.sender, address(this), _currentInputs[i]);
                }
                _lastMaximumInputs = maximumInputs;
                ++safeIssueCallCount;
                amountsIn = _currentInputs;
                mint(msg.sender, netCygldOut);
                mint(protocolTreasury, protocolFeeCygld);
                if (returnMode == 1) {
                    amountsIn = new uint256[](2);
                    amountsIn[0] = maximumInputs[0] + 1;
                    amountsIn[1] = _currentInputs[1];
                } else if (returnMode == 2) {
                    amountsIn = new uint256[](2);
                    amountsIn[0] = _currentInputs[0] - 1;
                    amountsIn[1] = _currentInputs[1];
                } else if (returnMode == 3) {
                    amountsIn = new uint256[](1);
                    amountsIn[0] = _currentInputs[0];
                }
                return (safeProtocolFeeOverrideEnabled ? safeProtocolFeeOverride : protocolFeeCygld, amountsIn);
            }
        }

        contract IssueTestAdapter is ISwapAdapter {
            using SafeERC20 for IERC20;

            uint256 public swapCallCount;
            IssueTestCore public driftCore;
            uint256 public driftFirst;
            uint256 public driftSecond;
            bool public driftEnabled;
            uint256 public reportedAmount;
            bool public reportedAmountEnabled;
            uint256 public extraInputDebit;

            function setDrift(IssueTestCore core, uint256 first, uint256 second) external {
                driftCore = core;
                driftFirst = first;
                driftSecond = second;
                driftEnabled = true;
            }

            function clearDrift() external {
                driftEnabled = false;
            }

            function setReportedAmount(uint256 amount) external {
                reportedAmount = amount;
                reportedAmountEnabled = true;
            }

            function clearReportedAmount() external {
                reportedAmountEnabled = false;
            }

            function setExtraInputDebit(uint256 amount) external {
                extraInputDebit = amount;
            }

            function swap(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
                external
                override
                returns (uint256 amountOut)
            {
                ++swapCallCount;
                uint256 refundInput;
                (amountOut, refundInput) = abi.decode(data, (uint256, uint256));
                require(refundInput <= amountIn, "refund");
                IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
                if (refundInput != 0) IERC20(tokenIn).safeTransfer(msg.sender, refundInput);
                IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
                if (extraInputDebit != 0) IssueTestToken(tokenIn).burn(msg.sender, extraInputDebit);
                if (driftEnabled) driftCore.setCurrentInputs(driftFirst, driftSecond);
                if (reportedAmountEnabled) amountOut = reportedAmount;
            }
        }

        contract IssueFacetHarness is RouterIssueFacet {
            using EnumerableSet for EnumerableSet.AddressSet;

            constructor(address permit2_) RouterIssueFacet(permit2_) {}

            function configure(
                address owner,
                address core,
                address wrappedNative,
                address adapter,
                uint256 helperFeePpm
            ) external {
                LibAppStorage.RouterStorage storage rs = LibAppStorage.routerStorage();
                rs.coreDiamond = core;
                rs.wrappedNative = wrappedNative;
                rs.helperFeePpm = helperFeePpm;
                rs.approvedAdapters.add(adapter);
                LibDiamond.setContractOwner(owner);
            }

            function setWrappedNativeForTest(address wrappedNative) external {
                LibAppStorage.routerStorage().wrappedNative = wrappedNative;
            }

            function acquireWithPermitForTest(address token, uint256 amount, PermitParams calldata permit) external {
                _acquireWithPermit(msg.sender, IERC20(token), amount, _copyPermit(permit));
            }

            function requireExactPayerDebitForTest(uint256 beforeBalance, uint256 afterBalance, uint256 expected)
                external
                pure
            {
                _requireExactPayerDebit(address(0x1), address(0x2), beforeBalance, afterBalance, expected);
            }

            function requireExactTokenCreditForTest(uint256 beforeBalance, uint256 afterBalance, uint256 expected)
                external
                pure
            {
                _requireExactTokenCredit(address(0x1), beforeBalance, afterBalance, expected);
            }

            function validateOrderedAssetsForTest(address[] memory provided, address[] memory actual) external pure {
                _validateOrderedBasketAssets(provided, actual);
            }

            function validateCoreAmountsForTest(address[] memory assets, uint256[] memory amounts) external pure {
                _validateCoreBasketAmounts(assets, amounts);
            }

            function loadBasketAssetsForTest() external view returns (address[] memory assets) {
                return _loadBasketAssets();
            }

            function requireBoundedInputsForTest(
                address[] memory assets,
                uint256[] memory maximumAmounts,
                uint256[] memory actualAmounts,
                uint256[] memory balancesBefore
            ) external view {
                _requireBoundedCoreInputDebits(assets, maximumAmounts, actualAmounts, balancesBefore);
            }

            function payoutNativeForTest(address to, address wrappedNative, uint256 amount) external {
                _payoutNative(to, wrappedNative, amount);
            }

            function payoutTokenForTest(address to, address token, bool isNative, uint256 amount) external {
                _payoutTokenExact(to, token, isNative, amount);
            }

            function executeIssueSwapForTest(
                address inputToken,
                address outputToken,
                uint256 requiredAmount,
                IssueSwapLeg calldata leg
            ) external {
                _executeIssueSwap(LibAppStorage.routerStorage(), IERC20(inputToken), outputToken, requiredAmount, leg);
            }

            receive() external payable {}
        }

        contract IssuePreviewFacetHarness is RouterIssuePreviewFacet {
            using EnumerableSet for EnumerableSet.AddressSet;

            constructor(address permit2_) RouterIssuePreviewFacet(permit2_) {}

            function configure(address core, address wrappedNative, address adapter, uint256 helperFeePpm) external {
                LibAppStorage.RouterStorage storage rs = LibAppStorage.routerStorage();
                rs.coreDiamond = core;
                rs.wrappedNative = wrappedNative;
                rs.helperFeePpm = helperFeePpm;
                rs.approvedAdapters.add(adapter);
            }

            function setWrappedNativeForTest(address wrappedNative) external {
                LibAppStorage.routerStorage().wrappedNative = wrappedNative;
            }
        }

        contract IssueBasketFacetHarness is RouterIssueBasketFacet {
            constructor(address permit2_) RouterIssueBasketFacet(permit2_) {}

            function configure(address owner, address core, uint256 helperFeePpm) external {
                LibAppStorage.RouterStorage storage rs = LibAppStorage.routerStorage();
                rs.coreDiamond = core;
                rs.helperFeePpm = helperFeePpm;
                LibDiamond.setContractOwner(owner);
            }
        }

        contract BasketRouterIssueTest is Test {
            uint256 private constant HELPER_FEE_PPM = 1_000;
            bytes32 private constant ISSUED_SIGNATURE =
                keccak256("Issued(address,address,address,uint256,uint256,uint256,uint256)");

            address private owner = address(0xA11CE);
            address private user = address(0xBEEF);
            address private recipient = address(0xCAFE);

            IssueTestToken private tokenA;
            IssueTestToken private tokenB;
            IssueTestWeth private wrappedNative;
            IssueTestPermit2 private permit2;
            IssueTestCore private core;
            IssueTestAdapter private adapter;
            IssueFacetHarness private issue;
            IssuePreviewFacetHarness private previews;

            function setUp() public {
                tokenA = new IssueTestToken("Asset A", "A");
                tokenB = new IssueTestToken("Asset B", "B");
                wrappedNative = new IssueTestWeth();
                permit2 = new IssueTestPermit2();
                core = new IssueTestCore(address(tokenA), address(tokenB));
                adapter = new IssueTestAdapter();
                issue = new IssueFacetHarness(address(permit2));
                previews = new IssuePreviewFacetHarness(address(permit2));
                issue.configure(owner, address(core), address(wrappedNative), address(adapter), HELPER_FEE_PPM);
                previews.configure(address(core), address(wrappedNative), address(adapter), HELPER_FEE_PPM);

                tokenA.mint(user, 100 ether);
                tokenA.mint(address(adapter), 100 ether);
                tokenB.mint(address(adapter), 100 ether);
                vm.deal(user, 100 ether);
                vm.prank(user);
                tokenA.approve(address(issue), type(uint256).max);
            }

            function testPreviewsUseCanonicalNamesAndNeverCallAdapters() public view {
                IBasketRouterTypes.IssueSwapLeg[] memory tokenLegs = _legs(1);
                tokenLegs[0] = _leg(5 ether, 5 ether, 0);
                IBasketRouterTypes.IssueExactOutPreview memory exactOut = previews.previewIssueFromTokenExactOut(
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                    }),
                    tokenLegs
                );
                assertEq(exactOut.orderedCoreAssets.length, 2);
                assertEq(exactOut.fees.protocolFeeCygld, core.protocolFeeCygld());

                IBasketRouterTypes.IssueExactInPreview memory exactIn = previews.previewIssueFromTokenExactIn(
                    IBasketRouterTypes.IssueFromTokenExactInParams({
                        inputToken: address(tokenA), inputAmount: 10 ether
                    }),
                    tokenLegs
                );
                assertGt(exactIn.netCygldOut, 0);
                assertEq(exactIn.orderedCoreAssets, exactOut.orderedCoreAssets);

                IBasketRouterTypes.IssueSwapLeg[] memory nativeLegs = _legs(2);
                nativeLegs[0] = _leg(5 ether, 5 ether, 0);
                nativeLegs[1] = _leg(5 ether, 5 ether, 0);
                previews.previewIssueFromNativeExactOut(
                    IBasketRouterTypes.IssueFromNativeExactOutParams({
                        maximumNativeIn: 10 ether, netCygldOut: 10 ether
                    }),
                    nativeLegs
                );
                previews.previewIssueFromNativeExactIn(10 ether, nativeLegs);
                assertEq(adapter.swapCallCount(), 0);
            }

            function testExactInTokenAndNativePreviewsConstructRetainedExactOutExecutions() public {
                IBasketRouterTypes.IssueSwapLeg[] memory tokenLegs = _legs(1);
                tokenLegs[0] = _legWithOutput(6 ether, 5 ether, 5 ether, 1 ether);
                IBasketRouterTypes.IssueExactInPreview memory tokenConstruction = previews.previewIssueFromTokenExactIn(
                    IBasketRouterTypes.IssueFromTokenExactInParams({
                        inputToken: address(tokenA), inputAmount: 12 ether
                    }),
                    tokenLegs
                );
                IBasketRouterTypes.IssueFromTokenExactOutParams memory tokenExecution =
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA),
                        maximumInputAmount: 12 ether,
                        netCygldOut: tokenConstruction.netCygldOut
                    });
                vm.prank(user);
                issue.issueFromTokenExactOut(tokenExecution, _execution(), tokenLegs);
                assertEq(core.balanceOf(recipient), tokenConstruction.netCygldOut);

                IBasketRouterTypes.IssueSwapLeg[] memory nativeLegs = _legs(2);
                nativeLegs[0] = _legWithOutput(6 ether, 5 ether, 5 ether, 1 ether);
                nativeLegs[1] = _legWithOutput(6 ether, 5 ether, 5 ether, 1 ether);
                IBasketRouterTypes.IssueExactInPreview memory nativeConstruction =
                    previews.previewIssueFromNativeExactIn(12 ether, nativeLegs);
                IBasketRouterTypes.IssueFromNativeExactOutParams memory nativeExecution =
                    IBasketRouterTypes.IssueFromNativeExactOutParams({
                        maximumNativeIn: 12 ether, netCygldOut: nativeConstruction.netCygldOut
                    });
                vm.prank(user);
                issue.issueFromNativeExactOut{value: 12 ether}(nativeExecution, _execution(), nativeLegs);
                assertEq(core.balanceOf(recipient), tokenConstruction.netCygldOut + nativeConstruction.netCygldOut);
                assertEq(adapter.swapCallCount(), 3);
            }

            function testExactInPreviewSkipsZeroTargetCanonicalMembers() public {
                core.setTargetsPpm(1_000_000, 0);

                IBasketRouterTypes.IssueSwapLeg[] memory noLegs = _legs(0);
                IBasketRouterTypes.IssueExactInPreview memory direct = previews.previewIssueFromTokenExactIn(
                    IBasketRouterTypes.IssueFromTokenExactInParams({
                        inputToken: address(tokenA), inputAmount: 10 ether
                    }),
                    noLegs
                );
                assertGt(direct.netCygldOut, 0);

                IBasketRouterTypes.IssueSwapLeg[] memory oneLeg = _legs(1);
                oneLeg[0] = _leg(10 ether, 10 ether, 0);
                IBasketRouterTypes.IssueExactInPreview memory zeroTargetInput = previews.previewIssueFromTokenExactIn(
                    IBasketRouterTypes.IssueFromTokenExactInParams({
                        inputToken: address(tokenB), inputAmount: 10 ether
                    }),
                    oneLeg
                );
                assertEq(zeroTargetInput.netCygldOut, direct.netCygldOut);

                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.QuoteLengthMismatch.selector, 1, 0));
                previews.previewIssueFromTokenExactIn(
                    IBasketRouterTypes.IssueFromTokenExactInParams({
                        inputToken: address(tokenA), inputAmount: 10 ether
                    }),
                    oneLeg
                );
            }

            function testExactInPreviewRejectsMisalignedCoreTargets() public {
                core.clearTargetsPpm();
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.CoreBasketTargetsLengthMismatch.selector, uint256(2), uint256(0)
                    )
                );
                previews.previewIssueFromTokenExactIn(
                    IBasketRouterTypes.IssueFromTokenExactInParams({
                        inputToken: address(tokenA), inputAmount: 10 ether
                    }),
                    _legs(1)
                );
            }

            function testTokenAllowanceIssueRefundsDustAndEmitsOneGenericOutcome() public {
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _leg(6 ether, 5 ether, 1 ether);
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
                    inputToken: address(tokenA), maximumInputAmount: 11 ether, netCygldOut: 10 ether
                });
                IBasketRouterTypes.IssueExactOutPreview memory preview = previews.previewIssueFromTokenExactOut(
                    params, legs
                );

                uint256 payerBefore = tokenA.balanceOf(user);
                vm.recordLogs();
                vm.prank(user);
                IBasketRouterTypes.Fees memory fees = issue.issueFromTokenExactOut(params, _execution(), legs);
                _assertIssued(vm.getRecordedLogs(), address(tokenA), 10 ether, 10 ether, fees);

                assertEq(tokenA.balanceOf(user), payerBefore - 10 ether);
                assertEq(core.balanceOf(recipient), 10 ether);
                assertEq(core.balanceOf(owner), preview.fees.helperFeeCygld);
                assertEq(fees.protocolFeeCygld, preview.fees.protocolFeeCygld);
                assertEq(fees.helperFeeCygld, preview.fees.helperFeeCygld);
                assertEq(adapter.swapCallCount(), 1);
                assertEq(tokenA.balanceOf(address(issue)), 0);
                assertEq(tokenB.balanceOf(address(issue)), 0);
            }

            function testPreexistingRouterBalancesAreNeverIncludedInOperationRefunds() public {
                tokenA.mint(address(issue), 3 ether);
                tokenB.mint(address(issue), 4 ether);
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _leg(6 ether, 5 ether, 1 ether);
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
                    inputToken: address(tokenA), maximumInputAmount: 11 ether, netCygldOut: 10 ether
                });

                uint256 payerABefore = tokenA.balanceOf(user);
                uint256 payerBBefore = tokenB.balanceOf(user);
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);
                assertEq(tokenA.balanceOf(user), payerABefore - 10 ether);
                assertEq(tokenB.balanceOf(user), payerBBefore);
                assertEq(tokenA.balanceOf(address(issue)), 3 ether);
                assertEq(tokenB.balanceOf(address(issue)), 4 ether);
            }

            function testTokenIssueSupportsPermit2() public {
                vm.startPrank(user);
                tokenA.approve(address(issue), 0);
                tokenA.approve(address(permit2), type(uint256).max);
                vm.stopPrank();

                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _leg(5 ether, 5 ether, 0);
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
                    inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                });
                IBasketRouterTypes.Permit2Params memory permit;
                permit.permit = ISignatureTransfer.PermitTransferFrom({
                    permitted: ISignatureTransfer.TokenPermissions({token: address(tokenA), amount: 10 ether}),
                    nonce: 7,
                    deadline: block.timestamp + 1 days
                });
                permit.signature = hex"01";

                vm.prank(user);
                issue.issueFromTokenExactOutWithPermit2(params, _execution(), permit, legs);
                assertTrue(permit2.used(user, 7));
                assertEq(core.balanceOf(recipient), 10 ether);
            }

            function testPermit2RejectsWrongTokenAmountAndDeadlineBeforeAcquisition() public {
                vm.prank(user);
                tokenA.approve(address(permit2), type(uint256).max);
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _leg(5 ether, 5 ether, 0);
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
                    inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                });

                IBasketRouterTypes.Permit2Params memory permit = _permit2(
                    address(tokenB), 10 ether, block.timestamp + 1 days
                );
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.InvalidPermit2Token.selector, address(tokenB), address(tokenA)
                    )
                );
                vm.prank(user);
                issue.issueFromTokenExactOutWithPermit2(params, _execution(), permit, legs);

                permit = _permit2(address(tokenA), 9 ether, block.timestamp + 1 days);
                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.Permit2AmountTooLow.selector, 9 ether, 10 ether)
                );
                vm.prank(user);
                issue.issueFromTokenExactOutWithPermit2(params, _execution(), permit, legs);

                permit = _permit2(address(tokenA), 10 ether, 0);
                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitExpired.selector, 0, block.timestamp));
                vm.prank(user);
                issue.issueFromTokenExactOutWithPermit2(params, _execution(), permit, legs);
                assertEq(adapter.swapCallCount(), 0);
            }

            function testDedicatedNativeIssueRequiresExactValueAndRefundsAsNative() public {
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(2);
                legs[0] = _leg(6 ether, 5 ether, 1 ether);
                legs[1] = _leg(6 ether, 5 ether, 1 ether);
                IBasketRouterTypes.IssueFromNativeExactOutParams memory params =
                    IBasketRouterTypes.IssueFromNativeExactOutParams({maximumNativeIn: 12 ether, netCygldOut: 10 ether});

                uint256 payerBefore = user.balance;
                vm.recordLogs();
                vm.prank(user);
                IBasketRouterTypes.Fees memory fees =
                    issue.issueFromNativeExactOut{value: 12 ether}(params, _execution(), legs);
                _assertIssued(vm.getRecordedLogs(), address(0), 10 ether, 10 ether, fees);
                assertEq(user.balance, payerBefore - 10 ether);
                assertEq(address(issue).balance, 0);
                assertEq(wrappedNative.balanceOf(address(issue)), 0);

                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.NativeValueMismatch.selector, 12 ether, 11 ether)
                );
                vm.prank(user);
                issue.issueFromNativeExactOut{value: 11 ether}(params, _execution(), legs);

                IBasketRouterTypes.IssueFromTokenExactOutParams memory tokenParams =
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                    });
                IBasketRouterTypes.IssueSwapLeg[] memory tokenLegs = _legs(1);
                tokenLegs[0] = _leg(5 ether, 5 ether, 0);
                vm.prank(user);
                (bool accepted,) = address(issue).call{value: 1}(
                    abi.encodeCall(issue.issueFromTokenExactOut, (tokenParams, _execution(), tokenLegs))
                );
                assertFalse(accepted);
            }

            function testRequirementDecreaseKeepsOriginalMaximaAndRefundsOperationSurplus() public {
                adapter.setDrift(core, 4 ether, 4 ether);
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _leg(5 ether, 5 ether, 0);
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
                    inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                });

                uint256 payerBefore = tokenA.balanceOf(user);
                vm.recordLogs();
                vm.prank(user);
                IBasketRouterTypes.Fees memory fees = issue.issueFromTokenExactOut(params, _execution(), legs);
                _assertIssued(vm.getRecordedLogs(), address(tokenA), 9 ether, 10 ether, fees);

                uint256[] memory maxima = core.lastMaximumInputs();
                assertEq(maxima[0], 5 ether);
                assertEq(maxima[1], 5 ether);
                assertEq(tokenA.balanceOf(user), payerBefore - 9 ether);
                assertEq(tokenB.balanceOf(user), 1 ether);
            }

            function testRequirementIncreaseMakesSafeIssueRejectInsteadOfRepreviewing() public {
                adapter.setDrift(core, 6 ether, 4 ether);
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _leg(5 ether, 5 ether, 0);
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
                    inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                });

                vm.expectRevert(bytes("max"));
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);
                assertEq(core.safeIssueCallCount(), 0);
                assertEq(core.balanceOf(recipient), 0);
            }

            function testCompactLegValidationRunsBeforeInputAcquisition() public {
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params =
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                    });
                uint256 payerBefore = tokenA.balanceOf(user);
                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.QuoteLengthMismatch.selector, 0, 1));
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), _legs(0));
                assertEq(tokenA.balanceOf(user), payerBefore);
                assertEq(adapter.swapCallCount(), 0);
            }

            function testTokenRecipientAmountAndExpectedOrderGuardsRunBeforeAcquisition() public {
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _leg(5 ether, 5 ether, 0);
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params = IBasketRouterTypes.IssueFromTokenExactOutParams({
                    inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                });

                IBasketRouterTypes.IssueExecutionParams memory execution = _execution();
                execution.recipient = address(0);
                vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
                vm.prank(user);
                issue.issueFromTokenExactOut(params, execution, legs);

                execution = _execution();
                (execution.expectedOrderedCoreAssets[0], execution.expectedOrderedCoreAssets[1]) =
                (execution.expectedOrderedCoreAssets[1], execution.expectedOrderedCoreAssets[0]);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.CoreAssetMismatch.selector, 0, address(tokenB), address(tokenA)
                    )
                );
                vm.prank(user);
                issue.issueFromTokenExactOut(params, execution, legs);

                params.inputToken = address(0);
                vm.expectRevert(IBasketRouterTypes.ZeroAddress.selector);
                previews.previewIssueFromTokenExactOut(params, legs);
                vm.expectRevert(IBasketRouterTypes.ZeroAddress.selector);
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);

                params.inputToken = address(tokenA);
                params.netCygldOut = 0;
                vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
                previews.previewIssueFromTokenExactOut(params, legs);
                assertEq(adapter.swapCallCount(), 0);
            }

            function testEveryAggregatedIssuanceRouteRejectsHelpersRecipientBeforeAcquisition() public {
                IBasketRouterTypes.IssueExecutionParams memory execution = _execution();
                execution.recipient = address(issue);

                IBasketRouterTypes.IssueSwapLeg[] memory tokenLegs = _legs(1);
                tokenLegs[0] = _leg(5 ether, 5 ether, 0);
                IBasketRouterTypes.IssueFromTokenExactOutParams memory tokenParams =
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                    });
                uint256 payerTokenBefore = tokenA.balanceOf(user);

                vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
                vm.prank(user);
                issue.issueFromTokenExactOut(tokenParams, execution, tokenLegs);

                IBasketRouterTypes.Permit2Params memory permit = _permit2(
                    address(tokenA), 10 ether, block.timestamp + 1 days
                );
                vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
                vm.prank(user);
                issue.issueFromTokenExactOutWithPermit2(tokenParams, execution, permit, tokenLegs);

                IBasketRouterTypes.IssueSwapLeg[] memory nativeLegs = _legs(2);
                nativeLegs[0] = _leg(5 ether, 5 ether, 0);
                nativeLegs[1] = _leg(5 ether, 5 ether, 0);
                IBasketRouterTypes.IssueFromNativeExactOutParams memory nativeParams =
                    IBasketRouterTypes.IssueFromNativeExactOutParams({maximumNativeIn: 10 ether, netCygldOut: 10 ether});
                vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
                vm.prank(user);
                issue.issueFromNativeExactOut{value: 10 ether}(nativeParams, execution, nativeLegs);

                assertEq(tokenA.balanceOf(user), payerTokenBefore);
                assertFalse(permit2.used(user, permit.permit.nonce));
                assertEq(adapter.swapCallCount(), 0);
                assertEq(core.safeIssueCallCount(), 0);
            }

            function testCompactLegBoundsAndApprovalGuards() public {
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params =
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                    });
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);

                legs[0] = _leg(0, 5 ether, 0);
                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.InvalidQuoteAmount.selector, 0, 5 ether));
                previews.previewIssueFromTokenExactOut(params, legs);

                legs[0] = _leg(6 ether, 5 ether, 0);
                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.InvalidQuoteAmount.selector, 6 ether, 5 ether)
                );
                previews.previewIssueFromTokenExactOut(params, legs);

                legs[0] = _leg(5 ether, 0, 0);
                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.ZeroLegMinimum.selector, 0));
                previews.previewIssueFromTokenExactOut(params, legs);

                legs[0] = _leg(5 ether, 4 ether, 0);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.InsufficientOutputForNeed.selector, address(tokenB), 5 ether, 4 ether
                    )
                );
                previews.previewIssueFromTokenExactOut(params, legs);

                params.maximumInputAmount = 4 ether;
                legs[0] = _leg(1 ether, 5 ether, 0);
                vm.expectRevert(IBasketRouterTypes.InsufficientInput.selector);
                previews.previewIssueFromTokenExactOut(params, legs);

                params.maximumInputAmount = 10 ether;
                IssueTestAdapter unapproved = new IssueTestAdapter();
                legs[0].adapter = address(unapproved);
                legs[0].amountIn = 5 ether;
                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.AdapterNotApproved.selector, address(unapproved))
                );
                previews.previewIssueFromTokenExactOut(params, legs);
            }

            function testAdapterMeasurementAndMinimumGuards() public {
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params =
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                    });

                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _legWithOutput(5 ether, 5 ether, 5 ether, 0);
                adapter.setReportedAmount(6 ether);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.AdapterOutputMismatch.selector,
                        address(tokenB),
                        address(adapter),
                        6 ether,
                        5 ether
                    )
                );
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);
                adapter.clearReportedAmount();

                legs[0] = _legWithOutput(5 ether, 5 ether, 4 ether, 0);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.InsufficientOutputForNeed.selector, address(tokenB), 5 ether, 4 ether
                    )
                );
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);

                legs[0] = _legWithOutput(5 ether, 6 ether, 5 ether, 0);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.InsufficientOutputForMinAmountOut.selector, address(tokenB), 6 ether, 5 ether
                    )
                );
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);

                legs[0] = _legWithOutput(5 ether, 5 ether, 5 ether, 0);
                adapter.setExtraInputDebit(1);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.AdapterInputDebitExceeded.selector,
                        address(tokenA),
                        address(adapter),
                        5 ether,
                        5 ether + 1
                    )
                );
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);
            }

            function testCoreReturnMustStayWithinSnapshotAndMatchObservedDebit() public {
                IBasketRouterTypes.IssueFromTokenExactOutParams memory params =
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(tokenA), maximumInputAmount: 10 ether, netCygldOut: 10 ether
                    });
                IBasketRouterTypes.IssueSwapLeg[] memory legs = _legs(1);
                legs[0] = _leg(5 ether, 5 ether, 0);

                core.setReturnMode(1);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.CoreInputAboveMaximum.selector, address(tokenA), 5 ether + 1, 5 ether
                    )
                );
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);

                core.setReturnMode(2);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.RouterTokenDebitMismatch.selector, address(tokenA), 5 ether - 1, 5 ether
                    )
                );
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);

                core.setReturnMode(3);
                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.CoreAssetAmountsLengthMismatch.selector, 2, 1)
                );
                vm.prank(user);
                issue.issueFromTokenExactOut(params, _execution(), legs);
            }

            function testAuthorizationFailureAndPermitBranches() public {
                IssuePermitToken permitToken = new IssuePermitToken();
                permitToken.mint(user, 10 ether);
                IBasketRouterTypes.PermitParams memory permit;
                permit.value = 1 ether;

                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.PermitExpired.selector, uint256(0), block.timestamp)
                );
                vm.prank(user);
                issue.acquireWithPermitForTest(address(permitToken), 1 ether, permit);

                permit.deadline = block.timestamp + 1 days;
                permit.value = 1 ether - 1;
                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.PermitAmountTooLow.selector, 1 ether - 1, 1 ether)
                );
                vm.prank(user);
                issue.acquireWithPermitForTest(address(permitToken), 1 ether, permit);

                permit.value = 1 ether;
                permitToken.setPermitBehavior(IssuePermitToken.PermitBehavior.EmptyRevert);
                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitAllowanceTooLow.selector, 0, 1 ether));
                vm.prank(user);
                issue.acquireWithPermitForTest(address(permitToken), 1 ether, permit);

                permitToken.setPermitBehavior(IssuePermitToken.PermitBehavior.ReasonRevert);
                vm.expectRevert(bytes("permit failure"));
                vm.prank(user);
                issue.acquireWithPermitForTest(address(permitToken), 1 ether, permit);

                permitToken.setPermitBehavior(IssuePermitToken.PermitBehavior.NoAllowance);
                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitAllowanceTooLow.selector, 0, 1 ether));
                vm.prank(user);
                issue.acquireWithPermitForTest(address(permitToken), 1 ether, permit);

                permitToken.setPermitBehavior(IssuePermitToken.PermitBehavior.Success);
                vm.prank(user);
                issue.acquireWithPermitForTest(address(permitToken), 1 ether, permit);
                assertEq(permitToken.balanceOf(address(issue)), 1 ether);

                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.PayerTokenDebitMismatch.selector,
                        address(0x1),
                        address(0x2),
                        uint256(1),
                        uint256(0)
                    )
                );
                issue.requireExactPayerDebitForTest(1, 2, 1);

                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.RouterTokenCreditMismatch.selector, address(0x1), uint256(1), uint256(0)
                    )
                );
                issue.requireExactTokenCreditForTest(2, 1, 1);
            }

            function testPublicEntryAndZeroRequirementGuardBranches() public {
                IBasketRouterTypes.IssueExecutionParams memory execution = _execution();
                IBasketRouterTypes.IssueSwapLeg[] memory oneLeg = _legs(1);
                oneLeg[0] = _leg(5 ether, 5 ether, 0);

                IBasketRouterTypes.IssueFromTokenExactOutParams memory tokenParams =
                    IBasketRouterTypes.IssueFromTokenExactOutParams({
                        inputToken: address(0), maximumInputAmount: 1 ether, netCygldOut: 1 ether
                    });
                IBasketRouterTypes.Permit2Params memory emptyPermit2;
                vm.expectRevert(IBasketRouterTypes.ZeroAddress.selector);
                issue.issueFromTokenExactOutWithPermit2(tokenParams, execution, emptyPermit2, oneLeg);

                issue.setWrappedNativeForTest(address(0));
                IBasketRouterTypes.IssueFromNativeExactOutParams memory nativeParams =
                    IBasketRouterTypes.IssueFromNativeExactOutParams({maximumNativeIn: 1 ether, netCygldOut: 1 ether});
                vm.expectRevert(IBasketRouterTypes.WrappedNativeNotSet.selector);
                issue.issueFromNativeExactOut{value: 1 ether}(nativeParams, execution, _legs(2));

                previews.setWrappedNativeForTest(address(0));
                vm.expectRevert(IBasketRouterTypes.WrappedNativeNotSet.selector);
                previews.previewIssueFromNativeExactOut(nativeParams, _legs(2));
                vm.expectRevert(IBasketRouterTypes.WrappedNativeNotSet.selector);
                previews.previewIssueFromNativeExactIn(1 ether, _legs(2));

                IBasketRouterTypes.IssueFromTokenExactInParams memory exactInParams =
                    IBasketRouterTypes.IssueFromTokenExactInParams({inputToken: address(0), inputAmount: 1 ether});
                vm.expectRevert(IBasketRouterTypes.ZeroAddress.selector);
                previews.previewIssueFromTokenExactIn(exactInParams, oneLeg);

                exactInParams.inputToken = address(tokenA);
                exactInParams.inputAmount = 0;
                vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
                previews.previewIssueFromTokenExactIn(exactInParams, oneLeg);

                tokenParams.inputToken = address(tokenA);
                tokenParams.maximumInputAmount = 0;
                tokenParams.netCygldOut = 1 ether;
                vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
                issue.issueFromTokenExactOut(tokenParams, execution, oneLeg);
                tokenParams.maximumInputAmount = 1 ether;
                tokenParams.netCygldOut = 0;
                vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
                issue.issueFromTokenExactOut(tokenParams, execution, oneLeg);

                previews.setWrappedNativeForTest(address(wrappedNative));
                core.setForceExactInZero(true);
                exactInParams.inputAmount = 10 ether;
                vm.expectRevert(IBasketRouterTypes.AmountTooSmallAfterFees.selector);
                previews.previewIssueFromTokenExactIn(exactInParams, oneLeg);

                core.setForceExactInZero(false);
                core.setCurrentInputs(0, 5 ether);
                tokenParams.maximumInputAmount = 5 ether;
                tokenParams.netCygldOut = 10 ether;
                vm.prank(user);
                issue.issueFromTokenExactOut(tokenParams, execution, oneLeg);
                assertEq(core.balanceOf(recipient), 10 ether);

                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.QuoteLengthMismatch.selector, 0, 1));
                previews.previewIssueFromTokenExactIn(exactInParams, _legs(0));
            }

            function testSharedSettlementAndInternalVectorGuardBranches() public {
                address[] memory emptyAddresses = new address[](0);
                address[] memory oneAddress = new address[](1);
                oneAddress[0] = address(tokenA);
                uint256[] memory emptyAmounts = new uint256[](0);
                uint256[] memory oneAmount = new uint256[](1);

                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.ExpectedOrderedCoreAssetsLengthMismatch.selector, uint256(0), uint256(1)
                    )
                );
                issue.validateOrderedAssetsForTest(emptyAddresses, oneAddress);

                vm.expectRevert(IBasketRouterTypes.CoreAssetsEmpty.selector);
                issue.validateCoreAmountsForTest(emptyAddresses, emptyAmounts);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.CoreAssetAmountsLengthMismatch.selector, uint256(1), uint256(0)
                    )
                );
                issue.validateCoreAmountsForTest(oneAddress, emptyAmounts);

                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.CoreAssetAmountsLengthMismatch.selector, uint256(1), uint256(0)
                    )
                );
                issue.requireBoundedInputsForTest(oneAddress, emptyAmounts, oneAmount, oneAmount);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.CoreAssetAmountsLengthMismatch.selector, uint256(1), uint256(0)
                    )
                );
                issue.requireBoundedInputsForTest(oneAddress, oneAmount, oneAmount, emptyAmounts);

                core.clearAssets();
                vm.expectRevert(IBasketRouterTypes.CoreAssetsEmpty.selector);
                issue.loadBasketAssetsForTest();

                IssueRejectNative rejectingRecipient = new IssueRejectNative();
                wrappedNative.mint(address(issue), 1 ether);
                vm.deal(address(wrappedNative), 1 ether);
                vm.expectRevert(IBasketRouterTypes.EthRefundFailed.selector);
                issue.payoutNativeForTest(address(rejectingRecipient), address(wrappedNative), 1 ether);

                IssueMalformedToken malformedDebit = new IssueMalformedToken();
                malformedDebit.mint(address(issue), 1 ether);
                malformedDebit.setTransferMode(IssueMalformedToken.TransferMode.CreditWithoutRouterDebit);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.RouterTokenDebitMismatch.selector,
                        address(malformedDebit),
                        uint256(1 ether),
                        uint256(0)
                    )
                );
                issue.payoutTokenForTest(recipient, address(malformedDebit), false, 1 ether);

                IssueMalformedToken malformedCredit = new IssueMalformedToken();
                malformedCredit.mint(address(issue), 1 ether);
                malformedCredit.setTransferMode(IssueMalformedToken.TransferMode.RouterDebitWithoutCredit);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.RecipientAmountOutMismatch.selector,
                        address(malformedCredit),
                        recipient,
                        uint256(0),
                        uint256(1 ether)
                    )
                );
                issue.payoutTokenForTest(recipient, address(malformedCredit), false, 1 ether);

                IssueTestAdapter unapproved = new IssueTestAdapter();
                IBasketRouterTypes.IssueSwapLeg memory unapprovedLeg;
                unapprovedLeg.adapter = address(unapproved);
                unapprovedLeg.amountIn = 1;
                unapprovedLeg.minimumAmountOut = 1;
                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.AdapterNotApproved.selector, address(unapproved))
                );
                issue.executeIssueSwapForTest(address(tokenA), address(tokenB), 1, unapprovedLeg);
            }

            function _execution() private view returns (IBasketRouterTypes.IssueExecutionParams memory execution) {
                execution.recipient = recipient;
                execution.expectedOrderedCoreAssets = new address[](2);
                execution.expectedOrderedCoreAssets[0] = address(tokenA);
                execution.expectedOrderedCoreAssets[1] = address(tokenB);
            }

            function _legs(uint256 count) private pure returns (IBasketRouterTypes.IssueSwapLeg[] memory legs) {
                return new IBasketRouterTypes.IssueSwapLeg[](count);
            }

            function _leg(uint256 amountIn, uint256 minimumAmountOut, uint256 refundInput)
                private
                view
                returns (IBasketRouterTypes.IssueSwapLeg memory leg)
            {
                return _legWithOutput(amountIn, minimumAmountOut, minimumAmountOut, refundInput);
            }

            function _legWithOutput(
                uint256 amountIn,
                uint256 minimumAmountOut,
                uint256 deliveredAmountOut,
                uint256 refundInput
            ) private view returns (IBasketRouterTypes.IssueSwapLeg memory leg) {
                leg.adapter = address(adapter);
                leg.amountIn = amountIn;
                leg.minimumAmountOut = minimumAmountOut;
                leg.data = abi.encode(deliveredAmountOut, refundInput);
            }

            function _permit2(address token, uint256 amount, uint256 deadline)
                private
                pure
                returns (IBasketRouterTypes.Permit2Params memory permit)
            {
                permit.permit = ISignatureTransfer.PermitTransferFrom({
                    permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
                    nonce: 99,
                    deadline: deadline
                });
                permit.signature = hex"01";
            }

            function _assertIssued(
                Vm.Log[] memory logs,
                address inputToken,
                uint256 inputUsed,
                uint256 netCygldOut,
                IBasketRouterTypes.Fees memory fees
            ) private {
                for (uint256 i; i < logs.length; ++i) {
                    if (logs[i].topics.length != 4 || logs[i].topics[0] != ISSUED_SIGNATURE) continue;
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), user);
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), recipient);
                    assertEq(address(uint160(uint256(logs[i].topics[3]))), inputToken);
                    (uint256 loggedInputUsed, uint256 loggedNet, uint256 loggedProtocolFee, uint256 loggedHelperFee) =
                        abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                    assertEq(loggedInputUsed, inputUsed);
                    assertEq(loggedNet, netCygldOut);
                    assertEq(loggedProtocolFee, fees.protocolFeeCygld);
                    assertEq(loggedHelperFee, fees.helperFeeCygld);
                    return;
                }
                fail("Issued event missing");
            }
        }

        contract BasketRouterDirectIssueTest is Test {
            uint256 private constant HELPER_FEE_PPM = 1_000;
            bytes32 private constant ISSUED_FROM_BASKET_SIGNATURE =
                keccak256("IssuedFromBasket(address,address,address[],uint256[],uint256,uint256,uint256)");

            address private owner = address(0xA11CE);
            address private user = address(0xBEEF);
            address private recipient = address(0xCAFE);

            IssueTestToken private tokenA;
            IssueTestToken private tokenB;
            IssueTestWeth private wrappedNative;
            IssueTestPermit2 private permit2;
            IssueTestCore private core;
            IssueTestAdapter private adapter;
            IssueBasketFacetHarness private basket;
            IssuePreviewFacetHarness private previews;

            function setUp() public {
                tokenA = new IssueTestToken("Asset A", "A");
                tokenB = new IssueTestToken("Asset B", "B");
                wrappedNative = new IssueTestWeth();
                permit2 = new IssueTestPermit2();
                core = new IssueTestCore(address(tokenA), address(tokenB));
                adapter = new IssueTestAdapter();
                basket = new IssueBasketFacetHarness(address(permit2));
                previews = new IssuePreviewFacetHarness(address(permit2));
                basket.configure(owner, address(core), HELPER_FEE_PPM);
                previews.configure(address(core), address(wrappedNative), address(adapter), HELPER_FEE_PPM);

                tokenA.mint(user, 100 ether);
                tokenB.mint(user, 100 ether);
                vm.startPrank(user);
                tokenA.approve(address(permit2), type(uint256).max);
                tokenB.approve(address(permit2), type(uint256).max);
                vm.stopPrank();
            }

            function testBasketPreviewsReturnOnlyConstructedOutputs() public view {
                uint256[] memory budgets = _amounts(8 ether, 6 ether);
                IBasketRouterTypes.BasketIssueExactInPreview memory exactIn = previews.previewIssueFromBasketExactIn(
                    budgets
                );
                assertEq(exactIn.netCygldOut, 12 ether - 0.012 ether);
                assertEq(exactIn.fees.protocolFeeCygld, core.protocolFeeCygld());
                assertEq(exactIn.fees.helperFeeCygld, 0.012 ether);
                assertEq(exactIn.amountsInExact, _amounts(6 ether, 6 ether));
                _assertAssets(exactIn.orderedCoreAssets);

                IBasketRouterTypes.BasketIssueExactOutPreview memory exactOut =
                    previews.previewIssueFromBasketExactOut(10 ether);
                assertEq(exactOut.fees.protocolFeeCygld, core.protocolFeeCygld());
                assertGt(exactOut.fees.helperFeeCygld, 0);
                assertEq(exactOut.amountsInExact, _amounts(5 ether, 5 ether));
                _assertAssets(exactOut.orderedCoreAssets);
            }

            function testExactInUsesSignedBudgetsButPullsAndApprovesOnlyFreshExactLots() public {
                IBasketRouterTypes.Permit2BatchParams memory permit =
                    _permit(_amounts(8 ether, 9 ether), 1, block.timestamp + 1 days);
                IBasketRouterTypes.BasketIssueExactInPreview memory preview =
                    previews.previewIssueFromBasketExactIn(_amounts(8 ether, 9 ether));

                uint256 payerABefore = tokenA.balanceOf(user);
                uint256 payerBBefore = tokenB.balanceOf(user);
                vm.recordLogs();
                vm.prank(user);
                IBasketRouterTypes.BasketIssueResult memory result = basket.issueFromBasketExactInWithPermit2(
                    IBasketRouterTypes.BasketIssueExactInRequest({
                        recipient: recipient, minimumNetCygldOut: preview.netCygldOut
                    }),
                    permit
                );

                assertEq(result.netCygldOut, preview.netCygldOut);
                assertEq(result.actualAmountsIn, _amounts(5 ether, 5 ether));
                assertEq(tokenA.balanceOf(user), payerABefore - 5 ether);
                assertEq(tokenB.balanceOf(user), payerBBefore - 5 ether);
                assertEq(core.lastMaximumInputs(), _amounts(8 ether, 8 ether));
                assertEq(core.balanceOf(recipient), preview.netCygldOut);
                assertEq(core.balanceOf(owner), preview.fees.helperFeeCygld);
                assertEq(tokenA.balanceOf(address(basket)), 0);
                assertEq(tokenB.balanceOf(address(basket)), 0);
                _assertOneBasketIssueEvent(vm.getRecordedLogs(), result);
            }

            function testExactOutDeliversRequestedNetAndBindsFreshCoreOrder() public {
                IBasketRouterTypes.Permit2BatchParams memory permit =
                    _permit(_amounts(7 ether, 8 ether), 2, block.timestamp + 1 days);
                vm.prank(user);
                IBasketRouterTypes.BasketIssueResult memory result = basket.issueFromBasketExactOutWithPermit2(
                    IBasketRouterTypes.BasketIssueExactOutRequest({netCygldOut: 10 ether, recipient: recipient}), permit
                );

                assertEq(result.netCygldOut, 10 ether);
                assertEq(result.actualAmountsIn, _amounts(5 ether, 5 ether));
                assertEq(core.lastMaximumInputs(), _amounts(5 ether, 5 ether));
                assertEq(core.balanceOf(recipient), 10 ether);
                assertGt(result.fees.helperFeeCygld, 0);
            }

            function testPermitBatchLengthOrderCeilingAndDeadlineRejectBeforePull() public {
                uint256 userABefore = tokenA.balanceOf(user);

                IBasketRouterTypes.Permit2BatchParams memory permit =
                    _permitOne(address(tokenA), 5 ether, 3, block.timestamp + 1 days);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.Permit2BatchLengthMismatch.selector, uint256(1), uint256(2)
                    )
                );
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(_exactOutRequest(), permit);

                permit = _permit(_amounts(5 ether, 5 ether), 4, block.timestamp + 1 days);
                (permit.permit.permitted[0], permit.permit.permitted[1]) =
                (permit.permit.permitted[1], permit.permit.permitted[0]);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.InvalidPermit2Token.selector, address(tokenB), address(tokenA)
                    )
                );
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(_exactOutRequest(), permit);

                permit = _permit(_amounts(4 ether, 5 ether), 5, block.timestamp + 1 days);
                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.Permit2AmountTooLow.selector, 4 ether, 5 ether)
                );
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(_exactOutRequest(), permit);

                permit = _permit(_amounts(5 ether, 5 ether), 6, 0);
                vm.expectRevert(abi.encodeWithSelector(IBasketRouterTypes.PermitExpired.selector, 0, block.timestamp));
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(_exactOutRequest(), permit);

                assertEq(tokenA.balanceOf(user), userABefore);
                assertEq(core.safeIssueCallCount(), 0);
            }

            function testExactInMinimumRejectsBeforePermit2AndZeroMinimumIsForbidden() public {
                IBasketRouterTypes.Permit2BatchParams memory permit =
                    _permit(_amounts(5 ether, 5 ether), 7, block.timestamp + 1 days);
                IBasketRouterTypes.BasketIssueExactInRequest memory request =
                    IBasketRouterTypes.BasketIssueExactInRequest({recipient: recipient, minimumNetCygldOut: 11 ether});
                vm.expectRevert(
                    abi.encodeWithSelector(IBasketRouterTypes.InsufficientOutput.selector, 11 ether, 9.99 ether)
                );
                vm.prank(user);
                basket.issueFromBasketExactInWithPermit2(request, permit);

                request.minimumNetCygldOut = 0;
                vm.expectRevert(IBasketRouterTypes.ZeroFinalMinimum.selector);
                vm.prank(user);
                basket.issueFromBasketExactInWithPermit2(request, permit);
                assertFalse(permit2.used(user, 7));
            }

            function testEveryDirectBasketIssuanceRouteRejectsInvalidRecipientsBeforePull() public {
                IBasketRouterTypes.Permit2BatchParams memory permit =
                    _permit(_amounts(5 ether, 5 ether), 70, block.timestamp + 1 days);
                IBasketRouterTypes.BasketIssueExactInRequest memory exactIn =
                    IBasketRouterTypes.BasketIssueExactInRequest({recipient: address(0), minimumNetCygldOut: 1});
                vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
                vm.prank(user);
                basket.issueFromBasketExactInWithPermit2(exactIn, permit);

                exactIn.recipient = address(basket);
                vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
                vm.prank(user);
                basket.issueFromBasketExactInWithPermit2(exactIn, permit);

                IBasketRouterTypes.BasketIssueExactOutRequest memory exactOut = _exactOutRequest();
                exactOut.recipient = address(0);
                vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(exactOut, permit);

                exactOut.recipient = address(basket);
                vm.expectRevert(IBasketRouterTypes.InvalidRecipient.selector);
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(exactOut, permit);

                exactOut.recipient = recipient;
                exactOut.netCygldOut = 0;
                vm.expectRevert(IBasketRouterTypes.ZeroInputAmount.selector);
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(exactOut, permit);

                core.setForceExactInZero(true);
                vm.expectRevert(IBasketRouterTypes.AmountTooSmallAfterFees.selector);
                previews.previewIssueFromBasketExactIn(_amounts(5 ether, 5 ether));

                exactIn.recipient = recipient;
                vm.expectRevert(IBasketRouterTypes.AmountTooSmallAfterFees.selector);
                vm.prank(user);
                basket.issueFromBasketExactInWithPermit2(exactIn, permit);
                assertFalse(permit2.used(user, 70));
            }

            function testOperationDustRefundPreservesPreexistingRouterBalances() public {
                tokenA.mint(address(basket), 2 ether);
                tokenB.mint(address(basket), 3 ether);
                permit2.setBatchDrift(core, 4 ether, 3 ether);
                IBasketRouterTypes.Permit2BatchParams memory permit =
                    _permit(_amounts(9 ether, 9 ether), 8, block.timestamp + 1 days);

                uint256 payerABefore = tokenA.balanceOf(user);
                uint256 payerBBefore = tokenB.balanceOf(user);
                vm.prank(user);
                IBasketRouterTypes.BasketIssueResult memory result =
                    basket.issueFromBasketExactOutWithPermit2(_exactOutRequest(), permit);

                assertEq(result.actualAmountsIn, _amounts(4 ether, 3 ether));
                assertEq(tokenA.balanceOf(user), payerABefore - 4 ether);
                assertEq(tokenB.balanceOf(user), payerBBefore - 3 ether);
                assertEq(tokenA.balanceOf(address(basket)), 2 ether);
                assertEq(tokenB.balanceOf(address(basket)), 3 ether);
                assertEq(core.lastMaximumInputs(), _amounts(5 ether, 5 ether));
            }

            function testPostPermitUpwardRequirementDriftRevertsWithoutUsingStaleBalances() public {
                tokenA.mint(address(basket), 20 ether);
                tokenB.mint(address(basket), 20 ether);
                permit2.setBatchDrift(core, 6 ether, 5 ether);
                IBasketRouterTypes.Permit2BatchParams memory permit =
                    _permit(_amounts(10 ether, 10 ether), 9, block.timestamp + 1 days);

                uint256 payerABefore = tokenA.balanceOf(user);
                vm.expectRevert(bytes("max"));
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(_exactOutRequest(), permit);

                assertEq(tokenA.balanceOf(user), payerABefore);
                assertEq(tokenA.balanceOf(address(basket)), 20 ether);
                assertEq(tokenB.balanceOf(address(basket)), 20 ether);
                assertFalse(permit2.used(user, 9));
                assertEq(core.safeIssueCallCount(), 0);
            }

            function testCoreReturnAndProtocolFeeMismatchRevertAtomically() public {
                IBasketRouterTypes.Permit2BatchParams memory permit =
                    _permit(_amounts(5 ether, 5 ether), 10, block.timestamp + 1 days);
                core.setReturnMode(3);
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IBasketRouterTypes.CoreAssetAmountsLengthMismatch.selector, uint256(2), uint256(1)
                    )
                );
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(_exactOutRequest(), permit);

                core.setReturnMode(0);
                permit = _permit(_amounts(5 ether, 5 ether), 11, block.timestamp + 1 days);
                core.setSafeProtocolFeeOverride(core.protocolFeeCygld() + 1, true);
                uint256 payerABefore = tokenA.balanceOf(user);
                uint256 payerBBefore = tokenB.balanceOf(user);
                uint256 routerABefore = tokenA.balanceOf(address(basket));
                uint256 routerBBefore = tokenB.balanceOf(address(basket));
                vm.expectRevert(IBasketRouterTypes.CoreIssuanceResultMismatch.selector);
                vm.prank(user);
                basket.issueFromBasketExactOutWithPermit2(_exactOutRequest(), permit);
                assertFalse(permit2.used(user, 11));
                assertEq(tokenA.balanceOf(user), payerABefore);
                assertEq(tokenB.balanceOf(user), payerBBefore);
                assertEq(tokenA.balanceOf(address(basket)), routerABefore);
                assertEq(tokenB.balanceOf(address(basket)), routerBBefore);
            }

            function _exactOutRequest()
                private
                view
                returns (IBasketRouterTypes.BasketIssueExactOutRequest memory request)
            {
                request.netCygldOut = 10 ether;
                request.recipient = recipient;
            }

            function _permit(uint256[] memory ceilings, uint256 nonce, uint256 deadline)
                private
                view
                returns (IBasketRouterTypes.Permit2BatchParams memory params)
            {
                params.permit.permitted = new ISignatureTransfer.TokenPermissions[](2);
                params.permit.permitted[0] = ISignatureTransfer.TokenPermissions({
                    token: address(tokenA), amount: ceilings[0]
                });
                params.permit.permitted[1] = ISignatureTransfer.TokenPermissions({
                    token: address(tokenB), amount: ceilings[1]
                });
                params.permit.nonce = nonce;
                params.permit.deadline = deadline;
                params.signature = hex"01";
            }

            function _permitOne(address token, uint256 amount, uint256 nonce, uint256 deadline)
                private
                pure
                returns (IBasketRouterTypes.Permit2BatchParams memory params)
            {
                params.permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
                params.permit.permitted[0] = ISignatureTransfer.TokenPermissions({token: token, amount: amount});
                params.permit.nonce = nonce;
                params.permit.deadline = deadline;
                params.signature = hex"01";
            }

            function _amounts(uint256 first, uint256 second) private pure returns (uint256[] memory amounts) {
                amounts = new uint256[](2);
                amounts[0] = first;
                amounts[1] = second;
            }

            function _assertAssets(address[] memory assets) private view {
                assertEq(assets.length, 2);
                assertEq(assets[0], address(tokenA));
                assertEq(assets[1], address(tokenB));
            }

            function _assertOneBasketIssueEvent(
                Vm.Log[] memory logs,
                IBasketRouterTypes.BasketIssueResult memory result
            ) private view {
                uint256 count;
                for (uint256 i; i < logs.length; ++i) {
                    if (logs[i].topics.length != 3 || logs[i].topics[0] != ISSUED_FROM_BASKET_SIGNATURE) continue;
                    ++count;
                    assertEq(address(uint160(uint256(logs[i].topics[1]))), user);
                    assertEq(address(uint160(uint256(logs[i].topics[2]))), recipient);
                    (
                        address[] memory assets,
                        uint256[] memory amountsIn,
                        uint256 netCygldOut,
                        uint256 protocolFeeCygld,
                        uint256 helperFeeCygld
                    ) = abi.decode(logs[i].data, (address[], uint256[], uint256, uint256, uint256));
                    _assertAssets(assets);
                    assertEq(amountsIn, result.actualAmountsIn);
                    assertEq(netCygldOut, result.netCygldOut);
                    assertEq(protocolFeeCygld, result.fees.protocolFeeCygld);
                    assertEq(helperFeeCygld, result.fees.helperFeeCygld);
                }
                assertEq(count, 1);
            }
        }
