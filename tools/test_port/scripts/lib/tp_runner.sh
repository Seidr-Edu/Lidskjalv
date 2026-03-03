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

tp_clean_junit_outputs() {
  local repo="$1"
  rm -rf \
    "${repo}/target/surefire-reports" \
    "${repo}/target/failsafe-reports" \
    "${repo}/build/test-results" \
    >/dev/null 2>&1 || true
}

tp_maven_local_repo_path() {
  local repo="$1"
  echo "${TP_MAVEN_LOCAL_REPO:-${repo}/.m2/repository}"
}

tp_run_maven_test() {
  local repo="$1"
  local log_file="$2"
  shift 2

  local maven_local_repo
  maven_local_repo="$(tp_maven_local_repo_path "$repo")"
  mkdir -p "$maven_local_repo"
  (cd "$repo" && mvn -q "-Dmaven.repo.local=${maven_local_repo}" "$@") >"$log_file" 2>&1
}

tp_run_tests() {
  local repo="$1"
  local log_file="$2"
  local runner
  runner="$(tp_detect_test_runner "$repo")"
  local had_errexit=false
  [[ $- == *e* ]] && had_errexit=true

  mkdir -p "$(dirname "$log_file")"
  tp_clean_junit_outputs "$repo"

  set +e
  case "$runner" in
    maven) tp_run_maven_test "$repo" "$log_file" test ;;
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

tp_baseline_failure_type_from_class() {
  local failure_class="$1"
  case "$failure_class" in
    compatibility-build) echo "compatibility" ;;
    environmental-build) echo "environmental-noise" ;;
    behavioral-mismatch) echo "behavioral" ;;
    runtime-test-failure) echo "runtime" ;;
    *) echo "unknown" ;;
  esac
}

tp_infer_baseline_failure_type() {
  local unit_class="$1"
  local full_class="$2"
  local unit_rc="$3"
  local full_rc="$4"

  if [[ "$full_rc" -eq 0 ]]; then
    echo ""
    return 0
  fi

  if [[ "$unit_rc" -eq 0 && "$full_rc" -ne 0 ]]; then
    echo "environmental-noise"
    return 0
  fi

  case "$full_class" in
    environmental-build)
      echo "environmental-noise"
      return 0
      ;;
    compatibility-build)
      echo "compatibility"
      return 0
      ;;
    behavioral-mismatch)
      echo "behavioral"
      return 0
      ;;
    runtime-test-failure)
      case "$unit_class" in
        environmental-build|runtime-test-failure|unknown) echo "environmental-noise" ;;
        *) echo "runtime" ;;
      esac
      return 0
      ;;
  esac

  case "$unit_class" in
    environmental-build) echo "environmental-noise" ;;
    compatibility-build) echo "compatibility" ;;
    behavioral-mismatch) echo "behavioral" ;;
    runtime-test-failure) echo "runtime" ;;
    *) echo "unknown" ;;
  esac
}

tp_run_baseline_tests() {
  local repo="$1"
  local log_file="$2"
  local runner
  runner="$(tp_detect_test_runner "$repo")"
  local had_errexit=false
  [[ $- == *e* ]] && had_errexit=true
  local rc=0
  local unit_rc=0
  local full_rc=0
  local unit_log=""
  local full_log=""
  local unit_class=""
  local full_class=""

  mkdir -p "$(dirname "$log_file")"
  tp_clean_junit_outputs "$repo"

  TP_BASELINE_LAST_STRATEGY="single-run"
  TP_BASELINE_LAST_STATUS="skipped"
  TP_BASELINE_LAST_UNIT_ONLY_RC=-1
  TP_BASELINE_LAST_FULL_RC=-1
  TP_BASELINE_LAST_FAILURE_CLASS=""
  TP_BASELINE_LAST_FAILURE_TYPE=""

  set +e
  case "$runner" in
    maven)
      TP_BASELINE_LAST_STRATEGY="maven-unit-first-fallback-full"
      unit_log="${log_file}.unit-only.log"
      full_log="${log_file}.full.log"

      tp_run_maven_test "$repo" "$unit_log" \
        "-DskipITs" "-DskipIT=true" "-DskipIntegrationTests=true" \
        "-DexcludedGroups=integration,IntegrationTest" \
        test
      unit_rc=$?
      TP_BASELINE_LAST_UNIT_ONLY_RC="$unit_rc"

      if [[ "$unit_rc" -eq 0 ]]; then
        cp "$unit_log" "$log_file"
        TP_BASELINE_LAST_STATUS="pass"
        $had_errexit && set -e || set +e
        return 0
      fi

      tp_run_maven_test "$repo" "$full_log" test
      full_rc=$?
      TP_BASELINE_LAST_FULL_RC="$full_rc"

      {
        printf '=== baseline unit-only run (integration-skip flags) rc=%s ===\n' "$unit_rc"
        cat "$unit_log"
        printf '\n=== baseline full test fallback rc=%s ===\n' "$full_rc"
        cat "$full_log"
      } >"$log_file"

      if [[ "$full_rc" -eq 0 ]]; then
        TP_BASELINE_LAST_STATUS="pass"
        TP_BASELINE_LAST_FAILURE_CLASS=""
        TP_BASELINE_LAST_FAILURE_TYPE=""
        $had_errexit && set -e || set +e
        return 0
      fi

      unit_class="$(tp_classify_test_failure_log "$unit_log")"
      full_class="$(tp_classify_test_failure_log "$full_log")"
      TP_BASELINE_LAST_FAILURE_CLASS="$full_class"
      TP_BASELINE_LAST_FAILURE_TYPE="$(tp_infer_baseline_failure_type "$unit_class" "$full_class" "$unit_rc" "$full_rc")"
      TP_BASELINE_LAST_STATUS="fail-with-integration-skip"
      $had_errexit && set -e || set +e
      return "$full_rc"
      ;;
    gradle-wrapper) (cd "$repo" && ./gradlew test --no-daemon) >"$log_file" 2>&1; rc=$? ;;
    gradle) (cd "$repo" && gradle test --no-daemon) >"$log_file" 2>&1; rc=$? ;;
    *)
      echo "unsupported test runner" >"$log_file"
      TP_BASELINE_LAST_STATUS="skipped"
      $had_errexit && set -e || set +e
      return 2
      ;;
  esac

  TP_BASELINE_LAST_STATUS="$(tp_test_rc_status "$rc")"
  if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
    TP_BASELINE_LAST_FAILURE_CLASS="$(tp_classify_test_failure_log "$log_file")"
    TP_BASELINE_LAST_FAILURE_TYPE="$(tp_baseline_failure_type_from_class "$TP_BASELINE_LAST_FAILURE_CLASS")"
  fi

  $had_errexit && set -e || set +e
  return "$rc"
}

tp_classify_test_failure_log() {
  local log_file="$1"
  [[ -f "$log_file" ]] || { echo "unknown"; return 0; }

  if LC_ALL=C grep -Eiq \
    'Non-resolvable parent POM|Could not transfer artifact|Could not find artifact|Could not resolve (dependencies|artifact)|Unknown host|No such host|Connection refused|Connection timed out|Read timed out|Temporary failure in name resolution|nodename nor servname provided|PKIX path building failed|Network is unreachable|No route to host|Failed to connect to' \
    "$log_file"; then
    echo "environmental-build"
    return 0
  fi

  if LC_ALL=C grep -Eiq \
    'COMPILATION ERROR|cannot find symbol|package [^ ]+ does not exist|error: cannot find symbol|error: package [^ ]+ does not exist|error: incompatible types|Execution failed for task .*compile(Test|Java|Kotlin)|Compilation failed|Could not compile' \
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
