#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/tests/lib/testlib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_fake_bin() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"

cat > "${fake_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
is_sonar_goal() {
  case "$*" in
    *org.sonarsource.scanner.maven:sonar-maven-plugin:*:sonar*)
      return 0
      ;;
  esac
  return 1
}
if [[ "$*" == *"clean compile"* ]]; then
  mkdir -p target/classes
  : > target/classes/App.class
  exit 0
fi
if [[ "$*" == *" test "* || "$*" == test* ]]; then
  if [[ -n "${FAKE_COVERAGE_TEST_EXIT_CODE:-}" ]]; then
    exit "${FAKE_COVERAGE_TEST_EXIT_CODE}"
  fi
  if [[ "${FAKE_COVERAGE_REPORT_MODE:-present}" != "missing" ]]; then
    mkdir -p target/site/jacoco
    printf '%s\n' '<report name="fake"/>' > target/site/jacoco/jacoco.xml
  fi
  exit 0
fi
if is_sonar_goal "$*"; then
  if [[ -n "${FAKE_EXPECT_COVERAGE_REPORT_PATHS:-}" && "$*" != *"-Dsonar.coverage.jacoco.xmlReportPaths=${FAKE_EXPECT_COVERAGE_REPORT_PATHS}"* ]]; then
    printf '%s\n' "coverage report paths mismatch" >&2
    exit 90
  fi
  if [[ -n "${FAKE_SONAR_SUBMIT_EXIT_CODE:-}" ]]; then
    exit "${FAKE_SONAR_SUBMIT_EXIT_CODE}"
  fi
  if [[ "${FAKE_REQUIRE_SONAR_SCM_DISABLED:-}" == "true" && "$*" != *"-Dsonar.scm.disabled=true"* ]]; then
    printf '%s\n' "missing -Dsonar.scm.disabled=true" >&2
    exit 91
  fi
  if [[ "${FAKE_REQUIRE_COVERAGE_REPORT_PATHS:-}" == "true" && "$*" != *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
    printf '%s\n' "missing -Dsonar.coverage.jacoco.xmlReportPaths" >&2
    exit 92
  fi
  if [[ "${FAKE_FORBID_COVERAGE_REPORT_PATHS:-}" == "true" && "$*" == *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
    printf '%s\n' "unexpected -Dsonar.coverage.jacoco.xmlReportPaths" >&2
    exit 93
  fi
  mkdir -p .scannerwork
  printf 'ceTaskId=%s\n' "${FAKE_SONAR_TASK_ID-fake-task}" > .scannerwork/report-task.txt
  exit 0
fi
exit 0
EOF
  chmod +x "${fake_bin}/mvn"

  cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
ce_status="${FAKE_SONAR_CE_STATUS:-SUCCESS}"
qg_status="${FAKE_SONAR_QG_STATUS-OK}"
measures_mode="${FAKE_SONAR_MEASURES_MODE:-present}"
task_id="${FAKE_SONAR_TASK_ID-fake-task}"

case "$url" in
  */api/system/status)
    printf '%s\n' '{"status":"UP"}'
    ;;
  */api/projects/search*)
    printf '%s\n' '{"paging":{"total":1}}'
    ;;
  */api/ce/task*)
    printf '{"task":{"id":"%s","status":"%s"}}\n' "$task_id" "$ce_status"
    ;;
  */api/qualitygates/project_status*)
    printf '{"projectStatus":{"status":"%s"}}\n' "$qg_status"
    ;;
  */api/measures/component*)
    if [[ "$measures_mode" == "present" ]]; then
      printf '%s\n' '{"component":{"measures":[{"metric":"bugs","value":"0"},{"metric":"code_smells","value":"3"}]}}'
    else
      printf '%s\n' '{"component":{"measures":[]}}'
    fi
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
EOF
  chmod +x "${fake_bin}/curl"
}

write_manifest() {
  local path="$1"
  local content="$2"
  printf '%s\n' "$content" > "$path"
}

run_service_with_fake_sonar() {
  local run_dir="$1"
  local manifest_yaml="$2"
  local fake_bin="$3"
  mkdir -p "${run_dir}/config"
  write_manifest "${run_dir}/config/manifest.yaml" "$manifest_yaml"
  PATH="${fake_bin}:$PATH" \
  SONAR_HOST_URL="https://sonar.example.test" \
  SONAR_TOKEN="token" \
  SONAR_ORGANIZATION="org" \
  LIDSKJALV_RUN_DIR="$run_dir" \
  LIDSKJALV_MANIFEST="${run_dir}/config/manifest.yaml" \
  LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_app" \
  ./lidskjalv-service.sh >/dev/null
}

pushd "$ROOT_DIR" >/dev/null

fake_bin="${tmp}/fake-bin"
make_fake_bin "$fake_bin"

scm_disabled_run="${tmp}/scm-disabled-run"
FAKE_REQUIRE_SONAR_SCM_DISABLED="true" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
FAKE_SONAR_CE_STATUS="SUCCESS" \
FAKE_SONAR_QG_STATUS="OK" \
FAKE_SONAR_MEASURES_MODE="present" \
run_service_with_fake_sonar \
  "$scm_disabled_run" \
  $'version: 1\nscan_label: original\nproject_key: scm-disabled\nproject_name: scm-disabled\nskip_sonar: false' \
  "$fake_bin"

assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.status' "passed" "service should disable Sonar SCM when workspace is not a git work tree"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.sonar_task_id' "fake-task" "successful async submission should persist task id"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.data_status' "pending" "successful async submission should mark follow-up pending"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.quality_gate_status' "null" "quality gate should not be resolved during async submission"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.scanner_mode' "native_maven" "service report should capture the native scanner mode"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.scanner_version' "5.5.0.6356" "service report should capture the Maven scanner version"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.status' "available" "successful submission should record available coverage"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.jdk' "17" "coverage JDK should match the successful build JDK"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.mode' "maven_test" "service report should capture the Maven coverage mode"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.command' "mvn test" "service report should capture the Maven coverage command"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.report_kind' "single_report" "service report should capture the coverage report kind"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.jacoco_version' "0.8.8" "java 17 fixture should select JaCoCo 0.8.8"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.attempted' "true" "coverage should be marked as attempted"
assert_json_value "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.tests_forced' "true" "Maven coverage should record forced test re-enable"
assert_json_path_exists "${scm_disabled_run}/outputs/run_report.json" '.scan.coverage.report_paths | length == 1' "coverage report path should be recorded"

missing_task_run="${tmp}/missing-task-run"
FAKE_SONAR_TASK_ID="" \
run_service_with_fake_sonar \
  "$missing_task_run" \
  $'version: 1\nscan_label: original\nproject_key: missing-task\nproject_name: missing-task\nskip_sonar: false' \
  "$fake_bin"

assert_json_value "${missing_task_run}/outputs/run_report.json" '.status' "failed" "missing task id should fail immediately"
assert_json_value "${missing_task_run}/outputs/run_report.json" '.reason' "sonar_submission_missing_task_id" "missing task id reason mismatch"

submit_failure_run="${tmp}/submit-failure-run"
FAKE_SONAR_SUBMIT_EXIT_CODE="42" \
run_service_with_fake_sonar \
  "$submit_failure_run" \
  $'version: 1\nscan_label: generated\nproject_key: submit-failure\nproject_name: submit-failure\nskip_sonar: false' \
  "$fake_bin"

assert_json_value "${submit_failure_run}/outputs/run_report.json" '.status' "failed" "submission failure should fail immediately"
assert_json_value "${submit_failure_run}/outputs/run_report.json" '.reason' "cli_fallback_failed" "submission failure reason mismatch"

fallback_run="${tmp}/fallback-run"
FAKE_COVERAGE_REPORT_MODE="missing" \
FAKE_FORBID_COVERAGE_REPORT_PATHS="true" \
run_service_with_fake_sonar \
  "$fallback_run" \
  $'version: 1\nscan_label: generated\nproject_key: fallback-run\nproject_name: fallback-run\nskip_sonar: false' \
  "$fake_bin"

assert_json_value "${fallback_run}/outputs/run_report.json" '.status' "passed" "coverage fallback should still submit sonar successfully"
assert_json_value "${fallback_run}/outputs/run_report.json" '.scan.coverage.status' "fallback" "missing coverage report should trigger fallback metadata"
assert_json_value "${fallback_run}/outputs/run_report.json" '.scan.coverage.reason' "tests_skipped_by_config" "fallback reason mismatch"

popd >/dev/null
