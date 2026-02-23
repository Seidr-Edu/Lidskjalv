#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_LIB="${ROOT_DIR}/scripts/adapters/adapter.sh"

if [[ ! -f "$ADAPTER_LIB" ]]; then
  echo "error: Missing adapter library: $ADAPTER_LIB" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$ADAPTER_LIB"
source "${ROOT_DIR}/scripts/lib/runner_common.sh"
source "${ROOT_DIR}/scripts/lib/runner_cli.sh"
source "${ROOT_DIR}/scripts/lib/runner_workspace.sh"
source "${ROOT_DIR}/scripts/lib/runner_gates.sh"
source "${ROOT_DIR}/scripts/lib/runner_flows.sh"
source "${ROOT_DIR}/scripts/lib/runner_report.sh"

main() {
  andvari_parse_args "$@"
  andvari_validate_config

  andvari_init_workspace
  andvari_init_artifact_paths

  START_TIME="$(andvari_timestamp_utc)"
  START_EPOCH="$(date -u +%s)"
  STATUS="failed"
  REPAIR_ITERATIONS_USED=0
  ADAPTER_FAILURES=0

  echo "[andvari] run id: ${RUN_ID}"
  echo "[andvari] run dir: ${RUN_DIR}"
  echo "[andvari] adapter: ${ADAPTER}"
  echo "[andvari] gating mode: ${GATING_MODE}"
  echo "[andvari] agents template: ${AGENTS_TEMPLATE_PATH}"

  if [[ "$GATING_MODE" == "fixed" ]]; then
    andvari_execute_fixed_flow
  else
    andvari_execute_model_flow
  fi

  andvari_write_run_report
  andvari_print_final_status_and_exit
}

main "$@"
