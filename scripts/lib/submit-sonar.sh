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
  
  # Record analysis method if available
  if [[ -f "${build_dir}/.sonar-analysis-method" ]]; then
    local method
    method="$(cat "${build_dir}/.sonar-analysis-method")"
    log_info "Analysis completed using method: $method"
    # Clean up marker file
    rm -f "${build_dir}/.sonar-analysis-method"
  fi
  
  # Extract task ID from log if possible
  SONAR_TASK_ID="$(sed -n 's/.*task?id=\([A-Za-z0-9_-]*\).*/\1/p' "$log_file" 2>/dev/null | tail -1 || echo "")"
  
  if [[ -n "$SONAR_TASK_ID" ]]; then
    log_success "Analysis submitted. Task ID: $SONAR_TASK_ID"
  else
    log_success "Analysis submitted for $key"
  fi
  
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
  
  # Check if already exists
  if sonar_project_exists "$key"; then
    log_info "Project $key already exists in SonarQube"
    return 0
  fi
  
  log_info "Creating SonarQube project: $key ($name)"
  
  curl -sf -u "${SONAR_TOKEN}:" \
    -X POST "${SONAR_HOST_URL}/api/projects/create" \
    --data-urlencode "project=${key}" \
    --data-urlencode "name=${name}" \
    >/dev/null 2>&1 || true
  
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
