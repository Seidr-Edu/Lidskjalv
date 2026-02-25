#!/usr/bin/env bash
# exp_test_port.sh - isolated test-port evaluation stage.

set -euo pipefail

exp_detect_test_runner() {
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

exp_test_rc_status() {
  local rc="$1"
  case "$rc" in
    0) echo "pass" ;;
    2) echo "skipped" ;;
    *) echo "fail" ;;
  esac
}

exp_run_tests() {
  local repo="$1"
  local log_file="$2"
  local runner
  runner="$(exp_detect_test_runner "$repo")"
  local had_errexit=false
  [[ $- == *e* ]] && had_errexit=true

  mkdir -p "$(dirname "$log_file")"

  set +e
  case "$runner" in
    maven) (cd "$repo" && mvn -q test) >"$log_file" 2>&1 ;;
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

exp_classify_test_failure_log() {
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

exp_is_allowed_test_path() {
  local rel="$1"
  case "$rel" in
    ./src/test/*|./src/*Test*/*|./test/*|./tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

exp_write_repo_manifest() {
  local repo="$1"
  local manifest_file="$2"

  : > "$manifest_file"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    local abs="${repo}/${rel#./}"
    printf '%s\t%s\n' "$rel" "$(exp_sha256_file "$abs")" >> "$manifest_file"
  done < <(
    cd "$repo" && find . -type f \
      ! -path './.git/*' \
      ! -path './target/*' \
      ! -path './build/*' \
      ! -path './.gradle/*' \
      ! -path './.scannerwork/*' \
      ! -path './out/*' \
      -print | LC_ALL=C sort
  )
}

exp_check_write_scope() {
  local repo="$1"
  local before_file="$2"
  local after_file="$3"

  local joined_file="${EXP_TEST_PORT_GUARDS_DIR}/ported-protected-joined.tsv"
  local changes_file="${EXP_TEST_PORT_GUARDS_DIR}/ported-protected-change-set.tsv"
  local diff_file="${EXP_TEST_PORT_GUARDS_DIR}/disallowed-change.diff"

  exp_write_repo_manifest "$repo" "$after_file"

  : > "$joined_file"
  : > "$changes_file"
  : > "$diff_file"

  join -t $'\t' -a1 -a2 -e '__MISSING__' -o '0,1.2,2.2' \
    "$before_file" "$after_file" > "$joined_file" || true

  local bad=0
  local violations=0
  while IFS=$'\t' read -r rel before_hash after_hash; do
    [[ -n "$rel" ]] || continue

    local kind=""
    if [[ "$before_hash" == "__MISSING__" ]]; then
      kind="A"
    elif [[ "$after_hash" == "__MISSING__" ]]; then
      kind="D"
    elif [[ "$before_hash" != "$after_hash" ]]; then
      kind="M"
    else
      continue
    fi

    printf '%s\t%s\n' "$kind" "$rel" >> "$changes_file"

    if ! exp_is_allowed_test_path "$rel"; then
      printf '%s\t%s\n' "$kind" "$rel" >> "${EXP_TEST_PORT_SUMMARY_DIR}/last-write-scope-failure.txt"
      printf '%s\t%s\n' "$kind" "$rel" >> "$diff_file"
      violations=$((violations + 1))
      bad=1
    fi
  done < "$joined_file"

  TEST_PORT_WRITE_SCOPE_VIOLATION_COUNT="$violations"
  return "$bad"
}

exp_finalize_new_repo_immutability_guard() {
  local after_file="${EXP_TEST_PORT_GUARDS_DIR}/new-repo-after.sha256"
  NEW_REPO_AFTER_HASH="$(exp_tree_fingerprint "$ANDVARI_NEW_REPO")"
  printf '%s\n' "$NEW_REPO_AFTER_HASH" > "$after_file"
  [[ "$NEW_REPO_BEFORE_HASH" == "$NEW_REPO_AFTER_HASH" ]] || TEST_PORT_NEW_REPO_UNCHANGED=false
}

exp_run_test_port() {
  TEST_PORT_STATUS="skipped"
  TEST_PORT_REASON=""
  TEST_PORT_NEW_REPO_UNCHANGED=true
  TEST_PORT_ITERATIONS_USED=0
  TEST_PORT_ADAPTER_NONZERO=0
  TEST_PORT_WRITE_SCOPE_POLICY="tests-only"
  TEST_PORT_WRITE_SCOPE_VIOLATION_COUNT=0
  TEST_PORT_WRITE_SCOPE_FAILURE_PATHS_FILE=""
  TEST_PORT_WRITE_SCOPE_DIFF_FILE=""
  TEST_PORT_FAILURE_CLASS=""

  BASELINE_ORIGINAL_STATUS="skipped"
  BASELINE_GENERATED_STATUS="skipped"
  PORTED_ORIGINAL_TESTS_STATUS="skipped"
  PORTED_ORIGINAL_TESTS_EXIT_CODE=-1

  [[ "$TEST_PORT_MODE" == "on" ]] || return 0
  [[ -d "$ANDVARI_NEW_REPO" ]] || { TEST_PORT_STATUS="skipped"; TEST_PORT_REASON="missing-generated-repo"; return 0; }
  if [[ "${TEST_PORT_ADAPTER_PREREQS_OK:-true}" != true ]]; then
    TEST_PORT_STATUS="skipped"
    TEST_PORT_REASON="adapter-prereqs-failed"
    return 0
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    TEST_PORT_STATUS="skipped"
    TEST_PORT_REASON="missing-rsync"
    return 0
  fi

  local tp_dir="$EXP_WORKSPACE_TEST_PORT_DIR"
  mkdir -p "$tp_dir" "$EXP_TEST_PORT_LOG_DIR" "$EXP_TEST_PORT_SUMMARY_DIR" "$EXP_TEST_PORT_GUARDS_DIR"

  BASELINE_ORIGINAL_LOG_PATH="${EXP_TEST_PORT_LOG_DIR}/baseline-original-tests.log"
  BASELINE_GENERATED_LOG_PATH="${EXP_TEST_PORT_LOG_DIR}/baseline-generated-tests.log"
  PORTED_ORIGINAL_TESTS_LOG_PATH=""
  TEST_PORT_WRITE_SCOPE_FAILURE_PATHS_FILE="${EXP_TEST_PORT_SUMMARY_DIR}/last-write-scope-failure.txt"
  TEST_PORT_WRITE_SCOPE_DIFF_FILE="${EXP_TEST_PORT_GUARDS_DIR}/disallowed-change.diff"

  exp_copy_dir "$ORIGINAL_EFFECTIVE_PATH" "$tp_dir/original-baseline-repo"
  exp_copy_dir "$ANDVARI_NEW_REPO" "$tp_dir/generated-baseline-repo"
  exp_copy_dir "$ANDVARI_NEW_REPO" "$tp_dir/ported-tests-repo"

  NEW_REPO_BEFORE_HASH="$(exp_tree_fingerprint "$ANDVARI_NEW_REPO")"
  printf '%s\n' "$NEW_REPO_BEFORE_HASH" > "${EXP_TEST_PORT_GUARDS_DIR}/new-repo-before.sha256"

  set +e
  exp_run_tests "$tp_dir/original-baseline-repo" "$BASELINE_ORIGINAL_LOG_PATH"
  BASELINE_ORIGINAL_RC=$?
  exp_run_tests "$tp_dir/generated-baseline-repo" "$BASELINE_GENERATED_LOG_PATH"
  BASELINE_GENERATED_RC=$?
  set -e
  BASELINE_ORIGINAL_STATUS="$(exp_test_rc_status "$BASELINE_ORIGINAL_RC")"
  BASELINE_GENERATED_STATUS="$(exp_test_rc_status "$BASELINE_GENERATED_RC")"

  mkdir -p "$tp_dir/original-tests-snapshot"
  if ! rsync -a --prune-empty-dirs \
    --include='*/' \
    --include='src/test/***' \
    --include='src/*Test*/***' \
    --include='test/***' \
    --include='tests/***' \
    --exclude='*' \
    "$ORIGINAL_EFFECTIVE_PATH/" "$tp_dir/original-tests-snapshot/" >/dev/null 2>&1; then
    TEST_PORT_STATUS="skipped"
    TEST_PORT_REASON="test-snapshot-copy-failed"
    exp_finalize_new_repo_immutability_guard
    return 0
  fi

  if ! find "$tp_dir/original-tests-snapshot" -type f -print -quit | grep -q .; then
    TEST_PORT_STATUS="skipped"
    TEST_PORT_REASON="no-test-files-found"
    exp_finalize_new_repo_immutability_guard
    return 0
  fi

  find "$tp_dir/ported-tests-repo" -type d \
    \( -path '*/src/test' -o -path '*/test' -o -path '*/tests' -o -path '*/src/*Test*' \) \
    -prune -exec rm -rf {} + 2>/dev/null || true
  if ! rsync -a "$tp_dir/original-tests-snapshot/" "$tp_dir/ported-tests-repo/" >/dev/null 2>&1; then
    TEST_PORT_STATUS="failed"
    TEST_PORT_REASON="ported-test-copy-failed"
    exp_finalize_new_repo_immutability_guard
    return 0
  fi

  local ported_runner
  ported_runner="$(exp_detect_test_runner "$tp_dir/ported-tests-repo")"
  if [[ "$ported_runner" == "unknown" ]]; then
    TEST_PORT_STATUS="skipped"
    TEST_PORT_REASON="unsupported-test-runner"
    PORTED_ORIGINAL_TESTS_STATUS="skipped"
    PORTED_ORIGINAL_TESTS_EXIT_CODE=2
    exp_finalize_new_repo_immutability_guard
    return 0
  fi

  local guard_before="${EXP_TEST_PORT_GUARDS_DIR}/ported-protected-before.sha256"
  local guard_after="${EXP_TEST_PORT_GUARDS_DIR}/ported-protected-after.sha256"
  exp_write_repo_manifest "$tp_dir/ported-tests-repo" "$guard_before"

  local gate_summary_file="${EXP_TEST_PORT_SUMMARY_DIR}/last-test-failure.txt"
  : > "$gate_summary_file"
  : > "$TEST_PORT_WRITE_SCOPE_FAILURE_PATHS_FILE"
  : > "$TEST_PORT_WRITE_SCOPE_DIFF_FILE"

  TEST_PORT_STATUS="failed"
  TEST_PORT_REASON="max-iterations-reached"

  local i
  for ((i=0; i<=TEST_PORT_MAX_ITER; i++)); do
    if [[ $i -eq 0 ]]; then
      adapter_run_test_port_initial \
        "$ADAPTER" \
        "$tp_dir/ported-tests-repo" \
        "$DIAGRAM_PATH" \
        "$ORIGINAL_EFFECTIVE_PATH" \
        "$EVENTS_LOG" \
        "$CODEX_STDERR_LOG" \
        "$OUTPUT_LAST_MESSAGE" \
        || TEST_PORT_ADAPTER_NONZERO=$((TEST_PORT_ADAPTER_NONZERO + 1))
    else
      adapter_run_test_port_iteration \
        "$ADAPTER" \
        "$tp_dir/ported-tests-repo" \
        "$DIAGRAM_PATH" \
        "$ORIGINAL_EFFECTIVE_PATH" \
        "$gate_summary_file" \
        "$EVENTS_LOG" \
        "$CODEX_STDERR_LOG" \
        "$OUTPUT_LAST_MESSAGE" \
        "$i" \
        || TEST_PORT_ADAPTER_NONZERO=$((TEST_PORT_ADAPTER_NONZERO + 1))
    fi

    : > "$TEST_PORT_WRITE_SCOPE_FAILURE_PATHS_FILE"
    : > "$TEST_PORT_WRITE_SCOPE_DIFF_FILE"
    if ! exp_check_write_scope "$tp_dir/ported-tests-repo" "$guard_before" "$guard_after"; then
      TEST_PORT_STATUS="failed"
      TEST_PORT_REASON="write-scope-violation"
      TEST_PORT_FAILURE_CLASS="write-scope-violation"
      PORTED_ORIGINAL_TESTS_STATUS="fail"
      PORTED_ORIGINAL_TESTS_EXIT_CODE=1
      TEST_PORT_ITERATIONS_USED="$i"
      break
    fi

    local adapt_log="${EXP_TEST_PORT_LOG_DIR}/adapt-iter-${i}.log"
    PORTED_ORIGINAL_TESTS_LOG_PATH="$adapt_log"
    if exp_run_tests "$tp_dir/ported-tests-repo" "$adapt_log"; then
      PORTED_ORIGINAL_TESTS_EXIT_CODE=0
      PORTED_ORIGINAL_TESTS_STATUS="pass"
      TEST_PORT_STATUS="passed"
      TEST_PORT_REASON=""
      TEST_PORT_FAILURE_CLASS=""
      TEST_PORT_ITERATIONS_USED="$i"
      break
    fi

    local adapt_rc=$?
    PORTED_ORIGINAL_TESTS_EXIT_CODE="$adapt_rc"
    PORTED_ORIGINAL_TESTS_STATUS="$(exp_test_rc_status "$adapt_rc")"
    TEST_PORT_ITERATIONS_USED="$i"

    if [[ "$adapt_rc" -eq 2 ]]; then
      TEST_PORT_STATUS="skipped"
      TEST_PORT_REASON="unsupported-test-runner"
      break
    fi

    tail -n 200 "$adapt_log" > "$gate_summary_file" || true
    TEST_PORT_STATUS="failed"
    TEST_PORT_FAILURE_CLASS="$(exp_classify_test_failure_log "$adapt_log")"
    if [[ "$TEST_PORT_FAILURE_CLASS" == "behavioral-mismatch" ]]; then
      TEST_PORT_REASON="behavioral-difference-evidence"
      break
    fi
    TEST_PORT_REASON="tests-failed"
  done

  exp_finalize_new_repo_immutability_guard
}
