#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/testlib.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/tools/test_port/scripts/lib/tp_common.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/tools/test_port/scripts/lib/tp_report.sh"

case_report_emits_ignored_prefixes() {
  local tmp
  tmp="$(tpt_mktemp_dir)"

  TP_JSON_PATH="${tmp}/outputs/test_port.json"
  TP_SUMMARY_MD_PATH="${tmp}/outputs/summary.md"
  TP_RUN_ID="run-1"
  TP_STARTED_AT="2026-03-01T00:00:00Z"
  TP_GENERATED_REPO="${tmp}/generated"
  TP_ORIGINAL_REPO="${tmp}/original"
  TP_ORIGINAL_SUBDIR=""
  TP_ORIGINAL_EFFECTIVE_PATH="${tmp}/original"
  TP_DIAGRAM_PATH="${tmp}/diagram.puml"
  TP_ADAPTER="codex"
  TP_MAX_ITER="1"
  TP_STRICT=false
  TP_WRITE_SCOPE_POLICY="tests-only"
  TP_STATUS="failed"
  TP_REASON="write-scope-violation"
  TP_FAILURE_CLASS="write-scope-violation"
  TP_ADAPTER_PREREQS_OK=true
  TP_BEHAVIORAL_VERDICT="invalid"
  TP_BEHAVIORAL_VERDICT_REASON="write-scope-violation"
  TP_GENERATED_REPO_UNCHANGED=true
  TP_GENERATED_BEFORE_HASH_PATH="${tmp}/before.sha256"
  TP_GENERATED_AFTER_HASH_PATH="${tmp}/after.sha256"
  TP_WRITE_SCOPE_VIOLATION_COUNT=1
  TP_WRITE_SCOPE_FAILURE_PATHS_FILE="${tmp}/last-write-scope-failure.txt"
  TP_WRITE_SCOPE_DIFF_FILE="${tmp}/disallowed-change.diff"
  TP_WRITE_SCOPE_CHANGE_SET_PATH="${tmp}/ported-protected-change-set.tsv"
  TP_WRITE_SCOPE_IGNORED_PREFIXES_CSV="./completion/proof/logs/:./.mvn_repo/:./custom/cache/"
  TP_BASELINE_ORIGINAL_STATUS="pass"
  TP_BASELINE_ORIGINAL_RC=0
  TP_BASELINE_ORIGINAL_LOG="${tmp}/baseline-original.log"
  TP_BASELINE_GENERATED_STATUS="pass"
  TP_BASELINE_GENERATED_RC=0
  TP_BASELINE_GENERATED_LOG="${tmp}/baseline-generated.log"
  TP_PORTED_ORIGINAL_TESTS_STATUS="fail"
  TP_PORTED_ORIGINAL_TESTS_EXIT_CODE=1
  TP_PORTED_ORIGINAL_TESTS_LOG="${tmp}/ported.log"
  TP_ITERATIONS_USED=1
  TP_ADAPTER_NONZERO_RUNS=0
  TP_ADAPTER_EVENTS_LOG="${tmp}/adapter-events.jsonl"
  TP_ADAPTER_STDERR_LOG="${tmp}/adapter-stderr.log"
  TP_ADAPTER_LAST_MESSAGE="${tmp}/adapter-last-message.md"
  TP_RUN_DIR="${tmp}"
  TP_LOG_DIR="${tmp}/logs"
  TP_WORKSPACE_DIR="${tmp}/workspace"
  TP_OUTPUT_DIR="${tmp}/outputs"
  TP_PORTED_REPO="${tmp}/workspace/ported-tests-repo"
  TP_ORIGINAL_TESTS_SNAPSHOT="${tmp}/workspace/original-tests-snapshot"

  mkdir -p "${tmp}/outputs" "${tmp}/workspace/ported-tests-repo/src/test/java" "${tmp}/workspace/original-tests-snapshot/src/test/java"
  echo "digest" > "$TP_GENERATED_BEFORE_HASH_PATH"
  echo "digest" > "$TP_GENERATED_AFTER_HASH_PATH"
  cat > "$TP_WRITE_SCOPE_FAILURE_PATHS_FILE" <<'TSV'
M	./src/main/java/Prod.java
TSV
  cat > "$TP_WRITE_SCOPE_DIFF_FILE" <<'TSV'
M	./src/main/java/Prod.java
TSV
  cat > "$TP_WRITE_SCOPE_CHANGE_SET_PATH" <<'TSV'
M	./src/test/java/AdaptedTest.java
TSV
  echo "class AdaptedTest {}" > "${TP_PORTED_REPO}/src/test/java/AdaptedTest.java"
  echo "class OriginalTest {}" > "${TP_ORIGINAL_TESTS_SNAPSHOT}/src/test/java/OriginalTest.java"

  tp_write_reports

  tpt_assert_file_exists "$TP_JSON_PATH" "json report must be written"
  tpt_assert_file_exists "$TP_SUMMARY_MD_PATH" "markdown summary must be written"

  python3 - <<'PY' "$TP_JSON_PATH"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    obj = json.load(f)
expected = ["./completion/proof/logs/", "./.mvn_repo/", "./custom/cache/"]
actual = obj["write_scope"].get("ignored_prefixes", [])
if actual != expected:
    raise SystemExit(f"unexpected ignored_prefixes: {actual}")
if obj["write_scope"].get("violation_count") != 1:
    raise SystemExit("unexpected violation_count")
PY

  tpt_assert_file_contains "$TP_SUMMARY_MD_PATH" "Write-scope ignored prefixes" "summary should mention ignored prefixes"
  tpt_assert_file_contains "$TP_SUMMARY_MD_PATH" "./completion/proof/logs/" "summary should include resolved ignored prefixes"
}

tpt_run_case "report includes ignored prefixes in json and summary" case_report_emits_ignored_prefixes

tpt_finish_suite
