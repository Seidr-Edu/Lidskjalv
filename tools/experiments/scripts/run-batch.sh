#!/usr/bin/env bash
# run-batch.sh - run a manifest of experiment cases sequentially.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TOOLS_DIR}/../.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: ./experiment-batch-run.sh --manifest <path> [options]

Options:
  --manifest <path>   JSON runset manifest (required)
  --fail-fast         Stop after the first non-zero experiment exit
  --dry-run           Print commands without executing
  -h, --help          Show help
USAGE
}

log() { printf '[batch][INFO] %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; }
warn() { printf '[batch][WARN] %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; }
fail() { printf '[batch][ERROR] %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

abs_path() {
  python3 - <<'PY' "$1"
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
}

sanitize_id() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr '[:space:]/:@' '_____' | tr -cd 'A-Za-z0-9._-')"
  [[ -n "$raw" ]] || raw="batch"
  printf '%s\n' "$raw"
}

get_json_field() {
  local json="$1"
  local jq_expr="$2"
  printf '%s' "$json" | jq -r "$jq_expr"
}

append_opt_if_nonempty() {
  local flag="$1"
  local value="$2"
  if [[ -n "$value" && "$value" != "null" ]]; then
    cmd+=("$flag" "$value")
  fi
  return 0
}

append_bool_flag_if_true() {
  local flag="$1"
  local value="$2"
  if [[ "$value" == "true" ]]; then
    cmd+=("$flag")
  fi
  return 0
}

parse_args() {
  MANIFEST_PATH=""
  FAIL_FAST=false
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest) MANIFEST_PATH="${2:-}"; shift 2 ;;
      --fail-fast) FAIL_FAST=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown argument: $1" ;;
    esac
  done
}

validate_manifest() {
  [[ -n "$MANIFEST_PATH" ]] || fail "--manifest is required"
  MANIFEST_PATH="$(abs_path "$MANIFEST_PATH")"
  [[ -f "$MANIFEST_PATH" ]] || fail "manifest not found: $MANIFEST_PATH"

  jq -e '.version == 1' "$MANIFEST_PATH" >/dev/null || fail "manifest version must be 1"
  jq -e '.runs | type == "array" and length > 0' "$MANIFEST_PATH" >/dev/null || fail "manifest.runs must be a non-empty array"
}

setup_batch_dirs() {
  local manifest_stem
  manifest_stem="$(basename "$MANIFEST_PATH" .json)"
  local batch_id
  batch_id="$(date -u +"%Y%m%dT%H%M%SZ")__$(sanitize_id "$manifest_stem")"

  BATCH_ID="$batch_id"
  BATCH_RUN_DIR="${REPO_ROOT}/.data/experiments/batches/${BATCH_ID}"
  BATCH_LOG_DIR="${BATCH_RUN_DIR}/logs"
  BATCH_RESULTS_TSV="${BATCH_RUN_DIR}/results.tsv"
  BATCH_SUMMARY_MD="${BATCH_RUN_DIR}/summary.md"

  mkdir -p "$BATCH_LOG_DIR"
  printf 'index\tid\tdiagram\tsource_repo\tsource_subdir\texit_code\tresult\n' > "$BATCH_RESULTS_TSV"
}

materialize_run_case() {
  local idx="$1"
  local run_json="$2"

  local merged
  merged="$(jq -c --argjson run "$run_json" '
    (.defaults // {}) as $d |
    (.sources // {}) as $s |
    ($run.source // "") as $source_key |
    ($s[$source_key] // {}) as $src |
    ($d + $src + $run)
  ' "$MANIFEST_PATH")"

  local source_key
  source_key="$(get_json_field "$run_json" '.source // ""')"
  if [[ -n "$source_key" && "$source_key" != "null" ]]; then
    jq -e --arg key "$source_key" '.sources[$key] != null' "$MANIFEST_PATH" >/dev/null \
      || fail "run[$idx] references missing source key: $source_key"
  fi

  local run_id diagram source_repo source_subdir
  run_id="$(get_json_field "$merged" '.id // ""')"
  diagram="$(get_json_field "$merged" '.diagram // ""')"
  source_repo="$(get_json_field "$merged" '.source_repo // ""')"
  source_subdir="$(get_json_field "$merged" '.source_subdir // ""')"

  [[ -n "$diagram" && "$diagram" != "null" ]] || fail "run[$idx] missing diagram"
  [[ -n "$source_repo" && "$source_repo" != "null" ]] || fail "run[$idx] missing source_repo (direct or via sources catalog)"

  if [[ "$diagram" != /* ]]; then
    diagram="${REPO_ROOT}/${diagram}"
  fi
  [[ -f "$diagram" ]] || fail "run[$idx] diagram not found: $diagram"

  local case_id
  if [[ -n "$run_id" && "$run_id" != "null" ]]; then
    case_id="$run_id"
  else
    case_id="$(basename "$diagram" .puml)"
  fi

  local -a cmd=("${REPO_ROOT}/experiment-run.sh"
    --diagram "$diagram"
    --source-repo "$source_repo"
  )

  append_opt_if_nonempty --source-subdir "$source_subdir"
  append_opt_if_nonempty --gating-mode "$(get_json_field "$merged" '.gating_mode // ""')"
  append_opt_if_nonempty --max-iter "$(get_json_field "$merged" '.max_iter // ""')"
  append_opt_if_nonempty --max-gate-revisions "$(get_json_field "$merged" '.max_gate_revisions // ""')"
  append_opt_if_nonempty --model-gate-timeout-sec "$(get_json_field "$merged" '.model_gate_timeout_sec // ""')"
  append_opt_if_nonempty --scan-original "$(get_json_field "$merged" '.scan_original // ""')"
  append_opt_if_nonempty --test-port "$(get_json_field "$merged" '.test_port // ""')"
  append_opt_if_nonempty --test-port-max-iter "$(get_json_field "$merged" '.test_port_max_iter // ""')"
  append_bool_flag_if_true --skip-sonar "$(get_json_field "$merged" '.skip_sonar // false')"
  append_bool_flag_if_true --strict-test-port "$(get_json_field "$merged" '.strict_test_port // false')"

  RUN_CASE_ID="$case_id"
  RUN_CASE_DIAGRAM="$diagram"
  RUN_CASE_SOURCE_REPO="$source_repo"
  RUN_CASE_SOURCE_SUBDIR="${source_subdir:-}"
  RUN_CASE_CMD_JSON="$merged"
  RUN_CASE_CMD=("${cmd[@]}")
}

write_summary() {
  local total="$1" ok="$2" failed="$3"
  {
    echo "# Experiment Batch Summary"
    echo
    echo "- Batch ID: ${BATCH_ID}"
    echo "- Manifest: ${MANIFEST_PATH}"
    echo "- Total runs: **${total}**"
    echo "- Passed (exit 0): **${ok}**"
    echo "- Failed (exit != 0): **${failed}**"
    echo "- Results TSV: ${BATCH_RESULTS_TSV}"
    echo "- Logs dir: ${BATCH_LOG_DIR}"
  } > "$BATCH_SUMMARY_MD"
}

main() {
  parse_args "$@"
  require_cmd jq
  require_cmd python3
  validate_manifest
  setup_batch_dirs

  log "manifest: $MANIFEST_PATH"
  log "batch run dir: $BATCH_RUN_DIR"

  local run_count
  run_count="$(jq '.runs | length' "$MANIFEST_PATH")"
  local executed_count=0
  local success_count=0
  local failure_count=0

  local idx=0
  while IFS= read -r run_json; do
    materialize_run_case "$idx" "$run_json"

    local case_log="${BATCH_LOG_DIR}/$(printf '%02d' "$((idx+1))")__$(sanitize_id "$RUN_CASE_ID").log"
    log "[$((idx+1))/${run_count}] ${RUN_CASE_ID}"
    log "diagram=$(realpath "$RUN_CASE_DIAGRAM" 2>/dev/null || printf '%s' "$RUN_CASE_DIAGRAM") source=${RUN_CASE_SOURCE_REPO}${RUN_CASE_SOURCE_SUBDIR:+ subdir=${RUN_CASE_SOURCE_SUBDIR}}"

    local rc=0
    if $DRY_RUN; then
      printf 'DRY RUN: ' | tee "$case_log" >/dev/null
      printf '%q ' "${RUN_CASE_CMD[@]}" | tee -a "$case_log" >/dev/null
      printf '\n' | tee -a "$case_log" >/dev/null
      rc=0
    else
      set +e
      "${RUN_CASE_CMD[@]}" >"$case_log" 2>&1
      rc=$?
      set -e
    fi

    local result_word="ok"
    if [[ "$rc" -eq 0 ]]; then
      success_count=$((success_count + 1))
    else
      failure_count=$((failure_count + 1))
      result_word="failed"
      warn "case ${RUN_CASE_ID} exited ${rc} (log: ${case_log})"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$((idx+1))" \
      "$RUN_CASE_ID" \
      "$RUN_CASE_DIAGRAM" \
      "$RUN_CASE_SOURCE_REPO" \
      "${RUN_CASE_SOURCE_SUBDIR:-}" \
      "$rc" \
      "$result_word" >> "$BATCH_RESULTS_TSV"
    executed_count=$((executed_count + 1))

    if $FAIL_FAST && [[ "$rc" -ne 0 ]]; then
      break
    fi

    idx=$((idx + 1))
  done < <(jq -c '.runs[]' "$MANIFEST_PATH")

  write_summary "$executed_count" "$success_count" "$failure_count"

  log "summary: $BATCH_SUMMARY_MD"
  log "results: $BATCH_RESULTS_TSV"

  [[ "$failure_count" -eq 0 ]]
}

main "$@"
