#!/usr/bin/env bash
# exp_test_port_client.sh - invoke standalone test-port tool and import result JSON.

set -euo pipefail

exp_import_test_port_json() {
  local json_path="$1"
  eval "$(
    python3 - <<'PY' "$json_path"
import json, shlex, sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    obj = json.load(f)

def s(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)

def g(*keys, default=""):
    cur = obj
    for k in keys:
        if not isinstance(cur, dict):
            return default
        cur = cur.get(k)
    return cur if cur is not None else default

assignments = {
    "TEST_PORT_STATUS": s(g("status")),
    "TEST_PORT_REASON": s(g("reason")),
    "TEST_PORT_FAILURE_CLASS": s(g("failure_class")),
    "TEST_PORT_ADAPTER_PREREQS_OK": s(g("adapter_prereqs_ok", default=False)),
    "TEST_PORT_NEW_REPO_UNCHANGED": s(g("immutability", "generated_repo_unchanged", default=False)),
    "TEST_PORT_WRITE_SCOPE_POLICY": s(g("write_scope", "policy")),
    "TEST_PORT_WRITE_SCOPE_VIOLATION_COUNT": s(g("write_scope", "violation_count", default=0)),
    "TEST_PORT_WRITE_SCOPE_FAILURE_PATHS_FILE": s(g("write_scope", "violations_log_path")),
    "TEST_PORT_WRITE_SCOPE_DIFF_FILE": s(g("write_scope", "diff_path")),
    "TEST_PORT_WRITE_SCOPE_CHANGE_SET_PATH": s(g("write_scope", "change_set_path")),
    "TEST_PORT_ITERATIONS_USED": s(g("ported_original_tests", "iterations_used", default=0)),
    "TEST_PORT_ADAPTER_NONZERO": s(g("ported_original_tests", "adapter_nonzero_runs", default=0)),
    "BASELINE_ORIGINAL_STATUS": s(g("baseline_original_tests", "status")),
    "BASELINE_ORIGINAL_RC": s(g("baseline_original_tests", "exit_code", default=-1)),
    "BASELINE_ORIGINAL_LOG_PATH": s(g("baseline_original_tests", "log_path")),
    "BASELINE_GENERATED_STATUS": s(g("baseline_generated_tests", "status")),
    "BASELINE_GENERATED_RC": s(g("baseline_generated_tests", "exit_code", default=-1)),
    "BASELINE_GENERATED_LOG_PATH": s(g("baseline_generated_tests", "log_path")),
    "PORTED_ORIGINAL_TESTS_STATUS": s(g("ported_original_tests", "status")),
    "PORTED_ORIGINAL_TESTS_EXIT_CODE": s(g("ported_original_tests", "exit_code", default=-1)),
    "PORTED_ORIGINAL_TESTS_LOG_PATH": s(g("ported_original_tests", "log_path")),
    "EVENTS_LOG": s(g("adapter", "events_log")),
    "CODEX_STDERR_LOG": s(g("adapter", "stderr_log")),
    "OUTPUT_LAST_MESSAGE": s(g("adapter", "last_message_path")),
    "TEST_PORT_BEHAVIORAL_VERDICT": s(g("behavioral_verdict")),
    "TEST_PORT_BEHAVIORAL_VERDICT_REASON": s(g("behavioral_verdict_reason")),
    "TEST_PORT_BEHAVIORAL_FAILING_CASE_COUNT": s(g("behavioral_evidence", "failing_case_count", default=0)),
    "TEST_PORT_SUITE_CHANGES_ADDED": s(g("suite_changes", "added", default=0)),
    "TEST_PORT_SUITE_CHANGES_MODIFIED": s(g("suite_changes", "modified", default=0)),
    "TEST_PORT_SUITE_CHANGES_DELETED": s(g("suite_changes", "deleted", default=0)),
    "TEST_PORT_SUITE_CHANGES_TOTAL": s(g("suite_changes", "total", default=0)),
    "TEST_PORT_SUITE_SHAPE_ORIGINAL_SNAPSHOT_FILE_COUNT": s(g("suite_shape", "original_snapshot_file_count", default=0)),
    "TEST_PORT_SUITE_SHAPE_FINAL_PORTED_TEST_FILE_COUNT": s(g("suite_shape", "final_ported_test_file_count", default=0)),
    "TEST_PORT_SUITE_SHAPE_RETENTION_RATIO": s(g("suite_shape", "retention_ratio")),
    "TEST_PORT_TOOL_RUN_DIR": s(g("artifacts", "run_dir")),
    "TEST_PORT_TOOL_SUMMARY_PATH": s(g("artifacts", "summary_md")),
    "TEST_PORT_TOOL_JSON_PATH": path,
}

for key, val in assignments.items():
    print(f"{key}={shlex.quote(val)}")
PY
  )"
}

exp_run_test_port() {
  TEST_PORT_TOOL_RUN_DIR="${EXP_RUN_DIR}/test-port"
  TEST_PORT_TOOL_JSON_PATH="${TEST_PORT_TOOL_RUN_DIR}/outputs/test_port.json"
  TEST_PORT_TOOL_SUMMARY_PATH="${TEST_PORT_TOOL_RUN_DIR}/outputs/summary.md"
  TEST_PORT_TOOL_LOG_PATH="${EXP_LOG_DIR}/test-port-tool.log"
  TEST_PORT_TOOL_EXIT_CODE=0

  local test_port_cmd=("${REPO_ROOT}/test-port-run.sh"
    --generated-repo "$ANDVARI_NEW_REPO"
    --original-repo "$ORIGINAL_REPO_PATH"
    --run-id "${RUN_ID}__test-port"
    --run-dir "$TEST_PORT_TOOL_RUN_DIR"
    --adapter "$ADAPTER"
    --max-iter "$TEST_PORT_MAX_ITER"
  )
  [[ -n "${DIAGRAM_PATH:-}" ]] && test_port_cmd+=(--diagram "$DIAGRAM_PATH")
  [[ -n "${SOURCE_SUBDIR:-}" ]] && test_port_cmd+=(--original-subdir "$SOURCE_SUBDIR")
  $STRICT_TEST_PORT && test_port_cmd+=(--strict)

  set +e
  "${test_port_cmd[@]}" >"$TEST_PORT_TOOL_LOG_PATH" 2>&1
  TEST_PORT_TOOL_EXIT_CODE=$?
  set -e

  if [[ -f "$TEST_PORT_TOOL_JSON_PATH" ]]; then
    exp_import_test_port_json "$TEST_PORT_TOOL_JSON_PATH"
    return 0
  fi

  TEST_PORT_STATUS="failed"
  TEST_PORT_REASON="test-port-tool-no-json"
  TEST_PORT_FAILURE_CLASS="tool-execution-failure"
  if [[ "$TEST_PORT_TOOL_EXIT_CODE" -eq 0 ]]; then
    TEST_PORT_TOOL_EXIT_CODE=1
  fi
  return 0
}
