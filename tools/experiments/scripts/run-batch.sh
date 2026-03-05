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
  --reuse-codegen-auto
                      Reuse latest compatible prior generated repo and skip codegen
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
  REUSE_CODEGEN_AUTO=false
  FAIL_FAST=false
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest) MANIFEST_PATH="${2:-}"; shift 2 ;;
      --reuse-codegen-auto) REUSE_CODEGEN_AUTO=true; shift ;;
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
  printf 'index\tid\tdiagram\tsource_repo\tsource_subdir\texit_code\tresult\tdetail\n' > "$BATCH_RESULTS_TSV"
}

resolve_reuse_codegen_candidate() {
  local diagram="$1"
  local source_repo="$2"
  local source_subdir="$3"
  local exclude_run_id="${4:-}"

  python3 - <<'PY' "${REPO_ROOT}/.data/experiments/runs" "$diagram" "$source_repo" "$source_subdir" "$exclude_run_id"
import glob
import json
import os
import sys

runs_root, diagram, source_repo, source_subdir, exclude_run_id = sys.argv[1:]
target_diagram = os.path.abspath(diagram)
target_source = source_repo
target_subdir = source_subdir or ""

candidates = []
for path in glob.glob(os.path.join(runs_root, "*", "outputs", "experiment.json")):
    try:
        with open(path, "r", encoding="utf-8") as f:
            obj = json.load(f)
    except Exception:
        continue

    exp_id = obj.get("experiment_id") or ""
    if exclude_run_id and exp_id == exclude_run_id:
        continue

    inputs = obj.get("inputs") if isinstance(obj.get("inputs"), dict) else {}
    src = inputs.get("source_repo") if isinstance(inputs.get("source_repo"), dict) else {}
    diagram_path = os.path.abspath(str(inputs.get("diagram_path") or ""))
    src_raw = str(src.get("raw") or "")
    src_subdir = str(src.get("subdir") or "")
    if diagram_path != target_diagram:
        continue
    if src_raw != target_source:
        continue
    if src_subdir != target_subdir:
        continue

    andvari = obj.get("andvari") if isinstance(obj.get("andvari"), dict) else {}
    try:
        andvari_exit = int(andvari.get("exit_code"))
    except Exception:
        continue
    if andvari_exit != 0:
        continue

    run_dir = str(andvari.get("run_dir") or "")
    if not run_dir:
        continue
    new_repo = os.path.abspath(os.path.join(run_dir, "new_repo"))
    if not os.path.isdir(new_repo):
        continue
    has_content = False
    for _root, _dirs, files in os.walk(new_repo):
        if files:
            has_content = True
            break
    if not has_content:
        continue

    finished_at = str(obj.get("finished_at") or "")
    started_at = str(obj.get("started_at") or "")
    candidates.append((finished_at, started_at, exp_id, new_repo))

if not candidates:
    raise SystemExit(1)

best = max(candidates, key=lambda item: (item[0], item[1], item[2]))
print(f"{best[2]}\t{best[3]}")
PY
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
  append_opt_if_nonempty --sonar-wait "$(get_json_field "$merged" '.sonar_wait // ""')"
  append_opt_if_nonempty --sonar-wait-timeout-sec "$(get_json_field "$merged" '.sonar_wait_timeout_sec // ""')"
  append_opt_if_nonempty --sonar-wait-poll-sec "$(get_json_field "$merged" '.sonar_wait_poll_sec // ""')"
  append_opt_if_nonempty --test-port "$(get_json_field "$merged" '.test_port // ""')"
  append_opt_if_nonempty --test-port-max-iter "$(get_json_field "$merged" '.test_port_max_iter // ""')"
  append_bool_flag_if_true --skip-sonar "$(get_json_field "$merged" '.skip_sonar // false')"
  append_bool_flag_if_true --strict-test-port "$(get_json_field "$merged" '.strict_test_port // false')"

  RUN_CASE_ID="$case_id"
  RUN_CASE_DIAGRAM="$diagram"
  RUN_CASE_SOURCE_REPO="$source_repo"
  RUN_CASE_SOURCE_SUBDIR="${source_subdir:-}"
  RUN_CASE_CMD_JSON="$merged"
  RUN_CASE_DETAIL=""
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
  log "reuse codegen auto: ${REUSE_CODEGEN_AUTO}"

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

    local skip_case=false
    if $REUSE_CODEGEN_AUTO; then
      local reuse_result=""
      if reuse_result="$(resolve_reuse_codegen_candidate "$RUN_CASE_DIAGRAM" "$RUN_CASE_SOURCE_REPO" "${RUN_CASE_SOURCE_SUBDIR:-}" "$RUN_CASE_ID")"; then
        local reuse_run_id=""
        local reuse_repo=""
        IFS=$'\t' read -r reuse_run_id reuse_repo <<< "$reuse_result"
        RUN_CASE_CMD+=(--reuse-generated-repo "$reuse_repo" --reuse-generated-run-id "$reuse_run_id")
        RUN_CASE_DETAIL="reused-codegen:${reuse_run_id}"
        log "resolved reuse candidate: ${reuse_run_id}"
      else
        RUN_CASE_DETAIL="no-reusable-codegen"
        skip_case=true
      fi
    fi

    local rc=0
    if $skip_case; then
      {
        printf 'AUTO-REUSE RESOLUTION FAILED\n'
        printf 'detail=%s\n' "$RUN_CASE_DETAIL"
        printf 'diagram=%s\n' "$RUN_CASE_DIAGRAM"
        printf 'source_repo=%s\n' "$RUN_CASE_SOURCE_REPO"
        printf 'source_subdir=%s\n' "${RUN_CASE_SOURCE_SUBDIR:-}"
      } > "$case_log"
      rc=1
    else
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
    fi

    local result_word="ok"
    if [[ "$rc" -eq 0 ]]; then
      success_count=$((success_count + 1))
    else
      failure_count=$((failure_count + 1))
      result_word="failed"
      warn "case ${RUN_CASE_ID} exited ${rc} (log: ${case_log})"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$((idx+1))" \
      "$RUN_CASE_ID" \
      "$RUN_CASE_DIAGRAM" \
      "$RUN_CASE_SOURCE_REPO" \
      "${RUN_CASE_SOURCE_SUBDIR:-}" \
      "$rc" \
      "$result_word" \
      "${RUN_CASE_DETAIL:-}" >> "$BATCH_RESULTS_TSV"
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
