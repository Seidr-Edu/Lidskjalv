#!/usr/bin/env bash
# batch_summary.sh - Post-run summary generation
# Creates timestamped summary files with success/failure/skipped repository lists

batch_generate_summary() {
  local summary_file=""
  summary_file="${LOG_DIR}/summary-$(date +%Y%m%d-%H%M%S).txt"

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
