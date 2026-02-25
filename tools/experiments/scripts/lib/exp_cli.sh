#!/usr/bin/env bash
# exp_cli.sh - CLI parsing and validation.

set -euo pipefail

exp_usage() {
  cat <<USAGE
Usage: ./experiment-run.sh --diagram <path> --source-repo <ref> [options]

Options:
  --diagram <path>
  --source-repo <https://...\|url:https://...\|path:/path\>
  --source-subdir <path>
  --run-id <id>
  --gating-mode <model|fixed>
  --max-iter <n>
  --max-gate-revisions <n>
  --model-gate-timeout-sec <n>
  --scan-original <auto|force|skip>   (default: auto)
  --skip-sonar
  --test-port <on|off>                (default: on)
  --test-port-max-iter <n>            (default: 5)
  --strict-test-port
  -h, --help
USAGE
}

exp_parse_args() {
  DIAGRAM_PATH=""
  SOURCE_REPO_RAW=""
  SOURCE_SUBDIR=""
  RUN_ID=""
  GATING_MODE="model"
  MAX_ITER="8"
  MAX_GATE_REVISIONS="3"
  MODEL_GATE_TIMEOUT_SEC="120"
  SCAN_ORIGINAL_MODE="auto"
  SKIP_SONAR=false
  TEST_PORT_MODE="on"
  TEST_PORT_MAX_ITER="5"
  STRICT_TEST_PORT=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --diagram) DIAGRAM_PATH="${2:-}"; shift 2 ;;
      --source-repo) SOURCE_REPO_RAW="${2:-}"; shift 2 ;;
      --source-subdir) SOURCE_SUBDIR="${2:-}"; shift 2 ;;
      --run-id) RUN_ID="${2:-}"; shift 2 ;;
      --gating-mode) GATING_MODE="${2:-}"; shift 2 ;;
      --max-iter) MAX_ITER="${2:-}"; shift 2 ;;
      --max-gate-revisions) MAX_GATE_REVISIONS="${2:-}"; shift 2 ;;
      --model-gate-timeout-sec) MODEL_GATE_TIMEOUT_SEC="${2:-}"; shift 2 ;;
      --scan-original) SCAN_ORIGINAL_MODE="${2:-}"; shift 2 ;;
      --skip-sonar) SKIP_SONAR=true; shift ;;
      --test-port) TEST_PORT_MODE="${2:-}"; shift 2 ;;
      --test-port-max-iter) TEST_PORT_MAX_ITER="${2:-}"; shift 2 ;;
      --strict-test-port) STRICT_TEST_PORT=true; shift ;;
      -h|--help) exp_usage; exit 0 ;;
      *) exp_fail "Unknown argument: $1" ;;
    esac
  done
}

exp_validate_args() {
  [[ -n "$DIAGRAM_PATH" ]] || exp_fail "--diagram is required"
  [[ -f "$DIAGRAM_PATH" ]] || exp_fail "diagram not found: $DIAGRAM_PATH"
  [[ -n "$SOURCE_REPO_RAW" ]] || exp_fail "--source-repo is required"

  case "$GATING_MODE" in model|fixed) ;; *) exp_fail "--gating-mode must be model|fixed";; esac
  case "$SCAN_ORIGINAL_MODE" in auto|force|skip) ;; *) exp_fail "--scan-original must be auto|force|skip";; esac
  case "$TEST_PORT_MODE" in on|off) ;; *) exp_fail "--test-port must be on|off";; esac

  [[ "$MAX_ITER" =~ ^[0-9]+$ ]] || exp_fail "--max-iter must be non-negative integer"
  [[ "$MAX_GATE_REVISIONS" =~ ^[0-9]+$ ]] || exp_fail "--max-gate-revisions must be non-negative integer"
  [[ "$MODEL_GATE_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || exp_fail "--model-gate-timeout-sec must be non-negative integer"
  [[ "$TEST_PORT_MAX_ITER" =~ ^[0-9]+$ ]] || exp_fail "--test-port-max-iter must be non-negative integer"
}
