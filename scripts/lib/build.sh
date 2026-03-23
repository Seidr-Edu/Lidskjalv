#!/usr/bin/env bash
# build.sh - Build execution module
# Orchestrates build attempts with multiple strategies

# Ensure dependencies are sourced
_BUILD_SH_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${_BUILD_SH_DIR}/common.sh"
source "${_BUILD_SH_DIR}/select-jdk.sh"
source "${_BUILD_SH_DIR}/../strategies/maven.sh"
source "${_BUILD_SH_DIR}/../strategies/gradle.sh"

# ============================================================================
# Build Results
# ============================================================================

# Global variables set after build attempts
BUILD_RESULT_JDK=""
BUILD_RESULT_REASON=""
BUILD_RESULT_MESSAGE=""
BUILD_RESULT_ATTEMPTS=0
BUILD_RESULT_ATTEMPTED_JDKS_CSV=""

# ============================================================================
# Build Orchestration
# ============================================================================

# Build a project using multiple strategies
# Usage: build_project <project_key> <build_dir> <build_tool> [jdk_hint]
# Returns: 0 on success, 1 on failure
# Sets: BUILD_RESULT_* variables
build_project() {
  local key="$1"
  local build_dir="$2"
  local build_tool="$3"
  local jdk_hint="${4:-}"
  
  local log_dir="${LOG_DIR}/${key}"
  ensure_dir "$log_dir"
  
  BUILD_RESULT_JDK=""
  BUILD_RESULT_REASON=""
  BUILD_RESULT_MESSAGE=""
  BUILD_RESULT_ATTEMPTS=0
  BUILD_RESULT_ATTEMPTED_JDKS_CSV=""
  
  log_info "Building project: $key (tool: $build_tool)"
  
  # Get strategies based on build tool
  local -a strategies
  case "$build_tool" in
    maven)
      strategies=("${MAVEN_STRATEGIES[@]}")
      ;;
    gradle)
      strategies=("${GRADLE_STRATEGIES[@]}")
      ;;
    *)
      BUILD_RESULT_REASON="unsupported_build_tool"
      BUILD_RESULT_MESSAGE="Unsupported build tool: $build_tool"
      log_error "$BUILD_RESULT_MESSAGE"
      return 1
      ;;
  esac
  
  # If JDK hint is provided, try it first by reordering strategies
  if [[ -n "$jdk_hint" ]]; then
    local -a reordered=()
    local -a rest=()
    
    for strategy in "${strategies[@]}"; do
      local jdk_version="${strategy%%|*}"
      if [[ "$jdk_version" == "$jdk_hint" ]]; then
        reordered+=("$strategy")
      else
        rest+=("$strategy")
      fi
    done
    
    if [[ ${#reordered[@]} -gt 0 ]]; then
      strategies=("${reordered[@]}" "${rest[@]}")
      log_info "Prioritizing JDK $jdk_hint based on hint"
    fi
  fi
  
  # Try each strategy
  local attempt=0
  local last_reason=""
  local last_message=""
  
  for strategy in "${strategies[@]}"; do
    local jdk_version="${strategy%%|*}"
    local build_args="${strategy#*|}"
    
    # Check if this JDK is available
    if ! is_jdk_available "$jdk_version"; then
      log_info "  Skipping JDK $jdk_version (not available)"
      continue
    fi
    
    ((++attempt))
    BUILD_RESULT_ATTEMPTS=$attempt
    if [[ -z "$BUILD_RESULT_ATTEMPTED_JDKS_CSV" ]]; then
      BUILD_RESULT_ATTEMPTED_JDKS_CSV="$jdk_version"
    else
      BUILD_RESULT_ATTEMPTED_JDKS_CSV="${BUILD_RESULT_ATTEMPTED_JDKS_CSV}:${jdk_version}"
    fi

    log_info "  Attempt $attempt: JDK $jdk_version with args: $build_args"
    
    # Select JDK
    if ! select_jdk "$jdk_version"; then
      log_warn "  Failed to select JDK $jdk_version"
      continue
    fi
    
    # Create log file for this attempt
    local attempt_log="${log_dir}/build-attempt-${attempt}.log"
    
    # Run build
    local build_exit_code=0
    case "$build_tool" in
      maven)
        maven_build "$build_dir" "$build_args" "$attempt_log" || build_exit_code=$?
        ;;
      gradle)
        gradle_build "$build_dir" "$build_args" "$attempt_log" || build_exit_code=$?
        ;;
    esac
    
    if [[ $build_exit_code -eq 0 ]]; then
      log_success "  Build succeeded with JDK $jdk_version"
      BUILD_RESULT_JDK="$jdk_version"
      return 0
    fi
    
    # Parse error for classification
    case "$build_tool" in
      maven)
        last_reason="$(parse_maven_error "$attempt_log")"
        last_message="$(extract_maven_error_message "$attempt_log")"
        ;;
      gradle)
        last_reason="$(parse_gradle_error "$attempt_log")"
        last_message="$(extract_gradle_error_message "$attempt_log")"
        ;;
    esac
    
    log_warn "  Attempt $attempt failed: $last_reason"
    
    # Check for timeout
    if [[ $build_exit_code -eq 124 ]]; then
      last_reason="build_timeout"
      last_message="Build exceeded ${BUILD_TIMEOUT}s timeout"
      # Don't continue trying if we hit timeout
      break
    fi
  done
  
  # All strategies failed
  BUILD_RESULT_REASON="${last_reason:-build_failure}"
  BUILD_RESULT_MESSAGE="${last_message:-All build strategies failed}"
  
  log_error "All build strategies failed for $key"
  log_error "Last error: $BUILD_RESULT_REASON - $BUILD_RESULT_MESSAGE"
  
  return 1
}

# Build with timeout
# Usage: build_project_with_timeout <project_key> <build_dir> <build_tool> [jdk_hint]
build_project_with_timeout() {
  local key="$1"
  local build_dir="$2"
  local build_tool="$3"
  local jdk_hint="${4:-}"
  
  # Note: Timeout is applied per-attempt in maven_build/gradle_build via run_logged
  # This wrapper exists for future timeout-at-project-level if needed
  build_project "$key" "$build_dir" "$build_tool" "$jdk_hint"
}

# ============================================================================
# Quick Build Check
# ============================================================================

# Quick check if build is likely to succeed
# Usage: quick_build_check <build_dir> <build_tool>
# Returns: 0 if looks OK, 1 if obvious issues detected
quick_build_check() {
  local build_dir="$1"
  local build_tool="$2"
  
  case "$build_tool" in
    maven)
      # Check if pom.xml exists and is valid XML
      if [[ ! -f "${build_dir}/pom.xml" ]]; then
        log_warn "pom.xml not found in $build_dir"
        return 1
      fi
      ;;
    gradle)
      # Check if build file exists
      if [[ ! -f "${build_dir}/build.gradle" && ! -f "${build_dir}/build.gradle.kts" ]]; then
        log_warn "No build.gradle found in $build_dir"
        return 1
      fi
      ;;
  esac
  
  return 0
}

# ============================================================================
# Build Info Extraction
# ============================================================================

# Get build result summary
# Usage: get_build_summary
get_build_summary() {
  if [[ -n "$BUILD_RESULT_JDK" ]]; then
    echo "Success with JDK $BUILD_RESULT_JDK after $BUILD_RESULT_ATTEMPTS attempt(s)"
  else
    echo "Failed after $BUILD_RESULT_ATTEMPTS attempt(s): $BUILD_RESULT_REASON"
  fi
}
