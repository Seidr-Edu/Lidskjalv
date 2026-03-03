#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "${TOOLS_DIR}/../.." && pwd)"

source "${TOOLS_DIR}/scripts/lib/tp_common.sh"
source "${TOOLS_DIR}/scripts/lib/tp_cli.sh"
source "${TOOLS_DIR}/scripts/lib/tp_runner.sh"
source "${TOOLS_DIR}/scripts/lib/tp_write_guard.sh"
source "${TOOLS_DIR}/scripts/lib/tp_copy.sh"
source "${TOOLS_DIR}/scripts/lib/tp_evidence.sh"
source "${TOOLS_DIR}/scripts/lib/tp_verdict.sh"
source "${TOOLS_DIR}/scripts/lib/tp_report.sh"

# Reuse Andvari adapter interface/prompt system.
ROOT_DIR="${REPO_ROOT}/tools/andvari"
source "${REPO_ROOT}/tools/andvari/scripts/adapters/adapter.sh"
source "${TOOLS_DIR}/scripts/lib/tp_adapter.sh"

tp_init_result_state() {
  TP_STARTED_AT="$(tp_timestamp_iso_utc)"
  TP_WORKSPACE_PREPARED=false

  TP_STATUS="skipped"
  TP_REASON=""
  TP_FAILURE_CLASS=""
  TP_ADAPTER_PREREQS_OK=true
  TP_GENERATED_REPO_UNCHANGED=true
  TP_ITERATIONS_USED=0
  TP_ADAPTER_NONZERO_RUNS=0
  TP_WRITE_SCOPE_VIOLATION_COUNT=0
  TP_BEHAVIORAL_VERDICT="skipped"
  TP_BEHAVIORAL_VERDICT_REASON="not-run"

  TP_BASELINE_ORIGINAL_STATUS="skipped"
  TP_BASELINE_ORIGINAL_RC=-1
  TP_BASELINE_ORIGINAL_STRATEGY="single-run"
  TP_BASELINE_ORIGINAL_UNIT_ONLY_RC=-1
  TP_BASELINE_ORIGINAL_FULL_RC=-1
  TP_BASELINE_ORIGINAL_FAILURE_CLASS=""
  TP_BASELINE_ORIGINAL_FAILURE_TYPE=""
  TP_BASELINE_GENERATED_STATUS="skipped"
  TP_BASELINE_GENERATED_RC=-1
  TP_BASELINE_GENERATED_STRATEGY="single-run"
  TP_BASELINE_GENERATED_UNIT_ONLY_RC=-1
  TP_BASELINE_GENERATED_FULL_RC=-1
  TP_BASELINE_GENERATED_FAILURE_CLASS=""
  TP_BASELINE_GENERATED_FAILURE_TYPE=""
  TP_PORTED_ORIGINAL_TESTS_STATUS="skipped"
  TP_PORTED_ORIGINAL_TESTS_EXIT_CODE=-1
  TP_PORTED_ORIGINAL_TESTS_LOG=""

  TP_GENERATED_REPO_BEFORE_HASH=""
  TP_GENERATED_REPO_AFTER_HASH=""

  TP_EVIDENCE_ORIGINAL_SNAPSHOT_FILE_COUNT=0
  TP_EVIDENCE_FINAL_PORTED_TEST_FILE_COUNT=0
  TP_EVIDENCE_RETAINED_ORIGINAL_TEST_FILE_COUNT=0
  TP_EVIDENCE_REMOVED_ORIGINAL_TEST_FILE_COUNT=0
  TP_EVIDENCE_RETENTION_RATIO=""
  TP_EVIDENCE_UNDOCUMENTED_REMOVED_TEST_COUNT=0
  TP_EVIDENCE_JUNIT_REPORT_COUNT=0
  TP_EVIDENCE_JUNIT_FAILING_CASE_COUNT=0

  TP_BEST_VALID_ITERATION=-1
  TP_BEST_VALID_RETAINED=-1
  TP_BEST_VALID_REMOVED=2147483647
  TP_BEST_VALID_LOG=""
  TP_RETENTION_POLICY_MODE="maximize-retained-original-tests"
  TP_RETENTION_DOCUMENTED_REMOVALS_REQUIRED=true

  mkdir -p "$TP_RUN_DIR" "$TP_LOG_DIR" "$TP_OUTPUT_DIR"
}

tp_stage_best_valid_candidate() {
  local iteration="$1"
  local adapt_log="$2"
  local retained removed
  retained="${TP_EVIDENCE_RETAINED_ORIGINAL_TEST_FILE_COUNT:-0}"
  removed="${TP_EVIDENCE_REMOVED_ORIGINAL_TEST_FILE_COUNT:-0}"

  if [[ "$retained" -lt "$TP_BEST_VALID_RETAINED" ]]; then
    return 0
  fi
  if [[ "$retained" -eq "$TP_BEST_VALID_RETAINED" && "$removed" -ge "$TP_BEST_VALID_REMOVED" ]]; then
    return 0
  fi

  tp_copy_dir "$TP_PORTED_REPO" "$TP_BEST_VALID_PORTED_REPO"
  cp "$TP_EVIDENCE_JSON_PATH" "$TP_BEST_VALID_EVIDENCE_JSON_PATH"
  TP_BEST_VALID_ITERATION="$iteration"
  TP_BEST_VALID_RETAINED="$retained"
  TP_BEST_VALID_REMOVED="$removed"
  TP_BEST_VALID_LOG="$adapt_log"
}

tp_restore_best_valid_candidate() {
  [[ "$TP_BEST_VALID_ITERATION" -ge 0 ]] || return 1
  [[ -d "$TP_BEST_VALID_PORTED_REPO" ]] || return 1
  [[ -f "$TP_BEST_VALID_EVIDENCE_JSON_PATH" ]] || return 1

  tp_copy_dir "$TP_BEST_VALID_PORTED_REPO" "$TP_PORTED_REPO"
  cp "$TP_BEST_VALID_EVIDENCE_JSON_PATH" "$TP_EVIDENCE_JSON_PATH"
  tp_load_evidence_state "$TP_EVIDENCE_JSON_PATH"

  TP_PORTED_ORIGINAL_TESTS_EXIT_CODE=0
  TP_PORTED_ORIGINAL_TESTS_STATUS="pass"
  TP_STATUS="passed"
  TP_REASON=""
  TP_FAILURE_CLASS=""
  TP_ITERATIONS_USED="$TP_BEST_VALID_ITERATION"
  TP_PORTED_ORIGINAL_TESTS_LOG="$TP_BEST_VALID_LOG"
  return 0
}

tp_execute() {
  : > "$TP_ADAPTER_EVENTS_LOG"
  : > "$TP_ADAPTER_STDERR_LOG"
  : > "$TP_ADAPTER_LAST_MESSAGE"

  [[ -d "$TP_GENERATED_REPO" ]] || { TP_STATUS="skipped"; TP_REASON="missing-generated-repo"; return 0; }

  if ! tp_adapter_check_prereqs "$TP_ADAPTER"; then
    TP_ADAPTER_PREREQS_OK=false
    TP_STATUS="skipped"
    TP_REASON="adapter-prereqs-failed"
    return 0
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    TP_STATUS="skipped"
    TP_REASON="missing-rsync"
    return 0
  fi

  tp_prepare_workspace_copies
  TP_WORKSPACE_PREPARED=true

  set +e
  tp_run_baseline_tests "$TP_ORIGINAL_BASELINE_REPO" "$TP_BASELINE_ORIGINAL_LOG"
  TP_BASELINE_ORIGINAL_RC=$?
  TP_BASELINE_ORIGINAL_STATUS="$TP_BASELINE_LAST_STATUS"
  TP_BASELINE_ORIGINAL_STRATEGY="$TP_BASELINE_LAST_STRATEGY"
  TP_BASELINE_ORIGINAL_UNIT_ONLY_RC="$TP_BASELINE_LAST_UNIT_ONLY_RC"
  TP_BASELINE_ORIGINAL_FULL_RC="$TP_BASELINE_LAST_FULL_RC"
  TP_BASELINE_ORIGINAL_FAILURE_CLASS="$TP_BASELINE_LAST_FAILURE_CLASS"
  TP_BASELINE_ORIGINAL_FAILURE_TYPE="$TP_BASELINE_LAST_FAILURE_TYPE"

  tp_run_baseline_tests "$TP_GENERATED_BASELINE_REPO" "$TP_BASELINE_GENERATED_LOG"
  TP_BASELINE_GENERATED_RC=$?
  TP_BASELINE_GENERATED_STATUS="$TP_BASELINE_LAST_STATUS"
  TP_BASELINE_GENERATED_STRATEGY="$TP_BASELINE_LAST_STRATEGY"
  TP_BASELINE_GENERATED_UNIT_ONLY_RC="$TP_BASELINE_LAST_UNIT_ONLY_RC"
  TP_BASELINE_GENERATED_FULL_RC="$TP_BASELINE_LAST_FULL_RC"
  TP_BASELINE_GENERATED_FAILURE_CLASS="$TP_BASELINE_LAST_FAILURE_CLASS"
  TP_BASELINE_GENERATED_FAILURE_TYPE="$TP_BASELINE_LAST_FAILURE_TYPE"
  set -e

  if ! tp_snapshot_original_tests; then
    if [[ -d "$TP_ORIGINAL_TESTS_SNAPSHOT" ]] && ! find "$TP_ORIGINAL_TESTS_SNAPSHOT" -type f -print -quit | grep -q .; then
      TP_STATUS="skipped"
      TP_REASON="no-test-files-found"
    else
      TP_STATUS="skipped"
      TP_REASON="test-snapshot-copy-failed"
    fi
    return 0
  fi

  if ! tp_seed_ported_repo_with_original_tests; then
    TP_STATUS="failed"
    TP_REASON="ported-test-copy-failed"
    return 0
  fi

  local ported_runner
  ported_runner="$(tp_detect_test_runner "$TP_PORTED_REPO")"
  if [[ "$ported_runner" == "unknown" ]]; then
    TP_STATUS="skipped"
    TP_REASON="unsupported-test-runner"
    TP_PORTED_ORIGINAL_TESTS_STATUS="skipped"
    TP_PORTED_ORIGINAL_TESTS_EXIT_CODE=2
    return 0
  fi

  tp_write_repo_manifest "$TP_PORTED_REPO" "$TP_WRITE_SCOPE_BEFORE_FILE"
  : > "$TP_LAST_TEST_FAILURE_SUMMARY_FILE"
  : > "$TP_WRITE_SCOPE_FAILURE_PATHS_FILE"
  : > "$TP_WRITE_SCOPE_DIFF_FILE"
  rm -rf "$TP_BEST_VALID_PORTED_REPO"
  rm -f "$TP_EVIDENCE_JSON_PATH" "$TP_BEST_VALID_EVIDENCE_JSON_PATH"

  TP_STATUS="failed"
  TP_REASON="max-iterations-reached"

  local i
  for ((i=0; i<=TP_MAX_ITER; i++)); do
    if [[ $i -eq 0 ]]; then
      tp_adapter_run_initial "$TP_ADAPTER" || TP_ADAPTER_NONZERO_RUNS=$((TP_ADAPTER_NONZERO_RUNS + 1))
    else
      tp_adapter_run_iteration "$TP_ADAPTER" "$i" || TP_ADAPTER_NONZERO_RUNS=$((TP_ADAPTER_NONZERO_RUNS + 1))
    fi

    : > "$TP_WRITE_SCOPE_FAILURE_PATHS_FILE"
    : > "$TP_WRITE_SCOPE_DIFF_FILE"
    if tp_check_write_scope "$TP_PORTED_REPO" "$TP_WRITE_SCOPE_BEFORE_FILE" "$TP_WRITE_SCOPE_AFTER_FILE"; then
      :
    else
      local write_scope_rc=$?
      TP_STATUS="failed"
      TP_PORTED_ORIGINAL_TESTS_STATUS="fail"
      TP_PORTED_ORIGINAL_TESTS_EXIT_CODE=1
      TP_ITERATIONS_USED="$i"
      if [[ "$write_scope_rc" -eq 1 ]]; then
        TP_REASON="write-scope-violation"
        TP_FAILURE_CLASS="write-scope-violation"
      else
        TP_REASON="write-scope-check-failed"
        TP_FAILURE_CLASS="write-scope-check-failed"
      fi
      break
    fi

    local adapt_log="${TP_LOG_DIR}/adapt-iter-${i}.log"
    TP_PORTED_ORIGINAL_TESTS_LOG="$adapt_log"
    if tp_run_tests "$TP_PORTED_REPO" "$adapt_log"; then
      TP_PORTED_ORIGINAL_TESTS_EXIT_CODE=0
      TP_PORTED_ORIGINAL_TESTS_STATUS="pass"
      TP_ITERATIONS_USED="$i"

      tp_refresh_evidence_state "$TP_PORTED_REPO" "$TP_ORIGINAL_TESTS_SNAPSHOT" "$TP_REMOVED_TESTS_MANIFEST_PATH" "$TP_EVIDENCE_JSON_PATH"

      if [[ "${TP_EVIDENCE_JUNIT_REPORT_COUNT:-0}" -eq 0 ]]; then
        TP_STATUS="failed"
        TP_REASON="insufficient-test-evidence"
        TP_FAILURE_CLASS="missing-junit-reports"
        TP_PORTED_ORIGINAL_TESTS_STATUS="fail"
        TP_PORTED_ORIGINAL_TESTS_EXIT_CODE=1
        tp_write_evidence_feedback_summary \
          "$TP_LAST_TEST_FAILURE_SUMMARY_FILE" \
          "$TP_EVIDENCE_JSON_PATH" \
          "Tests exited 0 but produced zero JUnit reports. Preserve and adapt original tests so they execute and emit JUnit XML." \
          "$TP_REMOVED_TESTS_MANIFEST_REL"
        if [[ "$i" -lt "$TP_MAX_ITER" ]]; then
          continue
        fi
        break
      fi

      if [[ "${TP_EVIDENCE_UNDOCUMENTED_REMOVED_TEST_COUNT:-0}" -gt 0 ]]; then
        TP_STATUS="failed"
        TP_REASON="insufficient-test-evidence"
        TP_FAILURE_CLASS="undocumented-test-removal"
        TP_PORTED_ORIGINAL_TESTS_STATUS="fail"
        TP_PORTED_ORIGINAL_TESTS_EXIT_CODE=1
        tp_write_evidence_feedback_summary \
          "$TP_LAST_TEST_FAILURE_SUMMARY_FILE" \
          "$TP_EVIDENCE_JSON_PATH" \
          "Original tests were removed without valid documentation. Restore them or document each removal in the required manifest." \
          "$TP_REMOVED_TESTS_MANIFEST_REL"
        if [[ "$i" -lt "$TP_MAX_ITER" ]]; then
          continue
        fi
        break
      fi

      tp_stage_best_valid_candidate "$i" "$adapt_log"

      TP_STATUS="passed"
      TP_REASON=""
      TP_FAILURE_CLASS=""

      if [[ "${TP_EVIDENCE_REMOVED_ORIGINAL_TEST_FILE_COUNT:-0}" -eq 0 ]]; then
        break
      fi
      if [[ "$i" -lt "$TP_MAX_ITER" ]]; then
        tp_write_evidence_feedback_summary \
          "$TP_LAST_TEST_FAILURE_SUMMARY_FILE" \
          "$TP_EVIDENCE_JSON_PATH" \
          "Tests pass, but retention policy requires restoring as many removed original tests as possible before finishing." \
          "$TP_REMOVED_TESTS_MANIFEST_REL"
        continue
      fi
      break
    fi

    local adapt_rc=$?
    TP_PORTED_ORIGINAL_TESTS_EXIT_CODE="$adapt_rc"
    TP_PORTED_ORIGINAL_TESTS_STATUS="$(tp_test_rc_status "$adapt_rc")"
    TP_ITERATIONS_USED="$i"

    if [[ "$adapt_rc" -eq 2 ]]; then
      TP_STATUS="skipped"
      TP_REASON="unsupported-test-runner"
      break
    fi

    tail -n 200 "$adapt_log" > "$TP_LAST_TEST_FAILURE_SUMMARY_FILE" || true
    TP_STATUS="failed"
    TP_FAILURE_CLASS="$(tp_classify_test_failure_log "$adapt_log")"
    if [[ "$TP_FAILURE_CLASS" == "behavioral-mismatch" ]]; then
      TP_REASON="behavioral-difference-evidence"
      break
    fi
    TP_REASON="tests-failed"
  done

  if [[ "$TP_BEST_VALID_ITERATION" -ge 0 && "$TP_REASON" != "write-scope-violation" && "$TP_REASON" != "write-scope-check-failed" ]]; then
    tp_restore_best_valid_candidate || true
  elif [[ -f "$TP_EVIDENCE_JSON_PATH" ]]; then
    tp_load_evidence_state "$TP_EVIDENCE_JSON_PATH"
  fi

  return 0
}

main() {
  tp_parse_args "$@"
  tp_validate_and_finalize_args
  tp_init_result_state

  # Codex adapter requires a diagram path to derive a readable context dir. When no
  # diagram is supplied, use a synthetic path under the generated repo (dirname exists).
  TP_ADAPTER_INPUT_DIAGRAM_PATH="${TP_DIAGRAM_PATH:-${TP_GENERATED_REPO}/.test-port-no-diagram.puml}"

  tp_log "run dir: $TP_RUN_DIR"
  tp_log "generated repo: $TP_GENERATED_REPO"
  tp_log "original repo: $TP_ORIGINAL_REPO"
  [[ -n "$TP_ORIGINAL_SUBDIR" ]] && tp_log "original subdir: $TP_ORIGINAL_SUBDIR"

  tp_execute

  if $TP_WORKSPACE_PREPARED; then
    tp_finalize_generated_repo_immutability_guard
  fi

  if [[ -d "${TP_PORTED_REPO:-}" && -d "${TP_ORIGINAL_TESTS_SNAPSHOT:-}" ]]; then
    tp_refresh_evidence_state "$TP_PORTED_REPO" "$TP_ORIGINAL_TESTS_SNAPSHOT" "$TP_REMOVED_TESTS_MANIFEST_PATH" "$TP_EVIDENCE_JSON_PATH" || true
  fi

  tp_compute_behavioral_verdict
  tp_write_reports

  tp_log "summary: $TP_SUMMARY_MD_PATH"
  tp_log "json: $TP_JSON_PATH"

  if $TP_STRICT && [[ "$TP_STATUS" != "passed" ]]; then
    return 1
  fi
  return 0
}

main "$@"
