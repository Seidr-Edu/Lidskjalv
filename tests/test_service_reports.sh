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
  mkdir -p .scannerwork
  printf 'ceTaskId=%s\n' "${FAKE_SONAR_TASK_ID:-fake-task}" > .scannerwork/report-task.txt
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
qg_status="${FAKE_SONAR_QG_STATUS:-OK}"
measures_mode="${FAKE_SONAR_MEASURES_MODE:-present}"
task_id="${FAKE_SONAR_TASK_ID:-fake-task}"

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

run_service_with_fake_sonar() {
  local run_dir="$1"
  local manifest_json="$2"
  local fake_bin="$3"
  mkdir -p "${run_dir}/config"
  printf '%s\n' "$manifest_json" > "${run_dir}/config/manifest.json"
  PATH="${fake_bin}:$PATH" \
  SONAR_HOST_URL="https://sonar.example.test" \
  SONAR_TOKEN="token" \
  SONAR_ORGANIZATION="org" \
  LIDSKJALV_RUN_DIR="$run_dir" \
  LIDSKJALV_MANIFEST="${run_dir}/config/manifest.json" \
  LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_app" \
  ./lidskjalv-service.sh >/dev/null
}

pushd "$ROOT_DIR" >/dev/null

fake_bin="${tmp}/fake-bin"
make_fake_bin "$fake_bin"

quality_gate_run="${tmp}/quality-gate-run"
FAKE_SONAR_CE_STATUS="SUCCESS" \
FAKE_SONAR_QG_STATUS="ERROR" \
FAKE_SONAR_MEASURES_MODE="present" \
run_service_with_fake_sonar \
  "$quality_gate_run" \
  '{"version":1,"scan_label":"original","project_key":"quality-gate","project_name":"quality-gate","skip_sonar":false,"sonar_wait_timeout_sec":1,"sonar_wait_poll_sec":0}' \
  "$fake_bin"

assert_json_value "${quality_gate_run}/outputs/run_report.json" '.status' "failed" "quality gate error should fail scan"
assert_json_value "${quality_gate_run}/outputs/run_report.json" '.reason' "quality-gate-failed" "quality gate failure reason mismatch"
assert_json_value "${quality_gate_run}/outputs/run_report.json" '.scan.ce_task_status' "SUCCESS" "ce task status should be captured"
assert_json_value "${quality_gate_run}/outputs/run_report.json" '.scan.quality_gate_status' "ERROR" "quality gate status should be captured"
assert_json_value "${quality_gate_run}/outputs/run_report.json" '.scan.data_status' "complete" "measures should be marked complete"

timeout_run="${tmp}/timeout-run"
FAKE_SONAR_CE_STATUS="IN_PROGRESS" \
FAKE_SONAR_QG_STATUS="OK" \
FAKE_SONAR_MEASURES_MODE="empty" \
run_service_with_fake_sonar \
  "$timeout_run" \
  '{"version":1,"scan_label":"generated","project_key":"timeout-case","skip_sonar":false,"sonar_wait_timeout_sec":0,"sonar_wait_poll_sec":0}' \
  "$fake_bin"

assert_json_value "${timeout_run}/outputs/run_report.json" '.status' "failed" "timeout should fail scan"
assert_json_value "${timeout_run}/outputs/run_report.json" '.reason' "sonar-timeout" "timeout reason mismatch"
assert_json_value "${timeout_run}/outputs/run_report.json" '.scan.ce_task_status' "IN_PROGRESS" "timeout should preserve last ce status"
assert_json_value "${timeout_run}/outputs/run_report.json" '.scan.data_status' "pending" "timeout should mark data pending"

popd >/dev/null
