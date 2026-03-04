#!/usr/bin/env bash
# exp_andvari.sh - invoke Andvari generation stage.

set -euo pipefail

exp_run_andvari() {
  ANDVARI_EXIT_CODE=0
  set +e
  "${REPO_ROOT}/andvari-run.sh" \
    --diagram "$DIAGRAM_PATH" \
    --run-id "$RUN_ID" \
    --gating-mode "$GATING_MODE" \
    --max-iter "$MAX_ITER" \
    --max-gate-revisions "$MAX_GATE_REVISIONS" \
    --model-gate-timeout-sec "$MODEL_GATE_TIMEOUT_SEC"
  ANDVARI_EXIT_CODE=$?
  set -e

  ANDVARI_RUN_DIR="${REPO_ROOT}/.data/andvari/runs/${RUN_ID}"
  ANDVARI_NEW_REPO="${ANDVARI_RUN_DIR}/new_repo"
  ANDVARI_RUN_REPORT="${ANDVARI_RUN_DIR}/outputs/run_report.md"
  ANDVARI_RUN_REPORT_JSON="${ANDVARI_RUN_DIR}/outputs/run_report.json"
}
