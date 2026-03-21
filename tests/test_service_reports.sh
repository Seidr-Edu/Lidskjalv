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
if [[ "$*" == *"clean compile"* ]]; then
  mkdir -p target/classes
  : > target/classes/App.class
  exit 0
fi
if [[ "$*" == *"org.sonarsource.scanner.maven:sonar-maven-plugin:sonar"* ]]; then
  if [[ -n "${FAKE_SONAR_SUBMIT_EXIT_CODE:-}" ]]; then
    exit "${FAKE_SONAR_SUBMIT_EXIT_CODE}"
  fi
  if [[ "${FAKE_REQUIRE_SONAR_SCM_DISABLED:-}" == "true" && "$*" != *"-Dsonar.scm.disabled=true"* ]]; then
    printf '%s\n' "missing -Dsonar.scm.disabled=true" >&2
    exit 91
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

missing_task_run="${tmp}/missing-task-run"
FAKE_SONAR_TASK_ID="" \
run_service_with_fake_sonar \
  "$missing_task_run" \
  $'version: 1\nscan_label: original\nproject_key: missing-task\nproject_name: missing-task\nskip_sonar: false' \
  "$fake_bin"

assert_json_value "${missing_task_run}/outputs/run_report.json" '.status' "failed" "missing task id should fail immediately"
assert_json_value "${missing_task_run}/outputs/run_report.json" '.reason' "sonar_submission_failed" "missing task id reason mismatch"

submit_failure_run="${tmp}/submit-failure-run"
FAKE_SONAR_SUBMIT_EXIT_CODE="42" \
run_service_with_fake_sonar \
  "$submit_failure_run" \
  $'version: 1\nscan_label: generated\nproject_key: submit-failure\nproject_name: submit-failure\nskip_sonar: false' \
  "$fake_bin"

assert_json_value "${submit_failure_run}/outputs/run_report.json" '.status' "failed" "submission failure should fail immediately"
assert_json_value "${submit_failure_run}/outputs/run_report.json" '.reason' "sonar_submission_failed" "submission failure reason mismatch"

popd >/dev/null
