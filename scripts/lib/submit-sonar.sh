#!/usr/bin/env bash
# submit-sonar.sh - SonarQube submission module
# Handles analysis submission and task tracking

# Ensure dependencies are sourced
_SUBMIT_SH_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${_SUBMIT_SH_DIR}/common.sh"
source "${_SUBMIT_SH_DIR}/select-jdk.sh"
source "${_SUBMIT_SH_DIR}/coverage.sh"
source "${_SUBMIT_SH_DIR}/../strategies/maven.sh"
source "${_SUBMIT_SH_DIR}/../strategies/gradle.sh"
if ! declare -f is_android_project >/dev/null 2>&1; then
  source "${_SUBMIT_SH_DIR}/detect-build.sh"
fi

# ============================================================================
# SonarQube Health Check
# ============================================================================

# Check if SonarQube server is healthy
# Usage: sonar_health_check
# Returns: 0 if healthy, 1 otherwise
sonar_health_check() {
  require_env "SONAR_HOST_URL" "Set in .env file"
  
  local status_url="${SONAR_HOST_URL}/api/system/status"
  local response
  
  log_info "Checking SonarQube health: $status_url"
  
  response="$(curl -sf "$status_url" 2>/dev/null || echo "")"
  
  if [[ -z "$response" ]]; then
    log_error "Cannot reach SonarQube at $SONAR_HOST_URL"
    return 1
  fi
  
  local status
  status="$(echo "$response" | jq -r '.status // empty')"
  
  if [[ "$status" != "UP" ]]; then
    log_error "SonarQube is not ready. Status: $status"
    log_error "Response: $response"
    return 1
  fi
  
  log_success "SonarQube is healthy"
  return 0
}

# Wait for SonarQube to be ready
# Usage: sonar_wait_ready [max_attempts] [delay_seconds]
sonar_wait_ready() {
  local max_attempts="${1:-30}"
  local delay="${2:-5}"
  
  log_info "Waiting for SonarQube to be ready..."
  
  for ((i=1; i<=max_attempts; i++)); do
    if sonar_health_check; then
      return 0
    fi
    
    log_info "Attempt $i/$max_attempts - waiting ${delay}s..."
    sleep "$delay"
  done
  
  log_error "SonarQube did not become ready after $max_attempts attempts"
  return 1
}

# ============================================================================
# SonarQube Submission
# ============================================================================

# shellcheck disable=SC2034  # Submission metadata is consumed by pipeline.sh and service reporting.
# Global variable for task ID
SONAR_TASK_ID=""
SONAR_SCANNER_MODE=""
SONAR_SCANNER_JDK=""
SONAR_SCANNER_RUNTIME_SOURCE=""
SONAR_SCANNER_VERSION=""
SONAR_FALLBACK_CHAIN=""
SONAR_SUBMISSION_REASON=""
SONAR_SUBMISSION_MESSAGE=""

sonar_reset_submission_metadata() {
  SONAR_TASK_ID=""
  SONAR_SCANNER_MODE=""
  SONAR_SCANNER_JDK=""
  SONAR_SCANNER_RUNTIME_SOURCE=""
  SONAR_SCANNER_VERSION=""
  SONAR_FALLBACK_CHAIN=""
  SONAR_SUBMISSION_REASON=""
  SONAR_SUBMISSION_MESSAGE=""
}

sonar_normalize_java_version() {
  local version="${1:-}"

  [[ -n "$version" ]] || {
    echo ""
    return 0
  }

  if [[ "$version" =~ ^1\.([0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
  fi

  version="${version%%[^0-9]*}"
  echo "$version"
}

sonar_append_fallback_step() {
  local step="$1"
  [[ -n "$step" ]] || return 0

  if [[ -z "$SONAR_FALLBACK_CHAIN" ]]; then
    SONAR_FALLBACK_CHAIN="$step"
  else
    SONAR_FALLBACK_CHAIN="${SONAR_FALLBACK_CHAIN},${step}"
  fi
}

sonar_record_submission_info() {
  local key="$1"

  if declare -f state_set_scanner_info >/dev/null 2>&1; then
    state_set_scanner_info \
      "$key" \
      "$SONAR_SCANNER_MODE" \
      "$SONAR_SCANNER_JDK" \
      "$SONAR_SCANNER_RUNTIME_SOURCE" \
      "$SONAR_SCANNER_VERSION" \
      "$SONAR_FALLBACK_CHAIN"
  fi
}

sonar_get_build_jdk_home() {
  local build_jdk="${1:-}"

  if [[ -z "$build_jdk" ]]; then
    echo ""
    return 0
  fi

  get_jdk_home "$build_jdk" 2>/dev/null || true
}

sonar_pick_dedicated_scanner_jdk() {
  local chosen=""
  chosen="$(get_best_jdk 21 25 17 11 8 2>/dev/null || true)"
  echo "$chosen"
}

sonar_select_native_runtime() {
  local build_tool="$1"
  local build_jdk="${2:-}"
  local override_jdk="${LIDSKJALV_SCANNER_JDK_HINT:-}"
  local normalized_build_jdk=""

  if [[ -n "$override_jdk" ]] && is_jdk_available "$override_jdk"; then
    echo "${override_jdk}|override"
    return 0
  fi

  normalized_build_jdk="$(sonar_normalize_java_version "$build_jdk")"
  case "$build_tool" in
    maven)
      if [[ -n "$normalized_build_jdk" ]] && (( normalized_build_jdk >= 17 )); then
        echo "${build_jdk}|build_jdk"
      else
        echo "$(sonar_pick_dedicated_scanner_jdk)|dedicated_jdk"
      fi
      ;;
    gradle)
      echo "${build_jdk}|build_jdk"
      ;;
    *)
      echo "${build_jdk}|build_jdk"
      ;;
  esac
}

sonar_select_cli_runtime() {
  local build_jdk="${1:-}"
  local override_jdk="${LIDSKJALV_SCANNER_JDK_HINT:-}"
  local normalized_build_jdk=""

  if [[ -n "$override_jdk" ]] && is_jdk_available "$override_jdk"; then
    echo "${override_jdk}|override"
    return 0
  fi

  normalized_build_jdk="$(sonar_normalize_java_version "$build_jdk")"
  if [[ -n "$normalized_build_jdk" ]] && (( normalized_build_jdk >= 17 )); then
    echo "${build_jdk}|build_jdk"
  else
    echo "$(sonar_pick_dedicated_scanner_jdk)|dedicated_jdk"
  fi
}

sonar_paths_to_csv() {
  local base_dir="$1"
  local csv=""
  local path=""
  local rel_path=""

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    rel_path="${path#"$base_dir"/}"
    if [[ "$rel_path" == "$path" ]]; then
      rel_path="$path"
    fi
    if [[ -z "$csv" ]]; then
      csv="$rel_path"
    else
      csv="${csv},${rel_path}"
    fi
  done

  echo "$csv"
}

sonar_collect_source_dirs() {
  local build_dir="$1"

  find "$build_dir" -type d \
    \( -path "*/src/main/java" -o -path "*/src/main/kotlin" -o -path "*/src/main/groovy" -o -path "*/src/main/scala" -o -path "*/src/main/resources" \
       -o -path "*/src/*/java" -o -path "*/src/*/kotlin" -o -path "*/src/*/groovy" -o -path "*/src/*/scala" -o -path "*/src/*/resources" \) \
    ! -path "*/src/test/*" ! -path "*/src/androidTest/*" ! -path "*/src/integrationTest/*" ! -path "*/src/functionalTest/*" \
    ! -path "*/src/testFixtures/*" \
    -print 2>/dev/null | sort -u
}

sonar_collect_test_dirs() {
  local build_dir="$1"

  find "$build_dir" -type d \
    \( -path "*/src/test/java" -o -path "*/src/test/kotlin" -o -path "*/src/test/groovy" -o -path "*/src/test/scala" -o -path "*/src/test/resources" \
       -o -path "*/src/androidTest/java" -o -path "*/src/androidTest/kotlin" -o -path "*/src/androidTest/groovy" -o -path "*/src/androidTest/scala" \
       -o -path "*/src/integrationTest/java" -o -path "*/src/integrationTest/kotlin" -o -path "*/src/integrationTest/groovy" -o -path "*/src/integrationTest/scala" \
       -o -path "*/src/functionalTest/java" -o -path "*/src/functionalTest/kotlin" -o -path "*/src/functionalTest/groovy" -o -path "*/src/functionalTest/scala" \
       -o -path "*/src/testFixtures/java" -o -path "*/src/testFixtures/kotlin" -o -path "*/src/testFixtures/groovy" -o -path "*/src/testFixtures/scala" \) \
    -print 2>/dev/null | sort -u
}

sonar_collect_binary_dirs() {
  local build_dir="$1"

  find "$build_dir" -type d \
    \( -path "*/target/classes" -o -path "*/build/classes/*/main" -o -path "*/build/classes/main" \
       -o -path "*/build/intermediates/javac/*/classes" -o -path "*/build/tmp/kotlin-classes/*" \) \
    -print 2>/dev/null | sort -u
}

sonar_collect_test_binary_dirs() {
  local build_dir="$1"

  find "$build_dir" -type d \
    \( -path "*/target/test-classes" -o -path "*/build/classes/*/test" -o -path "*/build/classes/test" \
       -o -path "*/target/it-classes" -o -path "*/target/integration-test-classes" \
       -o -path "*/build/classes/*/integrationTest" -o -path "*/build/classes/*/functionalTest" \
       -o -path "*/build/classes/*/testFixtures" \
       -o -path "*/build/tmp/kotlin-classes/test" -o -path "*/build/tmp/kotlin-classes/*Test" \
       -o -path "*/build/tmp/kotlin-classes/integrationTest" -o -path "*/build/tmp/kotlin-classes/functionalTest" \
       -o -path "*/build/tmp/kotlin-classes/testFixtures" \) \
    -print 2>/dev/null | sort -u
}

sonar_collect_library_paths() {
  local build_dir="$1"

  find "$build_dir" -type f \
    \( -path "*/target/dependency/*.jar" -o -path "*/build/libs/*.jar" -o -path "*/libs/*.jar" -o -path "*/lib/*.jar" \) \
    -print 2>/dev/null | sort -u
}

sonar_collect_fallback_source_dirs() {
  local build_dir="$1"

  find "$build_dir" \
    -type d \( -name .git -o -name target -o -name build -o -name .gradle -o -name out -o -name .scannerwork \) -prune -o \
    -type f \( -name "*.java" -o -name "*.kt" -o -name "*.groovy" -o -name "*.scala" \) -print 2>/dev/null | \
    sed 's#/[^/]*$##' | sort -u
}

sonar_cli_submit() {
  local build_dir="$1"
  local project_key="$2"
  local log_file="$3"
  local coverage_report_paths="${4:-}"
  local java_jdk_home="${5:-}"

  if ! command -v sonar-scanner >/dev/null 2>&1; then
    log_error "sonar-scanner CLI not available for fallback"
    return 127
  fi

  local source_dirs=""
  local test_dirs=""
  local binary_dirs=""
  local test_binary_dirs=""
  local library_paths=""

  source_dirs="$(sonar_collect_source_dirs "$build_dir" | sonar_paths_to_csv "$build_dir")"
  test_dirs="$(sonar_collect_test_dirs "$build_dir" | sonar_paths_to_csv "$build_dir")"
  binary_dirs="$(sonar_collect_binary_dirs "$build_dir" | sonar_paths_to_csv "$build_dir")"
  test_binary_dirs="$(sonar_collect_test_binary_dirs "$build_dir" | sonar_paths_to_csv "$build_dir")"
  library_paths="$(sonar_collect_library_paths "$build_dir" | sonar_paths_to_csv "$build_dir")"

  if [[ -z "$source_dirs" ]]; then
    source_dirs="$(sonar_collect_fallback_source_dirs "$build_dir" | sonar_paths_to_csv "$build_dir")"
  fi
  if [[ -z "$source_dirs" ]]; then
    source_dirs="."
    log_warn "No source directories auto-detected for CLI fallback; analyzing project base directory"
  fi

  local -a sonar_cmd=(
    sonar-scanner
    -Dsonar.host.url="$SONAR_HOST_URL"
    -Dsonar.token="$SONAR_TOKEN"
    -Dsonar.projectKey="$project_key"
    -Dsonar.organization="$SONAR_ORGANIZATION"
    -Dsonar.projectBaseDir="$build_dir"
    -Dsonar.sources="$source_dirs"
  )

  if [[ -n "$test_dirs" ]]; then
    sonar_cmd+=(-Dsonar.tests="$test_dirs")
  fi
  if [[ -n "$binary_dirs" ]]; then
    sonar_cmd+=(-Dsonar.java.binaries="$binary_dirs")
  fi
  if [[ -n "$test_binary_dirs" ]]; then
    sonar_cmd+=(-Dsonar.java.test.binaries="$test_binary_dirs")
  fi
  if [[ -n "$library_paths" ]]; then
    sonar_cmd+=(-Dsonar.java.libraries="$library_paths")
  fi
  if [[ -n "$coverage_report_paths" ]]; then
    sonar_cmd+=(-Dsonar.coverage.jacoco.xmlReportPaths="$coverage_report_paths")
  fi
  if [[ -n "$java_jdk_home" ]]; then
    sonar_cmd+=(-Dsonar.java.jdkHome="$java_jdk_home")
  fi
  if [[ "${SONAR_SCM_EXCLUSIONS_DISABLED:-}" == "true" ]]; then
    sonar_cmd+=(-Dsonar.scm.exclusions.disabled=true)
  fi
  if [[ "${SONAR_SCM_DISABLED:-}" == "true" ]]; then
    sonar_cmd+=(-Dsonar.scm.disabled=true)
  fi

  run_logged "$log_file" "${sonar_cmd[@]}"
}

# Remove stale report-task files so a previous analysis cannot be mistaken for current success.
sonar_cleanup_report_files() {
  local build_dir="$1"

  find "$build_dir" -type f \
    \( -path "*/.scannerwork/report-task.txt" -o -path "*/target/sonar/report-task.txt" -o -path "*/build/sonar/report-task.txt" \) \
    -delete 2>/dev/null || true
}

# Extract compute engine task ID from Sonar report-task artifacts.
sonar_extract_task_id_from_report() {
  local build_dir="$1"
  local report_file=""

  report_file="$(find "$build_dir" -type f \
    \( -path "*/.scannerwork/report-task.txt" -o -path "*/target/sonar/report-task.txt" -o -path "*/build/sonar/report-task.txt" \) \
    -print 2>/dev/null | head -1 || true)"

  if [[ -z "$report_file" ]]; then
    echo ""
    return 0
  fi

  sed -n 's/^ceTaskId=\(.*\)$/\1/p' "$report_file" | tail -1 || true
}

# Extract compute engine task ID from scanner logs.
sonar_extract_task_id_from_log() {
  local log_file="$1"
  sed -n 's/.*api\/ce\/task?id=\([A-Za-z0-9_-]*\).*/\1/p' "$log_file" 2>/dev/null | tail -1 || true
}

sonar_repo_has_main_sources() {
  local build_dir="$1"
  find "$build_dir" -type f \
    \( -name "*.java" -o -name "*.kt" -o -name "*.groovy" -o -name "*.scala" \) \
    -path "*/src/main/*" -print -quit 2>/dev/null | grep -q .
}

sonar_validate_main_source_indexing() {
  local build_dir="$1"
  local log_file="$2"

  [[ -f "$log_file" ]] || return 0
  sonar_repo_has_main_sources "$build_dir" || return 0

  if grep -Fq 'No "Main" source files to scan.' "$log_file"; then
    log_error "SonarScanner reported no main source files, but src/main contains source files."
    log_error "Likely build-model mismatch (for example Maven <packaging>pom</packaging> without modules)."
    log_error "See log: $log_file"
    return 1
  fi

  return 0
}

sonar_set_project_public_visibility() {
  local key="$1"
  [[ "$SONAR_HOST_URL" == *"sonarcloud.io"* ]] || return 0
  [[ -n "${SONAR_ORGANIZATION:-}" ]] || return 0

  if ! curl -sf -u "${SONAR_TOKEN}:" \
    -X POST "${SONAR_HOST_URL}/api/projects/update_visibility" \
    --data-urlencode "project=${key}" \
    --data-urlencode "organization=${SONAR_ORGANIZATION}" \
    --data-urlencode "visibility=public" \
    >/dev/null 2>&1; then
    log_warn "Could not set SonarCloud project visibility to public for ${key}"
    return 1
  fi

  log_info "Ensured SonarCloud project visibility is public: ${key}"
  return 0
}

sonar_record_coverage_info() {
  local key="$1"

  if declare -f state_set_coverage_info >/dev/null 2>&1; then
    state_set_coverage_info \
      "$key" \
      "$COVERAGE_STATUS" \
      "$COVERAGE_REASON" \
      "$COVERAGE_JDK" \
      "$COVERAGE_MODE" \
      "$COVERAGE_COMMAND" \
      "$COVERAGE_REPORT_KIND" \
      "$COVERAGE_JACOCO_VERSION" \
      "$COVERAGE_JAVA_TARGET" \
      "$COVERAGE_REPORT_PATHS_CSV" \
      "$COVERAGE_ATTEMPTED" \
      "$COVERAGE_TESTS_FORCED" \
      "$COVERAGE_REPORTS_FOUND"
  fi
}

sonar_cleanup_support_dir() {
  local support_dir="${1:-}"
  [[ -n "$support_dir" ]] || return 0
  [[ -d "$support_dir" ]] || return 0
  rm -rf "$support_dir"
}

sonar_classify_native_failure() {
  local build_tool="$1"
  local log_file="$2"

  case "$build_tool" in
    maven)
      maven_classify_sonar_failure "$log_file"
      ;;
    gradle)
      gradle_classify_sonar_failure "$log_file"
      ;;
    *)
      echo "native_scanner_incompatible"
      ;;
  esac
}

sonar_should_cli_fallback() {
  local build_tool="$1"
  local reason="$2"

  case "$reason" in
    scanner_runtime_mismatch|native_scanner_incompatible|native_scanner_server_download_failure)
      return 0
      ;;
  esac

  return 1
}

sonar_prepare_coverage() {
  local key="$1"
  local build_dir="$2"
  local build_tool="$3"
  local coverage_log="$4"
  local support_dir="$5"
  local repo_dir="${PIPELINE_REPO_DIR:-$build_dir}"
  local build_jdk="${PIPELINE_BUILD_JDK:-}"
  local java_version_hint="${PIPELINE_JAVA_VERSION_HINT:-}"
  local effective_build_dir="$build_dir"

  coverage_reset_metadata
  coverage_mark_attempted
  COVERAGE_JAVA_TARGET="$(coverage_detect_java_target "$build_dir" "$java_version_hint" "$build_jdk")"
  COVERAGE_JACOCO_VERSION="$(coverage_select_jacoco_version "$COVERAGE_JAVA_TARGET")"
  COVERAGE_JDK="$build_jdk"
  # shellcheck disable=SC2034  # Support dir path is recorded in shared coverage metadata; the directory itself is ephemeral.
  COVERAGE_SUPPORT_DIR="$support_dir"

  case "$build_tool" in
    maven)
      coverage_mark_tests_forced
      if ! maven_prepare_coverage "$repo_dir" "$build_dir" "$COVERAGE_JACOCO_VERSION" "$coverage_log" "$support_dir"; then
        coverage_mark_fallback "${MAVEN_COVERAGE_REASON:-maven_coverage_prepare_failed}"
        sonar_record_coverage_info "$key"
        return 1
      fi
      effective_build_dir="${MAVEN_COVERAGE_BUILD_DIR:-$build_dir}"
      ;;
    gradle)
      if is_android_project "$build_dir"; then
        coverage_mark_fallback "android_no_sdk"
        sonar_record_coverage_info "$key"
        return 1
      fi
      if ! gradle_prepare_coverage "$build_dir" "$COVERAGE_JACOCO_VERSION" "$coverage_log" "$support_dir"; then
        coverage_mark_fallback "${GRADLE_COVERAGE_REASON:-gradle_coverage_prepare_failed}"
        sonar_record_coverage_info "$key"
        return 1
      fi
      ;;
    *)
      coverage_mark_fallback "coverage_unsupported_build_tool"
      sonar_record_coverage_info "$key"
      return 1
      ;;
  esac

  local -a reports=()
  local -a selected_reports=()
  local report_path=""
  local selected_reports_file=""
  while IFS= read -r report_path; do
    [[ -n "$report_path" ]] || continue
    reports+=("$report_path")
  done < <(coverage_find_xml_reports "$effective_build_dir")
  if [[ ${#reports[@]} -eq 0 ]]; then
    local missing_reason=""
    case "$build_tool" in
      maven)
        missing_reason="$(maven_classify_coverage_missing_reports "$coverage_log")"
        ;;
      *)
        missing_reason="$(coverage_classify_missing_reports "$coverage_log")"
        ;;
    esac
    coverage_mark_fallback "${missing_reason:-coverage_report_missing}"
    sonar_record_coverage_info "$key"
    return 1
  fi

  selected_reports_file="${support_dir}/selected-coverage-reports.txt"
  : > "$selected_reports_file"
  coverage_select_preferred_reports "${reports[@]}" > "$selected_reports_file"
  while IFS= read -r report_path; do
    [[ -n "$report_path" ]] || continue
    selected_reports+=("$report_path")
  done < "$selected_reports_file"
  if [[ ${#selected_reports[@]} -eq 0 ]]; then
    coverage_mark_fallback "coverage_report_selection_failed"
    sonar_record_coverage_info "$key"
    return 1
  fi

  COVERAGE_REPORT_PATHS_CSV="$(coverage_format_report_paths "$effective_build_dir" "${selected_reports[@]}")"
  COVERAGE_REPORTS_FOUND="${#selected_reports[@]}"
  coverage_mark_available "$COVERAGE_JACOCO_VERSION" "$COVERAGE_JAVA_TARGET" "$COVERAGE_JDK" "$COVERAGE_REPORT_PATHS_CSV" "$COVERAGE_REPORTS_FOUND"
  COVERAGE_BUILD_DIR="$effective_build_dir"
  sonar_record_coverage_info "$key"
  return 0
}

# Submit a project to SonarQube for analysis
# Usage: submit_to_sonar <project_key> <build_dir> <build_tool>
# Returns: 0 on success, 1 on failure
# Sets: SONAR_TASK_ID
submit_to_sonar() {
  local key="$1"
  local build_dir="$2"
  local build_tool="$3"

  # shellcheck disable=SC2153  # LOG_DIR comes from common.sh at runtime.
  local log_dir="${LOG_DIR}/${key}"
  local log_file="${log_dir}/sonar.log"
  local native_log="${log_dir}/sonar-native.log"
  local cli_log="${log_dir}/sonar-cli.log"
  local coverage_log="${log_dir}/coverage.log"
  local support_dir=""
  local analysis_dir="$build_dir"
  local coverage_ready="false"
  local build_jdk="${PIPELINE_BUILD_JDK:-}"
  local build_jdk_home=""
  local submitter_preference="${LIDSKJALV_SUBMITTER_PREFERENCE:-native}"
  if [[ "$build_tool" == "gradle" ]] && is_android_project "$build_dir"; then
    submitter_preference="cli"
    log_info "Android project: using CLI scanner (native Gradle sonar requires Android SDK)"
  fi
  local native_runtime_selection=""
  local native_scanner_jdk=""
  local native_runtime_source=""
  local cli_runtime_selection=""
  local cli_scanner_jdk=""
  local cli_runtime_source=""
  local native_exit_code=0
  local cli_exit_code=0
  local exit_code=0
  local final_log_source=""
  local native_failure_reason=""
  local gradle_version_info=""
  local gradle_major_version=""
  local selected_gradle_plugin_version=""
  ensure_dir "$log_dir"

  require_env "SONAR_HOST_URL" "Set in .env file"
  require_env "SONAR_TOKEN" "Generate at sonarcloud.io → My Account → Security"
  require_env "SONAR_ORGANIZATION" "Your SonarCloud organization key"

  sonar_reset_submission_metadata
  build_jdk_home="$(sonar_get_build_jdk_home "$build_jdk")"

  log_info "Submitting to SonarQube: $key"

  # Verify SonarQube is healthy
  if ! sonar_health_check; then
    SONAR_SUBMISSION_REASON="sonar_unavailable"
    SONAR_SUBMISSION_MESSAGE="SonarQube health check failed"
    log_error "SonarQube is not available, skipping submission"
    sonar_record_submission_info "$key"
    return 1
  fi

  ensure_dir "$WORK_DIR"
  support_dir="$(mktemp -d "${WORK_DIR%/}/sonar-support-${key}.XXXXXX")"

  if sonar_prepare_coverage "$key" "$build_dir" "$build_tool" "$coverage_log" "$support_dir"; then
    coverage_ready="true"
    analysis_dir="${COVERAGE_BUILD_DIR:-$build_dir}"
    log_info "Prepared JaCoCo coverage using JaCoCo ${COVERAGE_JACOCO_VERSION}${COVERAGE_JAVA_TARGET:+ for Java ${COVERAGE_JAVA_TARGET}}"
  else
    log_warn "Proceeding without coverage for ${key}: ${COVERAGE_REASON:-coverage preparation failed}"
    analysis_dir="$build_dir"
  fi

  if [[ "$build_tool" == "gradle" ]]; then
    gradle_version_info="$(gradle_detect_version_info "$analysis_dir")"
    gradle_major_version="${gradle_version_info#*|}"
    selected_gradle_plugin_version="$(gradle_select_sonar_plugin_version "$gradle_major_version")"
  fi

  if [[ "$submitter_preference" != "cli" ]]; then
    native_runtime_selection="$(sonar_select_native_runtime "$build_tool" "$build_jdk")"
    native_scanner_jdk="${native_runtime_selection%%|*}"
    native_runtime_source="${native_runtime_selection#*|}"
    if [[ -n "$native_scanner_jdk" ]]; then
      if ! select_jdk "$native_scanner_jdk"; then
        log_warn "Could not activate native scanner JDK ${native_scanner_jdk}; continuing with current runtime"
        native_runtime_source="current_runtime"
        native_scanner_jdk="${build_jdk:-}"
      fi
    fi

    sonar_cleanup_report_files "$analysis_dir"
    sonar_append_fallback_step "native_${build_tool}"

    case "$build_tool" in
      maven)
        maven_sonar "$analysis_dir" "$key" "$native_log" "$COVERAGE_REPORT_PATHS_CSV" "$build_jdk_home" || native_exit_code=$?
        ;;
      gradle)
        gradle_sonar "$analysis_dir" "$key" "$native_log" "$COVERAGE_REPORT_PATHS_CSV" "$support_dir" "$build_jdk_home" || native_exit_code=$?
        ;;
      *)
        SONAR_SUBMISSION_REASON="native_scanner_incompatible"
        SONAR_SUBMISSION_MESSAGE="Unsupported build tool for SonarQube: $build_tool"
        log_error "$SONAR_SUBMISSION_MESSAGE"
        sonar_record_submission_info "$key"
        sonar_cleanup_support_dir "$support_dir"
        return 1
        ;;
    esac

    if [[ $native_exit_code -eq 0 ]]; then
      exit_code=0
      final_log_source="$native_log"
      case "$build_tool" in
        maven)
          SONAR_SCANNER_MODE="native_maven"
          SONAR_SCANNER_VERSION="$MAVEN_SONAR_PLUGIN_VERSION"
          ;;
        gradle)
          SONAR_SCANNER_MODE="native_gradle"
          if gradle_has_sonarqube_plugin "$analysis_dir"; then
            SONAR_SCANNER_VERSION="project_plugin"
          else
            SONAR_SCANNER_VERSION="$selected_gradle_plugin_version"
          fi
          ;;
      esac
      SONAR_SCANNER_JDK="${native_scanner_jdk:-$build_jdk}"
      SONAR_SCANNER_RUNTIME_SOURCE="$native_runtime_source"
    else
      native_failure_reason="$(sonar_classify_native_failure "$build_tool" "$native_log")"
      log_warn "Native ${build_tool} Sonar submission failed for ${key}: ${native_failure_reason}"
      if sonar_should_cli_fallback "$build_tool" "$native_failure_reason"; then
        submitter_preference="cli"
      else
        SONAR_SUBMISSION_REASON="$native_failure_reason"
        SONAR_SUBMISSION_MESSAGE="Native ${build_tool} Sonar submission failed"
        exit_code=$native_exit_code
        final_log_source="$native_log"
      fi
    fi
  fi

  if [[ "$submitter_preference" == "cli" && $exit_code -eq 0 && -z "$SONAR_SCANNER_MODE" ]]; then
    cli_runtime_selection="$(sonar_select_cli_runtime "$build_jdk")"
    cli_scanner_jdk="${cli_runtime_selection%%|*}"
    cli_runtime_source="${cli_runtime_selection#*|}"
    if [[ -n "$cli_scanner_jdk" ]]; then
      if ! select_jdk "$cli_scanner_jdk"; then
        log_warn "Could not activate CLI scanner JDK ${cli_scanner_jdk}; continuing with current runtime"
        cli_runtime_source="current_runtime"
        cli_scanner_jdk="${build_jdk:-}"
      fi
    fi

    sonar_cleanup_report_files "$analysis_dir"
    sonar_append_fallback_step "cli_fallback"
    sonar_cli_submit "$analysis_dir" "$key" "$cli_log" "$COVERAGE_REPORT_PATHS_CSV" "$build_jdk_home" || cli_exit_code=$?
    if [[ $cli_exit_code -eq 0 ]]; then
      exit_code=0
      final_log_source="$cli_log"
      SONAR_SCANNER_MODE="cli_fallback"
      SONAR_SCANNER_JDK="${cli_scanner_jdk:-$build_jdk}"
      SONAR_SCANNER_RUNTIME_SOURCE="$cli_runtime_source"
      SONAR_SCANNER_VERSION="sonar-scanner"
    else
      exit_code=$cli_exit_code
      final_log_source="$cli_log"
      SONAR_SUBMISSION_REASON="cli_fallback_failed"
      if [[ $cli_exit_code -eq 127 ]]; then
        SONAR_SUBMISSION_MESSAGE="sonar-scanner CLI is not available for fallback"
      else
        SONAR_SUBMISSION_MESSAGE="sonar-scanner CLI fallback failed"
      fi
    fi
  fi

  if [[ -n "$final_log_source" && -f "$final_log_source" ]]; then
    cp "$final_log_source" "$log_file"
    if [[ -f "$native_log" && "$final_log_source" != "$native_log" ]]; then
      {
        printf '\n\n===== Native Submission Log =====\n\n'
        cat "$native_log"
      } >> "$log_file"
    fi
  fi

  if [[ $exit_code -ne 0 ]]; then
    log_error "SonarQube analysis failed for $key"
    sonar_record_submission_info "$key"
    sonar_cleanup_support_dir "$support_dir"
    return 1
  fi

  if ! sonar_validate_main_source_indexing "$analysis_dir" "$log_file"; then
    SONAR_SUBMISSION_REASON="native_scanner_incompatible"
    SONAR_SUBMISSION_MESSAGE="SonarScanner reported no main sources despite src/main sources existing"
    sonar_record_submission_info "$key"
    sonar_cleanup_support_dir "$support_dir"
    return 1
  fi

  if [[ "$coverage_ready" == "true" ]]; then
    log_info "Submitted SonarQube analysis with coverage reports: ${COVERAGE_REPORT_PATHS_CSV}"
  fi

  # Extract task ID; without it we cannot verify a real SonarQube submission happened.
  SONAR_TASK_ID="$(sonar_extract_task_id_from_report "$analysis_dir")"
  if [[ -z "$SONAR_TASK_ID" ]]; then
    SONAR_TASK_ID="$(sonar_extract_task_id_from_log "$log_file")"
  fi

  if [[ -z "$SONAR_TASK_ID" ]]; then
    # shellcheck disable=SC2034  # Reported back through pipeline.sh after submission failure.
    SONAR_SUBMISSION_REASON="sonar_submission_missing_task_id"
    SONAR_SUBMISSION_MESSAGE="SonarQube command exited but produced no task ID"
    log_error "SonarQube command exited but produced no task ID for $key"
    log_error "Likely no analysis was submitted (for example, a custom wrapper ignored the sonar task)"
    log_error "See log: $log_file"
    sonar_record_submission_info "$key"
    sonar_cleanup_support_dir "$support_dir"
    return 1
  fi

  log_success "Analysis submitted. Task ID: $SONAR_TASK_ID"
  sonar_record_submission_info "$key"
  sonar_cleanup_support_dir "$support_dir"

  return 0
}

# ============================================================================
# Task Polling (Optional)
# ============================================================================

# Get the status of a SonarQube compute engine task
# Usage: sonar_get_task_status <task_id>
# Returns: task status (PENDING, IN_PROGRESS, SUCCESS, FAILED, CANCELED)
sonar_get_task_status() {
  local task_id="$1"
  
  require_env "SONAR_HOST_URL"
  require_env "SONAR_TOKEN"
  
  local response
  response="$(curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/ce/task?id=${task_id}" 2>/dev/null || echo "")"
  
  if [[ -z "$response" ]]; then
    echo "UNKNOWN"
    return 1
  fi
  
  echo "$response" | jq -r '.task.status // "UNKNOWN"'
}

# Wait for a SonarQube task to complete
# Usage: sonar_wait_task <task_id> [max_attempts] [delay_seconds]
# Returns: 0 if SUCCESS, 1 otherwise
sonar_wait_task() {
  local task_id="$1"
  local max_attempts="${2:-60}"
  local delay="${3:-5}"
  
  log_info "Waiting for task $task_id to complete..."
  
  for ((i=1; i<=max_attempts; i++)); do
    local status
    status="$(sonar_get_task_status "$task_id")"
    
    case "$status" in
      SUCCESS)
        log_success "Task completed successfully"
        return 0
        ;;
      FAILED|CANCELED)
        log_error "Task $status"
        return 1
        ;;
      PENDING|IN_PROGRESS)
        log_info "Task status: $status (attempt $i/$max_attempts)"
        sleep "$delay"
        ;;
      *)
        log_warn "Unknown task status: $status"
        sleep "$delay"
        ;;
    esac
  done
  
  log_warn "Task did not complete within timeout"
  return 1
}

# ============================================================================
# Project Management
# ============================================================================

# Check if a project exists in SonarQube
# Usage: sonar_project_exists <project_key>
# Returns: 0 if exists, 1 if not
sonar_project_exists() {
  local key="$1"
  
  require_env "SONAR_HOST_URL"
  require_env "SONAR_TOKEN"
  
  local response
  response="$(curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/projects/search?projects=${key}" 2>/dev/null || echo "")"
  
  if [[ -z "$response" ]]; then
    return 1
  fi
  
  local count
  count="$(echo "$response" | jq '.paging.total // 0')"
  
  [[ "$count" -gt 0 ]]
}

# Create a project in SonarQube (if it doesn't exist)
# Usage: sonar_create_project <project_key> <project_name>
sonar_create_project() {
  local key="$1"
  local name="$2"
  
  require_env "SONAR_HOST_URL"
  require_env "SONAR_TOKEN"
  if [[ "$SONAR_HOST_URL" == *"sonarcloud.io"* ]]; then
    require_env "SONAR_ORGANIZATION" "Required for SonarCloud project creation"
  fi
  
  # Check if already exists
  if sonar_project_exists "$key"; then
    log_info "Project $key already exists in SonarQube"
    sonar_set_project_public_visibility "$key" || true
    return 0
  fi
  
  log_info "Creating SonarQube project: $key ($name)"

  local -a create_args=(
    --data-urlencode "project=${key}"
    --data-urlencode "name=${name}"
  )
  if [[ -n "${SONAR_ORGANIZATION:-}" ]]; then
    create_args+=(--data-urlencode "organization=${SONAR_ORGANIZATION}")
  fi
  if [[ "$SONAR_HOST_URL" == *"sonarcloud.io"* ]]; then
    create_args+=(--data-urlencode "visibility=public")
  fi

  curl -sf -u "${SONAR_TOKEN}:" \
    -X POST "${SONAR_HOST_URL}/api/projects/create" \
    "${create_args[@]}" \
    >/dev/null 2>&1 || true

  sonar_set_project_public_visibility "$key" || true
  
  return 0
}

# Delete a project from SonarQube
# Usage: sonar_delete_project <project_key>
sonar_delete_project() {
  local key="$1"
  
  require_env "SONAR_HOST_URL"
  require_env "SONAR_TOKEN"
  
  log_warn "Deleting SonarQube project: $key"
  
  curl -sf -u "${SONAR_TOKEN}:" \
    -X POST "${SONAR_HOST_URL}/api/projects/delete" \
    --data-urlencode "project=${key}" \
    >/dev/null 2>&1 || true
}

# ============================================================================
# Results Retrieval
# ============================================================================

# Get project analysis status
# Usage: sonar_get_project_status <project_key>
sonar_get_project_status() {
  local key="$1"
  
  require_env "SONAR_HOST_URL"
  require_env "SONAR_TOKEN"
  
  curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/qualitygates/project_status?projectKey=${key}" 2>/dev/null || echo "{}"
}

# Get project measures
# Usage: sonar_get_measures <project_key> [metrics]
sonar_get_measures() {
  local key="$1"
  local metrics="${2:-bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density}"
  
  require_env "SONAR_HOST_URL"
  require_env "SONAR_TOKEN"
  
  curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/measures/component?component=${key}&metricKeys=${metrics}" 2>/dev/null || echo "{}"
}
