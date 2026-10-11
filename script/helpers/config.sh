#!/usr/bin/env bash
# shellcheck shell=bash

config_path() {
  echo "${DEPLOY_CONFIG_PATH:-$ROOT/config/deploy-config.json}"
}

config_exists() {
  [[ -f "$(config_path)" ]]
}

config_read() {
  local key="$1"
  local path
  path="$(config_path)"

  if [[ ! -f "$path" ]]; then
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required to read ${path}" >&2
    exit 1
  fi

  local out
  out="$(jq -r ".$key // empty | if type == \"number\" then tostring elif type == \"boolean\" then (if . then \"1\" else \"0\" end) else . end" "$path")"
  if [[ -z "$out" || "$out" == "null" ]]; then
    return 1
  fi
  echo "$out"
}
