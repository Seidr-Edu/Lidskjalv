#!/usr/bin/env bash
# exp_naming.sh - experiment IDs and sonar key/name derivation.

set -euo pipefail

_exp_limit_project_key() {
  local raw="$1"
  local key
  key="$(sanitize_project_key "$raw")"

  # Sonar supports long keys, but keep headroom for future suffixes and readability.
  if [[ ${#key} -le 180 ]]; then
    echo "$key"
    return 0
  fi

  local suffix_hash=""
  if declare -F _short_hash >/dev/null 2>&1; then
    suffix_hash="$(_short_hash "$key")"
  elif command -v shasum >/dev/null 2>&1; then
    suffix_hash="$(printf '%s' "$key" | shasum -a 1 | awk '{print substr($1,1,8)}')"
  elif command -v sha1sum >/dev/null 2>&1; then
    suffix_hash="$(printf '%s' "$key" | sha1sum | awk '{print substr($1,1,8)}')"
  else
    suffix_hash="$(printf '%s' "$key" | cksum | awk '{print $1}')"
  fi

  printf '%s__%s\n' "${key:0:169}" "$suffix_hash"
}

exp_init_source_identity() {
  local parsed
  parsed="$(parse_repo_source "$SOURCE_REPO_RAW" 2>/dev/null || true)"
  [[ -n "$parsed" ]] || exp_fail "invalid --source-repo: $SOURCE_REPO_RAW"
  IFS='|' read -r SOURCE_TYPE SOURCE_REF <<< "$parsed"
  SOURCE_REF="$(normalize_source_ref "$SOURCE_TYPE" "$SOURCE_REF" "$REPO_ROOT")"

  ORIGINAL_SOURCE_KEY="$(derive_source_key "$SOURCE_TYPE" "$SOURCE_REF" "")"
  ORIGINAL_DISPLAY_NAME="$(derive_source_display_name "$SOURCE_TYPE" "$SOURCE_REF" "")"
  ORIGINAL_SCAN_KEY="$ORIGINAL_SOURCE_KEY"
  ORIGINAL_SCAN_DISPLAY_NAME="$ORIGINAL_DISPLAY_NAME"
  if [[ -n "$SOURCE_SUBDIR" ]]; then
    local subdir_fragment
    subdir_fragment="$(printf '%s' "$SOURCE_SUBDIR" | sed -E 's#[^a-zA-Z0-9_.-]+#_#g; s#_+#_#g; s#^_+##; s#_+$##')"
    [[ -n "$subdir_fragment" ]] || subdir_fragment="subdir"
    ORIGINAL_SCAN_KEY="$(_exp_limit_project_key "${ORIGINAL_SOURCE_KEY}__subdir__${subdir_fragment}")"
    ORIGINAL_SCAN_DISPLAY_NAME="${ORIGINAL_DISPLAY_NAME} [subdir:${SOURCE_SUBDIR}]"
  fi

  DIAGRAM_STEM="$(basename "$DIAGRAM_PATH")"
  DIAGRAM_STEM="${DIAGRAM_STEM%.*}"

  EXP_TS="$(exp_timestamp_compact_utc)"
  if [[ -z "$RUN_ID" ]]; then
    RUN_ID="${EXP_TS}__${ORIGINAL_SOURCE_KEY}__${DIAGRAM_STEM}"
  fi

  GENERATED_SONAR_KEY="$(_exp_limit_project_key "${ORIGINAL_SOURCE_KEY}__gen__${DIAGRAM_STEM}__${EXP_TS}")"
  GENERATED_DISPLAY_NAME="${ORIGINAL_DISPLAY_NAME} [andvari gen:${DIAGRAM_STEM} @ ${EXP_TS}]"
}
