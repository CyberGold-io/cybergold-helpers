#!/usr/bin/env python3
"""Enforce the frozen lean Helpers release ABI."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ABI_PATH = ROOT / "generated" / "abi" / "HelpersDiamond.json"
EXPECTED_INTERFACE_ID = "0x57d58bc4"
EXPECTED_SELECTOR_COUNT = 54

FEES = (("protocolFeeCygld", "uint256"), ("helperFeeCygld", "uint256"))
TOKEN_PERMIT = (("value", "uint256"), ("deadline", "uint256"), ("v", "uint8"), ("r", "bytes32"), ("s", "bytes32"))
ISSUE_EXACT_OUT = (
    ("inputToken", "address"),
    ("maximumInputAmount", "uint256"),
    ("netCygldOut", "uint256"),
)
ISSUE_EXACT_IN = (("inputToken", "address"), ("inputAmount", "uint256"))
ISSUE_NATIVE_EXACT_OUT = (("maximumNativeIn", "uint256"), ("netCygldOut", "uint256"))
ISSUE_EXECUTION = (("recipient", "address"), ("expectedOrderedCoreAssets", "address[]"))
ISSUE_LEG = (
    ("adapter", "address"),
    ("amountIn", "uint256"),
    ("minimumAmountOut", "uint256"),
    ("data", "bytes"),
)
REDEMPTION_LEG = (("adapter", "address"), ("minimumAmountOut", "uint256"), ("data", "bytes"))
TOKEN_AMOUNT = (
    ("kind", "uint8"),
    ("token", "address"),
    ("id", "uint256"),
    ("amount", "uint256"),
)
TOKEN_MINIMUM = (
    ("kind", "uint8"),
    ("token", "address"),
    ("id", "uint256"),
    ("minimumAmount", "uint256"),
)
TOKEN_REQUEST = (
    ("grossCygldIn", "uint256"),
    ("outputToken", "address"),
    ("recipient", "address"),
    ("minimumAmountOut", "uint256"),
    ("expectedCoreOutputs", "tuple[]"),
)
NATIVE_REQUEST = (
    ("grossCygldIn", "uint256"),
    ("recipient", "address"),
    ("minimumAmountOut", "uint256"),
    ("expectedCoreOutputs", "tuple[]"),
)
BASKET_ISSUE_EXACT_OUT_REQUEST = (("netCygldOut", "uint256"), ("recipient", "address"))
BASKET_ISSUE_EXACT_IN_REQUEST = (("recipient", "address"), ("minimumNetCygldOut", "uint256"))
BASKET_ISSUE_EXACT_IN_PREVIEW = (
    ("netCygldOut", "uint256"),
    ("fees", "tuple"),
    ("amountsInExact", "uint256[]"),
    ("orderedCoreAssets", "address[]"),
)
BASKET_ISSUE_EXACT_OUT_PREVIEW = (
    ("fees", "tuple"),
    ("amountsInExact", "uint256[]"),
    ("orderedCoreAssets", "address[]"),
)
BASKET_ISSUE_RESULT = (("netCygldOut", "uint256"), ("fees", "tuple"), ("actualAmountsIn", "uint256[]"))
BASKET_REDEMPTION_REQUEST = (
    ("grossCygldIn", "uint256"),
    ("recipient", "address"),
    ("expectedCoreOutputs", "tuple[]"),
)
BASKET_REDEMPTION_EXACT_IN_PREVIEW = (
    ("projectedCoreOutputs", "tuple[]"),
    ("fees", "tuple"),
)
BASKET_REDEMPTION_EXACT_OUT_PREVIEW = (
    ("grossCygldIn", "uint256"),
    ("projectedCoreOutputs", "tuple[]"),
    ("fees", "tuple"),
)
BASKET_REDEMPTION_RESULT = (("outputs", "tuple[]"), ("fees", "tuple"))
PERMIT2_BATCH = (("permit", "tuple"), ("signature", "bytes"))
PERMIT2_BATCH_TRANSFER = (("permitted", "tuple[]"), ("nonce", "uint256"), ("deadline", "uint256"))
TOKEN_PERMISSION = (("token", "address"), ("amount", "uint256"))
BASKET_ISSUE_INPUT = (
    ("token", "address"),
    ("maximumInputAmount", "uint256"),
    ("authorization", "uint8"),
    ("permit", "tuple"),
)

EXPECTED_ROUTE_SELECTORS = {
    "0x95a287e6": "previewIssueFromTokenExactOut",
    "0xde318080": "previewIssueFromTokenExactIn",
    "0x00a7f551": "issueFromTokenExactOut",
    "0xd85eb636": "issueFromTokenExactOutWithPermit2",
    "0x462835d6": "issueFromTokenExactOutWithPermit",
    "0x76dd3e97": "previewIssueFromNativeExactOut",
    "0xa9863541": "previewIssueFromNativeExactIn",
    "0xe4fdc64a": "issueFromNativeExactOut",
    "0x7b67ed8b": "previewRedeemToTokenExactIn",
    "0x3b25a19c": "redeemToTokenExactIn",
    "0x6fa6d883": "redeemToTokenExactInWithPermit",
    "0x1c0b4907": "redeemToTokenExactInWithPermit2",
    "0xdb78bdb5": "previewRedeemToNativeExactIn",
    "0xf2c4c397": "redeemToNativeExactIn",
    "0x065600b2": "redeemToNativeExactInWithPermit",
    "0x300b4423": "redeemToNativeExactInWithPermit2",
    "0xdb129a1c": "previewIssueFromBasketExactIn",
    "0xf1f487d5": "previewIssueFromBasketExactOut",
    "0xe813952e": "issueFromBasketExactInWithPermit2",
    "0x705b2d0b": "issueFromBasketExactInWithMixedPermits",
    "0xac7fbf2f": "issueFromBasketExactOutWithMixedPermits",
    "0xabf4c20e": "issueFromBasketExactOutWithPermit2",
    "0xde1e8b45": "previewRedeemToBasketExactIn",
    "0xac49c069": "previewRedeemToBasketExactOut",
    "0xc2f2261c": "redeemToBasketExactIn",
    "0xddf6a573": "redeemToBasketExactInWithPermit",
    "0x233f8db8": "redeemToBasketExactInWithPermit2",
}


def fail(message: str) -> None:
    raise SystemExit(f"Helpers semantic ABI conformance failed: {message}")


def fields(items: list[dict[str, Any]]) -> tuple[tuple[str, str], ...]:
    return tuple((str(item.get("name", "")), str(item.get("type", ""))) for item in items)


def require_fields(label: str, items: list[dict[str, Any]], expected: tuple[tuple[str, str], ...]) -> None:
    actual = fields(items)
    if actual != expected:
        fail(f"{label}: fields {actual!r}, expected {expected!r}")


def require_tuple(label: str, item: dict[str, Any], expected: tuple[tuple[str, str], ...]) -> None:
    if item.get("type") not in ("tuple", "tuple[]"):
        fail(f"{label}: expected tuple, found {item.get('type')!r}")
    components = item.get("components")
    if not isinstance(components, list):
        fail(f"{label}: tuple components missing")
    require_fields(label, components, expected)


def one(abi: list[dict[str, Any]], kind: str, name: str) -> dict[str, Any]:
    matches = [item for item in abi if item.get("type") == kind and item.get("name") == name]
    if len(matches) != 1:
        fail(f"{kind} {name}: expected one entry, found {len(matches)}")
    return matches[0]


def function(abi: list[dict[str, Any]], name: str) -> dict[str, Any]:
    return one(abi, "function", name)


def require_function(
    abi: list[dict[str, Any]],
    name: str,
    inputs: tuple[tuple[str, str], ...],
    output: tuple[tuple[str, str], ...],
    mutability: str,
) -> dict[str, Any]:
    item = function(abi, name)
    require_fields(f"function {name} inputs", item.get("inputs", []), inputs)
    require_fields(f"function {name} outputs", item.get("outputs", []), output)
    if item.get("stateMutability") != mutability:
        fail(f"function {name}: mutability {item.get('stateMutability')!r}, expected {mutability!r}")
    return item


def tuple_at(item: dict[str, Any], index: int, expected: tuple[tuple[str, str], ...], label: str) -> dict[str, Any]:
    inputs = item.get("inputs", [])
    if index >= len(inputs):
        fail(f"{label}: input {index} missing")
    value = inputs[index]
    require_tuple(label, value, expected)
    return value


def output_tuple(item: dict[str, Any], expected: tuple[tuple[str, str], ...], label: str) -> dict[str, Any]:
    outputs = item.get("outputs", [])
    if len(outputs) != 1:
        fail(f"{label}: expected one tuple output")
    require_tuple(label, outputs[0], expected)
    return outputs[0]


def require_nested_tuple(parent: dict[str, Any], field_name: str, expected: tuple[tuple[str, str], ...], label: str) -> None:
    components = parent.get("components", [])
    nested = next((field for field in components if field.get("name") == field_name), None)
    if not isinstance(nested, dict):
        fail(f"{label}: field {field_name} missing")
    require_tuple(f"{label} {field_name}", nested, expected)


def main() -> None:
    payload = json.loads(ABI_PATH.read_text(encoding="utf-8"))
    abi = payload.get("abi")
    if not isinstance(abi, list):
        fail("ABI array missing")

    interface_metadata = payload.get("interface", {})
    if not isinstance(interface_metadata, dict):
        fail("interface metadata missing")
    interface_id = str(interface_metadata.get("interfaceId", "")).lower()
    if interface_id != EXPECTED_INTERFACE_ID or payload.get("interfaceIdInt") != int(EXPECTED_INTERFACE_ID, 16):
        fail(f"interface ID is {interface_id}, expected {EXPECTED_INTERFACE_ID}")
    if interface_metadata.get("erc165Advertised") is not False:
        fail("aggregate Helpers interface must explicitly record erc165Advertised=false")

    selectors = payload.get("selectors")
    if not isinstance(selectors, list) or len(selectors) != EXPECTED_SELECTOR_COUNT:
        fail(
            f"selector count is {len(selectors) if isinstance(selectors, list) else 'invalid'}, "
            f"expected {EXPECTED_SELECTOR_COUNT}"
        )
    by_selector = {str(item.get("selector", "")).lower(): str(item.get("signature", "")) for item in selectors}
    for selector, name in EXPECTED_ROUTE_SELECTORS.items():
        signature = by_selector.get(selector, "")
        if not signature.startswith(f"{name}("):
            fail(f"{selector}: expected {name}, found {signature!r}")

    funcs = [item for item in abi if item.get("type") == "function"]
    names = {str(item.get("name", "")) for item in funcs}
    forbidden_fragments = ("Rebalance", "RecoveryRedeem", "quote", "Quote")
    for name in names:
        if any(fragment in name for fragment in forbidden_fragments):
            fail(f"legacy function remains: {name}")
    exact_input_issuance = sorted(name for name in names if name.startswith("issue") and "ExactIn" in name)
    if exact_input_issuance != ["issueFromBasketExactInWithMixedPermits", "issueFromBasketExactInWithPermit2"]:
        fail(f"exact-input issuance executor set is {exact_input_issuance!r}")

    preview_issue_token_out = require_function(
        abi, "previewIssueFromTokenExactOut", (("params", "tuple"), ("legs", "tuple[]")), (("preview", "tuple"),), "view"
    )
    preview_issue_token_in = require_function(
        abi, "previewIssueFromTokenExactIn", (("params", "tuple"), ("legs", "tuple[]")), (("preview", "tuple"),), "view"
    )
    preview_issue_native_out = require_function(
        abi, "previewIssueFromNativeExactOut", (("params", "tuple"), ("legs", "tuple[]")), (("preview", "tuple"),), "view"
    )
    preview_issue_native_in = require_function(
        abi, "previewIssueFromNativeExactIn", (("nativeAmountIn", "uint256"), ("legs", "tuple[]")), (("preview", "tuple"),), "view"
    )
    issue_token = require_function(
        abi,
        "issueFromTokenExactOut",
        (("params", "tuple"), ("execution", "tuple"), ("legs", "tuple[]")),
        (("fees", "tuple"),),
        "nonpayable",
    )
    issue_token_permit = require_function(
        abi,
        "issueFromTokenExactOutWithPermit",
        (("params", "tuple"), ("execution", "tuple"), ("permit", "tuple"), ("legs", "tuple[]")),
        (("fees", "tuple"),),
        "nonpayable",
    )
    issue_token_permit2 = require_function(
        abi,
        "issueFromTokenExactOutWithPermit2",
        (("params", "tuple"), ("execution", "tuple"), ("permit", "tuple"), ("legs", "tuple[]")),
        (("fees", "tuple"),),
        "nonpayable",
    )
    issue_native = require_function(
        abi,
        "issueFromNativeExactOut",
        (("params", "tuple"), ("execution", "tuple"), ("legs", "tuple[]")),
        (("fees", "tuple"),),
        "payable",
    )

    for item, schema, label in (
        (preview_issue_token_out, ISSUE_EXACT_OUT, "token exact-out params"),
        (preview_issue_token_in, ISSUE_EXACT_IN, "token exact-in params"),
        (preview_issue_native_out, ISSUE_NATIVE_EXACT_OUT, "native exact-out params"),
        (issue_token, ISSUE_EXACT_OUT, "token execution params"),
        (issue_token_permit2, ISSUE_EXACT_OUT, "token Permit2 params"),
        (issue_token_permit, ISSUE_EXACT_OUT, "token ERC-2612 params"),
        (issue_native, ISSUE_NATIVE_EXACT_OUT, "native execution params"),
    ):
        tuple_at(item, 0, schema, label)
    for item in (issue_token, issue_token_permit, issue_token_permit2, issue_native):
        tuple_at(item, 1, ISSUE_EXECUTION, f"{item['name']} execution")
    for item in (preview_issue_token_out, preview_issue_token_in, preview_issue_native_out, preview_issue_native_in):
        tuple_at(item, 1, ISSUE_LEG, f"{item['name']} legs")
    tuple_at(issue_token, 2, ISSUE_LEG, "issueFromTokenExactOut legs")
    tuple_at(issue_token_permit, 2, TOKEN_PERMIT, "issueFromTokenExactOutWithPermit permit")
    tuple_at(issue_token_permit, 3, ISSUE_LEG, "issueFromTokenExactOutWithPermit legs")
    tuple_at(issue_token_permit2, 3, ISSUE_LEG, "issueFromTokenExactOutWithPermit2 legs")
    tuple_at(issue_native, 2, ISSUE_LEG, "issueFromNativeExactOut legs")

    issue_out_schema = (("fees", "tuple"), ("orderedCoreAssets", "address[]"))
    issue_in_schema = (("netCygldOut", "uint256"), ("fees", "tuple"), ("orderedCoreAssets", "address[]"))
    for item in (preview_issue_token_out, preview_issue_native_out):
        result = output_tuple(item, issue_out_schema, item["name"])
        require_nested_tuple(result, "fees", FEES, item["name"])
    for item in (preview_issue_token_in, preview_issue_native_in):
        result = output_tuple(item, issue_in_schema, item["name"])
        require_nested_tuple(result, "fees", FEES, item["name"])
    for item in (issue_token, issue_token_permit, issue_token_permit2, issue_native):
        require_tuple(item["name"], item["outputs"][0], FEES)

    preview_basket_in = require_function(
        abi,
        "previewIssueFromBasketExactIn",
        (("maximumAmountsIn", "uint256[]"),),
        (("preview", "tuple"),),
        "view",
    )
    preview_basket_out = require_function(
        abi,
        "previewIssueFromBasketExactOut",
        (("netCygldOut", "uint256"),),
        (("preview", "tuple"),),
        "view",
    )
    for item, schema in (
        (preview_basket_in, BASKET_ISSUE_EXACT_IN_PREVIEW),
        (preview_basket_out, BASKET_ISSUE_EXACT_OUT_PREVIEW),
    ):
        result = output_tuple(item, schema, item["name"])
        require_nested_tuple(result, "fees", FEES, item["name"])

    issue_basket_in = require_function(
        abi,
        "issueFromBasketExactInWithPermit2",
        (("request", "tuple"), ("permit", "tuple")),
        (("result", "tuple"),),
        "nonpayable",
    )
    issue_basket_out = require_function(
        abi,
        "issueFromBasketExactOutWithPermit2",
        (("request", "tuple"), ("permit", "tuple")),
        (("result", "tuple"),),
        "nonpayable",
    )
    tuple_at(issue_basket_in, 0, BASKET_ISSUE_EXACT_IN_REQUEST, "basket exact-in request")
    tuple_at(issue_basket_out, 0, BASKET_ISSUE_EXACT_OUT_REQUEST, "basket exact-out request")
    for name, request_fields in (
        ("issueFromBasketExactInWithMixedPermits", BASKET_ISSUE_EXACT_IN_REQUEST),
        ("issueFromBasketExactOutWithMixedPermits", BASKET_ISSUE_EXACT_OUT_REQUEST),
    ):
        mixed = require_function(
            abi, name,
            (("request", "tuple"), ("inputs", "tuple[]"), ("permit2", "tuple")),
            (("result", "tuple"),), "nonpayable",
        )
        tuple_at(mixed, 0, request_fields, name + " request")
        mixed_inputs = tuple_at(mixed, 1, BASKET_ISSUE_INPUT, name + " inputs")
        require_nested_tuple(mixed_inputs, "permit", TOKEN_PERMIT, name + " inputs")
        batch = tuple_at(mixed, 2, PERMIT2_BATCH, name + " permit2")
        require_nested_tuple(batch, "permit", PERMIT2_BATCH_TRANSFER, name + " permit2")
        transfer = next(field for field in batch["components"] if field["name"] == "permit")
        require_nested_tuple(transfer, "permitted", TOKEN_PERMISSION, name + " permit2 transfer")
        result = output_tuple(mixed, BASKET_ISSUE_RESULT, name)
        require_nested_tuple(result, "fees", FEES, name + " result")
    for item in (issue_basket_in, issue_basket_out):
        permit = tuple_at(item, 1, PERMIT2_BATCH, f"{item['name']} Permit2 batch")
        require_nested_tuple(permit, "permit", PERMIT2_BATCH_TRANSFER, item["name"])
        permit_transfer = next(field for field in permit["components"] if field["name"] == "permit")
        require_nested_tuple(permit_transfer, "permitted", TOKEN_PERMISSION, item["name"])
        result = output_tuple(item, BASKET_ISSUE_RESULT, item["name"])
        require_nested_tuple(result, "fees", FEES, item["name"])

    redemption_specs = {
        "previewRedeemToTokenExactIn": ((("params", "tuple"), ("legs", "tuple[]")), "view", "preview", False),
        "previewRedeemToNativeExactIn": ((("grossCygldIn", "uint256"), ("legs", "tuple[]")), "view", "preview", False),
        "redeemToTokenExactIn": ((("request", "tuple"), ("legs", "tuple[]")), "nonpayable", "result", False),
        "redeemToTokenExactInWithPermit": ((("request", "tuple"), ("permit", "tuple"), ("legs", "tuple[]")), "nonpayable", "result", False),
        "redeemToTokenExactInWithPermit2": ((("request", "tuple"), ("permit", "tuple"), ("legs", "tuple[]")), "nonpayable", "result", False),
        "redeemToNativeExactIn": ((("request", "tuple"), ("legs", "tuple[]")), "nonpayable", "result", True),
        "redeemToNativeExactInWithPermit": ((("request", "tuple"), ("permit", "tuple"), ("legs", "tuple[]")), "nonpayable", "result", True),
        "redeemToNativeExactInWithPermit2": ((("request", "tuple"), ("permit", "tuple"), ("legs", "tuple[]")), "nonpayable", "result", True),
    }
    for name, (input_schema, mutability, output_name, native_request) in redemption_specs.items():
        item = require_function(abi, name, input_schema, ((output_name, "tuple"),), mutability)
        tuple_at(item, len(item["inputs"]) - 1, REDEMPTION_LEG, f"{name} legs")
        if name == "previewRedeemToTokenExactIn":
            tuple_at(item, 0, (("grossCygldIn", "uint256"), ("outputToken", "address")), f"{name} params")
        elif not name.startswith("preview"):
            request = tuple_at(item, 0, NATIVE_REQUEST if native_request else TOKEN_REQUEST, f"{name} request")
            require_nested_tuple(request, "expectedCoreOutputs", TOKEN_MINIMUM, f"{name} request")

        if name.startswith("preview"):
            result = output_tuple(
                item,
                (("minimumAmountOut", "uint256"), ("projectedCoreOutputs", "tuple[]"), ("fees", "tuple")),
                name,
            )
            require_nested_tuple(result, "projectedCoreOutputs", TOKEN_AMOUNT, name)
            require_nested_tuple(result, "fees", FEES, name)
        else:
            result = output_tuple(
                item,
                (("amountOut", "uint256"), ("recoveryShareOutputs", "tuple[]"), ("fees", "tuple")),
                name,
            )
            require_nested_tuple(result, "recoveryShareOutputs", TOKEN_AMOUNT, name)
            require_nested_tuple(result, "fees", FEES, name)

    preview_basket_redeem_in = require_function(
        abi,
        "previewRedeemToBasketExactIn",
        (("grossCygldIn", "uint256"),),
        (("preview", "tuple"),),
        "view",
    )
    preview_basket_redeem_out = require_function(
        abi,
        "previewRedeemToBasketExactOut",
        (("minimumOutputs", "tuple[]"),),
        (("preview", "tuple"),),
        "view",
    )
    tuple_at(preview_basket_redeem_out, 0, TOKEN_MINIMUM, "basket redemption exact-out minima")
    for item, schema in (
        (preview_basket_redeem_in, BASKET_REDEMPTION_EXACT_IN_PREVIEW),
        (preview_basket_redeem_out, BASKET_REDEMPTION_EXACT_OUT_PREVIEW),
    ):
        result = output_tuple(item, schema, item["name"])
        require_nested_tuple(result, "projectedCoreOutputs", TOKEN_AMOUNT, item["name"])
        require_nested_tuple(result, "fees", FEES, item["name"])

    basket_redemption_names = (
        "redeemToBasketExactIn",
        "redeemToBasketExactInWithPermit",
        "redeemToBasketExactInWithPermit2",
    )
    for name in basket_redemption_names:
        inputs = (("request", "tuple"),)
        if name.endswith("WithPermit") or name.endswith("WithPermit2"):
            inputs += (("permit", "tuple"),)
        item = require_function(abi, name, inputs, (("result", "tuple"),), "nonpayable")
        request = tuple_at(item, 0, BASKET_REDEMPTION_REQUEST, f"{name} request")
        require_nested_tuple(request, "expectedCoreOutputs", TOKEN_MINIMUM, f"{name} request")
        result = output_tuple(item, BASKET_REDEMPTION_RESULT, name)
        require_nested_tuple(result, "outputs", TOKEN_AMOUNT, name)
        require_nested_tuple(result, "fees", FEES, name)

    native_permits = sorted(name for name in names if name.endswith("WithPermit"))
    if native_permits != [
        "issueFromTokenExactOutWithPermit",
        "redeemToBasketExactInWithPermit",
        "redeemToNativeExactInWithPermit",
        "redeemToTokenExactInWithPermit",
    ]:
        fail(f"ERC-2612 route set is {native_permits!r}")

    setter = function(abi, "setAdapterApproval")
    require_fields(
        "setAdapterApproval inputs",
        setter.get("inputs", []),
        (("adapter", "address"), ("currentApproval", "bool"), ("newApproval", "bool")),
    )
    if "setPermit2" in names:
        fail("mutable setPermit2 remains")

    issued = one(abi, "event", "Issued")
    issued_from_basket = one(abi, "event", "IssuedFromBasket")
    redeemed = one(abi, "event", "Redeemed")
    redeemed_to_basket = one(abi, "event", "RedeemedToBasket")
    issued_expected = (
        ("payer", "address", True),
        ("recipient", "address", True),
        ("inputToken", "address", True),
        ("inputUsed", "uint256", False),
        ("netCygldOut", "uint256", False),
        ("protocolFeeCygld", "uint256", False),
        ("helperFeeCygld", "uint256", False),
    )
    redeemed_expected = (
        ("payer", "address", True),
        ("recipient", "address", True),
        ("outputToken", "address", True),
        ("grossCygldIn", "uint256", False),
        ("amountOut", "uint256", False),
        ("recoveryAssets", "address[]", False),
        ("recoveryShareAmounts", "uint256[]", False),
        ("protocolFeeCygld", "uint256", False),
        ("helperFeeCygld", "uint256", False),
    )
    issued_from_basket_expected = (
        ("payer", "address", True),
        ("recipient", "address", True),
        ("orderedCoreAssets", "address[]", False),
        ("amountsIn", "uint256[]", False),
        ("netCygldOut", "uint256", False),
        ("protocolFeeCygld", "uint256", False),
        ("helperFeeCygld", "uint256", False),
    )
    redeemed_to_basket_expected = (
        ("payer", "address", True),
        ("recipient", "address", True),
        ("grossCygldIn", "uint256", False),
        ("kinds", "uint8[]", False),
        ("tokens", "address[]", False),
        ("ids", "uint256[]", False),
        ("amounts", "uint256[]", False),
        ("protocolFeeCygld", "uint256", False),
        ("helperFeeCygld", "uint256", False),
    )
    for label, event, expected in (
        ("Issued", issued, issued_expected),
        ("IssuedFromBasket", issued_from_basket, issued_from_basket_expected),
        ("Redeemed", redeemed, redeemed_expected),
        ("RedeemedToBasket", redeemed_to_basket, redeemed_to_basket_expected),
    ):
        actual = tuple(
            (str(item.get("name", "")), str(item.get("type", "")), bool(item.get("indexed", False)))
            for item in event.get("inputs", [])
        )
        if actual != expected:
            fail(f"event {label}: fields {actual!r}, expected {expected!r}")

    payable = sorted(item["name"] for item in funcs if item.get("stateMutability") == "payable")
    if payable != ["issueFromNativeExactOut"]:
        fail(f"payable function set is {payable!r}")

    rendered = json.dumps(abi, sort_keys=True)
    for forbidden in ("donateDust", "callValue", "recoveryEpoch", "orderedBasketAssets", "QuoteParams", "QuoteResult"):
        if forbidden in rendered:
            fail(f"legacy ABI fragment remains: {forbidden}")

    internal_types: set[str] = set()

    def collect_internal_types(items: list[dict[str, Any]]) -> None:
        for item in items:
            internal_type = item.get("internalType")
            if isinstance(internal_type, str):
                internal_types.add(internal_type)
            components = item.get("components")
            if isinstance(components, list):
                collect_internal_types(components)

    for item in abi:
        collect_internal_types(item.get("inputs", []))
        collect_internal_types(item.get("outputs", []))

    required_internal_types = {
        "struct IBasketRouterTypes.Fees",
        "struct IBasketRouterTypes.IssueFromTokenExactOutParams",
        "struct IBasketRouterTypes.IssueFromTokenExactInParams",
        "struct IBasketRouterTypes.IssueFromNativeExactOutParams",
        "struct IBasketRouterTypes.IssueExecutionParams",
        "struct IBasketRouterTypes.IssueSwapLeg[]",
        "struct IBasketRouterTypes.RedemptionSwapLeg[]",
        "struct IBasketRouterTypes.IssueExactOutPreview",
        "struct IBasketRouterTypes.IssueExactInPreview",
        "struct IBasketRouterTypes.BasketIssueExactOutRequest",
        "struct IBasketRouterTypes.BasketIssueExactInRequest",
        "struct IBasketRouterTypes.BasketIssueExactInPreview",
        "struct IBasketRouterTypes.BasketIssueExactOutPreview",
        "struct IBasketRouterTypes.BasketIssueResult",
        "struct IBasketRouterTypes.RedeemToTokenExactInParams",
        "struct IBasketRouterTypes.AggregatedRedemptionPreview",
        "struct IBasketRouterTypes.AggregatedRedemptionRequest",
        "struct IBasketRouterTypes.AggregatedNativeRedemptionRequest",
        "struct IBasketRouterTypes.AggregatedRedemptionResult",
        "struct IBasketRouterTypes.BasketRedemptionRequest",
        "struct IBasketRouterTypes.BasketRedemptionExactInPreview",
        "struct IBasketRouterTypes.BasketRedemptionExactOutPreview",
        "struct IBasketRouterTypes.BasketRedemptionResult",
        "struct IBasketRouterTypes.PermitParams",
        "struct IBasketRouterTypes.Permit2Params",
        "struct IBasketRouterTypes.Permit2BatchParams",
        "struct ICoreRedemption.TokenAmount[]",
        "struct ICoreRedemption.TokenMinimum[]",
    }
    missing_internal_types = sorted(required_internal_types - internal_types)
    if missing_internal_types:
        fail(f"frozen internal types missing: {missing_internal_types!r}")

    print("Helpers semantic ABI conformance OK")


if __name__ == "__main__":
    main()
