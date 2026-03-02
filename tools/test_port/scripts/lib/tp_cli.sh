#!/usr/bin/env bash
# tp_cli.sh - CLI parsing/validation for standalone test-port tool.

set -euo pipefail

tp_print_help() {
  cat <<'EOF'
Usage: test-port-run.sh --generated-repo PATH --original-repo PATH [options]

Required:
  --generated-repo PATH       Generated repository root (read-only source; copied internally)
  --original-repo PATH        Original repository root (read-only source; copied internally)

Optional:
  --diagram PATH              Diagram file path (passed as read-only adapter context)
  --original-subdir PATH      Subdirectory under original repo to use for tests
  --run-id ID                 Explicit run id
  --run-dir PATH              Explicit run directory (default: .data/test-port/runs/<run-id>)
  --adapter NAME              Adapter name (default: codex)
  --max-iter N                Adaptation iterations after initial pass (default: 5)
  --strict                    Non-zero exit if status is not passed
  --write-scope-policy NAME   Only "tests-only" is supported (default: tests-only)
  -h, --help                  Show this help
EOF
}

tp_parse_args() {
  TP_GENERATED_REPO=""
  TP_ORIGINAL_REPO=""
  TP_DIAGRAM_PATH=""
  TP_ORIGINAL_SUBDIR=""
  TP_RUN_ID=""
  TP_RUN_DIR=""
  TP_ADAPTER="${ANDVARI_ADAPTER:-codex}"
  TP_MAX_ITER="5"
  TP_STRICT=false
  TP_WRITE_SCOPE_POLICY="tests-only"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --generated-repo) TP_GENERATED_REPO="${2:-}"; shift 2 ;;
      --original-repo) TP_ORIGINAL_REPO="${2:-}"; shift 2 ;;
      --diagram) TP_DIAGRAM_PATH="${2:-}"; shift 2 ;;
      --original-subdir) TP_ORIGINAL_SUBDIR="${2:-}"; shift 2 ;;
      --run-id) TP_RUN_ID="${2:-}"; shift 2 ;;
      --run-dir) TP_RUN_DIR="${2:-}"; shift 2 ;;
      --adapter) TP_ADAPTER="${2:-}"; shift 2 ;;
      --max-iter) TP_MAX_ITER="${2:-}"; shift 2 ;;
      --write-scope-policy) TP_WRITE_SCOPE_POLICY="${2:-}"; shift 2 ;;
      --strict) TP_STRICT=true; shift ;;
      -h|--help) tp_print_help; exit 0 ;;
      *)
        tp_fail "unknown argument: $1"
        ;;
    esac
  done
}

tp_validate_and_finalize_args() {
  [[ -n "$TP_GENERATED_REPO" ]] || tp_fail "--generated-repo is required"
  [[ -n "$TP_ORIGINAL_REPO" ]] || tp_fail "--original-repo is required"
  [[ "$TP_MAX_ITER" =~ ^[0-9]+$ ]] || tp_fail "--max-iter must be non-negative integer"
  [[ "$TP_WRITE_SCOPE_POLICY" == "tests-only" ]] || tp_fail "--write-scope-policy must be tests-only"

  TP_GENERATED_REPO="$(tp_abs_path "$TP_GENERATED_REPO")"
  TP_ORIGINAL_REPO="$(tp_abs_path "$TP_ORIGINAL_REPO")"

  [[ -d "$TP_ORIGINAL_REPO" ]] || tp_fail "original repo not found: $TP_ORIGINAL_REPO"

  if [[ -n "$TP_DIAGRAM_PATH" ]]; then
    TP_DIAGRAM_PATH="$(tp_abs_path "$TP_DIAGRAM_PATH")"
    [[ -f "$TP_DIAGRAM_PATH" ]] || tp_fail "diagram not found: $TP_DIAGRAM_PATH"
  fi

  TP_ORIGINAL_EFFECTIVE_PATH="$TP_ORIGINAL_REPO"
  if [[ -n "$TP_ORIGINAL_SUBDIR" ]]; then
    TP_ORIGINAL_EFFECTIVE_PATH="${TP_ORIGINAL_REPO}/${TP_ORIGINAL_SUBDIR}"
    [[ -d "$TP_ORIGINAL_EFFECTIVE_PATH" ]] || tp_fail "--original-subdir not found: $TP_ORIGINAL_SUBDIR"
  fi

  if [[ -z "$TP_RUN_ID" ]]; then
    local gen_component
    gen_component="$(tp_sanitize_id_component "$TP_GENERATED_REPO")"
    TP_RUN_ID="$(tp_timestamp_compact_utc)__${gen_component}__test-port"
  fi

  if [[ -z "$TP_RUN_DIR" ]]; then
    local runs_root
    runs_root="${TEST_PORT_RUNS_DIR:-${REPO_ROOT}/.data/test-port/runs}"
    TP_RUN_DIR="${runs_root}/${TP_RUN_ID}"
  fi
  TP_RUN_DIR="$(tp_abs_path "$TP_RUN_DIR")"

  TP_LOG_DIR="${TP_RUN_DIR}/logs"
  TP_WORKSPACE_DIR="${TP_RUN_DIR}/workspace"
  TP_OUTPUT_DIR="${TP_RUN_DIR}/outputs"
  TP_SUMMARY_DIR="${TP_WORKSPACE_DIR}/summaries"
  TP_GUARDS_DIR="${TP_WORKSPACE_DIR}/write-guards"

  TP_ORIGINAL_BASELINE_REPO="${TP_WORKSPACE_DIR}/original-baseline-repo"
  TP_GENERATED_BASELINE_REPO="${TP_WORKSPACE_DIR}/generated-baseline-repo"
  TP_PORTED_REPO="${TP_WORKSPACE_DIR}/ported-tests-repo"
  TP_ORIGINAL_TESTS_SNAPSHOT="${TP_WORKSPACE_DIR}/original-tests-snapshot"

  TP_BASELINE_ORIGINAL_LOG="${TP_LOG_DIR}/baseline-original-tests.log"
  TP_BASELINE_GENERATED_LOG="${TP_LOG_DIR}/baseline-generated-tests.log"
  TP_ADAPTER_EVENTS_LOG="${TP_LOG_DIR}/adapter-events.jsonl"
  TP_ADAPTER_STDERR_LOG="${TP_LOG_DIR}/adapter-stderr.log"
  TP_ADAPTER_LAST_MESSAGE="${TP_LOG_DIR}/adapter-last-message.md"

  TP_WRITE_SCOPE_FAILURE_PATHS_FILE="${TP_SUMMARY_DIR}/last-write-scope-failure.txt"
  TP_LAST_TEST_FAILURE_SUMMARY_FILE="${TP_SUMMARY_DIR}/last-test-failure.txt"
  TP_WRITE_SCOPE_DIFF_FILE="${TP_GUARDS_DIR}/disallowed-change.diff"
  TP_WRITE_SCOPE_BEFORE_FILE="${TP_GUARDS_DIR}/ported-protected-before.sha256"
  TP_WRITE_SCOPE_AFTER_FILE="${TP_GUARDS_DIR}/ported-protected-after.sha256"
  TP_WRITE_SCOPE_CHANGE_SET_PATH="${TP_GUARDS_DIR}/ported-protected-change-set.tsv"
  TP_GENERATED_BEFORE_HASH_PATH="${TP_GUARDS_DIR}/new-repo-before.sha256"
  TP_GENERATED_AFTER_HASH_PATH="${TP_GUARDS_DIR}/new-repo-after.sha256"

  TP_JSON_PATH="${TP_OUTPUT_DIR}/test_port.json"
  TP_SUMMARY_MD_PATH="${TP_OUTPUT_DIR}/summary.md"
}
