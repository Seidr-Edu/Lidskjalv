#!/usr/bin/env bash
# common.sh - Shared utilities for batch scanning
# Source this file in other scripts: source "$(dirname "$0")/lib/common.sh"

# Source guard - prevent multiple sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

set -euo pipefail

# ============================================================================
# Configuration defaults
# ============================================================================

export WORK_DIR="${WORK_DIR:-_work}"
export LOG_DIR="${LOG_DIR:-logs}"
export STATE_FILE="${STATE_FILE:-state/scan-state.json}"
export BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"

# ============================================================================
# Convert paths to absolute (prevents issues when cwd changes during execution)
# ============================================================================

# Helper to convert relative path to absolute
_to_absolute_path() {
  local path="$1"
  if [[ ! "$path" = /* ]]; then
    echo "$(pwd)/${path}"
  else
    echo "$path"
  fi
}

# Convert all config paths to absolute
resolve_config_paths() {
  WORK_DIR="$(_to_absolute_path "$WORK_DIR")"
  LOG_DIR="$(_to_absolute_path "$LOG_DIR")"
  STATE_FILE="$(_to_absolute_path "$STATE_FILE")"
  export WORK_DIR LOG_DIR STATE_FILE
}

# ============================================================================
# Logging utilities
# ============================================================================

# ANSI color codes (disabled if not a terminal)
if [[ -t 1 ]]; then
  readonly COLOR_RED='\033[0;31m'
  readonly COLOR_GREEN='\033[0;32m'
  readonly COLOR_YELLOW='\033[0;33m'
  readonly COLOR_BLUE='\033[0;34m'
  readonly COLOR_RESET='\033[0m'
else
  readonly COLOR_RED=''
  readonly COLOR_GREEN=''
  readonly COLOR_YELLOW=''
  readonly COLOR_BLUE=''
  readonly COLOR_RESET=''
fi

# Get ISO 8601 timestamp
timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Log info message
log_info() {
  echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $(timestamp) $*" >&2
}

# Log success message
log_success() {
  echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $(timestamp) $*" >&2
}

# Log warning message
log_warn() {
  echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $(timestamp) $*" >&2
}

# Log error message
log_error() {
  echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $(timestamp) $*" >&2
}

# ============================================================================
# Directory utilities
# ============================================================================

# Ensure directory exists
ensure_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
  fi
}

# Get the script's directory (for sourcing relative files)
get_script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}

# Get project root directory (assumes scripts are in scripts/)
get_project_root() {
  local script_dir
  script_dir="$(get_script_dir)"
  # Navigate up from scripts/lib or scripts/
  if [[ "$(basename "$script_dir")" == "lib" ]]; then
    dirname "$(dirname "$script_dir")"
  elif [[ "$(basename "$script_dir")" == "strategies" ]]; then
    dirname "$(dirname "$script_dir")"
  else
    dirname "$script_dir"
  fi
}

# ============================================================================
# Project key derivation
# ============================================================================

# Derive a project key from a repository URL
# Example: https://github.com/spring-projects/spring-petclinic.git -> spring-projects_spring-petclinic
derive_key() {
  local url="$1"
  local path
  # Remove protocol and host
  path="$(echo "$url" | sed -E 's#https?://[^/]+/##')"
  
  local org repo
  org="$(echo "$path" | cut -d/ -f1)"
  repo="$(echo "$path" | cut -d/ -f2 | sed -E 's#\.git$##')"
  
  local key="${org}_${repo}"
  # Replace illegal characters with underscore
  key="$(echo "$key" | sed -E 's#[^a-zA-Z0-9_.-]#_#g')"
  
  echo "$key"
}

# Extract org/repo display name from URL
# Example: https://github.com/spring-projects/spring-petclinic.git -> spring-projects/spring-petclinic
derive_display_name() {
  local url="$1"
  local path
  path="$(echo "$url" | sed -E 's#https?://[^/]+/##')"
  
  local org repo
  org="$(echo "$path" | cut -d/ -f1)"
  repo="$(echo "$path" | cut -d/ -f2 | sed -E 's#\.git$##')"
  
  echo "${org}/${repo}"
}

# ============================================================================
# Command execution utilities
# ============================================================================

# Run a command with timeout
# Usage: run_with_timeout <timeout_seconds> <command...>
# Returns the command's exit code, or 124 if timed out
run_with_timeout() {
  local timeout_secs="$1"
  shift
  
  # Use gtimeout on macOS if available, otherwise timeout
  local timeout_cmd="timeout"
  if command -v gtimeout &>/dev/null; then
    timeout_cmd="gtimeout"
  elif ! command -v timeout &>/dev/null; then
    # No timeout command available, run without timeout
    log_warn "No timeout command available, running without timeout"
    "$@"
    return $?
  fi
  
  "$timeout_cmd" "$timeout_secs" "$@"
  return $?
}

# Run a command and capture output to a log file
# Usage: run_logged <log_file> <command...>
# Returns the command's exit code
run_logged() {
  local log_file="$1"
  shift
  
  ensure_dir "$(dirname "$log_file")"
  
  {
    echo "========================================"
    echo "Command: $*"
    echo "Timestamp: $(timestamp)"
    echo "Working directory: $(pwd)"
    echo "JAVA_HOME: ${JAVA_HOME:-<not set>}"
    echo "========================================"
    echo ""
  } > "$log_file"
  
  local exit_code=0
  local start_time
  start_time=$(date +%s)
  
  # Run command, capturing both stdout and stderr
  "$@" >> "$log_file" 2>&1 || exit_code=$?
  
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))
  
  {
    echo ""
    echo "========================================"
    echo "Exit code: $exit_code"
    echo "Duration: ${duration}s"
    echo "Completed: $(timestamp)"
    echo "========================================"
  } >> "$log_file"
  
  return $exit_code
}

# ============================================================================
# Environment loading
# ============================================================================

# Load .env file if present
load_env() {
  local env_file="${1:-.env}"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
  fi
}

# Verify required environment variables are set
require_env() {
  local var_name="$1"
  local hint="${2:-}"
  
  if [[ -z "${!var_name:-}" ]]; then
    log_error "Missing required environment variable: $var_name"
    if [[ -n "$hint" ]]; then
      log_error "Hint: $hint"
    fi
    exit 1
  fi
}

# ============================================================================
# repos.txt parsing
# ============================================================================

# Validate a repository URL
# Usage: is_valid_repo_url <url>
# Returns: 0 if valid, 1 if invalid
is_valid_repo_url() {
  local url="$1"
  
  # Must start with https:// or http://
  if [[ ! "$url" =~ ^https?:// ]]; then
    return 1
  fi
  
  # Must contain at least one path component after the host
  if [[ ! "$url" =~ ^https?://[^/]+/.+ ]]; then
    return 1
  fi
  
  return 0
}

# Parse repos.txt and output URLs with optional metadata
# Format: Each line outputs: URL|jdk|subdir
# Example: https://github.com/org/repo.git|17|backend
parse_repos_file() {
  local repos_file="${1:-repos.txt}"
  
  if [[ ! -f "$repos_file" ]]; then
    log_error "Repository file not found: $repos_file"
    exit 1
  fi
  
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines
    [[ -z "$line" ]] && continue
    # Skip comment lines (starting with #)
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Extract URL (everything before # or end of line)
    local url
    url="$(echo "$line" | sed -E 's/#.*//' | xargs)"
    [[ -z "$url" ]] && continue
    
    # Validate URL
    if ! is_valid_repo_url "$url"; then
      log_warn "Skipping invalid URL: $url"
      continue
    fi
    
    # Extract metadata from comment if present
    local jdk="" subdir=""
    if [[ "$line" =~ \# ]]; then
      local comment
      comment="$(echo "$line" | sed -E 's/[^#]*#//')"
      
      # Parse jdk=XX
      if [[ "$comment" =~ jdk=([0-9]+) ]]; then
        jdk="${BASH_REMATCH[1]}"
      fi
      
      # Parse subdir=path
      if [[ "$comment" =~ subdir=([^,[:space:]]+) ]]; then
        subdir="${BASH_REMATCH[1]}"
      fi
    fi
    
    echo "${url}|${jdk}|${subdir}"
  done < "$repos_file"
}

# ============================================================================
# Dependency checking
# ============================================================================

# Check if required tools are available
check_dependencies() {
  local missing=()
  
  for cmd in git jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required dependencies: ${missing[*]}"
    log_error "Please install them before running this script."
    exit 1
  fi
}
