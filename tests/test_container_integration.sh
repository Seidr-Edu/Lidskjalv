#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/tests/lib/testlib.sh"

if ! command -v docker >/dev/null 2>&1; then
  test_fail "docker is required for container integration tests"
fi

tmp="$(mktemp -d)"
image_tag="lidskjalv:test-container-${RANDOM}"
cleanup() {
  docker image rm -f "$image_tag" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

run_container_scan() {
  local run_name="$1"
  local repo_path="$2"
  local manifest_json="$3"
  local run_dir="${tmp}/${run_name}"

  mkdir -p "${run_dir}/config"
  chmod 0777 "$run_dir" "${run_dir}/config"
  printf '%s\n' "$manifest_json" > "${run_dir}/config/manifest.json"
  chmod 0644 "${run_dir}/config/manifest.json"

  docker run --rm \
    -v "${repo_path}:/input/repo:ro" \
    -v "${run_dir}:/run" \
    "$image_tag" >/dev/null

  printf '%s\n' "$run_dir"
}

assert_run_dir_removable() {
  local run_dir="$1"
  if ! rm -rf "$run_dir"; then
    test_fail "container run dir should be removable by host cleanup: ${run_dir}"
  fi
  assert_not_exists "$run_dir" "container run dir should be deleted cleanly"
}

pushd "$ROOT_DIR" >/dev/null

docker build -t "$image_tag" .

container_jdks="$(
  docker run --rm --entrypoint bash "$image_tag" -lc \
    'source /app/scripts/lib/common.sh; source /app/scripts/lib/select-jdk.sh; list_available_jdks | tr "\n" " "'
)"
for expected_jdk in 8 11 17 21 25; do
  assert_contains "$expected_jdk" "$container_jdks" "container image should expose JDK ${expected_jdk}"
done

original_run_dir="$(
  run_container_scan \
    "original-run" \
    "${ROOT_DIR}/tests/fixtures/maven_app" \
    '{"version":1,"run_id":"container-test-original","scan_label":"original","project_key":"container-original","project_name":"container-original","skip_sonar":true}'
)"
assert_json_value "${original_run_dir}/outputs/run_report.json" '.status' "passed" "original container scan should pass"
assert_json_value "${original_run_dir}/outputs/run_report.json" '.scan_label' "original" "original container scan should preserve scan label"
assert_dir_exists "${original_run_dir}/artifacts/scans/original/workspace/repo" "original container workspace should exist"
assert_run_dir_removable "$original_run_dir"

generated_run_dir="$(
  run_container_scan \
    "generated-run" \
    "${ROOT_DIR}/tests/fixtures/maven_monorepo" \
    '{"version":1,"run_id":"container-test-generated","scan_label":"generated","project_key":"container-generated","project_name":"container-generated","repo_subdir":"app","skip_sonar":true}'
)"
assert_json_value "${generated_run_dir}/outputs/run_report.json" '.status' "passed" "generated container scan should pass"
assert_json_value "${generated_run_dir}/outputs/run_report.json" '.scan_label' "generated" "generated container scan should preserve scan label"
assert_json_value "${generated_run_dir}/outputs/run_report.json" '.inputs.repo_subdir' "app" "container scan should preserve repo_subdir"
assert_dir_exists "${generated_run_dir}/artifacts/scans/generated/workspace/repo/app" "generated container workspace should include subdir repo copy"
assert_run_dir_removable "$generated_run_dir"

popd >/dev/null
