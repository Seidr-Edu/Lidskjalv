#!/usr/bin/env bash
# submit-sonar.sh - SonarQube submission module
# Handles analysis submission and task tracking

# Ensure dependencies are sourced
_SUBMIT_SH_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${_SUBMIT_SH_DIR}/common.sh"
source "${_SUBMIT_SH_DIR}/../strategies/maven.sh"
source "${_SUBMIT_SH_DIR}/../strategies/gradle.sh"

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

# Global variable for task ID
SONAR_TASK_ID=""

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

# Submit a project to SonarQube for analysis
# Usage: submit_to_sonar <project_key> <build_dir> <build_tool>
# Returns: 0 on success, 1 on failure
# Sets: SONAR_TASK_ID
submit_to_sonar() {
  local key="$1"
  local build_dir="$2"
  local build_tool="$3"
  
  local log_dir="${LOG_DIR}/${key}"
  local log_file="${log_dir}/sonar.log"
  ensure_dir "$log_dir"
  
  require_env "SONAR_HOST_URL" "Set in .env file"
  require_env "SONAR_TOKEN" "Generate at sonarcloud.io → My Account → Security"
  require_env "SONAR_ORGANIZATION" "Your SonarCloud organization key"
  
  SONAR_TASK_ID=""
  
  log_info "Submitting to SonarQube: $key"
  
  # Verify SonarQube is healthy
  if ! sonar_health_check; then
    log_error "SonarQube is not available, skipping submission"
    return 1
  fi

  # Ensure task ID we extract belongs to this run, not a previous submission.
  sonar_cleanup_report_files "$build_dir"
  
  # Run analysis based on build tool
  local exit_code=0
  case "$build_tool" in
    maven)
      maven_sonar "$build_dir" "$key" "$log_file" || exit_code=$?
      ;;
    gradle)
      gradle_sonar "$build_dir" "$key" "$log_file" || exit_code=$?
      ;;
    *)
      log_error "Unsupported build tool for SonarQube: $build_tool"
      return 1
      ;;
  esac
  
  if [[ $exit_code -ne 0 ]]; then
    log_error "SonarQube analysis failed for $key"
    return 1
  fi

  if ! sonar_validate_main_source_indexing "$build_dir" "$log_file"; then
    return 1
  fi
  
  # Record analysis method if available
  if [[ -f "${build_dir}/.sonar-analysis-method" ]]; then
    local method
    method="$(cat "${build_dir}/.sonar-analysis-method")"
    log_info "Analysis completed using method: $method"
    # Clean up marker file
    rm -f "${build_dir}/.sonar-analysis-method"
  fi
  
  # Extract task ID; without it we cannot verify a real SonarQube submission happened.
  SONAR_TASK_ID="$(sonar_extract_task_id_from_report "$build_dir")"
  if [[ -z "$SONAR_TASK_ID" ]]; then
    SONAR_TASK_ID="$(sonar_extract_task_id_from_log "$log_file")"
  fi

  if [[ -z "$SONAR_TASK_ID" ]]; then
    log_error "SonarQube command exited but produced no task ID for $key"
    log_error "Likely no analysis was submitted (for example, a custom wrapper ignored the sonar task)"
    log_error "See log: $log_file"
    return 1
  fi

  log_success "Analysis submitted. Task ID: $SONAR_TASK_ID"
  
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
