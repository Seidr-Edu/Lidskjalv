#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/tests/lib/testlib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="${tmp}/fake-bin"
make_fake_build_bin "$fake_bin"

pushd "$ROOT_DIR" >/dev/null

./scripts/scan-one.sh --help >/dev/null
./scripts/batch-scan.sh --help >/dev/null
./scripts/create-projects.sh --help >/dev/null
./lidskjalv-service.sh --help >/dev/null

path_data_dir="${tmp}/path-data"
PATH="${fake_bin}:$PATH" \
LIDSKJALV_DATA_DIR="$path_data_dir" \
./scripts/scan-one.sh \
  --path "${ROOT_DIR}/tests/fixtures/maven_app" \
  --project-key cli_path_repo \
  --project-name cli-path-repo \
  --skip-sonar >/dev/null

assert_file_exists "${path_data_dir}/state/scan-state.json" "path scan state missing"
assert_json_value "${path_data_dir}/state/scan-state.json" '.repositories["cli_path_repo"].status' "success" "path scan should succeed"

url_source="${tmp}/url-source"
mkdir -p "$url_source"
cp -a "${ROOT_DIR}/tests/fixtures/maven_app/." "$url_source/"
git -C "$url_source" init >/dev/null
git -C "$url_source" checkout -b main >/dev/null
git -C "$url_source" config user.email "tests@example.com"
git -C "$url_source" config user.name "Tests"
git -C "$url_source" add . >/dev/null
git -C "$url_source" commit -m "fixture" >/dev/null

remote_root="${tmp}/git-remote/example/org"
mkdir -p "$remote_root"
git clone --bare "$url_source" "${remote_root}/repo.git" >/dev/null

git_home="${tmp}/git-home"
mkdir -p "$git_home"
HOME="$git_home" git config --global url."file://${tmp}/git-remote/".insteadOf https://example.test/

url_data_dir="${tmp}/url-data"
HOME="$git_home" \
PATH="${fake_bin}:$PATH" \
LIDSKJALV_DATA_DIR="$url_data_dir" \
./scripts/scan-one.sh \
  "https://example.test/example/org/repo.git" \
  --project-key cli_url_repo \
  --project-name cli-url-repo \
  --skip-sonar >/dev/null

assert_json_value "${url_data_dir}/state/scan-state.json" '.repositories["cli_url_repo"].status' "success" "url scan should succeed"
assert_dir_exists "${url_data_dir}/work/cli_url_repo/.git" "url scan should clone into work dir"

batch_input="${tmp}/repos.txt"
printf 'path:%s\n' "${ROOT_DIR}/tests/fixtures/maven_app" > "$batch_input"
batch_data_dir="${tmp}/batch-data"

LIDSKJALV_DATA_DIR="$batch_data_dir" \
PATH="${fake_bin}:$PATH" \
./scripts/batch-scan.sh \
  --skip-sonar \
  --input "$batch_input" >/dev/null

first_attempts="$(jq -r '.repositories | to_entries[0].value.attempts' "${batch_data_dir}/state/scan-state.json")"
assert_eq "1" "$first_attempts" "first batch run should record one attempt"

LIDSKJALV_DATA_DIR="$batch_data_dir" \
PATH="${fake_bin}:$PATH" \
./scripts/batch-scan.sh \
  --skip-sonar \
  --input "$batch_input" >/dev/null

second_attempts="$(jq -r '.repositories | to_entries[0].value.attempts' "${batch_data_dir}/state/scan-state.json")"
assert_eq "1" "$second_attempts" "successful batch rerun should reuse state"

popd >/dev/null
