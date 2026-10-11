#!/usr/bin/env python3
"""Remove RPC URLs and credential-bearing fragments from retained diagnostics."""

from __future__ import annotations

import os
import urllib.parse


def _add_candidate(
    tokens: set[str],
    candidate: str | None,
    *,
    minimum_length: int = 1,
) -> None:
    if not candidate:
        return
    for value in (candidate, urllib.parse.unquote(candidate)):
        if len(value) >= minimum_length:
            tokens.add(value)


def rpc_secret_tokens(rpc_url: str) -> set[str]:
    """Return full and fragment forms that an RPC client/provider may echo."""

    tokens: set[str] = set()
    _add_candidate(tokens, rpc_url)
    decoded_url = urllib.parse.unquote(rpc_url)
    _add_candidate(tokens, decoded_url)

    for candidate_url in (rpc_url, decoded_url):
        parsed = urllib.parse.urlsplit(candidate_url)
        _add_candidate(tokens, parsed.username)
        _add_candidate(tokens, parsed.password)
        for segment in parsed.path.split("/"):
            _add_candidate(tokens, segment, minimum_length=4)
        for _, value in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True):
            _add_candidate(tokens, value)
        _add_candidate(tokens, parsed.fragment)

    # Only very short path components such as "v2" are ignored as protocol
    # structure. Explicit username/password/query/fragment values are always
    # credentials, even when an unsafe provider configuration made them short.
    return tokens


def sanitize_rpc_text(
    text: str,
    rpc_url: str,
    *,
    url_replacement: str,
    credential_replacement: str,
    bearer: str | None = None,
) -> str:
    selected_bearer = bearer if bearer is not None else os.environ.get("MAINNET_RPC_BEARER", "")
    sanitized = text.replace(selected_bearer, credential_replacement) if selected_bearer else text
    full_url_tokens = {rpc_url, urllib.parse.unquote(rpc_url)}
    for token in sorted(rpc_secret_tokens(rpc_url), key=len, reverse=True):
        replacement = url_replacement if token in full_url_tokens else credential_replacement
        sanitized = sanitized.replace(token, replacement)
    return sanitized
