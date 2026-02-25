#!/usr/bin/env bash
# run-diagram-compare.sh - orchestrate Andvari generation, dual scan, and test-port evaluation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TOOLS_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/lib/exp_common.sh"
source "${SCRIPT_DIR}/lib/exp_cli.sh"
source "${SCRIPT_DIR}/lib/exp_naming.sh"
source "${SCRIPT_DIR}/lib/exp_sources.sh"
source "${SCRIPT_DIR}/lib/exp_andvari.sh"
source "${SCRIPT_DIR}/lib/exp_lidskjalv.sh"
source "${SCRIPT_DIR}/lib/exp_test_port.sh"
source "${SCRIPT_DIR}/lib/exp_report.sh"

# Reuse Lidskjalv source parsing/key derivation helpers and state lookup.
source "${REPO_ROOT}/tools/lidskjalv/scripts/lib/common.sh"
source "${REPO_ROOT}/tools/lidskjalv/scripts/lib/state.sh"
# Reuse Andvari adapter interface for test-port model edits.
ROOT_DIR="${REPO_ROOT}/tools/andvari"
source "${REPO_ROOT}/tools/andvari/scripts/adapters/adapter.sh"

main() {
  exp_parse_args "$@"
  exp_validate_args
  exp_init_source_identity

  EXP_STARTED_AT="$(exp_timestamp_iso_utc)"
  DIAGRAM_SHA="$(exp_sha256_file "$DIAGRAM_PATH")"

  EXP_RUN_DIR="${REPO_ROOT}/.data/experiments/runs/${RUN_ID}"
  EXP_LOG_DIR="${EXP_RUN_DIR}/logs"
  EXP_WORKSPACE_DIR="${EXP_RUN_DIR}/workspace"
  EXP_WORKSPACE_SCAN_DIR="${EXP_WORKSPACE_DIR}/scan"
  EXP_WORKSPACE_TEST_PORT_DIR="${EXP_WORKSPACE_DIR}/test-port"
  EXP_TEST_PORT_LOG_DIR="${EXP_LOG_DIR}/test-port"
  EXP_TEST_PORT_SUMMARY_DIR="${EXP_WORKSPACE_TEST_PORT_DIR}/summaries"
  EXP_TEST_PORT_GUARDS_DIR="${EXP_WORKSPACE_TEST_PORT_DIR}/write-guards"
  EXP_OUTPUT_DIR="${EXP_RUN_DIR}/outputs"
  EXP_JSON="${EXP_OUTPUT_DIR}/experiment.json"
  EXP_SUMMARY_MD="${EXP_OUTPUT_DIR}/summary.md"

  mkdir -p "$EXP_LOG_DIR" "$EXP_WORKSPACE_SCAN_DIR" "$EXP_OUTPUT_DIR" "$EXP_TEST_PORT_LOG_DIR"

  EVENTS_LOG="${EXP_TEST_PORT_LOG_DIR}/adapter-events.jsonl"
  CODEX_STDERR_LOG="${EXP_TEST_PORT_LOG_DIR}/adapter-stderr.log"
  OUTPUT_LAST_MESSAGE="${EXP_TEST_PORT_LOG_DIR}/adapter-last-message.md"
  ADAPTER="${ANDVARI_ADAPTER:-codex}"

  state_init

  exp_log "running andvari"
  exp_run_andvari

  exp_log "materializing original source"
  exp_materialize_original_repo

  TEST_PORT_STATUS="skipped"
  TEST_PORT_REASON=""
  TEST_PORT_FAILURE_CLASS=""
  BASELINE_ORIGINAL_RC=-1
  BASELINE_GENERATED_RC=-1
  BASELINE_ORIGINAL_STATUS="skipped"
  BASELINE_GENERATED_STATUS="skipped"
  BASELINE_ORIGINAL_LOG_PATH=""
  BASELINE_GENERATED_LOG_PATH=""
  PORTED_ORIGINAL_TESTS_STATUS="skipped"
  PORTED_ORIGINAL_TESTS_EXIT_CODE=-1
  PORTED_ORIGINAL_TESTS_LOG_PATH=""
  TEST_PORT_NEW_REPO_UNCHANGED=true
  TEST_PORT_ITERATIONS_USED=0
  TEST_PORT_ADAPTER_NONZERO=0
  TEST_PORT_WRITE_SCOPE_POLICY="tests-only"
  TEST_PORT_WRITE_SCOPE_VIOLATION_COUNT=0
  TEST_PORT_WRITE_SCOPE_FAILURE_PATHS_FILE=""
  TEST_PORT_WRITE_SCOPE_DIFF_FILE=""
  TEST_PORT_ADAPTER_PREREQS_OK=true
  if [[ "$TEST_PORT_MODE" == "on" ]]; then
    if ! adapter_check_prereqs "$ADAPTER"; then
      TEST_PORT_ADAPTER_PREREQS_OK=false
      exp_warn "adapter prereqs failed; test-port stage will be skipped"
    fi
    exp_log "running test-port stage"
    exp_run_test_port
  fi

  exp_log "scanning original"
  exp_scan_original

  exp_log "scanning generated"
  exp_scan_generated

  exp_write_reports

  exp_log "summary: $EXP_SUMMARY_MD"
  exp_log "json: $EXP_JSON"

  local final_rc=0
  [[ "$ANDVARI_EXIT_CODE" -eq 0 ]] || final_rc=1
  [[ "$ORIGINAL_SCAN_STATUS" =~ ^(success|skipped)$ ]] || final_rc=1
  [[ "$GENERATED_SCAN_STATUS" =~ ^(success|skipped)$ ]] || final_rc=1
  if $STRICT_TEST_PORT && [[ "$TEST_PORT_STATUS" != "passed" ]]; then
    final_rc=1
  fi
  return "$final_rc"
}

main "$@"
