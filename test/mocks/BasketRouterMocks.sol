// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ISignatureTransfer} from "permit2/interfaces/ISignatureTransfer.sol";
import {ISwapAdapter} from "src/interfaces/ISwapAdapter.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

contract MintableToken is IERC20 {
    string public name;
    string public symbol;
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @dev Test-only hook used to model an allowance written during a mocked Core callback.
    function setAllowanceForTest(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
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

    contract MockWETH is MintableToken {
        constructor() MintableToken("Wrapped Ether", "WETH") {}

        function deposit() external payable {
            mint(msg.sender, msg.value);
        }

        function withdraw(uint256 amount) external {
            require(balanceOf[msg.sender] >= amount, "balance");
            balanceOf[msg.sender] -= amount;
            totalSupply -= amount;
            emit Transfer(msg.sender, address(0), amount);
            (bool success,) = msg.sender.call{value: amount}("");
            require(success, "eth");
        }

        receive() external payable {}
    }

    contract MockSwapAdapterRouter is ISwapAdapter {
        using SafeERC20 for IERC20;

        uint256 public lastCallValue;
        uint256 public totalCallValue;
        uint256 public swapCallCount;
        uint256 public ethRefundAmount;
        bool public fabricateOutput;
        address public reentryTarget;
        bytes public reentryCalldata;
        bool public reentryBlocked;

        function swap(address tokenIn, address tokenOut, uint256 amountIn, bytes calldata data)
            external
            override
            returns (uint256 amountOut)
        {
            swapCallCount += 1;
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            address desiredOut;
            uint256 quotedOut;
            uint256 refundIn;
            if (data.length == 0) {
                return amountIn;
            } else if (data.length == 64) {
                (desiredOut, quotedOut) = abi.decode(data, (address, uint256));
            } else if (data.length == 96) {
                (desiredOut, quotedOut, refundIn) = abi.decode(data, (address, uint256, uint256));
            } else {
                revert("bad swap data");
            }
            require(tokenOut == desiredOut, "wrong output");
            require(refundIn <= amountIn, "bad refund");
            amountOut = quotedOut;
            uint256 burnAmount = amountIn - refundIn;
            if (burnAmount > 0) {
                IERC20(tokenIn).safeTransfer(address(0xdead), burnAmount);
            }
            if (refundIn > 0) {
                IERC20(tokenIn).safeTransfer(msg.sender, refundIn);
            }
            if (!fabricateOutput) IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

            address target = reentryTarget;
            if (target != address(0)) {
                bytes memory callData = reentryCalldata;
                reentryTarget = address(0);
                (bool success, bytes memory revertData) = target.call(callData);
                require(!success, "reentry succeeded");
                require(revertData.length >= 4, "reentry revert missing");
                bytes4 actualSelector;
                assembly ("memory-safe") {
                    actualSelector := mload(add(revertData, 0x20))
                }
                require(
                    actualSelector == ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
                    "unexpected reentry revert"
                );
                reentryBlocked = true;
            }

            if (ethRefundAmount > 0) {
                uint256 refund = ethRefundAmount;
                ethRefundAmount = 0;
                (bool sent,) = msg.sender.call{value: refund}("");
                require(sent, "eth refund failed");
            }
        }

        function setEthRefund(uint256 amount) external {
            ethRefundAmount = amount;
        }

        function setFabricateOutput(bool enabled) external {
            fabricateOutput = enabled;
        }

        function setReentry(address target, bytes calldata callData) external {
            reentryTarget = target;
            reentryCalldata = callData;
            reentryBlocked = false;
        }

        receive() external payable {}
    }

    contract MockPermitToken is MintableToken, IERC20Permit {
        mapping(address => uint256) public override nonces;

        constructor(string memory name_, string memory symbol_) MintableToken(name_, symbol_) {}

        function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32)
            external
            override
        {
            // This mock mirrors ERC-2612 timestamp deadline semantics.
            // forge-lint: disable-next-line(block-timestamp)
            require(deadline >= block.timestamp, "expired");
            allowance[owner][spender] = value;
            nonces[owner] += 1;
            emit Approval(owner, spender, value);
        }

        // forge-lint: disable-next-line(mixed-case-function)
        function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
            return bytes32(0);
        }
    }

        contract MockPermit2 is ISignatureTransfer {
            using SafeERC20 for IERC20;

            mapping(address => mapping(uint256 => bool)) public usedNonces;

            function permitTransferFrom(
                PermitTransferFrom memory permit,
                SignatureTransferDetails calldata transferDetails,
                address owner,
                bytes calldata
            ) external override {
                // This mock mirrors Permit2 timestamp deadline semantics.
                // forge-lint: disable-next-line(block-timestamp)
                require(permit.deadline >= block.timestamp, "expired");
                require(!usedNonces[owner][permit.nonce], "nonce");
                require(permit.permitted.amount >= transferDetails.requestedAmount, "amount");

                usedNonces[owner][permit.nonce] = true;
                IERC20(permit.permitted.token)
                    .safeTransferFrom(owner, transferDetails.to, transferDetails.requestedAmount);
            }

            function permitWitnessTransferFrom(
                PermitTransferFrom memory,
                SignatureTransferDetails calldata,
                address,
                bytes32,
                string calldata,
                bytes calldata
            ) external pure override {
                revert("witness-disabled");
            }

            function permitTransferFrom(
                PermitBatchTransferFrom memory permit,
                SignatureTransferDetails[] calldata transferDetails,
                address owner,
                bytes calldata
            ) external override {
                // This mock mirrors Permit2 timestamp deadline semantics.
                // forge-lint: disable-next-line(block-timestamp)
                require(permit.deadline >= block.timestamp, "expired");
                require(!usedNonces[owner][permit.nonce], "nonce");
                require(permit.permitted.length == transferDetails.length, "length");

                usedNonces[owner][permit.nonce] = true;
                for (uint256 i = 0; i < permit.permitted.length; i++) {
                    uint256 requestedAmount = transferDetails[i].requestedAmount;
                    require(permit.permitted[i].amount >= requestedAmount, "amount");
                    if (requestedAmount != 0) {
                        IERC20(permit.permitted[i].token)
                            .safeTransferFrom(owner, transferDetails[i].to, requestedAmount);
                    }
                }
            }

            function permitWitnessTransferFrom(
                PermitBatchTransferFrom memory,
                SignatureTransferDetails[] calldata,
                address,
                bytes32,
                string calldata,
                bytes calldata
            ) external pure override {
                revert("batch-witness-disabled");
            }

            function nonceBitmap(address, uint256) external pure override returns (uint256) {
                return 0;
            }

            function invalidateUnorderedNonces(uint256, uint256) external pure override {}

            // forge-lint: disable-next-line(mixed-case-function)
            function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
                return keccak256("MockPermit2");
            }
        }

        contract MockCoreController is MintableToken, IERC20Permit {
            using SafeERC20 for IERC20;

            address[] internal _assets;
            uint256[] internal _weights;
            uint256[] internal _conversions;
            uint256 internal constant _PCT = 1_000_000;
            mapping(address => uint256) public override nonces;
            uint256[] internal _overrideRedeemAmounts;
            bool internal _useRedeemOverride;
            uint256[] internal _overrideSafeRedeemReturnAmounts;
            bool internal _useSafeRedeemReturnOverride;
            uint256 internal _overrideRedeemLength;
            bool internal _useRedeemLengthOverride;
            uint256 public maxTotalSupply = type(uint256).max;
            uint256 public issuanceFeePpm;
            address public issuanceTreasury = address(0xC0FFEE);
            uint256 public lastIssueNetCygldOut;
            uint256 public safeIssueCallCount;
            uint256 public safeIssueProtocolFeeOverride;
            bool public useSafeIssueProtocolFeeOverride;
            uint256 public safeRedeemCallCount;
            uint256 public redemptionFeePpm;
            address public redemptionTreasury = address(0xC0FFEE);
            mapping(address => bool) public redemptionFeeExempt;
            address[] internal _lastSafeIssueExpectedAssets;
            uint256[] internal _lastSafeIssueMaxAmountsIn;
            uint256[] internal _lastSafeRedeemMinAmountsOut;
            uint256 public lastSafeRedeemGrossCygldIn;
            uint256[] internal _overrideIssueReturnAmounts;
            bool internal _useIssueReturnOverride;
            uint256 internal _overrideIssueReturnLength;
            bool internal _useIssueReturnLengthOverride;
            uint256[] internal _overrideSafeIssueRequiredAmounts;
            bool internal _useSafeIssueRequiredAmountsOverride;
            uint256 internal _safeIssueAllowanceSeedIndex;
            uint256 internal _safeIssueAllowanceSeedAmount;
            bool internal _useSafeIssueAllowanceSeed;
            uint256 public safeIssueAllowanceSeedCallCount;
            uint256 internal _safeRedeemBonusIndex;
            uint256 internal _safeRedeemBonusAmount;
            bool internal _useSafeRedeemBonus;
            uint256 internal _safeRedeemDebitAmount;
            bool internal _useSafeRedeemDebitOverride;
            bool public rejectBasketLensAfterSafeRedeem;
            bool internal _safeRedeemCompleted;

            constructor(address[] memory assets, uint256[] memory weights, uint256[] memory conversions)
                MintableToken("Mock CYGLD", "MCYGLD")
            {
                _assets = assets;
                _weights = weights;
                _conversions = conversions;
            }

            function basketAssets() external view returns (address[] memory) {
                if (rejectBasketLensAfterSafeRedeem && _safeRedeemCompleted) revert("basket lens reloaded");
                return _assets;
            }

            function basketTargetsPpm() external view returns (uint256[] memory) {
                return _weights;
            }

            function setMaxTotalSupply(uint256 maxTotalSupply_) external {
                maxTotalSupply = maxTotalSupply_;
            }

            function setIssuanceFeePpm(uint256 issuanceFeePpm_) external {
                require(issuanceFeePpm_ < _PCT, "fee");
                issuanceFeePpm = issuanceFeePpm_;
            }

            function setIssuanceTreasury(address issuanceTreasury_) external {
                require(issuanceTreasury_ != address(0), "treasury");
                issuanceTreasury = issuanceTreasury_;
            }

            function setRedemptionFeePpm(uint256 redemptionFeePpm_) external {
                require(redemptionFeePpm_ < _PCT, "fee");
                redemptionFeePpm = redemptionFeePpm_;
            }

            function setRedemptionTreasury(address redemptionTreasury_) external {
                require(redemptionTreasury_ != address(0), "treasury");
                redemptionTreasury = redemptionTreasury_;
            }

            function setRedemptionFeeExempt(address account, bool exempt) external {
                redemptionFeeExempt[account] = exempt;
            }

            function setRejectBasketLensAfterSafeRedeem(bool reject) external {
                rejectBasketLensAfterSafeRedeem = reject;
                _safeRedeemCompleted = false;
            }

            function setSafeRedeemBonus(uint256 index, uint256 amount) external {
                _safeRedeemBonusIndex = index;
                _safeRedeemBonusAmount = amount;
                _useSafeRedeemBonus = true;
            }

            function clearSafeRedeemBonus() external {
                _useSafeRedeemBonus = false;
            }

            function setSafeRedeemDebitAmount(uint256 amount) external {
                _safeRedeemDebitAmount = amount;
                _useSafeRedeemDebitOverride = true;
            }

            function clearSafeRedeemDebitAmount() external {
                _useSafeRedeemDebitOverride = false;
            }

            function setOverrideIssueReturnAmounts(uint256[] memory amounts) external {
                _overrideIssueReturnAmounts = amounts;
                _useIssueReturnOverride = true;
            }

            function setSafeIssueProtocolFeeOverride(uint256 protocolFeeCygld) external {
                safeIssueProtocolFeeOverride = protocolFeeCygld;
                useSafeIssueProtocolFeeOverride = true;
            }

            function clearSafeIssueProtocolFeeOverride() external {
                useSafeIssueProtocolFeeOverride = false;
            }

            function clearOverrideIssueReturnAmounts() external {
                _useIssueReturnOverride = false;
                delete _overrideIssueReturnAmounts;
            }

            function setIssueReturnLength(uint256 length) external {
                _overrideIssueReturnLength = length;
                _useIssueReturnLengthOverride = true;
            }

            function clearIssueReturnLength() external {
                _useIssueReturnLengthOverride = false;
            }

            /// @dev Override only safeIssue's realized lot; Core previews remain unchanged.
            function setSafeIssueRequiredAmounts(uint256[] memory amounts) external {
                _overrideSafeIssueRequiredAmounts = amounts;
                _useSafeIssueRequiredAmountsOverride = true;
            }

            function clearSafeIssueRequiredAmounts() external {
                _useSafeIssueRequiredAmountsOverride = false;
                delete _overrideSafeIssueRequiredAmounts;
            }

            /// @dev Model a callback-time allowance on a zero-amount leg for cleanup coverage.
            function setSafeIssueAllowanceSeed(uint256 index, uint256 amount) external {
                _safeIssueAllowanceSeedIndex = index;
                _safeIssueAllowanceSeedAmount = amount;
                _useSafeIssueAllowanceSeed = true;
            }

            function clearSafeIssueAllowanceSeed() external {
                _useSafeIssueAllowanceSeed = false;
            }

            function lastSafeIssueExpectedAssets() external view returns (address[] memory) {
                return _lastSafeIssueExpectedAssets;
            }

            function lastSafeIssueMaxAmountsIn() external view returns (uint256[] memory) {
                return _lastSafeIssueMaxAmountsIn;
            }

            function lastSafeRedeemMinAmountsOut() external view returns (uint256[] memory) {
                return _lastSafeRedeemMinAmountsOut;
            }

            function safeIssue(
                uint256 netCygldOut,
                address[] calldata expectedOrderedBasketAssets,
                uint256[] calldata maxAmountsIn
            ) public returns (uint256 protocolFeeCygld, uint256[] memory amountsIn) {
                require(netCygldOut != 0, "value");
                _validateOrderedAssets(expectedOrderedBasketAssets);
                uint256 grossCygldOut;
                (grossCygldOut, protocolFeeCygld) = _grossForNet(netCygldOut);
                _requireMintWithinCap(grossCygldOut);
                lastIssueNetCygldOut = netCygldOut;
                safeIssueCallCount += 1;
                _lastSafeIssueExpectedAssets = expectedOrderedBasketAssets;
                _lastSafeIssueMaxAmountsIn = maxAmountsIn;
                uint256 len = _assets.length;
                require(maxAmountsIn.length == len, "max len");
                if (_useSafeIssueRequiredAmountsOverride) {
                    require(_overrideSafeIssueRequiredAmounts.length == len, "required len");
                }
                amountsIn = new uint256[](len);
                for (uint256 i = 0; i < len; i++) {
                    uint256 share = Math.mulDiv(grossCygldOut, _weights[i], _PCT, Math.Rounding.Ceil);
                    uint256 required = Math.mulDiv(share, 1e18, _conversions[i], Math.Rounding.Ceil);
                    if (_useSafeIssueRequiredAmountsOverride) {
                        required = _overrideSafeIssueRequiredAmounts[i];
                    }
                    require(required <= maxAmountsIn[i], "max input");
                    amountsIn[i] = required;
                    IERC20(_assets[i]).safeTransferFrom(msg.sender, address(this), required);
                }
                if (_useSafeIssueAllowanceSeed) {
                    require(_safeIssueAllowanceSeedIndex < len, "seed index");
                    require(amountsIn[_safeIssueAllowanceSeedIndex] == 0, "seed nonzero leg");
                    safeIssueAllowanceSeedCallCount += 1;
                    MintableToken(_assets[_safeIssueAllowanceSeedIndex])
                        .setAllowanceForTest(msg.sender, address(this), _safeIssueAllowanceSeedAmount);
                }
                mint(msg.sender, netCygldOut);
                if (protocolFeeCygld != 0) mint(issuanceTreasury, protocolFeeCygld);
                if (useSafeIssueProtocolFeeOverride) protocolFeeCygld = safeIssueProtocolFeeOverride;
                if (_useIssueReturnOverride) amountsIn = _overrideIssueReturnAmounts;
                if (_useIssueReturnLengthOverride) amountsIn = _resize(amountsIn, _overrideIssueReturnLength);
                return (protocolFeeCygld, amountsIn);
            }

            function setOverrideRedeemAmounts(uint256[] memory amounts) external {
                delete _overrideRedeemAmounts;
                for (uint256 i = 0; i < amounts.length; i++) {
                    _overrideRedeemAmounts.push(amounts[i]);
                }
                _useRedeemOverride = true;
            }

            function clearOverrideRedeemAmounts() external {
                _useRedeemOverride = false;
                delete _overrideRedeemAmounts;
            }

            function setOverrideSafeRedeemReturnAmounts(uint256[] memory amounts) external {
                _overrideSafeRedeemReturnAmounts = amounts;
                _useSafeRedeemReturnOverride = true;
            }

            function clearOverrideSafeRedeemReturnAmounts() external {
                _useSafeRedeemReturnOverride = false;
                delete _overrideSafeRedeemReturnAmounts;
            }

            function setRedeemOutputLength(uint256 length) external {
                _overrideRedeemLength = length;
                _useRedeemLengthOverride = true;
            }

            function clearRedeemOutputLength() external {
                _useRedeemLengthOverride = false;
            }

            function safeRedeem(uint256 grossCygldIn, ICoreRedemption.TokenMinimum[] calldata expectedOutputs)
                external
                returns (ICoreRedemption.RedemptionQuote memory quote)
            {
                quote = _mixedRedeemQuote(grossCygldIn, msg.sender);
                require(expectedOutputs.length == quote.outputs.length, "min len");
                if (_useSafeRedeemBonus) {
                    require(_safeRedeemBonusIndex < quote.outputs.length, "bonus index");
                    quote.outputs[_safeRedeemBonusIndex].amount += _safeRedeemBonusAmount;
                }
                delete _lastSafeRedeemMinAmountsOut;
                for (uint256 i; i < quote.outputs.length; ++i) {
                    ICoreRedemption.TokenMinimum calldata expected = expectedOutputs[i];
                    ICoreRedemption.TokenAmount memory output = quote.outputs[i];
                    require(
                        expected.kind == output.kind && expected.token == output.token && expected.id == output.id,
                        "descriptor"
                    );
                    require(output.amount >= expected.minimumAmount, "min output");
                    _lastSafeRedeemMinAmountsOut.push(expected.minimumAmount);
                }

                safeRedeemCallCount += 1;
                lastSafeRedeemGrossCygldIn = grossCygldIn;
                uint256 debit = _useSafeRedeemDebitOverride ? _safeRedeemDebitAmount : grossCygldIn;
                require(balanceOf[msg.sender] >= debit, "balance");
                balanceOf[msg.sender] -= debit;
                totalSupply -= debit;
                emit Transfer(msg.sender, address(0), debit);
                for (uint256 i; i < quote.outputs.length; ++i) {
                    if (quote.outputs[i].amount != 0) {
                        IERC20(quote.outputs[i].token).safeTransfer(msg.sender, quote.outputs[i].amount);
                    }
                }
                if (quote.protocolFeeCygld != 0) mint(redemptionTreasury, quote.protocolFeeCygld);
                if (_useSafeRedeemReturnOverride) {
                    require(_overrideSafeRedeemReturnAmounts.length == quote.outputs.length, "safe override len");
                    for (uint256 i; i < quote.outputs.length; ++i) {
                        quote.outputs[i].amount = _overrideSafeRedeemReturnAmounts[i];
                    }
                }
                if (_useRedeemLengthOverride) {
                    ICoreRedemption.TokenAmount[] memory resized = new ICoreRedemption
                        .TokenAmount[](_overrideRedeemLength);
                    for (uint256 i; i < _overrideRedeemLength && i < quote.outputs.length; ++i) {
                        resized[i] = quote.outputs[i];
                    }
                    quote.outputs = resized;
                }
                _safeRedeemCompleted = true;
            }

            function previewIssueFromBasketExactOut(uint256 netCygldOut)
                external
                view
                returns (uint256 protocolFeeCygld, uint256[] memory amountsIn, address[] memory orderedBasketAssets)
            {
                require(netCygldOut != 0, "value");
                uint256 grossCygldOut;
                (grossCygldOut, protocolFeeCygld) = _grossForNet(netCygldOut);
                _requireMintWithinCap(grossCygldOut);
                uint256 len = _assets.length;
                require(len != 0, "basket");
                amountsIn = new uint256[](len);
                for (uint256 i = 0; i < len; i++) {
                    uint256 share = Math.mulDiv(grossCygldOut, _weights[i], _PCT, Math.Rounding.Ceil);
                    amountsIn[i] = Math.mulDiv(share, 1e18, _conversions[i], Math.Rounding.Ceil);
                }
                return (protocolFeeCygld, amountsIn, _assets);
            }

            function previewIssueFromBasketExactIn(uint256[] calldata amountsIn)
                external
                view
                returns (
                    uint256 netCygldOut,
                    uint256 protocolFeeCygld,
                    uint256[] memory amountsInExact,
                    address[] memory orderedBasketAssets
                )
            {
                uint256 len = _assets.length;
                require(len != 0, "basket");
                require(amountsIn.length == len, "len");

                uint256 grossCygldOut = type(uint256).max;
                for (uint256 i = 0; i < len; i++) {
                    if (_weights[i] == 0) continue;
                    uint256 share = Math.mulDiv(amountsIn[i], _conversions[i], 1e18, Math.Rounding.Floor);
                    if (share == 0) {
                        grossCygldOut = 0;
                        break;
                    }
                    uint256 implied = Math.mulDiv(share, _PCT, _weights[i], Math.Rounding.Floor);
                    if (implied < grossCygldOut) {
                        grossCygldOut = implied;
                    }
                }

                if (grossCygldOut == type(uint256).max) {
                    grossCygldOut = 0;
                }
                uint256 remaining = _remainingMintableSupply();
                if (grossCygldOut > remaining) {
                    grossCygldOut = remaining;
                }

                protocolFeeCygld = Math.mulDiv(grossCygldOut, issuanceFeePpm, _PCT);
                netCygldOut = grossCygldOut - protocolFeeCygld;
                if (netCygldOut != 0) {
                    (grossCygldOut, protocolFeeCygld) = _grossForNet(netCygldOut);
                }

                amountsInExact = new uint256[](len);
                for (uint256 i = 0; i < len; i++) {
                    uint256 share = Math.mulDiv(grossCygldOut, _weights[i], _PCT, Math.Rounding.Ceil);
                    amountsInExact[i] = Math.mulDiv(share, 1e18, _conversions[i], Math.Rounding.Ceil);
                }

                return (netCygldOut, protocolFeeCygld, amountsInExact, _assets);
            }

            function _grossForNet(uint256 netCygldOut)
                internal
                view
                returns (uint256 grossCygldOut, uint256 protocolFeeCygld)
            {
                uint256 maxNetCygldOut = type(uint256).max - Math.mulDiv(type(uint256).max, issuanceFeePpm, _PCT);
                require(netCygldOut <= maxNetCygldOut, "gross overflow");
                grossCygldOut = Math.mulDiv(netCygldOut - 1, _PCT, _PCT - issuanceFeePpm) + 1;
                protocolFeeCygld = grossCygldOut - netCygldOut;
            }

            function _remainingMintableSupply() internal view returns (uint256) {
                if (totalSupply >= maxTotalSupply) {
                    return 0;
                }
                return maxTotalSupply - totalSupply;
            }

            function _requireMintWithinCap(uint256 grossCygldOut) internal view {
                require(grossCygldOut <= _remainingMintableSupply(), "cap");
            }

            function previewRedeemExactIn(uint256 grossCygldIn)
                external
                view
                returns (ICoreRedemption.RedemptionQuote memory quote)
            {
                quote = _mixedRedeemQuote(grossCygldIn, msg.sender);
                if (_useRedeemOverride) {
                    require(_overrideRedeemAmounts.length == quote.outputs.length, "override len mismatch");
                    for (uint256 i; i < quote.outputs.length; ++i) {
                        quote.outputs[i].amount = _overrideRedeemAmounts[i];
                    }
                }
            }

            function _mixedRedeemQuote(uint256 grossCygldIn, address caller)
                internal
                view
                returns (ICoreRedemption.RedemptionQuote memory quote)
            {
                uint256[] memory amountsOut;
                (quote.netCygldIn, quote.protocolFeeCygld, amountsOut) = _calculateRedeem(grossCygldIn, caller);
                quote.grossCygldIn = grossCygldIn;
                quote.outputs = new ICoreRedemption.TokenAmount[](_assets.length);
                for (uint256 i; i < _assets.length; ++i) {
                    quote.outputs[i] = ICoreRedemption.TokenAmount({
                        kind: ICoreRedemption.TokenKind.ERC20, token: _assets[i], id: 0, amount: amountsOut[i]
                    });
                }
            }

            function _calculateRedeem(uint256 grossCygldIn, address caller)
                internal
                view
                returns (uint256 netCygldIn, uint256 protocolFeeCygld, uint256[] memory amountsOut)
            {
                require(grossCygldIn != 0, "value");
                uint256 supply = totalSupply;
                require(supply >= grossCygldIn, "supply");
                uint256 len = _assets.length;
                require(len != 0, "basket");
                uint256 feePpm = redemptionFeeExempt[caller] ? 0 : redemptionFeePpm;
                protocolFeeCygld = Math.mulDiv(grossCygldIn, feePpm, _PCT, Math.Rounding.Floor);
                netCygldIn = grossCygldIn - protocolFeeCygld;
                amountsOut = new uint256[](len);
                for (uint256 i; i < len; ++i) {
                    uint256 balance = IERC20(_assets[i]).balanceOf(address(this));
                    if (balance != 0) {
                        amountsOut[i] = Math.mulDiv(balance, netCygldIn, supply, Math.Rounding.Floor);
                    }
                }
            }

            function _validateOrderedAssets(address[] calldata expected) internal view {
                require(expected.length == _assets.length, "asset len");
                for (uint256 i; i < expected.length; ++i) {
                    require(expected[i] == _assets[i], "asset");
                }
            }

            function _resize(uint256[] memory source, uint256 length) internal pure returns (uint256[] memory resized) {
                resized = new uint256[](length);
                for (uint256 i; i < length && i < source.length; ++i) {
                    resized[i] = source[i];
                }
            }

            function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32)
                external
                override
            {
                // This mock mirrors ERC-2612 timestamp deadline semantics.
                // forge-lint: disable-next-line(block-timestamp)
                require(deadline >= block.timestamp, "expired");
                allowance[owner][spender] = value;
                nonces[owner] += 1;
                emit Approval(owner, spender, value);
            }

            // forge-lint: disable-next-line(mixed-case-function)
            function DOMAIN_SEPARATOR() external pure override returns (bytes32) {
                return bytes32(0);
            }
        }
