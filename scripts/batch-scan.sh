#!/usr/bin/env bash
# batch-scan.sh - Main orchestrator for batch scanning
# Processes multiple repositories through the analysis pipeline

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root
cd "$PROJECT_ROOT"

# Source library modules
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/clone.sh"
source "${SCRIPT_DIR}/lib/detect-build.sh"
source "${SCRIPT_DIR}/lib/build.sh"
source "${SCRIPT_DIR}/lib/submit-sonar.sh"

# Resolve all config paths to absolute (prevents issues when cwd changes)
resolve_config_paths

# ============================================================================
# CLI Arguments
# ============================================================================

FORCE_RERUN=false
DRY_RUN=false
SINGLE_REPO=""
CONTINUE_MODE=false
FORCED_JDK=""
REPOS_FILE="repos.txt"
SKIP_SONAR=false
CLEANUP_AFTER=false

print_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Batch scan Java repositories with SonarQube.

Options:
  -f, --force           Reprocess all repos (ignore previous success)
  -n, --dry-run         Show what would be processed without running
  -r, --repo <url>      Process only this specific repository
  -c, --continue        Resume from last incomplete run
  -j, --jdk <version>   Force specific JDK for all repos
  -i, --input <file>    Use specified repos file (default: repos.txt)
  --skip-sonar          Build only, skip SonarQube submission
  --cleanup             Remove cloned repos after successful analysis
  -h, --help            Show this help message

Examples:
  $(basename "$0")                           # Process all pending repos
  $(basename "$0") --force                   # Reprocess everything
  $(basename "$0") --repo https://github.com/org/repo.git
  $(basename "$0") --jdk 17                  # Force JDK 17 for all builds
  $(basename "$0") --dry-run                 # Preview what would run

State is persisted in: ${STATE_FILE}
Logs are saved in: ${LOG_DIR}/
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        FORCE_RERUN=true
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -r|--repo)
        SINGLE_REPO="$2"
        shift 2
        ;;
      -c|--continue)
        CONTINUE_MODE=true
        shift
        ;;
      -j|--jdk)
        FORCED_JDK="$2"
        shift 2
        ;;
      -i|--input)
        REPOS_FILE="$2"
        shift 2
        ;;
      --skip-sonar)
        SKIP_SONAR=true
        shift
        ;;
      --cleanup)
        CLEANUP_AFTER=true
        shift
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        print_usage
        exit 1
        ;;
    esac
  done
}

# ============================================================================
# Main Pipeline
# ============================================================================

# Process a single repository through the entire pipeline
# Usage: process_repo <url> [jdk_hint] [subdir_hint]
# Returns: 0 on success, 1 on failure
process_repo() {
  local url="$1"
  local jdk_hint="${2:-}"
  local subdir_hint="${3:-}"
  
  local key
  key="$(derive_key "$url")"
  local display_name
  display_name="$(derive_display_name "$url")"
  
  log_info "=========================================="
  log_info "Processing: $display_name"
  log_info "Project key: $key"
  log_info "=========================================="
  
  # Initialize repo in state if needed
  state_init_repo "$key" "$url"
  
  # Check if already successful (unless force mode)
  if ! $FORCE_RERUN && state_is_success "$key"; then
    log_info "Already successfully analyzed, skipping (use --force to rerun)"
    return 0
  fi
  
  # Increment attempt counter
  state_increment_attempts "$key"
  
  # ---- CLONE STAGE ----
  state_set_status "$key" "cloning"
  
  if ! clone_repo "$url" "$key"; then
    state_set_status "$key" "failed" "clone_failed" "Failed to clone repository"
    return 1
  fi
  
  local repo_dir
  repo_dir="$(clone_get_path "$key")"
  
  # ---- DETECT STAGE ----
  local build_result
  build_result="$(detect_build_system "$repo_dir" "$key")"
  
  if [[ "$build_result" == "unknown" ]]; then
    state_set_status "$key" "skipped" "no_build_file" "No pom.xml or build.gradle found"
    log_warn "No build system detected, skipping"
    return 1
  fi
  
  # Parse build result
  parse_build_result "$build_result"
  local build_tool="$BUILD_TOOL"
  local build_subdir="${subdir_hint:-$BUILD_SUBDIR}"
  
  log_info "Detected build system: $build_tool${build_subdir:+ (subdir: $build_subdir)}"
  
  # Get effective build directory
  local build_dir="$repo_dir"
  if [[ -n "$build_subdir" ]]; then
    build_dir="${repo_dir}/${build_subdir}"
  fi
  
  # Use forced JDK or hint
  local effective_jdk="${FORCED_JDK:-$jdk_hint}"
  
  # ---- BUILD STAGE ----
  state_set_status "$key" "building"
  state_set_build_info "$key" "$build_tool" ""
  
  if ! build_project "$key" "$build_dir" "$build_tool" "$effective_jdk"; then
    state_set_status "$key" "failed" "$BUILD_RESULT_REASON" "$BUILD_RESULT_MESSAGE"
    return 1
  fi
  
  # Update state with successful build info
  state_set_build_info "$key" "$build_tool" "$BUILD_RESULT_JDK"
  
  # ---- SONAR STAGE ----
  if $SKIP_SONAR; then
    log_info "Skipping SonarQube submission (--skip-sonar)"
    state_set_status "$key" "success"
  else
    state_set_status "$key" "submitting"
    
    if ! submit_to_sonar "$key" "$build_dir" "$build_tool"; then
      state_set_status "$key" "failed" "sonar_submission_failed" "SonarQube analysis failed"
      return 1
    fi
    
    # Store task ID if available
    if [[ -n "$SONAR_TASK_ID" ]]; then
      state_set_sonar_task "$key" "$SONAR_TASK_ID"
    fi
    
    state_set_status "$key" "success"
  fi
  
  # ---- CLEANUP ----
  if $CLEANUP_AFTER; then
    clone_cleanup "$key"
  fi
  
  log_success "Successfully processed: $display_name"
  return 0
}

# ============================================================================
# Summary Report
# ============================================================================

generate_summary() {
  local summary_file="${LOG_DIR}/summary-$(date +%Y%m%d-%H%M%S).txt"
  
  ensure_dir "$LOG_DIR"
  
  {
    echo "Batch Scan Summary - $(timestamp)"
    echo "=========================================="
    echo ""
    state_summary
    echo ""
    
    local failed_count
    failed_count="$(state_count_by_status "failed")"
    if [[ "$failed_count" -gt 0 ]]; then
      echo "Failed repositories:"
      state_list_failed
      echo ""
    fi
    
    local skipped_count
    skipped_count="$(state_count_by_status "skipped")"
    if [[ "$skipped_count" -gt 0 ]]; then
      echo "Skipped repositories:"
      state_list_skipped
      echo ""
    fi
    
    echo "See ${LOG_DIR}/ directory for detailed logs."
  } | tee "$summary_file"
  
  log_info "Summary saved to: $summary_file"
}

# ============================================================================
# Main Entry Point
# ============================================================================

main() {
  parse_args "$@"
  
  # Load environment
  load_env
  
  # Check dependencies
  check_dependencies
  
  # Verify required env vars (unless dry run)
  if ! $DRY_RUN && ! $SKIP_SONAR; then
    require_env "SONAR_HOST_URL" "Set in .env file"
    require_env "SONAR_TOKEN" "Generate in SonarQube UI → My Account → Security"
  fi
  
  # Initialize state
  state_init
  state_update_last_run
  
  # Discover available JDKs
  discover_jdks
  
  log_info "Batch Scanner Starting"
  log_info "  Force mode: $FORCE_RERUN"
  log_info "  Dry run: $DRY_RUN"
  log_info "  Forced JDK: ${FORCED_JDK:-<auto>}"
  log_info "  Available JDKs: ${AVAILABLE_JDKS[*]:-none}"
  echo ""
  
  # Build list of repos to process
  declare -a repos_to_process=()
  
  if [[ -n "$SINGLE_REPO" ]]; then
    # Single repo mode
    repos_to_process+=("${SINGLE_REPO}||")
  else
    # Read from repos file
    if [[ ! -f "$REPOS_FILE" ]]; then
      log_error "Repos file not found: $REPOS_FILE"
      exit 1
    fi
    
    while IFS= read -r line; do
      repos_to_process+=("$line")
    done < <(parse_repos_file "$REPOS_FILE")
  fi
  
  local total=${#repos_to_process[@]}
  log_info "Found $total repositories to process"
  echo ""
  
  # Dry run: just show what would be processed
  if $DRY_RUN; then
    log_info "DRY RUN - Would process:"
    for entry in "${repos_to_process[@]}"; do
      IFS='|' read -r url jdk subdir <<< "$entry"
      local key
      key="$(derive_key "$url")"
      local status
      status="$(state_get_status "$key")"
      
      if ! $FORCE_RERUN && [[ "$status" == "success" ]]; then
        echo "  [SKIP] $url (already successful)"
      else
        echo "  [PROCESS] $url${jdk:+ (jdk=$jdk)}${subdir:+ (subdir=$subdir)}"
      fi
    done
    exit 0
  fi
  
  # Process each repository
  local processed=0
  local succeeded=0
  local failed=0
  local skipped=0
  
  for entry in "${repos_to_process[@]}"; do
    IFS='|' read -r url jdk subdir <<< "$entry"
    
    ((processed++))
    log_info "[$processed/$total] Processing..."
    
    if process_repo "$url" "$jdk" "$subdir"; then
      ((succeeded++))
    else
      local key
      key="$(derive_key "$url")"
      local status
      status="$(state_get_status "$key")"
      
      if [[ "$status" == "skipped" ]]; then
        ((skipped++))
      else
        ((failed++))
      fi
    fi
    
    echo ""
  done
  
  # Generate summary
  echo ""
  log_info "=========================================="
  log_info "Batch Processing Complete"
  log_info "=========================================="
  generate_summary
  
  # Exit with error if any failed
  if [[ $failed -gt 0 ]]; then
    exit 1
  fi
}

# Run main
main "$@"
