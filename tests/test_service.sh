#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/tests/lib/testlib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="${tmp}/fake-bin"
make_fake_build_bin "$fake_bin"

pushd "$ROOT_DIR" >/dev/null

root_state_checksum="$(file_checksum "${ROOT_DIR}/.data/lidskjalv/state/scan-state.json")"

invalid_run="${tmp}/invalid-run"
mkdir -p "${invalid_run}/config" "${invalid_run}/input"
printf '%s\n' '{"version":1,"scan_label":"original","project_key":"invalid","unexpected":true}' > "${invalid_run}/config/manifest.json"
LIDSKJALV_RUN_DIR="$invalid_run" \
LIDSKJALV_MANIFEST="${invalid_run}/config/manifest.json" \
LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_app" \
./lidskjalv-service.sh >/dev/null
assert_json_value "${invalid_run}/outputs/run_report.json" '.status' "error" "invalid manifest should emit error report"
assert_json_value "${invalid_run}/outputs/run_report.json" '.reason' "invalid-service-manifest" "invalid manifest reason mismatch"

missing_manifest_run="${tmp}/missing-manifest-run"
mkdir -p "${missing_manifest_run}/config"
LIDSKJALV_RUN_DIR="$missing_manifest_run" \
LIDSKJALV_MANIFEST="${missing_manifest_run}/config/manifest.json" \
LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_app" \
./lidskjalv-service.sh >/dev/null
assert_json_value "${missing_manifest_run}/outputs/run_report.json" '.status' "error" "missing manifest should emit error report"
assert_json_value "${missing_manifest_run}/outputs/run_report.json" '.reason' "missing-service-manifest" "missing manifest reason mismatch"

missing_input_run="${tmp}/missing-input-run"
mkdir -p "${missing_input_run}/config"
printf '%s\n' '{"version":1,"scan_label":"original","project_key":"missing-input","skip_sonar":true}' > "${missing_input_run}/config/manifest.json"
LIDSKJALV_RUN_DIR="$missing_input_run" \
LIDSKJALV_MANIFEST="${missing_input_run}/config/manifest.json" \
LIDSKJALV_INPUT_REPO="${missing_input_run}/input/repo" \
./lidskjalv-service.sh >/dev/null
assert_json_value "${missing_input_run}/outputs/run_report.json" '.reason' "missing-input-repo" "missing input should be reported"

unwritable_parent="${tmp}/unwritable"
mkdir -p "$unwritable_parent"
chmod 500 "$unwritable_parent"
set +e
LIDSKJALV_RUN_DIR="${unwritable_parent}/run" \
LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_app" \
LIDSKJALV_SCAN_LABEL=original \
LIDSKJALV_PROJECT_KEY=unwritable-run \
LIDSKJALV_SKIP_SONAR=true \
./lidskjalv-service.sh >/dev/null 2>&1
unwritable_rc=$?
set -e
chmod 700 "$unwritable_parent"
assert_eq "1" "$unwritable_rc" "unwritable run dir should fail before report creation"

missing_sonar_run="${tmp}/missing-sonar-run"
mkdir -p "${missing_sonar_run}/config"
printf '%s\n' '{"version":1,"scan_label":"original","project_key":"needs-sonar","skip_sonar":false}' > "${missing_sonar_run}/config/manifest.json"
env -u SONAR_HOST_URL -u SONAR_TOKEN -u SONAR_ORGANIZATION \
  LIDSKJALV_RUN_DIR="$missing_sonar_run" \
  LIDSKJALV_MANIFEST="${missing_sonar_run}/config/manifest.json" \
  LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_app" \
  ./lidskjalv-service.sh >/dev/null
assert_json_value "${missing_sonar_run}/outputs/run_report.json" '.reason' "missing-sonar-env" "missing sonar env should be a service error"

manifest_owned_run="${tmp}/manifest-owned-run"
mkdir -p "${manifest_owned_run}/config"
printf '%s\n' '{"version":1,"scan_label":"original","project_key":"manifest-owned","project_name":"manifest-owned","repo_subdir":"app","skip_sonar":true}' > "${manifest_owned_run}/config/manifest.json"
PATH="${fake_bin}:$PATH" \
LIDSKJALV_RUN_DIR="$manifest_owned_run" \
LIDSKJALV_MANIFEST="${manifest_owned_run}/config/manifest.json" \
LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_monorepo" \
LIDSKJALV_SCAN_LABEL="generated" \
LIDSKJALV_PROJECT_KEY="ignored-key" \
LIDSKJALV_PROJECT_NAME="ignored-name" \
LIDSKJALV_REPO_SUBDIR="ignored/subdir" \
LIDSKJALV_SKIP_SONAR="false" \
LIDSKJALV_SONAR_WAIT_TIMEOUT_SEC="1" \
LIDSKJALV_SONAR_WAIT_POLL_SEC="0" \
./lidskjalv-service.sh >/dev/null
assert_json_value "${manifest_owned_run}/outputs/run_report.json" '.status' "passed" "manifest-owned run should pass"
assert_json_value "${manifest_owned_run}/outputs/run_report.json" '.scan_label' "original" "service should ignore env scan_label overrides"
assert_json_value "${manifest_owned_run}/outputs/run_report.json" '.project_key' "manifest-owned" "service should ignore env project_key overrides"
assert_json_value "${manifest_owned_run}/outputs/run_report.json" '.inputs.repo_subdir' "app" "service should ignore env repo_subdir overrides"
assert_dir_exists "${manifest_owned_run}/artifacts/scans/original/workspace/repo" "manifest-owned scan should use manifest label"
assert_not_exists "${manifest_owned_run}/artifacts/scans/generated" "env scan_label override should not create generated scan dir"

for scan_label in original generated; do
  run_dir="${tmp}/${scan_label}-service-run"
  mkdir -p "${run_dir}/config"
  printf '%s\n' "{\"version\":1,\"scan_label\":\"${scan_label}\",\"project_key\":\"${scan_label}-scan\",\"project_name\":\"${scan_label}-scan\",\"skip_sonar\":true}" > "${run_dir}/config/manifest.json"
  PATH="${fake_bin}:$PATH" \
  LIDSKJALV_RUN_DIR="$run_dir" \
  LIDSKJALV_MANIFEST="${run_dir}/config/manifest.json" \
  LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_app" \
  ./lidskjalv-service.sh >/dev/null

  assert_json_value "${run_dir}/outputs/run_report.json" '.status' "passed" "service run should pass with skip-sonar"
  assert_dir_exists "${run_dir}/artifacts/scans/${scan_label}/workspace/repo" "workspace repo should exist"
  assert_dir_exists "${run_dir}/artifacts/scans/${scan_label}/logs" "logs dir should exist"
  assert_dir_exists "${run_dir}/artifacts/scans/${scan_label}/metadata" "metadata dir should exist"
  assert_file_exists "${run_dir}/artifacts/scans/${scan_label}/metadata/scan-state.json" "service state file missing"
done

gradle_run="${tmp}/gradle-service-run"
mkdir -p "${gradle_run}/config"
printf '%s\n' '{"version":1,"scan_label":"generated","project_key":"gradle-service","skip_sonar":true}' > "${gradle_run}/config/manifest.json"
PATH="${fake_bin}:$PATH" \
LIDSKJALV_RUN_DIR="$gradle_run" \
LIDSKJALV_MANIFEST="${gradle_run}/config/manifest.json" \
LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/gradle_app" \
./lidskjalv-service.sh >/dev/null
assert_json_value "${gradle_run}/outputs/run_report.json" '.scan.build_tool' "gradle" "gradle fixture should use gradle build tool"
assert_json_value "${gradle_run}/outputs/run_report.json" '.status' "passed" "gradle service run should pass"

subdir_run="${tmp}/subdir-service-run"
mkdir -p "${subdir_run}/config"
printf '%s\n' '{"version":1,"scan_label":"original","project_key":"subdir-service","repo_subdir":"app","skip_sonar":true}' > "${subdir_run}/config/manifest.json"
PATH="${fake_bin}:$PATH" \
LIDSKJALV_RUN_DIR="$subdir_run" \
LIDSKJALV_MANIFEST="${subdir_run}/config/manifest.json" \
LIDSKJALV_INPUT_REPO="${ROOT_DIR}/tests/fixtures/maven_monorepo" \
./lidskjalv-service.sh >/dev/null
assert_json_value "${subdir_run}/outputs/run_report.json" '.inputs.repo_subdir' "app" "service should preserve repo_subdir"
assert_json_value "${subdir_run}/outputs/run_report.json" '.scan.build_tool' "maven" "subdir run should use maven"
assert_json_value "${subdir_run}/outputs/run_report.json" '.status' "passed" "subdir service run should pass"

updated_root_state_checksum="$(file_checksum "${ROOT_DIR}/.data/lidskjalv/state/scan-state.json")"
assert_eq "$root_state_checksum" "$updated_root_state_checksum" "service mode should not touch shared local state"

popd >/dev/null
