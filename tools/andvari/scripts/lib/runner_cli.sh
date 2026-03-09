#!/usr/bin/env bash
# runner_cli.sh - CLI argument parsing and configuration validation
# Handles command-line option parsing, defaults, and config validation for Andvari runner

andvari_parse_args() {
  DIAGRAM_PATH=""
  RUN_ID=""
  MAX_ITER="8"
  GATING_MODE="${ANDVARI_GATING_MODE:-model}"
  MAX_GATE_REVISIONS="${ANDVARI_MAX_GATE_REVISIONS:-3}"
  MODEL_GATE_TIMEOUT_SEC="${ANDVARI_MODEL_GATE_TIMEOUT_SEC:-120}"
  ADAPTER=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --diagram)
        [[ $# -ge 2 ]] || andvari_fail "--diagram requires a value"
        DIAGRAM_PATH="$2"
        shift 2
        ;;
      --run-id)
        [[ $# -ge 2 ]] || andvari_fail "--run-id requires a value"
        RUN_ID="$2"
        shift 2
        ;;
      --max-iter)
        [[ $# -ge 2 ]] || andvari_fail "--max-iter requires a value"
        MAX_ITER="$2"
        shift 2
        ;;
      --gating-mode)
        [[ $# -ge 2 ]] || andvari_fail "--gating-mode requires a value"
        GATING_MODE="$2"
        shift 2
        ;;
      --max-gate-revisions)
        [[ $# -ge 2 ]] || andvari_fail "--max-gate-revisions requires a value"
        MAX_GATE_REVISIONS="$2"
        shift 2
        ;;
      --model-gate-timeout-sec)
        [[ $# -ge 2 ]] || andvari_fail "--model-gate-timeout-sec requires a value"
        MODEL_GATE_TIMEOUT_SEC="$2"
        shift 2
        ;;
      --adapter)
        [[ $# -ge 2 ]] || andvari_fail "--adapter requires a value"
        ADAPTER="$2"
        shift 2
        ;;
      -h|--help)
        andvari_usage
        exit 0
        ;;
      *)
        andvari_fail "Unknown argument: $1"
        ;;
    esac
  done
}

andvari_validate_config() {
  [[ -n "$DIAGRAM_PATH" ]] || andvari_fail "--diagram is required"
  andvari_require_file "$DIAGRAM_PATH"

  if [[ -z "$RUN_ID" ]]; then
    RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
  fi

  andvari_validate_run_id "$RUN_ID" || andvari_fail "Invalid --run-id '$RUN_ID' (allowed: letters, numbers, ., _, -)"
  [[ "$MAX_ITER" =~ ^[0-9]+$ ]] || andvari_fail "--max-iter must be a non-negative integer"
  [[ "$MAX_GATE_REVISIONS" =~ ^[0-9]+$ ]] || andvari_fail "--max-gate-revisions must be a non-negative integer"
  [[ "$MODEL_GATE_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || andvari_fail "--model-gate-timeout-sec must be a non-negative integer"
  MAX_ITER=$((10#$MAX_ITER))
  MAX_GATE_REVISIONS=$((10#$MAX_GATE_REVISIONS))
  MODEL_GATE_TIMEOUT_SEC=$((10#$MODEL_GATE_TIMEOUT_SEC))

  case "$GATING_MODE" in
    model|fixed)
      ;;
    *)
      andvari_fail "--gating-mode must be one of: model, fixed"
      ;;
  esac

  [[ -n "$ADAPTER" ]] || andvari_fail "--adapter is required"
  if ! adapter_is_supported "$ADAPTER"; then
    andvari_fail "Unsupported adapter: ${ADAPTER}. Supported adapters: $(adapter_list)"
  fi

  if [[ "$GATING_MODE" == "model" ]]; then
    AGENTS_TEMPLATE_PATH="${ROOT_DIR}/AGENTS.model.md"
  else
    AGENTS_TEMPLATE_PATH="${ROOT_DIR}/AGENTS.fixed.md"
  fi
}
