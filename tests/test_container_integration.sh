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
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo -n rm -rf "$tmp"
  else
    rm -rf "$tmp" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

write_manifest() {
  local path="$1"
  local content="$2"
  printf '%s\n' "$content" > "$path"
}

run_container_scan() {
  local run_name="$1"
  local repo_path="$2"
  local manifest_yaml="$3"
  local run_dir="${tmp}/${run_name}"

  mkdir -p "${run_dir}/config"
  chmod 0777 "$run_dir" "${run_dir}/config"
  write_manifest "${run_dir}/config/manifest.yaml" "$manifest_yaml"
  chmod 0644 "${run_dir}/config/manifest.yaml"

  docker run --rm \
    -v "${repo_path}:/input/repo:ro" \
    -v "${run_dir}:/run" \
    "$image_tag" >/dev/null

  printf '%s\n' "$run_dir"
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
    $'version: 1\nrun_id: container-test-original\nscan_label: original\nproject_key: container-original\nproject_name: container-original\nskip_sonar: true'
)"
assert_json_value "${original_run_dir}/outputs/run_report.json" '.status' "passed" "original container scan should pass"
assert_json_value "${original_run_dir}/outputs/run_report.json" '.scan_label' "original" "original container scan should preserve scan label"
assert_json_value "${original_run_dir}/outputs/run_report.json" '.artifacts.workspace_dir' "null" "original container workspace should be reported as ephemeral"
assert_not_exists "${original_run_dir}/artifacts/scans/original/workspace" "original container workspace should be cleaned"
assert_dir_exists "${original_run_dir}/artifacts/scans/original/logs" "original container logs should exist"
assert_dir_exists "${original_run_dir}/artifacts/scans/original/metadata" "original container metadata should exist"

generated_run_dir="$(
  run_container_scan \
    "generated-run" \
    "${ROOT_DIR}/tests/fixtures/maven_monorepo" \
    $'version: 1\nrun_id: container-test-generated\nscan_label: generated\nproject_key: container-generated\nproject_name: container-generated\nrepo_subdir: app\nskip_sonar: true'
)"
assert_json_value "${generated_run_dir}/outputs/run_report.json" '.status' "passed" "generated container scan should pass"
assert_json_value "${generated_run_dir}/outputs/run_report.json" '.scan_label' "generated" "generated container scan should preserve scan label"
assert_json_value "${generated_run_dir}/outputs/run_report.json" '.inputs.repo_subdir' "app" "container scan should preserve repo_subdir"
assert_json_value "${generated_run_dir}/outputs/run_report.json" '.artifacts.workspace_dir' "null" "generated container workspace should be reported as ephemeral"
assert_not_exists "${generated_run_dir}/artifacts/scans/generated/workspace" "generated container workspace should be cleaned"
assert_dir_exists "${generated_run_dir}/artifacts/scans/generated/logs" "generated container logs should exist"
assert_dir_exists "${generated_run_dir}/artifacts/scans/generated/metadata" "generated container metadata should exist"

generated_v2_run_dir="$(
  run_container_scan \
    "generated-v2-run" \
    "${ROOT_DIR}/tests/fixtures/maven_monorepo" \
    $'version: 1\nrun_id: container-test-generated-v2\nscan_label: generated-v2\nproject_key: container-generated-v2\nproject_name: container-generated-v2\nrepo_subdir: app\nskip_sonar: true'
)"
assert_json_value "${generated_v2_run_dir}/outputs/run_report.json" '.status' "passed" "generated-v2 container scan should pass"
assert_json_value "${generated_v2_run_dir}/outputs/run_report.json" '.scan_label' "generated-v2" "generated-v2 container scan should preserve scan label"
assert_json_value "${generated_v2_run_dir}/outputs/run_report.json" '.inputs.repo_subdir' "app" "generated-v2 container scan should preserve repo_subdir"
assert_json_value "${generated_v2_run_dir}/outputs/run_report.json" '.artifacts.workspace_dir' "null" "generated-v2 container workspace should be reported as ephemeral"
assert_not_exists "${generated_v2_run_dir}/artifacts/scans/generated-v2/workspace" "generated-v2 container workspace should be cleaned"
assert_dir_exists "${generated_v2_run_dir}/artifacts/scans/generated-v2/logs" "generated-v2 container logs should exist"
assert_dir_exists "${generated_v2_run_dir}/artifacts/scans/generated-v2/metadata" "generated-v2 container metadata should exist"

popd >/dev/null
