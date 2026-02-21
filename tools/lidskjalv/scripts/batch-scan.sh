#!/usr/bin/env bash
# batch-scan.sh - Main orchestrator for batch scanning
# Processes multiple repositories through the analysis pipeline

set -euo pipefail

# ============================================================================
# Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ORIGINAL_CWD="$(pwd)"

cd "$PROJECT_ROOT"

source "${SCRIPT_DIR}/lib/bootstrap.sh"
lidskjalv_bootstrap "$PROJECT_ROOT" "$ORIGINAL_CWD"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/clone.sh"
source "${SCRIPT_DIR}/lib/detect-build.sh"
source "${SCRIPT_DIR}/lib/build.sh"
source "${SCRIPT_DIR}/lib/submit-sonar.sh"
source "${SCRIPT_DIR}/lib/pipeline.sh"

resolve_config_paths

# ============================================================================
# Time Limit Handling
# ============================================================================

WORKFLOW_START_TIME=$(date +%s)
WORKFLOW_TIME_LIMIT_MINUTES=${WORKFLOW_TIME_LIMIT_MINUTES:-0}

should_continue_processing() {
  # Skip time limit check if disabled (0 = no limit, for local runs)
  if [[ "$WORKFLOW_TIME_LIMIT_MINUTES" -eq 0 ]]; then
    return 0
  fi

  local current_time
  current_time=$(date +%s)
  local time_limit_seconds=$((WORKFLOW_TIME_LIMIT_MINUTES * 60))
  local elapsed=$((current_time - WORKFLOW_START_TIME))
  local remaining=$((time_limit_seconds - elapsed))

  log_info "Time check: start=$WORKFLOW_START_TIME, now=$current_time, elapsed=${elapsed}s, remaining=${remaining}s"

  if [[ $remaining -lt 600 ]]; then  # Less than 10 minutes remaining
    log_warn "Time limit approaching (${remaining}s remaining)"
    log_warn "Stopping gracefully - incomplete repos will retry next run"
    return 1
  fi

  return 0
}

# ============================================================================
# CLI Arguments
# ============================================================================

FORCE_RERUN=false
DRY_RUN=false
SINGLE_REPO=""
REPOS_FILE="repos.txt"
REPOS_ROOT="${REPOS_ROOT:-$PROJECT_ROOT}"
SKIP_SONAR=false
CLEANUP_AFTER=false
RETRY_SONAR_FAILED=false

print_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Batch scan Java repositories with SonarQube.

Options:
  -f, --force              Reprocess all repos (ignore previous success and sonar failures)
  -n, --dry-run            Show what would be processed without running
  -r, --repo <ref>         Process only this repository (URL, url:<...>, or path:<...>)
  -i, --input <file>       Use specified repos file (default: repos.txt)
  --repos-root <dir>       Base directory for resolving relative path:<...> entries
  --skip-sonar             Build only, skip SonarQube submission
  --cleanup                Remove cloned URL repos after successful analysis
  --retry-sonar-failed     Retry repos that previously failed SonarQube submission
  -h, --help               Show this help message

Examples:
  $(basename "$0")                                       # Process all pending repos
  $(basename "$0") --force                               # Reprocess everything
  $(basename "$0") --repo https://github.com/org/repo.git
  $(basename "$0") --repo path:repos/PRDownloader
  $(basename "$0") --repos-root /opt/repos --dry-run

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
      -i|--input)
        REPOS_FILE="$2"
        shift 2
        ;;
      --repos-root)
        REPOS_ROOT="$2"
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
      --retry-sonar-failed)
        RETRY_SONAR_FAILED=true
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

process_repo() {
  local source_type="$1"
  local source_ref="$2"
  local jdk_hint="${3:-}"
  local subdir_hint="${4:-}"
  local key_override="${5:-}"
  local name_override="${6:-}"

  local normalized_ref
  normalized_ref="$(normalize_source_ref "$source_type" "$source_ref" "$REPOS_ROOT")"

  local key
  key="$(derive_source_key "$source_type" "$normalized_ref" "$key_override")"
  local display_name
  display_name="$(derive_source_display_name "$source_type" "$normalized_ref" "$name_override")"

  log_info "=========================================="
  log_info "Processing: $display_name"
  log_info "Project key: $key"
  log_info "Source: $source_type ($normalized_ref)"
  log_info "=========================================="

  state_init_repo "$key" "$source_type" "$normalized_ref"

  if ! $FORCE_RERUN && state_is_success "$key"; then
    log_info "Already successfully analyzed, skipping (use --force to rerun)"
    return 0
  fi

  local current_status
  current_status="$(state_get_status "$key")"
  if [[ "$current_status" == "sonar_failed" ]]; then
    if ! $RETRY_SONAR_FAILED && ! $FORCE_RERUN; then
      log_info "Previously failed SonarQube submission, skipping"
      return 0
    fi
    log_info "Retrying SonarQube-failed repository"
  fi

  if ! run_scan_pipeline \
    "$key" \
    "$display_name" \
    "$source_type" \
    "$normalized_ref" \
    "$REPOS_ROOT" \
    "$jdk_hint" \
    "$subdir_hint" \
    "$SKIP_SONAR" \
    "sonar_failed" \
    "true"; then
    return 1
  fi

  # ---- CLEANUP ----
  if $CLEANUP_AFTER; then
    source_cleanup "$source_type" "$key"
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

    local success_count
    success_count="$(state_count_by_status "success")"
    if [[ "$success_count" -gt 0 ]]; then
      echo "Successful repositories:"
      state_list_successful
      echo ""
    fi

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
  REPOS_ROOT="$(resolve_repo_path "$REPOS_ROOT" "$ORIGINAL_CWD")"

  check_dependencies

  if ! $DRY_RUN && ! $SKIP_SONAR; then
    require_env "SONAR_HOST_URL" "Set in .env file"
    require_env "SONAR_TOKEN" "Generate in SonarQube UI → My Account → Security"
  fi

  state_init
  state_update_last_run

  discover_jdks

  log_info "Batch Scanner Starting"
  log_info "  Force mode: $FORCE_RERUN"
  log_info "  Dry run: $DRY_RUN"
  log_info "  Retry SonarQube failures: $RETRY_SONAR_FAILED"
  log_info "  Repos root: $REPOS_ROOT"
  log_info "  Available JDKs: ${AVAILABLE_JDKS[*]:-none}"
  echo ""

  declare -a repos_to_process=()

  if [[ -n "$SINGLE_REPO" ]]; then
    local parsed_source
    parsed_source="$(parse_repo_source "$SINGLE_REPO" 2>/dev/null || true)"
    if [[ -z "$parsed_source" ]]; then
      log_error "Invalid --repo value: $SINGLE_REPO"
      log_error "Use URL, url:<...>, or path:<...>"
      exit 1
    fi
    local source_type source_ref
    IFS='|' read -r source_type source_ref <<< "$parsed_source"
    repos_to_process+=("${source_type}|${source_ref}||||")
  else
    if [[ ! -f "$REPOS_FILE" ]]; then
      log_error "Repos file not found: $REPOS_FILE"
      exit 1
    fi

    while IFS= read -r line; do
      repos_to_process+=("$line")
    done < <(parse_repos_file "$REPOS_FILE")
  fi

  local total=${#repos_to_process[@]}
  if [[ "$total" -eq 0 ]]; then
    log_warn "No repository entries to process"
    exit 0
  fi

  log_info "Found $total repositories to process"
  echo ""

  # Debug: show time limit status
  log_info "Time limit: ${WORKFLOW_TIME_LIMIT_MINUTES:-0} minutes"

  if $DRY_RUN; then
    log_info "DRY RUN - Would process:"
    for entry in "${repos_to_process[@]}"; do
      local source_type source_ref jdk subdir key_override name_override
      IFS='|' read -r source_type source_ref jdk subdir key_override name_override <<< "$entry"
      local normalized_ref
      normalized_ref="$(normalize_source_ref "$source_type" "$source_ref" "$REPOS_ROOT")"
      local key
      key="$(derive_source_key "$source_type" "$normalized_ref" "$key_override")"
      local display_name
      display_name="$(derive_source_display_name "$source_type" "$normalized_ref" "$name_override")"
      local status
      status="$(state_get_status "$key")"

      if ! $FORCE_RERUN && [[ "$status" == "success" ]]; then
        echo "  [SKIP] ${display_name} (${source_type}:${source_ref}) (already successful)"
      else
        echo "  [PROCESS] ${display_name} (${source_type}:${source_ref})${jdk:+ (jdk=$jdk)}${subdir:+ (subdir=$subdir)}${key_override:+ (key=$key_override)}"
      fi
    done
    exit 0
  fi

  local processed=0
  local succeeded=0
  local failed=0
  local skipped=0
  local stopped_early=false

  log_info "Starting main processing loop..."

  for entry in "${repos_to_process[@]}"; do
    log_info "Processing entry: $entry"

    # Check time limit before starting new repo
    if ! should_continue_processing; then
      log_info "Stopped due to time limit - will resume next run"
      stopped_early=true
      break
    fi

    local source_type source_ref jdk subdir key_override name_override
    IFS='|' read -r source_type source_ref jdk subdir key_override name_override <<< "$entry"

    ((++processed))
    log_info "[$processed/$total] Processing..."

    if process_repo "$source_type" "$source_ref" "$jdk" "$subdir" "$key_override" "$name_override"; then
      ((++succeeded))
    else
      local normalized_ref
      normalized_ref="$(normalize_source_ref "$source_type" "$source_ref" "$REPOS_ROOT")"
      local key
      key="$(derive_source_key "$source_type" "$normalized_ref" "$key_override" 2>/dev/null || true)"
      local status
      status="$(state_get_status "$key")"

      if [[ "$status" == "skipped" ]]; then
        ((++skipped))
      else
        ((++failed))
      fi
    fi

    echo ""
  done

  echo ""
  log_info "=========================================="
  if $stopped_early; then
    log_info "Batch Processing Stopped (time limit)"
    log_info "Processed $processed of $total repos before stopping"
  else
    log_info "Batch Processing Complete"
  fi
  log_info "=========================================="
  generate_summary

  # Exit with error if any failed (but not if we just stopped early)
  if [[ $failed -gt 0 ]]; then
    exit 1
  fi
}

# Run main
main "$@"
