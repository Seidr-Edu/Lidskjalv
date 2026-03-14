#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/tests/lib/testlib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="${tmp}/fake-bin"
make_fake_build_bin "$fake_bin"
failing_system_build_bin="${tmp}/failing-system-build-bin"
mkdir -p "$failing_system_build_bin"
cat > "${failing_system_build_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "system mvn should not run during wrapper tests" >&2
exit 42
EOF
chmod +x "${failing_system_build_bin}/mvn"
cat > "${failing_system_build_bin}/gradle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "system gradle should not run during wrapper tests" >&2
exit 42
EOF
chmod +x "${failing_system_build_bin}/gradle"
maven_app_copy="${tmp}/maven-app"
cp -a "${ROOT_DIR}/tests/fixtures/maven_app/." "$maven_app_copy/"
create_projects_env="${tmp}/create-projects.env"
cat > "$create_projects_env" <<EOF
SONAR_HOST_URL=https://sonar.example.test
SONAR_TOKEN=test-token
SONAR_ORGANIZATION=test-org
EOF

cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "${FAKE_CURL_LOG:?}"
printf '%s\n' '{"project":{"key":"fake"}}'
EOF
chmod +x "${fake_bin}/curl"

pushd "$ROOT_DIR" >/dev/null

./scripts/scan-one.sh --help >/dev/null
./scripts/batch-scan.sh --help >/dev/null
./scripts/create-projects.sh --help >/dev/null
./lidskjalv-service.sh --help >/dev/null

path_data_dir="${tmp}/path-data"
PATH="${fake_bin}:$PATH" \
LIDSKJALV_DATA_DIR="$path_data_dir" \
./scripts/scan-one.sh \
  --path "$maven_app_copy" \
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

custom_maven_repo="${tmp}/custom-maven-wrapper"
mkdir -p "${custom_maven_repo}/src/main/java/example"
cat > "${custom_maven_repo}/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>example</groupId>
  <artifactId>custom-maven-wrapper</artifactId>
  <version>1.0.0</version>
</project>
EOF
cat > "${custom_maven_repo}/mvnw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p target/classes
: > target/classes/App.class
EOF
chmod +x "${custom_maven_repo}/mvnw"
cat > "${custom_maven_repo}/src/main/java/example/App.java" <<'EOF'
package example;

class App {}
EOF

custom_maven_data_dir="${tmp}/custom-maven-data"
PATH="${failing_system_build_bin}:$PATH" \
LIDSKJALV_DATA_DIR="$custom_maven_data_dir" \
./scripts/scan-one.sh \
  --path "$custom_maven_repo" \
  --project-key custom_maven_wrapper \
  --project-name custom-maven-wrapper \
  --skip-sonar >/dev/null

assert_json_value "${custom_maven_data_dir}/state/scan-state.json" '.repositories["custom_maven_wrapper"].status' "success" "custom mvnw repo should build successfully"
custom_maven_logs="$(find "${custom_maven_data_dir}/logs/custom_maven_wrapper" -name 'build-attempt-*.log' -print0 | xargs -0 cat)"
assert_contains "${custom_maven_repo}/mvnw" "$custom_maven_logs" "custom mvnw should be used instead of system mvn"

custom_gradle_repo="${tmp}/custom-gradle-wrapper"
mkdir -p "${custom_gradle_repo}/src/main/java/example"
cat > "${custom_gradle_repo}/gradlew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
task="${1:-}"
case "$task" in
  compileJava)
    mkdir -p build/classes/java/main
    : > build/classes/java/main/App.class
    ;;
  *)
    echo "Unsupported task: ${task}" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${custom_gradle_repo}/gradlew"
cat > "${custom_gradle_repo}/src/main/java/example/App.java" <<'EOF'
package example;

class App {}
EOF

custom_gradle_data_dir="${tmp}/custom-gradle-data"
PATH="${failing_system_build_bin}:$PATH" \
LIDSKJALV_DATA_DIR="$custom_gradle_data_dir" \
./scripts/scan-one.sh \
  --path "$custom_gradle_repo" \
  --project-key custom_gradle_wrapper \
  --project-name custom-gradle-wrapper \
  --skip-sonar >/dev/null

assert_json_value "${custom_gradle_data_dir}/state/scan-state.json" '.repositories["custom_gradle_wrapper"].status' "success" "custom gradlew repo should build successfully"
custom_gradle_logs="$(find "${custom_gradle_data_dir}/logs/custom_gradle_wrapper" -name 'build-attempt-*.log' -print0 | xargs -0 cat)"
assert_contains "${custom_gradle_repo}/gradlew compileJava" "$custom_gradle_logs" "custom gradlew should reach the compileJava fallback"

batch_input="${tmp}/repos.txt"
printf 'path:%s\n' "$maven_app_copy" > "$batch_input"
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

set +e
missing_jdk_output="$(PATH="${fake_bin}:$PATH" ./scripts/scan-one.sh --jdk 2>&1)"
missing_jdk_rc=$?
set -e
assert_eq "1" "$missing_jdk_rc" "missing jdk value should exit 1"
assert_contains "--jdk requires a value" "$missing_jdk_output" "missing jdk value should explain the error"

set +e
missing_repos_root_output="$(LIDSKJALV_SKIP_ENV_LOAD=true ./scripts/create-projects.sh --repos-root 2>&1)"
missing_repos_root_rc=$?
set -e
assert_eq "1" "$missing_repos_root_rc" "missing repos-root value should exit 1"
assert_contains "--repos-root requires a directory argument" "$missing_repos_root_output" "missing repos-root should explain the error"

create_projects_root="${tmp}/create-projects-root"
mkdir -p "$create_projects_root"
cp -a "$maven_app_copy/." "${create_projects_root}/maven-app/"
create_projects_curl_log="${tmp}/create-projects-curl.log"
expected_create_projects_key="$(
  ROOT_DIR="$ROOT_DIR" \
  CREATE_PROJECTS_TARGET="${create_projects_root}/maven-app" \
  bash -lc 'source "$ROOT_DIR/scripts/lib/common.sh"; derive_source_key path "$CREATE_PROJECTS_TARGET"'
)"
expected_create_projects_name="$(
  ROOT_DIR="$ROOT_DIR" \
  CREATE_PROJECTS_TARGET="${create_projects_root}/maven-app" \
  bash -lc 'source "$ROOT_DIR/scripts/lib/common.sh"; derive_source_display_name path "$CREATE_PROJECTS_TARGET"'
)"

PATH="${fake_bin}:$PATH" \
FAKE_CURL_LOG="$create_projects_curl_log" \
LIDSKJALV_ENV_FILE="$create_projects_env" \
./scripts/create-projects.sh \
  --repos-root "$create_projects_root" \
  path:maven-app >/dev/null

create_projects_curl_args="$(cat "$create_projects_curl_log")"
assert_contains "/api/projects/create" "$create_projects_curl_args" "create-projects single-source mode should call Sonar create API"
assert_contains "project=${expected_create_projects_key}" "$create_projects_curl_args" "create-projects should derive the project key from a single path source"
assert_contains "name=${expected_create_projects_name}" "$create_projects_curl_args" "create-projects should derive the project name from a single path source"

popd >/dev/null
