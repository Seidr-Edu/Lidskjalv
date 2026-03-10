#!/usr/bin/env bash
# select-jdk.sh - JDK discovery and selection module
# Handles finding and configuring the appropriate JDK version
# Compatible with bash 3.x (macOS default)

# Ensure common.sh is sourced
if [[ -z "${WORK_DIR:-}" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# ============================================================================
# JDK Discovery
# ============================================================================

# Cache for available JDKs (populated on first call)
# Using regular array for versions, and _JDK_HOME_<version> variables for paths
AVAILABLE_JDKS=()

# Helper: Set JDK home for a version (bash 3.x compatible)
_set_jdk_home() {
  local version="$1"
  local path="$2"
  eval "_JDK_HOME_${version}=\"$path\""
}

# Helper: Get JDK home for a version (bash 3.x compatible)
_get_jdk_home() {
  local version="$1"
  eval "echo \"\${_JDK_HOME_${version}:-}\""
}

# Helper: Check if JDK home is set for a version
_has_jdk_home() {
  local version="$1"
  local home
  home="$(_get_jdk_home "$version")"
  [[ -n "$home" ]]
}

# Normalize java -version output majors.
# Examples: 1.8 -> 8, 11.0.22 -> 11, 25 -> 25
_normalize_discovered_jdk_version() {
  local version="$1"

  if [[ "$version" =~ ^1\.([0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
  else
    version="$(printf '%s' "$version" | sed -E 's/^([0-9]+).*$/\1/')"
  fi

  printf '%s\n' "$version"
}

# Discover available JDK versions on the system
# Populates AVAILABLE_JDKS array and _JDK_HOME_<version> variables
discover_jdks() {
  # Return if already discovered
  if [[ ${#AVAILABLE_JDKS[@]} -gt 0 ]]; then
    return 0
  fi
  
  AVAILABLE_JDKS=()
  
  case "$(uname -s)" in
    Darwin)
      _discover_jdks_macos
      ;;
    Linux)
      _discover_jdks_linux
      ;;
    *)
      log_warn "Unknown OS, attempting generic JDK discovery"
      _discover_jdks_generic
      ;;
  esac
  
  # Sort versions in descending order (newest first)
  if [[ ${#AVAILABLE_JDKS[@]} -gt 0 ]]; then
    local sorted
    sorted="$(printf '%s\n' "${AVAILABLE_JDKS[@]}" | sort -rn | uniq)"
    AVAILABLE_JDKS=()
    while IFS= read -r v; do
      [[ -n "$v" ]] && AVAILABLE_JDKS+=("$v")
    done <<< "$sorted"
  fi
  
  log_info "Discovered JDKs: ${AVAILABLE_JDKS[*]:-none}"
}

# Discover JDKs on macOS using java_home
_discover_jdks_macos() {
  local java_home_output
  java_home_output="$(/usr/libexec/java_home -V 2>&1 || true)"
  
  while IFS= read -r line; do
    # Parse lines like: "    21.0.1 (arm64) "Homebrew" - "OpenJDK 21.0.1" /opt/homebrew/Cellar/..."
    if [[ "$line" =~ ^[[:space:]]+([0-9]+) ]]; then
      local version="${BASH_REMATCH[1]}"
      local jdk_path
      jdk_path="$(/usr/libexec/java_home -v "$version" 2>/dev/null || true)"
      
      if [[ -n "$jdk_path" && -d "$jdk_path" ]]; then
        AVAILABLE_JDKS+=("$version")
        _set_jdk_home "$version" "$jdk_path"
      fi
    fi
  done <<< "$java_home_output"
  
  # Also check common Homebrew locations
  for jdk_dir in /opt/homebrew/opt/openjdk@* /usr/local/opt/openjdk@*; do
    if [[ -d "$jdk_dir" ]]; then
      local version
      version="$(basename "$jdk_dir" | sed 's/openjdk@//')"
      if ! _has_jdk_home "$version"; then
        if [[ -d "${jdk_dir}/libexec/openjdk.jdk/Contents/Home" ]]; then
          AVAILABLE_JDKS+=("$version")
          _set_jdk_home "$version" "${jdk_dir}/libexec/openjdk.jdk/Contents/Home"
        fi
      fi
    fi
  done
}

# Discover JDKs on Linux
_discover_jdks_linux() {
  # First check GitHub Actions environment variables (JAVA_HOME_*_X64)
  _discover_jdks_github_actions
  
  # Check common Linux JDK locations
  local jdk_base_dirs="/usr/lib/jvm /usr/java /opt/java $HOME/.sdkman/candidates/java"
  
  for base_dir in $jdk_base_dirs; do
    [[ -d "$base_dir" ]] || continue
    
    for jdk_dir in "$base_dir"/*; do
      [[ -d "$jdk_dir" ]] || continue
      [[ -f "${jdk_dir}/bin/java" ]] || continue
      
      # Try to extract version
      local version
      version="$("${jdk_dir}/bin/java" -version 2>&1 | head -1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
      version="$(_normalize_discovered_jdk_version "$version")"
      
      if [[ -n "$version" ]] && ! _has_jdk_home "$version"; then
        AVAILABLE_JDKS+=("$version")
        _set_jdk_home "$version" "$jdk_dir"
      fi
    done
  done
}

# Discover JDKs from GitHub Actions environment variables
# actions/setup-java sets JAVA_HOME_8_X64, JAVA_HOME_11_X64, etc.
_discover_jdks_github_actions() {
  # Check for GitHub Actions runner
  if [[ -z "${GITHUB_ACTIONS:-}" ]]; then
    return 0
  fi
  
  log_info "Detected GitHub Actions environment"
  
  # Check for JAVA_HOME_*_X64 environment variables
  for version in 8 11 17 21 25; do
    local var_name="JAVA_HOME_${version}_X64"
    local jdk_path="${!var_name:-}"
    
    if [[ -n "$jdk_path" && -d "$jdk_path" ]]; then
      if ! _has_jdk_home "$version"; then
        AVAILABLE_JDKS+=("$version")
        _set_jdk_home "$version" "$jdk_path"
        log_info "Found JDK $version from GitHub Actions: $jdk_path"
      fi
    fi
  done
}

# Generic JDK discovery (fallback)
_discover_jdks_generic() {
  # Just check if java is available
  if command -v java &>/dev/null; then
    local version
    version="$(java -version 2>&1 | head -1 | sed -n 's/.*version "\([^"]*\)".*/\1/p')"
    version="$(_normalize_discovered_jdk_version "$version")"
    if [[ -n "$version" ]]; then
      AVAILABLE_JDKS+=("$version")
      _set_jdk_home "$version" "${JAVA_HOME:-$(dirname "$(dirname "$(command -v java)")")}"
    fi
  fi
}

# ============================================================================
# JDK Selection
# ============================================================================

# Check if a specific JDK version is available
# Usage: is_jdk_available <version>
is_jdk_available() {
  local version="$1"
  discover_jdks
  
  _has_jdk_home "$version"
}

# Get JAVA_HOME for a specific version
# Usage: get_jdk_home <version>
get_jdk_home() {
  local version="$1"
  discover_jdks
  
  _get_jdk_home "$version"
}

# Select and configure a JDK version
# Usage: select_jdk <version>
# Sets: JAVA_HOME and updates PATH
# Returns: 0 on success, 1 if not available
select_jdk() {
  local version="$1"
  discover_jdks
  
  local jdk_home
  jdk_home="$(_get_jdk_home "$version")"
  
  if [[ -z "$jdk_home" ]]; then
    log_error "JDK $version not available"
    log_error "Available versions: ${AVAILABLE_JDKS[*]:-none}"
    return 1
  fi
  
  export JAVA_HOME="$jdk_home"
  export PATH="${JAVA_HOME}/bin:${PATH}"
  
  log_info "Selected JDK $version: $JAVA_HOME"
  
  # Verify it works
  if ! java -version &>/dev/null; then
    log_error "JDK $version selected but java command failed"
    return 1
  fi
  
  return 0
}

# Get the best available JDK from a list of preferred versions
# Usage: get_best_jdk <version1> <version2> ...
# Returns: First available version from the list
get_best_jdk() {
  discover_jdks
  
  for version in "$@"; do
    if is_jdk_available "$version"; then
      echo "$version"
      return 0
    fi
  done
  
  # Return first available as fallback
  if [[ ${#AVAILABLE_JDKS[@]} -gt 0 ]]; then
    echo "${AVAILABLE_JDKS[0]}"
    return 0
  fi
  
  return 1
}

# List all available JDK versions
# Usage: list_available_jdks
list_available_jdks() {
  discover_jdks
  printf '%s\n' "${AVAILABLE_JDKS[@]}"
}

# Print current Java configuration
print_java_info() {
  log_info "JAVA_HOME: ${JAVA_HOME:-<not set>}"
  if command -v java &>/dev/null; then
    log_info "Java version: $(java -version 2>&1 | head -1)"
  else
    log_warn "java command not found in PATH"
  fi
}

# ============================================================================
# JDK Strategy helpers
# ============================================================================

# Get default JDK fallback order for a build tool
# Usage: get_jdk_fallback_order [build_tool]
# Returns: Space-separated list of JDK versions to try
get_jdk_fallback_order() {
  # Modern first, then older LTS versions
  echo "25 21 17 11 8"
}

# Select JDK based on project hints and availability
# Usage: select_jdk_for_project <repo_dir> <build_tool> [subdir] [forced_version]
# Returns: 0 on success with JDK configured, 1 on failure
select_jdk_for_project() {
  local repo_dir="$1"
  local build_tool="$2"
  local subdir="${3:-}"
  local forced_version="${4:-}"
  
  discover_jdks
  
  # If version is forced, use it
  if [[ -n "$forced_version" ]]; then
    if select_jdk "$forced_version"; then
      return 0
    fi
    log_warn "Forced JDK $forced_version not available, falling back..."
  fi
  
  # Source detect-build.sh for version extraction
  source "$(dirname "${BASH_SOURCE[0]}")/detect-build.sh"
  
  # Try to detect from project files
  local detected_version
  detected_version="$(detect_java_version "$repo_dir" "$build_tool" "$subdir")"
  
  if [[ -n "$detected_version" ]]; then
    log_info "Project requires Java $detected_version"
    if select_jdk "$detected_version"; then
      return 0
    fi
    log_warn "Required JDK $detected_version not available, trying alternatives..."
  fi
  
  # Fall back to available JDKs in preferred order
  local fallback_order
  fallback_order="$(get_jdk_fallback_order "$build_tool")"
  
  for version in $fallback_order; do
    if select_jdk "$version"; then
      return 0
    fi
  done
  
  # Last resort: use whatever is available
  if [[ ${#AVAILABLE_JDKS[@]} -gt 0 ]]; then
    select_jdk "${AVAILABLE_JDKS[0]}"
    return $?
  fi
  
  log_error "No JDK available"
  return 1
}
