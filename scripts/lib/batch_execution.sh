#!/usr/bin/env bash
# batch_execution.sh - Main processing loop and time-limit checks
# Orchestrates per-repository processing with workflow time-limit enforcement

WORKFLOW_START_TIME=""
WORKFLOW_TIME_LIMIT_MINUTES=${WORKFLOW_TIME_LIMIT_MINUTES:-0}

batch_init_timer() {
  WORKFLOW_START_TIME=$(date +%s)
}

batch_should_continue_processing() {
  if [[ "$WORKFLOW_TIME_LIMIT_MINUTES" -eq 0 ]]; then
    return 0
  fi

  if [[ -z "${WORKFLOW_START_TIME:-}" ]]; then
    batch_init_timer
  fi

  local current_time
  current_time=$(date +%s)
  local time_limit_seconds=$((WORKFLOW_TIME_LIMIT_MINUTES * 60))
  local elapsed=$((current_time - WORKFLOW_START_TIME))
  local remaining=$((time_limit_seconds - elapsed))

  log_info "Time check: start=$WORKFLOW_START_TIME, now=$current_time, elapsed=${elapsed}s, remaining=${remaining}s"

  if [[ $remaining -lt 600 ]]; then
    log_warn "Time limit approaching (${remaining}s remaining)"
    log_warn "Stopping gracefully - incomplete repos will retry next run"
    return 1
  fi

  return 0
}

batch_process_repo_entry() {
  local entry="$1"
  local source_type source_ref jdk_hint subdir_hint key_override name_override

  IFS='|' read -r source_type source_ref jdk_hint subdir_hint key_override name_override <<< "$entry"

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

  if $CLEANUP_AFTER; then
    source_cleanup "$source_type" "$key"
  fi

  log_success "Successfully processed: $display_name"
  return 0
}

batch_run_loop() {
  local total=${#BATCH_REPOS_TO_PROCESS[@]}
  local entry source_type source_ref _jdk _subdir key_override name_override

  # shellcheck disable=SC2034  # Read by batch-scan.sh after this loop completes.
  BATCH_PROCESSED=0
  BATCH_SUCCEEDED=0
  BATCH_FAILED=0
  BATCH_SKIPPED=0
  BATCH_STOPPED_EARLY=false

  batch_init_timer
  log_info "Starting main processing loop..."

  for entry in "${BATCH_REPOS_TO_PROCESS[@]}"; do
    log_info "Processing entry: $entry"

    if ! batch_should_continue_processing; then
      log_info "Stopped due to time limit - will resume next run"
      # shellcheck disable=SC2034  # Read by batch-scan.sh after the loop exits.
      BATCH_STOPPED_EARLY=true
      break
    fi

    IFS='|' read -r source_type source_ref _jdk _subdir key_override name_override <<< "$entry"

    ((++BATCH_PROCESSED))
    log_info "[$BATCH_PROCESSED/$total] Processing..."

    if batch_process_repo_entry "$entry"; then
      ((++BATCH_SUCCEEDED))
    else
      local normalized_ref
      normalized_ref="$(normalize_source_ref "$source_type" "$source_ref" "$REPOS_ROOT")"
      local key
      key="$(derive_source_key "$source_type" "$normalized_ref" "$key_override" 2>/dev/null || true)"
      local status
      status="$(state_get_status "$key")"

      if [[ "$status" == "skipped" ]]; then
        ((++BATCH_SKIPPED))
      else
        ((++BATCH_FAILED))
      fi
    fi

    echo ""
  done
}
