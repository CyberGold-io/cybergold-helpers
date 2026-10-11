#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
# shellcheck disable=SC2153
source "$ROOT/lib/cybergold-protocol/script/helpers/selector-utils.sh"

# Selectors intentionally shared across facets (e.g., FACET_VERSION, FACET_NAMESPACE).
declare -A DUPLICATE_SELECTOR_WHITELIST=()
shared_selectors="$(selector_shared_list)"
while IFS= read -r selector; do
  DUPLICATE_SELECTOR_WHITELIST["$selector"]=1
done <<< "$shared_selectors"

function inspect_methods() {
  local root="$1"
  local target="$2"
  local raw
  local methods
  if ! raw="$(forge_inspect_methods "$root" "$target")"; then
    echo "ERROR: forge inspect failed for selector target $target" >&2
    return 1
  fi
  if ! methods="$(
    awk -F'|' '
      /^\|/ {
        m=$2; s=$3;
        gsub(/^[ \t]+|[ \t]+$/, "", m);
        gsub(/^[ \t]+|[ \t]+$/, "", s);
        if (s ~ /^[0-9a-fA-F]{8}$/) {
          print m "|" tolower(s);
        }
      }' <<< "$raw"
  )"; then
    echo "ERROR: selector inventory parsing failed for $target" >&2
    return 1
  fi
  if [[ -z "$methods" ]]; then
    echo "ERROR: selector target returned an empty method inventory: $target" >&2
    return 1
  fi
  printf '%s\n' "$methods"
}

function gather_selectors() {
  local -a base_targets=(
    "cut|src/facets/DiamondCutOwnerFacet.sol:DiamondCutOwnerFacet"
    "loupe|lib/cybergold-protocol/packages/0_shared/src/facets/ProtocolDiamondLoupeFacet.sol"
    "ownership|OwnershipFacet"
    "pause|src/facets/OwnerPausableFacet.sol:OwnerPausableFacet"
  )

  local entry facet target methods
  for entry in "${base_targets[@]}"; do
    IFS='|' read -r facet target <<< "$entry"
    if ! methods="$(inspect_methods "$ROOT" "$target")"; then
      return 1
    fi
    while IFS='|' read -r sig selector; do
      echo "SELECTOR helpers ${facet} 0x${selector} ${sig}"
    done <<< "$methods"
  done

  local product_selectors
  if ! product_selectors="$(
    awk '
      /function [A-Za-z0-9_]+Selectors\(/ {
        facet = $2
        sub(/\(.*/, "", facet)
        sub(/Selectors$/, "", facet)
      }
      /selectors\[[0-9]+\] = 0x[0-9a-fA-F]+;/ {
        selector = $0
        sub(/^.*= 0x/, "", selector)
        sub(/;.*/, "", selector)
        sig = $0
        sub(/^.*\/\/[ \t]*/, "", sig)
        print "SELECTOR helpers " facet " 0x" tolower(selector) " " sig
      }
    ' "$ROOT/src/deploy/FacetSelectors.sol"
  )"; then
    echo "ERROR: generated product selector inventory could not be read" >&2
    return 1
  fi
  if [[ -z "$product_selectors" ]]; then
    echo "ERROR: generated product selector inventory is empty" >&2
    return 1
  fi
  printf '%s\n' "$product_selectors"
}

function check_duplicates() {
  declare -A seen=()
  declare -A dupes=()
  local count=0
  local selectors
  if ! selectors="$(gather_selectors)"; then
    echo "ERROR: selector gathering failed" >&2
    return 1
  fi
  if [[ -z "$selectors" ]]; then
    echo "ERROR: no selectors gathered for duplicate check" >&2
    return 1
  fi
  while read -r _ pkg facet selector _sig; do
    count=$((count + 1))
    selector="${selector#0x}"
    if [[ -n "${DUPLICATE_SELECTOR_WHITELIST[$selector]:-}" ]]; then
      continue
    fi
    local value="${pkg}:${facet}"
    if [[ -n "${seen[$selector]:-}" ]]; then
      dupes[$selector]="${seen[$selector]},${value}"
    else
      seen[$selector]="$value"
    fi
  done <<< "$selectors"

  if [ "$count" -eq 0 ]; then
    echo "ERROR: no selectors gathered for duplicate check" >&2
    return 1
  fi

  if [ "${#dupes[@]}" -gt 0 ]; then
    echo "ERROR: duplicate selectors detected" >&2
    for selector in "${!dupes[@]}"; do
      echo "  selector 0x${selector} used by facets: ${dupes[$selector]}" >&2
    done
    return 1
  fi
}

if ! check_duplicates; then
  exit 1
fi
