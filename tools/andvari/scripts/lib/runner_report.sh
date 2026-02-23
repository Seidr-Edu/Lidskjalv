#!/usr/bin/env bash
# runner_report.sh - Run report generation and final exit handling
# Creates markdown run reports and prints final status messages

andvari_write_run_report() {
  END_TIME="$(andvari_timestamp_utc)"
  END_EPOCH="$(date -u +%s)"
  DURATION_SECONDS=$((END_EPOCH - START_EPOCH))
  LATEST_GATE_VERSION="$(andvari_latest_gate_version)"

  cat > "$RUN_REPORT" <<REPORT_EOF
# Run Report

- Run ID: \`${RUN_ID}\`
- Adapter: \`${ADAPTER}\`
- Diagram: \`runs/${RUN_ID}/input/diagram.puml\`
- Gating Mode: \`${GATING_MODE}\`
- AGENTS Template: \`${AGENTS_TEMPLATE_PATH##*/}\`
- Status: \`${STATUS}\`
- Max Repair Iterations: \`${MAX_ITER}\`
- Repair Iterations Used: \`${REPAIR_ITERATIONS_USED}\`
- Max Gate Revisions: \`${MAX_GATE_REVISIONS}\`
- Model Gate Timeout (seconds): \`${MODEL_GATE_TIMEOUT_SEC}\`
- Latest Gate Version Observed: \`${LATEST_GATE_VERSION}\`
- Adapter Non-zero Runs: \`${ADAPTER_FAILURES}\`
- Started (UTC): \`${START_TIME}\`
- Finished (UTC): \`${END_TIME}\`
- Duration (seconds): \`${DURATION_SECONDS}\`

## Artifacts

- Codex events log: \`runs/${RUN_ID}/logs/codex_events.jsonl\`
- Codex stderr log: \`runs/${RUN_ID}/logs/codex_stderr.log\`
- Gate log: \`runs/${RUN_ID}/logs/gate.log\`
- Report: \`runs/${RUN_ID}/outputs/run_report.md\`
REPORT_EOF
}

andvari_print_final_status_and_exit() {
  if [[ "$STATUS" == "passed" ]]; then
    echo "[andvari] status: PASS"
    echo "[andvari] run folder: ${RUN_DIR}"
    exit 0
  fi

  echo "[andvari] status: FAIL"
  echo "[andvari] run folder: ${RUN_DIR}"
  echo "[andvari] see logs: ${GATE_LOG}, ${CODEX_STDERR_LOG}, ${EVENTS_LOG}"
  exit 1
}
