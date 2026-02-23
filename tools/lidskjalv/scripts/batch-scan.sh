#!/usr/bin/env bash
# batch-scan.sh - Main orchestrator for batch scanning
# Processes multiple repositories through the analysis pipeline

set -euo pipefail

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
source "${SCRIPT_DIR}/lib/batch_cli.sh"
source "${SCRIPT_DIR}/lib/batch_repo_selection.sh"
source "${SCRIPT_DIR}/lib/batch_execution.sh"
source "${SCRIPT_DIR}/lib/batch_summary.sh"

resolve_config_paths
batch_init_defaults

main() {
  batch_parse_args "$@"
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

  batch_collect_repos
  local total=${#BATCH_REPOS_TO_PROCESS[@]}
  if [[ "$total" -eq 0 ]]; then
    log_warn "No repository entries to process"
    exit 0
  fi

  log_info "Found $total repositories to process"
  echo ""
  log_info "Time limit: ${WORKFLOW_TIME_LIMIT_MINUTES:-0} minutes"

  if $DRY_RUN; then
    batch_print_dry_run_plan
    exit 0
  fi

  batch_run_loop

  echo ""
  log_info "=========================================="
  if $BATCH_STOPPED_EARLY; then
    log_info "Batch Processing Stopped (time limit)"
    log_info "Processed $BATCH_PROCESSED of $total repos before stopping"
  else
    log_info "Batch Processing Complete"
  fi
  log_info "=========================================="

  batch_generate_summary

  if [[ $BATCH_FAILED -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
