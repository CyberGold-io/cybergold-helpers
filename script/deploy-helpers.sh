#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENV="${ROOT}/.env.local"
if [[ -f "$LOCAL_ENV" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$LOCAL_ENV"
  set +a
fi

# shellcheck source=/dev/null
source "${ROOT}/script/helpers/config.sh"

ZERO_ADDRESS="0x0000000000000000000000000000000000000000"

set_env_from_config() {
  local env_key="$1"
  local config_key="$2"
  if [[ -n "${!env_key:-}" ]]; then
    return 0
  fi

  local value
  if ! value="$(config_read "$config_key")"; then
    return 0
  fi

  export "${env_key}=${value}"
}

set_address_env_from_config() {
  local env_key="$1"
  local config_key="$2"
  if [[ -n "${!env_key:-}" ]]; then
    return 0
  fi

  local value
  if ! value="$(config_read "$config_key")"; then
    return 0
  fi

  local lower
  lower="${value,,}"
  if [[ "$lower" == "${ZERO_ADDRESS,,}" ]]; then
    return 0
  fi

  export "${env_key}=${value}"
}

set_address_env_from_config HELPER_ADMIN "helpers.admin"
set_env_from_config HELPER_FEE_PPM "helpers.helperFeePpm"
set_address_env_from_config CORE_DIAMOND_ADDRESS "helpers.coreDiamond"
set_address_env_from_config PERMIT2_ADDR "helpers.permit2"
set_address_env_from_config WETH_ADDR "helpers.wrappedNative"
set_address_env_from_config ONEINCH_ROUTER "helpers.oneInchRouter"
set_address_env_from_config UNISWAP_ROUTER "helpers.uniswapRouter"

if [[ -z "${HELPER_ADMIN:-}" ]]; then
  echo "HELPER_ADMIN is required and must be supplied explicitly; no deployment-owner default is permitted." >&2
  exit 1
fi

if [[ "${HELPER_ADMIN,,}" == "${ZERO_ADDRESS,,}" ]]; then
  echo "HELPER_ADMIN must be nonzero." >&2
  exit 1
fi

if [[ -z "${CORE_DIAMOND_ADDRESS:-}" ]]; then
  echo "CORE_DIAMOND_ADDRESS is required (env or config/deploy-config.json .helpers.coreDiamond)." >&2
  exit 1
fi

echo "Helpers package execution is simulation-only; use cybergold-ops/deploy/cgops for transaction submission."
forge script "${ROOT}/script/DeployHelpers.s.sol:DeployHelpers" --slow "$@"
