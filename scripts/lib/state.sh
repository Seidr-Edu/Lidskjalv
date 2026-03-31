#!/usr/bin/env bash
# state.sh - State management for batch scanning
# Handles reading/writing scan state to JSON file

# Ensure common.sh is sourced
if [[ -z "${WORK_DIR:-}" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# ============================================================================
# State file operations
# ============================================================================

# Initialize state file if it doesn't exist
state_init() {
  # Convert STATE_FILE to absolute path if relative (prevents issues when cwd changes)
  if [[ ! "$STATE_FILE" = /* ]]; then
    STATE_FILE="$(pwd)/${STATE_FILE}"
  fi
  
  ensure_dir "$(dirname "$STATE_FILE")"
  
  if [[ ! -f "$STATE_FILE" ]]; then
    cat > "$STATE_FILE" << 'EOF'
{
  "version": 1,
  "last_run": null,
  "repositories": {}
}
EOF
    log_info "Created new state file: $STATE_FILE"
  fi
}

# Read the entire state file
state_read() {
  if [[ ! -f "$STATE_FILE" ]]; then
    state_init
  fi
  cat "$STATE_FILE"
}

# Write state atomically (write to temp, then rename)
state_write() {
  local new_state="$1"
  local temp_file="${STATE_FILE}.tmp.$$"
  
  ensure_dir "$(dirname "$STATE_FILE")"
  
  # Validate JSON before writing
  if ! echo "$new_state" | jq empty 2>/dev/null; then
    log_error "Invalid JSON, refusing to write state"
    return 1
  fi
  
  # Write to temp file
  echo "$new_state" > "$temp_file"
  
  # Atomic rename
  mv "$temp_file" "$STATE_FILE"
}

# ============================================================================
# Repository state operations
# ============================================================================

# Get a field from a repository's state
# Usage: state_get <project_key> <field>
# Returns empty string if not found
state_get() {
  local key="$1"
  local field="$2"
  
  state_read | jq -r ".repositories[\"$key\"][\"$field\"] // empty"
}

# Set a single field for a repository
# Usage: state_set <project_key> <field> <value>
state_set() {
  local key="$1"
  local field="$2"
  local value="$3"
  
  local current_state
  current_state="$(state_read)"
  
  # Update the state
  local new_state
  new_state="$(echo "$current_state" | jq --arg key "$key" --arg field "$field" --arg value "$value" '
    .repositories[$key][$field] = $value
  ')"
  
  state_write "$new_state"
}

# Set a numeric field for a repository
# Usage: state_set_num <project_key> <field> <value>
state_set_num() {
  local key="$1"
  local field="$2"
  local value="$3"
  
  local current_state
  current_state="$(state_read)"
  
  local new_state
  new_state="$(echo "$current_state" | jq --arg key "$key" --arg field "$field" --argjson value "$value" '
    .repositories[$key][$field] = $value
  ')"
  
  state_write "$new_state"
}

# Initialize a repository entry with source information
# Usage (legacy): state_init_repo <project_key> <url>
# Usage: state_init_repo <project_key> <source_type> <source_ref>
state_init_repo() {
  local key="$1"
  local source_type="url"
  local source_ref=""

  if [[ $# -eq 2 ]]; then
    # Backward compatibility: second arg is URL.
    source_ref="$2"
  else
    source_type="$2"
    source_ref="$3"
  fi

  local url=""
  if [[ "$source_type" == "url" ]]; then
    url="$source_ref"
  else
    url="path:${source_ref}"
  fi
  
  local current_state
  current_state="$(state_read)"
  
  # Check if repo already exists
  local exists
  exists="$(echo "$current_state" | jq -r ".repositories[\"$key\"] != null")"
  
  if [[ "$exists" == "true" ]]; then
    # Update source metadata in case it changed
    local new_state
    new_state="$(echo "$current_state" | jq \
      --arg key "$key" \
      --arg url "$url" \
      --arg source_type "$source_type" \
      --arg source_ref "$source_ref" '
      .repositories[$key].url = $url |
      .repositories[$key].source_type = $source_type |
      .repositories[$key].source_ref = $source_ref
    ')"
    state_write "$new_state"
  else
    # Create new entry
    local new_state
    new_state="$(echo "$current_state" | jq \
      --arg key "$key" \
      --arg url "$url" \
      --arg source_type "$source_type" \
      --arg source_ref "$source_ref" \
      --arg ts "$(timestamp)" '
      .repositories[$key] = {
        "url": $url,
        "source_type": $source_type,
        "source_ref": $source_ref,
        "status": "pending",
        "build_tool": null,
        "jdk_version": null,
        "successful_build_tool": null,
        "successful_build_version": null,
        "last_attempt": $ts,
        "attempts": 0
      }
    ')"
    state_write "$new_state"
  fi
}

# Update repository status with optional failure info
# Usage: state_set_status <project_key> <status> [failure_reason] [failure_message]
state_set_status() {
  local key="$1"
  local status="$2"
  local reason="${3:-}"
  local message="${4:-}"
  
  local current_state
  current_state="$(state_read)"
  
  local new_state
  if [[ -n "$reason" ]]; then
    new_state="$(echo "$current_state" | jq \
      --arg key "$key" \
      --arg status "$status" \
      --arg reason "$reason" \
      --arg message "$message" \
      --arg ts "$(timestamp)" '
      .repositories[$key].status = $status |
      .repositories[$key].last_attempt = $ts |
      .repositories[$key].failure_reason = $reason |
      .repositories[$key].failure_message = $message
    ')"
  else
    new_state="$(echo "$current_state" | jq \
      --arg key "$key" \
      --arg status "$status" \
      --arg ts "$(timestamp)" '
      .repositories[$key].status = $status |
      .repositories[$key].last_attempt = $ts |
      del(.repositories[$key].failure_reason) |
      del(.repositories[$key].failure_message)
    ')"
  fi
  
  state_write "$new_state"
}

# Increment the attempts counter
# Usage: state_increment_attempts <project_key>
state_increment_attempts() {
  local key="$1"
  
  local current_state
  current_state="$(state_read)"
  
  local new_state
  new_state="$(echo "$current_state" | jq --arg key "$key" '
    .repositories[$key].attempts = ((.repositories[$key].attempts // 0) + 1)
  ')"
  
  state_write "$new_state"
}

# Set build info on success
# Usage: state_set_build_info <project_key> <build_tool> <jdk_version>
state_set_build_info() {
  local key="$1"
  local build_tool="$2"
  local jdk_version="$3"
  
  local current_state
  current_state="$(state_read)"
  
  local new_state
  new_state="$(echo "$current_state" | jq \
    --arg key "$key" \
    --arg tool "$build_tool" \
    --arg jdk "$jdk_version" '
    .repositories[$key].build_tool = $tool |
    .repositories[$key].jdk_version = $jdk
  ')"
  
  state_write "$new_state"
}

# Set successful build configuration (for re-runs)
# Usage: state_set_successful_build <project_key> <build_tool> <jdk_version>
state_set_successful_build() {
  local key="$1"
  local build_tool="$2"
  local jdk_version="$3"
  
  local current_state
  current_state="$(state_read)"
  
  local new_state
  new_state="$(echo "$current_state" | jq \
    --arg key "$key" \
    --arg tool "$build_tool" \
    --arg jdk "$jdk_version" '
    .repositories[$key].build_tool = $tool |
    .repositories[$key].jdk_version = $jdk |
    .repositories[$key].successful_build_tool = $tool |
    .repositories[$key].successful_build_version = $jdk
  ')"
  
  state_write "$new_state"
}

# Get successful build version for a repository
# Usage: state_get_successful_build_version <project_key>
state_get_successful_build_version() {
  local key="$1"
  state_get "$key" "successful_build_version"
}

# Set SonarQube task ID on successful submission
# Usage: state_set_sonar_task <project_key> <task_id>
state_set_sonar_task() {
  local key="$1"
  local task_id="$2"
  
  state_set "$key" "sonar_task_id" "$task_id"
}

# Set analysis method used (GRADLE or CLI)
# Usage: state_set_analysis_method <project_key> <method>
state_set_analysis_method() {
  local key="$1"
  local method="$2"
  
  state_set "$key" "analysis_method" "$method"
}

# Clear coverage metadata for a repository.
# Usage: state_clear_coverage_info <project_key>
state_clear_coverage_info() {
  local key="$1"

  local current_state
  current_state="$(state_read)"

  local new_state
  new_state="$(echo "$current_state" | jq --arg key "$key" '
    del(.repositories[$key].coverage_status) |
    del(.repositories[$key].coverage_reason) |
    del(.repositories[$key].coverage_jdk) |
    del(.repositories[$key].coverage_mode) |
    del(.repositories[$key].coverage_command) |
    del(.repositories[$key].coverage_report_kind) |
    del(.repositories[$key].coverage_jacoco_version) |
    del(.repositories[$key].coverage_java_target) |
    del(.repositories[$key].coverage_report_paths) |
    del(.repositories[$key].coverage_attempted) |
    del(.repositories[$key].coverage_tests_forced) |
    del(.repositories[$key].coverage_reports_found)
  ')"

  state_write "$new_state"
}

# Set coverage metadata for a repository.
# Usage: state_set_coverage_info <project_key> <status> <reason> <coverage_jdk> <mode> <command> <report_kind> <jacoco_version> <java_target> <report_paths_csv> [attempted] [tests_forced] [reports_found]
state_set_coverage_info() {
  local key="$1"
  local status="$2"
  local reason="$3"
  local coverage_jdk="$4"
  local coverage_mode="$5"
  local coverage_command="$6"
  local coverage_report_kind="$7"
  local jacoco_version="$8"
  local java_target="$9"
  local report_paths="${10}"
  local attempted="${11:-}"
  local tests_forced="${12:-}"
  local reports_found="${13:-}"

  local current_state
  current_state="$(state_read)"

  local new_state
  new_state="$(echo "$current_state" | jq \
    --arg key "$key" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg coverage_jdk "$coverage_jdk" \
    --arg coverage_mode "$coverage_mode" \
    --arg coverage_command "$coverage_command" \
    --arg coverage_report_kind "$coverage_report_kind" \
    --arg jacoco_version "$jacoco_version" \
    --arg java_target "$java_target" \
    --arg report_paths "$report_paths" \
    --arg attempted "$attempted" \
    --arg tests_forced "$tests_forced" \
    --arg reports_found "$reports_found" '
    .repositories[$key].coverage_status = (if $status == "" then null else $status end) |
    .repositories[$key].coverage_reason = (if $reason == "" then null else $reason end) |
    .repositories[$key].coverage_jdk = (if $coverage_jdk == "" then null else $coverage_jdk end) |
    .repositories[$key].coverage_mode = (if $coverage_mode == "" then null else $coverage_mode end) |
    .repositories[$key].coverage_command = (if $coverage_command == "" then null else $coverage_command end) |
    .repositories[$key].coverage_report_kind = (if $coverage_report_kind == "" then null else $coverage_report_kind end) |
    .repositories[$key].coverage_jacoco_version = (if $jacoco_version == "" then null else $jacoco_version end) |
    .repositories[$key].coverage_java_target = (if $java_target == "" then null else $java_target end) |
    .repositories[$key].coverage_report_paths = (if $report_paths == "" then null else $report_paths end) |
    .repositories[$key].coverage_attempted = (if $attempted == "" then null else ($attempted == "true") end) |
    .repositories[$key].coverage_tests_forced = (if $tests_forced == "" then null else ($tests_forced == "true") end) |
    .repositories[$key].coverage_reports_found = (if $reports_found == "" then null else ($reports_found | tonumber) end)
  ')"

  state_write "$new_state"
}

state_clear_scanner_info() {
  local key="$1"

  local current_state
  current_state="$(state_read)"

  local new_state
  new_state="$(echo "$current_state" | jq --arg key "$key" '
    del(.repositories[$key].scanner_mode) |
    del(.repositories[$key].scanner_jdk) |
    del(.repositories[$key].scanner_runtime_source) |
    del(.repositories[$key].scanner_version) |
    del(.repositories[$key].fallback_chain)
  ')"

  state_write "$new_state"
}

# Usage: state_set_scanner_info <project_key> <mode> <scanner_jdk> <runtime_source> <scanner_version> <fallback_chain_csv>
state_set_scanner_info() {
  local key="$1"
  local mode="$2"
  local scanner_jdk="$3"
  local runtime_source="$4"
  local scanner_version="$5"
  local fallback_chain="$6"

  local current_state
  current_state="$(state_read)"

  local new_state
  new_state="$(echo "$current_state" | jq \
    --arg key "$key" \
    --arg mode "$mode" \
    --arg scanner_jdk "$scanner_jdk" \
    --arg runtime_source "$runtime_source" \
    --arg scanner_version "$scanner_version" \
    --arg fallback_chain "$fallback_chain" '
    .repositories[$key].scanner_mode = (if $mode == "" then null else $mode end) |
    .repositories[$key].scanner_jdk = (if $scanner_jdk == "" then null else $scanner_jdk end) |
    .repositories[$key].scanner_runtime_source = (if $runtime_source == "" then null else $runtime_source end) |
    .repositories[$key].scanner_version = (if $scanner_version == "" then null else $scanner_version end) |
    .repositories[$key].fallback_chain = (if $fallback_chain == "" then null else $fallback_chain end)
  ')"

  state_write "$new_state"
}

# Set clone timestamp (when repo was last cloned or fetched)
# Usage: state_set_clone_timestamp <project_key>
state_set_clone_timestamp() {
  local key="$1"
  state_set "$key" "clone_timestamp" "$(timestamp)"
}

# Set scan timestamp (when SonarCloud analysis completed successfully)
# Usage: state_set_scan_timestamp <project_key>
state_set_scan_timestamp() {
  local key="$1"
  state_set "$key" "scan_timestamp" "$(timestamp)"
}

# ============================================================================
# State query operations
# ============================================================================

# Check if a repository was successfully analyzed
# Usage: state_is_success <project_key>
# Returns: 0 (true) if success, 1 (false) otherwise
state_is_success() {
  local key="$1"
  local status
  status="$(state_get "$key" "status")"
  [[ "$status" == "success" ]]
}

# Get status of a repository
# Usage: state_get_status <project_key>
state_get_status() {
  local key="$1"
  state_get "$key" "status"
}

# List all repository keys with a specific status
# Usage: state_list_by_status <status>
state_list_by_status() {
  local status="$1"
  state_read | jq -r --arg status "$status" '
    .repositories | to_entries[] | select(.value.status == $status) | .key
  '
}

# List all repository keys that are NOT successful
# Usage: state_get_pending
state_get_pending() {
  state_read | jq -r '
    .repositories | to_entries[] | select(.value.status != "success") | .key
  '
}

# List all repository keys
# Usage: state_list_all
state_list_all() {
  state_read | jq -r '.repositories | keys[]'
}

# Get count of repositories by status
# Usage: state_count_by_status <status>
state_count_by_status() {
  local status="$1"
  state_read | jq --arg status "$status" '
    [.repositories | to_entries[] | select(.value.status == $status)] | length
  '
}

# Update last_run timestamp
state_update_last_run() {
  local current_state
  current_state="$(state_read)"
  
  local new_state
  new_state="$(echo "$current_state" | jq --arg ts "$(timestamp)" '.last_run = $ts')"
  
  state_write "$new_state"
}

# ============================================================================
# State reporting
# ============================================================================

# Generate a summary of current state
state_summary() {
  local state
  state="$(state_read)"
  
  local total success failed sonar_failed skipped pending
  total="$(echo "$state" | jq '.repositories | length')"
  success="$(echo "$state" | jq '[.repositories | to_entries[] | select(.value.status == "success")] | length')"
  failed="$(echo "$state" | jq '[.repositories | to_entries[] | select(.value.status == "failed")] | length')"
  sonar_failed="$(echo "$state" | jq '[.repositories | to_entries[] | select(.value.status == "sonar_failed")] | length')"
  skipped="$(echo "$state" | jq '[.repositories | to_entries[] | select(.value.status == "skipped")] | length')"
  pending="$(echo "$state" | jq '[.repositories | to_entries[] | select(.value.status == "pending" or .value.status == "cloning" or .value.status == "building" or .value.status == "submitting")] | length')"
  
  echo "State Summary"
  echo "============="
  echo "Total repositories: $total"
  echo "  Successful: $success"
  echo "  Failed (build): $failed"
  echo "  Failed (SonarQube): $sonar_failed"
  echo "  Skipped: $skipped"
  echo "  Pending: $pending"
}

# Get failed repositories with reasons
state_list_failed() {
  state_read | jq -r '
    .repositories | to_entries[] | 
    select(.value.status == "failed") | 
    "  - \(.key): \(.value.failure_reason // "unknown") - \(.value.failure_message // "no message")"
  '
}

# Get SonarQube-failed repositories with reasons
state_list_sonar_failed() {
  state_read | jq -r '
    .repositories | to_entries[] | 
    select(.value.status == "sonar_failed") | 
    "  - \(.key): \(.value.failure_reason // "unknown") - \(.value.failure_message // "no message")\(if .value.successful_build_version then " (cached: JDK \(.value.successful_build_version))" else "" end)"
  '
}

# Get skipped repositories with reasons
state_list_skipped() {
  state_read | jq -r '
    .repositories | to_entries[] | 
    select(.value.status == "skipped") | 
    "  - \(.key): \(.value.failure_reason // "skipped") - \(.value.failure_message // "no message")"
  '
}

# List successful repositories with timestamps
state_list_successful() {
  state_read | jq -r '
    .repositories | to_entries[] | 
    select(.value.status == "success") | 
    "  - \(.key):
      Cloned:  \(.value.clone_timestamp // "N/A")
      Scanned: \(.value.scan_timestamp // "N/A")
      Build:   \(.value.build_tool // "N/A") with JDK \(.value.jdk_version // "N/A")
      Cached:  \(if .value.successful_build_version then "JDK \(.value.successful_build_version)" else "N/A" end)"
  '
}

# List all repositories with detailed status
state_list_all_details() {
  state_read | jq -r '
    .repositories | to_entries[] | 
    "Repository: \(.key)
  Status:  \(.value.status)
  Cloned:  \(.value.clone_timestamp // "N/A")
  Scanned: \(.value.scan_timestamp // "N/A")
  Build:   \(.value.build_tool // "N/A")\(if .value.jdk_version then " with JDK \(.value.jdk_version)" else "" end)
"
  '
}
