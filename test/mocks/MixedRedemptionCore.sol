// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ICoreRedemption} from "cybergold-core/interfaces/ICoreRedemption.sol";

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

