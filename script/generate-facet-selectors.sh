#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/cybergold-protocol/script/helpers/foundry.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/cybergold-protocol/script/helpers/selector-utils.sh"

require_forge
require_cast

inspect_methods() {
  local root="$1"
  local target="$2"
  forge_inspect_methods "$root" "$target" \
    | awk -F'|' '
      /^\|/ {
        m=$2; s=$3;
        gsub(/^[ \t]+|[ \t]+$/, "", m);
        gsub(/^[ \t]+|[ \t]+$/, "", s);
        if (s ~ /^[0-9a-fA-F]{8}$/) {
          print m "|" tolower(s);
        }
      }'
}

declare -A EXCLUDE_SELECTORS=()
add_exclude() {
  EXCLUDE_SELECTORS["$1"]=1
}

add_exclude_sig() {
  local sig="$1"
  local selector
  selector="$(cast sig "$sig")"
  selector="${selector#0x}"
  add_exclude "$selector"
}

# Selectors that intentionally overlap across facets (FACET_VERSION / FACET_NAMESPACE).
while IFS= read -r selector; do
  add_exclude "$selector"
done < <(selector_shared_list)

BASE_ROOT="$ROOT"
BASE_TARGETS=(
  "src/facets/DiamondCutOwnerLiveFacet.sol:DiamondCutOwnerLiveFacet"
  "OwnershipFacet"
  "src/facets/OwnerPausableFacet.sol:OwnerPausableFacet"
)

ensure_base_lib_link() {
  local lib_link="$BASE_ROOT/lib"
  if [ ! -e "$lib_link" ]; then
    ln -s "$ROOT/lib/cybergold-protocol/lib" "$lib_link"
  fi
}

ensure_base_lib_link

for target in "${BASE_TARGETS[@]}"; do
  while IFS='|' read -r _sig selector; do
    add_exclude "$selector"
  done < <(inspect_methods "$BASE_ROOT" "$target")
done

add_exclude_sig "facets()"
add_exclude_sig "facetFunctionSelectors(address)"
add_exclude_sig "facetAddresses()"
add_exclude_sig "facetAddress(bytes4)"
add_exclude_sig "supportsInterface(bytes4)"

collect_selectors() {
  local root="$1"
  local target="$2"
  local used_var="$3"
  local out_var="$4"
  declare -n used_ref="$used_var"
  declare -n out_ref="$out_var"

  local -a entries=()
  local skipped=0
  local methods=""
  methods="$(inspect_methods "$root" "$target")"

  while IFS='|' read -r sig selector; do
    if [[ "$sig" =~ ^init[A-Z] ]]; then
      continue
    fi
    if [[ -n "${EXCLUDE_SELECTORS[$selector]:-}" ]]; then
      continue
    fi
    if [[ -n "${used_ref[$selector]:-}" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    used_ref[$selector]="$target"
    entries+=("${sig}|${selector}")
  done <<< "$methods"

  if [ "$skipped" -gt 0 ]; then
    echo "Note: skipped ${skipped} selectors from ${target} due to earlier facets." >&2
  fi

  out_ref=()
  if [ "${#entries[@]}" -gt 0 ]; then
    IFS=$'\n' read -r -d '' -a out_ref < <(printf '%s\n' "${entries[@]}" | sort && printf '\0')
  fi
}

write_selectors() {
  local func_name="$1"
  local out="$2"
  local selectors="$3"
  local facet_name="$4"

  local -a sorted=()
  if [[ -n "$selectors" ]]; then
    mapfile -t sorted <<< "$selectors"
  fi

  {
    echo "    /// @notice Return selectors exposed by the ${facet_name} facet."
    echo "    /// @return selectors ${facet_name} facet selectors in deterministic order."
    echo "    function ${func_name}() internal pure returns (bytes4[] memory selectors) {"
    echo "        selectors = new bytes4[](${#sorted[@]});"
    local i=0
    local entry sig selector
    for entry in "${sorted[@]}"; do
      sig="${entry%%|*}"
      selector="${entry##*|}"
      echo "        selectors[${i}] = 0x${selector}; // ${sig}"
      i=$((i + 1))
    done
    echo "    }"
    echo ""
  } >> "$out"
}

generate_helpers() {
  local out_file="$1"
  local comment="$2"

  local tmp
  tmp="$(mktemp)"

  {
    echo "// SPDX-License-Identifier: AGPL-3.0"
    echo "pragma solidity ^0.8.37;"
    echo ""
    echo "import {FacetSpec} from \"diamond-infra/deploy/FacetSpec.sol\";"
    echo ""
    echo "/// @notice ${comment}"
    echo "library FacetSelectors {"
    echo ""
  } > "$tmp"

  declare -A used=()
  declare -A selectors_by_func=()

  local -a facets=(
    "adminSelectors|admin|admin|src/facets/RouterAdminFacet.sol:RouterAdminFacet"
    "issuePreviewSelectors|issuePreview|issuePreview|src/facets/RouterIssuePreviewFacet.sol:RouterIssuePreviewFacet"
    "issueSelectors|issue|issue|src/facets/RouterIssueFacet.sol:RouterIssueFacet"
    "issueBasketSelectors|issueBasket|issueBasket|src/facets/RouterIssueBasketFacet.sol:RouterIssueBasketFacet"
    "redeemSelectors|redeem|redeem|src/facets/RouterRedeemFacet.sol:RouterRedeemFacet"
    "redeemBasketSelectors|redeemBasket|redeemBasket|src/facets/RouterRedeemBasketFacet.sol:RouterRedeemBasketFacet"
    "recoveryShareReceiverSelectors|recoveryShareReceiver|recoveryShareReceiver|src/facets/RecoveryShareReceiverFacet.sol:RecoveryShareReceiverFacet"
  )

  local entry func_name facet_name param_name target
  for entry in "${facets[@]}"; do
    IFS='|' read -r func_name facet_name param_name target <<< "$entry"
    local -a collected=()
    collect_selectors "$ROOT" "$target" used collected
    selectors_by_func["$func_name"]="$(printf '%s\n' "${collected[@]}")"
  done

  for entry in "${facets[@]}"; do
    IFS='|' read -r func_name facet_name param_name target <<< "$entry"
    write_selectors "$func_name" "$tmp" "${selectors_by_func[$func_name]}" "$facet_name"
  done

  local params=""
  for entry in "${facets[@]}"; do
    IFS='|' read -r func_name facet_name param_name target <<< "$entry"
    if [[ -n "$params" ]]; then
      params+=", "
    fi
    params+="address ${param_name}"
  done

  {
    echo "    /// @notice Build facet specifications for this diamond cut."
    for entry in "${facets[@]}"; do
      IFS='|' read -r _func_name facet_name param_name _target <<< "$entry"
      echo "    /// @param ${param_name} ${facet_name} facet address."
    done
    echo "    /// @return entries Named facet specifications with their expected selectors."
    echo "    function specs(${params})"
    echo "        internal"
    echo "        pure"
    echo "        returns (FacetSpec.Entry[] memory entries)"
    echo "    {"
    echo "        entries = new FacetSpec.Entry[](${#facets[@]});"
  } >> "$tmp"

  local i=0
  for entry in "${facets[@]}"; do
    IFS='|' read -r func_name facet_name param_name target <<< "$entry"
    echo "        entries[${i}] = FacetSpec.Entry({name: \"${facet_name}\", facet: ${param_name}, selectors: ${func_name}()});" >> "$tmp"
    i=$((i + 1))
  done

  {
    echo "    }"
    echo "}"
  } >> "$tmp"

  mv "$tmp" "$out_file"
  echo "Generated $out_file"
}

OUT_FILE="$ROOT/src/deploy/FacetSelectors.sol"
COMMENT="Selector tables for the helpers diamond to keep deployment helpers/test harnesses in sync."

case "${1:-}" in
  --check)
    tmp_dir="$(mktemp -d)"
    tmp="$tmp_dir/FacetSelectors.sol"
    generate_helpers "$tmp" "$COMMENT" >/dev/null
    forge fmt "$tmp" >/dev/null
    if ! diff -u "$OUT_FILE" "$tmp" >/dev/null; then
      echo "ERROR: $OUT_FILE is out of date. Run: script/generate-facet-selectors.sh" >&2
      diff -u "$OUT_FILE" "$tmp" || true
      rm -rf "$tmp_dir"
      exit 1
    fi
    rm -rf "$tmp_dir"
    ;;
  *)
    generate_helpers "$OUT_FILE" "$COMMENT"
    forge fmt "$OUT_FILE" >/dev/null
    ;;
esac
