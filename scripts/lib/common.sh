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

_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_COMMON_PROJECT_ROOT="$(cd "${_COMMON_LIB_DIR}/../.." && pwd)"

export LIDSKJALV_ROOT="${LIDSKJALV_ROOT:-${_COMMON_PROJECT_ROOT}}"
export LIDSKJALV_MONOREPO_ROOT="${LIDSKJALV_MONOREPO_ROOT:-${LIDSKJALV_ROOT}}"
export LIDSKJALV_DATA_DIR="${LIDSKJALV_DATA_DIR:-${LIDSKJALV_ROOT}/.data/lidskjalv}"
export WORK_DIR="${WORK_DIR:-${LIDSKJALV_DATA_DIR}/work}"
export LOG_DIR="${LOG_DIR:-${LIDSKJALV_DATA_DIR}/logs}"
export STATE_FILE="${STATE_FILE:-${LIDSKJALV_DATA_DIR}/state/scan-state.json}"
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
# Repository source helpers
# ============================================================================

# Trim leading/trailing whitespace
trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  echo "$value"
}

# Replace characters unsupported by SonarQube project keys
sanitize_project_key() {
  local value="$1"
  echo "$value" | sed -E 's#[^a-zA-Z0-9_.-]#_#g'
}

# Convert git remote (https/ssh/scp-like) to org/repo path
# Example: git@github.com:org/repo.git -> org/repo
_remote_to_path() {
  local remote="$1"
  local normalized="$remote"

  normalized="${normalized#ssh://}"
  normalized="${normalized#http://}"
  normalized="${normalized#https://}"
  normalized="${normalized#git://}"
  normalized="${normalized#git@}"
  normalized="${normalized#*@}"

  # Convert scp-like syntax host:path -> host/path
  normalized="$(echo "$normalized" | sed -E 's#^([^/]+):#\1/#')"
  echo "${normalized#*/}"
}

# Short deterministic hash used for local path fallback keys
_short_hash() {
  local value="$1"
  if command -v shasum &>/dev/null; then
    printf '%s' "$value" | shasum -a 1 | awk '{print substr($1,1,8)}'
  elif command -v sha1sum &>/dev/null; then
    printf '%s' "$value" | sha1sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$value" | cksum | awk '{print $1}'
  fi
}

# Resolve a path against a base directory.
# If the directory exists, returns canonical path.
resolve_repo_path() {
  local path_ref="$1"
  local base_dir="${2:-$(pwd)}"
  local candidate="$path_ref"

  if [[ ! "$candidate" = /* ]]; then
    candidate="${base_dir}/${candidate}"
  fi

  if [[ -d "$candidate" ]]; then
    (cd "$candidate" >/dev/null 2>&1 && pwd -P) || echo "$candidate"
  else
    # Best-effort absolute path even when it does not exist.
    local parent_dir
    parent_dir="$(dirname "$candidate")"
    if [[ -d "$parent_dir" ]]; then
      echo "$(cd "$parent_dir" >/dev/null 2>&1 && pwd -P)/$(basename "$candidate")"
    else
      echo "$candidate"
    fi
  fi
}

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

# Parse a source entry. Supports:
#   - plain URL (treated as url)
#   - url:<url>
#   - path:<path>
# Output format: source_type|source_ref
parse_repo_source() {
  local raw_entry="$1"
  local entry
  entry="$(trim_whitespace "$raw_entry")"

  if [[ -z "$entry" ]]; then
    return 1
  fi

  if [[ "$entry" == url:* ]]; then
    local url_ref
    url_ref="$(trim_whitespace "${entry#url:}")"
    if ! is_valid_repo_url "$url_ref"; then
      return 1
    fi
    echo "url|$url_ref"
    return 0
  fi

  if [[ "$entry" == path:* ]]; then
    local path_ref
    path_ref="$(trim_whitespace "${entry#path:}")"
    [[ -n "$path_ref" ]] || return 1
    echo "path|$path_ref"
    return 0
  fi

  if is_valid_repo_url "$entry"; then
    echo "url|$entry"
    return 0
  fi

  return 1
}

# Normalize source reference to a stable value
# URLs are unchanged, paths become absolute (resolved against base_dir).
normalize_source_ref() {
  local source_type="$1"
  local source_ref="$2"
  local base_dir="${3:-$(pwd)}"

  case "$source_type" in
    url) echo "$source_ref" ;;
    path) resolve_repo_path "$source_ref" "$base_dir" ;;
    *) echo "$source_ref" ;;
  esac
}

# Derive a project key from a repository URL
# Example: https://github.com/spring-projects/spring-petclinic.git -> spring-projects_spring-petclinic
derive_key() {
  local url="$1"
  local path
  path="$(echo "$url" | sed -E 's#https?://[^/]+/##')"

  local org repo
  org="$(echo "$path" | cut -d/ -f1)"
  repo="$(echo "$path" | cut -d/ -f2 | sed -E 's#\.git$##')"

  sanitize_project_key "${org}_${repo}"
}

# Try to derive key from git remote URL (supports https/ssh/scp syntax)
derive_key_from_git_remote() {
  local remote="$1"
  local path
  path="$(_remote_to_path "$remote")"

  local org repo
  org="$(echo "$path" | cut -d/ -f1)"
  repo="$(echo "$path" | cut -d/ -f2 | sed -E 's#\.git$##')"

  if [[ -z "$org" || -z "$repo" ]]; then
    return 1
  fi

  sanitize_project_key "${org}_${repo}"
}

# Derive a project key from local path.
# Priority: git remote origin key -> local_<basename>_<hash>.
derive_key_from_path() {
  local path_ref="$1"
  local abs_path
  abs_path="$(resolve_repo_path "$path_ref")"

  local remote=""
  if [[ -d "$abs_path/.git" ]]; then
    remote="$(git -C "$abs_path" remote get-url origin 2>/dev/null || echo "")"
  fi

  if [[ -n "$remote" ]]; then
    local remote_key=""
    remote_key="$(derive_key_from_git_remote "$remote" 2>/dev/null || true)"
    if [[ -n "$remote_key" ]]; then
      echo "$remote_key"
      return 0
    fi
  fi

  local base_name
  base_name="$(basename "$abs_path")"
  base_name="$(sanitize_project_key "$base_name")"
  local hash
  hash="$(_short_hash "$abs_path")"

  sanitize_project_key "local_${base_name}_${hash}"
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

# Derive display name from local path.
# Uses git remote org/repo if available, else directory name.
derive_display_name_from_path() {
  local path_ref="$1"
  local abs_path
  abs_path="$(resolve_repo_path "$path_ref")"

  local remote=""
  if [[ -d "$abs_path/.git" ]]; then
    remote="$(git -C "$abs_path" remote get-url origin 2>/dev/null || echo "")"
  fi

  if [[ -n "$remote" ]]; then
    local remote_path
    remote_path="$(_remote_to_path "$remote")"
    local org repo
    org="$(echo "$remote_path" | cut -d/ -f1)"
    repo="$(echo "$remote_path" | cut -d/ -f2 | sed -E 's#\.git$##')"
    if [[ -n "$org" && -n "$repo" ]]; then
      echo "${org}/${repo}"
      return 0
    fi
  fi

  basename "$abs_path"
}

# Derive project key for any source.
# Usage: derive_source_key <source_type> <source_ref> [explicit_key]
derive_source_key() {
  local source_type="$1"
  local source_ref="$2"
  local explicit_key="${3:-}"

  if [[ -n "$explicit_key" ]]; then
    sanitize_project_key "$explicit_key"
    return 0
  fi

  case "$source_type" in
    url) derive_key "$source_ref" ;;
    path) derive_key_from_path "$source_ref" ;;
    *)
      log_error "Unknown source type for key derivation: $source_type"
      return 1
      ;;
  esac
}

# Derive display name for any source.
# Usage: derive_source_display_name <source_type> <source_ref> [explicit_name]
derive_source_display_name() {
  local source_type="$1"
  local source_ref="$2"
  local explicit_name="${3:-}"

  if [[ -n "$explicit_name" ]]; then
    echo "$explicit_name"
    return 0
  fi

  case "$source_type" in
    url) derive_display_name "$source_ref" ;;
    path) derive_display_name_from_path "$source_ref" ;;
    *)
      log_error "Unknown source type for display name derivation: $source_type"
      return 1
      ;;
  esac
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
  local candidates=("$env_file")

  if [[ "$env_file" == ".env" ]]; then
    local project_root
    project_root="$(get_project_root)"
    if [[ -n "${LIDSKJALV_ENV_FILE:-}" ]]; then
      candidates=("${LIDSKJALV_ENV_FILE}" "${candidates[@]}")
    fi
    if [[ -n "${LIDSKJALV_ROOT:-}" ]]; then
      candidates+=("${LIDSKJALV_ROOT}/.env")
    fi
    candidates+=("${project_root}/.env")
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      set -a
      # shellcheck source=/dev/null
      source "$candidate"
      set +a
      return 0
    fi
  done
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

# Parse metadata from comment section.
# Output format: jdk|subdir|key|name
parse_repo_metadata() {
  local comment="$1"
  local jdk=""
  local subdir=""
  local key=""
  local name=""

  if [[ "$comment" =~ (^|[[:space:],])jdk=([^,[:space:]]+) ]]; then
    jdk="$(trim_whitespace "${BASH_REMATCH[2]}")"
  fi
  if [[ "$comment" =~ (^|[[:space:],])subdir=([^,[:space:]]+) ]]; then
    subdir="$(trim_whitespace "${BASH_REMATCH[2]}")"
  fi
  if [[ "$comment" =~ (^|[[:space:],])key=([^,[:space:]]+) ]]; then
    key="$(trim_whitespace "${BASH_REMATCH[2]}")"
  fi
  if [[ "$comment" =~ (^|[[:space:],])name=([^,]+) ]]; then
    name="$(trim_whitespace "${BASH_REMATCH[2]}")"
  fi

  echo "${jdk}|${subdir}|${key}|${name}"
}

# Parse repos.txt with optional metadata and mixed source types.
# Output format: source_type|source_ref|jdk|subdir|key|name
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

    # Extract source entry (everything before # or end of line)
    local entry
    entry="$(trim_whitespace "$(echo "$line" | sed -E 's/#.*//')")"
    [[ -z "$entry" ]] && continue

    local parsed_source
    parsed_source="$(parse_repo_source "$entry" 2>/dev/null || true)"
    if [[ -z "$parsed_source" ]]; then
      log_warn "Skipping invalid repo entry: $entry"
      continue
    fi

    local source_type source_ref
    IFS='|' read -r source_type source_ref <<< "$parsed_source"

    # Extract metadata from comment if present
    local jdk="" subdir="" key="" name=""
    if [[ "$line" == *"#"* ]]; then
      local comment
      comment="$(trim_whitespace "${line#*#}")"
      local parsed_meta
      parsed_meta="$(parse_repo_metadata "$comment")"
      IFS='|' read -r jdk subdir key name <<< "$parsed_meta"
    fi

    echo "${source_type}|${source_ref}|${jdk}|${subdir}|${key}|${name}"
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

# Count source LOC for JVM projects using a fast local file scan.
# Usage: count_source_loc <directory>
count_source_loc() {
  local source_root="$1"
  local total=0

  if [[ -z "$source_root" || ! -d "$source_root" ]]; then
    echo "0"
    return 0
  fi

  while IFS= read -r -d '' file; do
    local line_count
    line_count="$(wc -l < "$file" 2>/dev/null || echo "0")"
    line_count="$(echo "$line_count" | tr -d '[:space:]')"
    ((total += line_count))
  done < <(
    find "$source_root" \
      -type d \( -name .git -o -name build -o -name target -o -name .gradle -o -name out -o -name .idea -o -name node_modules -o -name .scannerwork \) -prune -o \
      -type f \( -name "*.java" -o -name "*.kt" -o -name "*.kts" -o -name "*.groovy" -o -name "*.scala" \) -print0
  )

  echo "$total"
}
