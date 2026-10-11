#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/cybergold-protocol/script/helpers/selector-utils.sh"

FACET_DIR_REL="src/facets"
SNAPSHOT_PATH="$ROOT/ci/selector-snapshot.helpers.txt"

function list_facets() {
  local facet_dir="$ROOT/$FACET_DIR_REL"
  if [ ! -d "$facet_dir" ]; then
    echo "ERROR: facet directory missing at $facet_dir" >&2
    exit 1
  fi
  find "$facet_dir" -maxdepth 1 -type f -name '*Facet.sol' -print0 \
    | sort -z \
    | while IFS= read -r -d '' file; do
        basename "${file%.sol}"
      done
}

function generate_snapshot() {
  local out_file="$1"
  : > "$out_file"
  mapfile -t facets < <(list_facets)
  if [ "${#facets[@]}" -eq 0 ]; then
    echo "WARNING: no facets found under $ROOT/$FACET_DIR_REL" >&2
  fi
  for facet in "${facets[@]}"; do
    echo "## $facet" >> "$out_file"
    local target="$FACET_DIR_REL/${facet}.sol:${facet}"
    forge_inspect_methods "$ROOT" "$target" >> "$out_file"
    echo "" >> "$out_file"
  done
}

case "${1:-}" in
  --update)
    generate_snapshot "$SNAPSHOT_PATH"
    echo "Selector snapshot updated at $SNAPSHOT_PATH"
    ;;
  *)
    if [ ! -f "$SNAPSHOT_PATH" ]; then
      echo "ERROR: snapshot file missing at $SNAPSHOT_PATH. Run with --update to create it." >&2
      exit 1
    fi
    tmp="$(mktemp)"
    generate_snapshot "$tmp"
    if ! diff -u "$SNAPSHOT_PATH" "$tmp" >/dev/null; then
      echo "ERROR: selector snapshot drift detected. If intentional, run: ci/check-selector-snapshots.sh --update" >&2
      diff -u "$SNAPSHOT_PATH" "$tmp" || true
      rm -f "$tmp"
      exit 1
    fi
    rm -f "$tmp"
    ;;
esac
