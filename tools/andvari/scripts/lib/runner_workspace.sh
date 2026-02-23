#!/usr/bin/env bash

andvari_init_workspace() {
  RUNS_DIR="${ANDVARI_RUNS_DIR:-${ROOT_DIR}/runs}"
  RUN_DIR="${RUNS_DIR}/${RUN_ID}"
  INPUT_DIR="${RUN_DIR}/input"
  NEW_REPO_DIR="${RUN_DIR}/new_repo"
  LOGS_DIR="${RUN_DIR}/logs"
  OUTPUTS_DIR="${RUN_DIR}/outputs"

  if [[ -e "$RUN_DIR" ]]; then
    andvari_fail "Run directory already exists: $RUN_DIR. Use a different --run-id."
  fi

  andvari_require_file "${ROOT_DIR}/AGENTS.md"
  andvari_require_file "${ROOT_DIR}/AGENTS.model.md"
  andvari_require_file "${ROOT_DIR}/AGENTS.fixed.md"
  andvari_require_file "${ROOT_DIR}/gate_recon.sh"
  andvari_require_file "${ROOT_DIR}/gate_hard.sh"
  andvari_require_file "${ROOT_DIR}/scripts/verify_outcome_coverage.sh"
  adapter_check_prereqs "$ADAPTER"

  mkdir -p "$INPUT_DIR" "$NEW_REPO_DIR" "$LOGS_DIR" "$OUTPUTS_DIR" "${NEW_REPO_DIR}/scripts"
  cp "$DIAGRAM_PATH" "${INPUT_DIR}/diagram.puml"
  cp "$AGENTS_TEMPLATE_PATH" "${NEW_REPO_DIR}/AGENTS.md"
  cp "${ROOT_DIR}/gate_recon.sh" "${NEW_REPO_DIR}/gate_recon.sh"
  cp "${ROOT_DIR}/gate_hard.sh" "${NEW_REPO_DIR}/gate_hard.sh"
  cp "${ROOT_DIR}/scripts/verify_outcome_coverage.sh" "${NEW_REPO_DIR}/scripts/verify_outcome_coverage.sh"
  chmod +x "${NEW_REPO_DIR}/gate_recon.sh" "${NEW_REPO_DIR}/gate_hard.sh" "${NEW_REPO_DIR}/scripts/verify_outcome_coverage.sh"
}

andvari_init_artifact_paths() {
  EVENTS_LOG="${LOGS_DIR}/codex_events.jsonl"
  CODEX_STDERR_LOG="${LOGS_DIR}/codex_stderr.log"
  GATE_LOG="${LOGS_DIR}/gate.log"
  LAST_FIXED_GATE_OUTPUT="${LOGS_DIR}/gate_fixed_last.log"
  LAST_HARD_GATE_OUTPUT="${LOGS_DIR}/gate_hard_last.log"
  LAST_MODEL_VERIFY_OUTPUT="${LOGS_DIR}/gate_model_verify_last.log"
  GATE_SUMMARY_FILE="${LOGS_DIR}/gate_summary.txt"
  RUN_REPORT="${OUTPUTS_DIR}/run_report.md"

  touch "$EVENTS_LOG" "$CODEX_STDERR_LOG" "$GATE_LOG"
}
