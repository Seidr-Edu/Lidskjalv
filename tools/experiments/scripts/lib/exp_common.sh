#!/usr/bin/env bash
# exp_common.sh - shared utilities and defaults for experiment orchestration.

set -euo pipefail

exp_timestamp_compact_utc() { date -u +"%Y%m%dT%H%M%SZ"; }
exp_timestamp_iso_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

exp_log() { printf '[exp][INFO] %s %s\n' "$(exp_timestamp_iso_utc)" "$*" >&2; }
exp_warn() { printf '[exp][WARN] %s %s\n' "$(exp_timestamp_iso_utc)" "$*" >&2; }
exp_err() { printf '[exp][ERROR] %s %s\n' "$(exp_timestamp_iso_utc)" "$*" >&2; }
exp_fail() { exp_err "$*"; exit 1; }

exp_sha256_file() {
  local target="$1"
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$target" | awk '{print $1}';
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$target" | awk '{print $1}';
  else cksum "$target" | awk '{print $1}'; fi
}

exp_tree_fingerprint() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    echo "missing"
    return 0
  fi
  local manifest
  manifest="$(mktemp)"
  (
    cd "$dir"
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      printf '%s\t%s\n' "$rel" "$(exp_sha256_file "${dir}/${rel#./}")"
    done < <(find . -type f ! -path './.git/*' -print | LC_ALL=C sort)
  ) > "$manifest"
  exp_sha256_file "$manifest"
  rm -f "$manifest"
}

exp_copy_dir() {
  local src="$1" dest="$2"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -R "$src" "$dest"
}

exp_json_escape() {
  python3 - <<'PY' "$1"
import json,sys
print(json.dumps(sys.argv[1]))
PY
}
