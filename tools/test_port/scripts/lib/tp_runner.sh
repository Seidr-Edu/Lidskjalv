#!/usr/bin/env bash
# tp_runner.sh - test command detection and execution helpers.

set -euo pipefail

tp_detect_test_runner() {
  local repo="$1"
  if [[ -f "$repo/pom.xml" ]]; then
    echo "maven"
  elif [[ -x "$repo/gradlew" ]]; then
    echo "gradle-wrapper"
  elif [[ -f "$repo/build.gradle" || -f "$repo/build.gradle.kts" ]]; then
    echo "gradle"
  else
    echo "unknown"
  fi
}

tp_test_rc_status() {
  local rc="$1"
  case "$rc" in
    0) echo "pass" ;;
    2) echo "skipped" ;;
    *) echo "fail" ;;
  esac
}

tp_run_tests() {
  local repo="$1"
  local log_file="$2"
  local runner
  runner="$(tp_detect_test_runner "$repo")"
  local had_errexit=false
  [[ $- == *e* ]] && had_errexit=true

  mkdir -p "$(dirname "$log_file")"

  set +e
  case "$runner" in
    maven)
      local maven_local_repo="${TP_MAVEN_LOCAL_REPO:-${repo}/.m2/repository}"
      mkdir -p "$maven_local_repo"
      (cd "$repo" && mvn -q "-Dmaven.repo.local=${maven_local_repo}" test) >"$log_file" 2>&1
      ;;
    gradle-wrapper) (cd "$repo" && ./gradlew test --no-daemon) >"$log_file" 2>&1 ;;
    gradle) (cd "$repo" && gradle test --no-daemon) >"$log_file" 2>&1 ;;
    *)
      echo "unsupported test runner" >"$log_file"
      $had_errexit && set -e || set +e
      return 2
      ;;
  esac
  local rc=$?
  $had_errexit && set -e || set +e
  return "$rc"
}

tp_classify_test_failure_log() {
  local log_file="$1"
  [[ -f "$log_file" ]] || { echo "unknown"; return 0; }

  if LC_ALL=C grep -Eiq \
    'COMPILATION ERROR|cannot find symbol|package .+ does not exist|Execution failed for task .*compile(Test|Kotlin)|Could not resolve|error: ' \
    "$log_file"; then
    echo "compatibility-build"
    return 0
  fi

  if LC_ALL=C grep -Eiq \
    'Assertion(Error|FailedError)|ComparisonFailure|expected:<.*> but was:<.*>|There were test failures|Tests run: .*Failures: [1-9]' \
    "$log_file"; then
    echo "behavioral-mismatch"
    return 0
  fi

  if LC_ALL=C grep -Eiq \
    'Tests run: .*Errors: [1-9]|BUILD FAILED|FAILURE: Build failed' \
    "$log_file"; then
    echo "runtime-test-failure"
    return 0
  fi

  echo "unknown"
}
