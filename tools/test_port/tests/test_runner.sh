#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/testlib.sh"
# shellcheck source=/dev/null
source "${REPO_ROOT}/tools/test_port/scripts/lib/tp_runner.sh"

case_maven_uses_workspace_local_repo() {
  local tmp repo fake_bin log args_file local_repo
  tmp="$(tpt_mktemp_dir)"
  repo="${tmp}/repo"
  fake_bin="${tmp}/bin"
  log="${tmp}/mvn.log"
  args_file="${tmp}/mvn-args.txt"
  local_repo="${tmp}/workspace/.m2/repository"

  mkdir -p "$repo" "$fake_bin"
  echo "<project/>" > "${repo}/pom.xml"

  cat > "${fake_bin}/mvn" <<'MVN'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$TPT_MVN_ARGS_FILE"
repo_local=""
for arg in "$@"; do
  case "$arg" in
    -Dmaven.repo.local=*) repo_local="${arg#*=}" ;;
  esac
done
[[ -n "$repo_local" ]]
mkdir -p "$repo_local" target/surefire-reports
echo "cached" > "${repo_local}/artifact.txt"
cat > target/surefire-reports/TEST-fake.xml <<'XML'
<testsuite tests="1" failures="0" errors="0"><testcase classname="fake" name="ok"/></testsuite>
XML
MVN
  chmod +x "${fake_bin}/mvn"

  export TPT_MVN_ARGS_FILE="$args_file"
  TP_MAVEN_LOCAL_REPO="$local_repo"
  PATH="${fake_bin}:$PATH"
  hash -r

  tp_run_tests "$repo" "$log"

  tpt_assert_file_contains "$args_file" "-Dmaven.repo.local=${local_repo}" "maven invocation must set workspace local repo"
  tpt_assert_file_exists "${local_repo}/artifact.txt" "maven local repo should receive runtime cache writes"
}

case_gradle_wrapper_invocation_unchanged() {
  local tmp repo log args_file
  tmp="$(tpt_mktemp_dir)"
  repo="${tmp}/repo"
  log="${tmp}/gradlew.log"
  args_file="${tmp}/gradlew-args.txt"

  mkdir -p "$repo"
  cat > "${repo}/gradlew" <<'GRADLEW'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$TPT_GRADLEW_ARGS_FILE"
GRADLEW
  chmod +x "${repo}/gradlew"

  export TPT_GRADLEW_ARGS_FILE="$args_file"
  tp_run_tests "$repo" "$log"

  tpt_assert_file_contains "$args_file" "test --no-daemon" "gradle wrapper invocation should remain unchanged"
}

case_gradle_invocation_unchanged() {
  local tmp repo fake_bin log args_file
  tmp="$(tpt_mktemp_dir)"
  repo="${tmp}/repo"
  fake_bin="${tmp}/bin"
  log="${tmp}/gradle.log"
  args_file="${tmp}/gradle-args.txt"

  mkdir -p "$repo" "$fake_bin"
  echo "plugins {}" > "${repo}/build.gradle"

  cat > "${fake_bin}/gradle" <<'GRADLE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$TPT_GRADLE_ARGS_FILE"
GRADLE
  chmod +x "${fake_bin}/gradle"

  export TPT_GRADLE_ARGS_FILE="$args_file"
  PATH="${fake_bin}:$PATH"
  hash -r
  tp_run_tests "$repo" "$log"

  tpt_assert_file_contains "$args_file" "test --no-daemon" "plain gradle invocation should remain unchanged"
}

case_unknown_runner_returns_skipped_code() {
  local tmp repo log rc
  tmp="$(tpt_mktemp_dir)"
  repo="${tmp}/repo"
  log="${tmp}/unknown.log"

  mkdir -p "$repo"

  if tp_run_tests "$repo" "$log"; then
    echo "expected unknown runner to return skip code" >&2
    return 1
  else
    rc=$?
  fi

  tpt_assert_eq "2" "$rc" "unknown runner must return code 2"
  tpt_assert_file_contains "$log" "unsupported test runner" "unknown runner log should explain skip"
}

tpt_run_case "maven uses workspace local repo" case_maven_uses_workspace_local_repo
tpt_run_case "gradle wrapper invocation unchanged" case_gradle_wrapper_invocation_unchanged
tpt_run_case "gradle invocation unchanged" case_gradle_invocation_unchanged
tpt_run_case "unknown runner returns skip code" case_unknown_runner_returns_skipped_code

tpt_finish_suite
