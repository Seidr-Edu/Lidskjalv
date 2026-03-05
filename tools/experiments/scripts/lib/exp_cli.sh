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
  --runs-root <path>
  --gating-mode <model|fixed>
  --max-iter <n>
  --adapter <codex|claude>            (required)
  --max-gate-revisions <n>
  --model-gate-timeout-sec <n>
  --scan-original <auto|force|skip>   (default: auto)
  --skip-sonar
  --sonar-wait <on|off>               (default: on)
  --sonar-wait-timeout-sec <n>        (default: 300)
  --sonar-wait-poll-sec <n>           (default: 5)
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
  EXPERIMENT_RUNS_ROOT="${EXPERIMENT_RUNS_ROOT:-}"
  GATING_MODE="model"
  MAX_ITER="8"
  ADAPTER=""
  MAX_GATE_REVISIONS="3"
  MODEL_GATE_TIMEOUT_SEC="120"
  SCAN_ORIGINAL_MODE="auto"
  SKIP_SONAR=false
  SONAR_WAIT="on"
  SONAR_WAIT_TIMEOUT_SEC="300"
  SONAR_WAIT_POLL_SEC="5"
  TEST_PORT_MODE="on"
  TEST_PORT_MAX_ITER="5"
  STRICT_TEST_PORT=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --diagram) DIAGRAM_PATH="${2:-}"; shift 2 ;;
      --source-repo) SOURCE_REPO_RAW="${2:-}"; shift 2 ;;
      --source-subdir) SOURCE_SUBDIR="${2:-}"; shift 2 ;;
      --run-id) RUN_ID="${2:-}"; shift 2 ;;
      --runs-root) EXPERIMENT_RUNS_ROOT="${2:-}"; shift 2 ;;
      --gating-mode) GATING_MODE="${2:-}"; shift 2 ;;
      --max-iter) MAX_ITER="${2:-}"; shift 2 ;;
      --adapter) ADAPTER="${2:-}"; shift 2 ;;
      --max-gate-revisions) MAX_GATE_REVISIONS="${2:-}"; shift 2 ;;
      --model-gate-timeout-sec) MODEL_GATE_TIMEOUT_SEC="${2:-}"; shift 2 ;;
      --scan-original) SCAN_ORIGINAL_MODE="${2:-}"; shift 2 ;;
      --skip-sonar) SKIP_SONAR=true; shift ;;
      --sonar-wait) SONAR_WAIT="${2:-}"; shift 2 ;;
      --sonar-wait-timeout-sec) SONAR_WAIT_TIMEOUT_SEC="${2:-}"; shift 2 ;;
      --sonar-wait-poll-sec) SONAR_WAIT_POLL_SEC="${2:-}"; shift 2 ;;
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

  if [[ -z "$EXPERIMENT_RUNS_ROOT" ]]; then
    EXPERIMENT_RUNS_ROOT="${REPO_ROOT}/.data/experiments/runs"
  fi

  case "$GATING_MODE" in model|fixed) ;; *) exp_fail "--gating-mode must be model|fixed";; esac
  case "$SCAN_ORIGINAL_MODE" in auto|force|skip) ;; *) exp_fail "--scan-original must be auto|force|skip";; esac
  case "$SONAR_WAIT" in on|off) ;; *) exp_fail "--sonar-wait must be on|off";; esac
  case "$TEST_PORT_MODE" in on|off) ;; *) exp_fail "--test-port must be on|off";; esac

  [[ "$MAX_ITER" =~ ^[0-9]+$ ]] || exp_fail "--max-iter must be non-negative integer"
  [[ -n "$ADAPTER" ]] || exp_fail "--adapter is required"
  case "$ADAPTER" in codex|claude) ;; *) exp_fail "--adapter must be codex|claude" ;; esac
  [[ "$MAX_GATE_REVISIONS" =~ ^[0-9]+$ ]] || exp_fail "--max-gate-revisions must be non-negative integer"
  [[ "$MODEL_GATE_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || exp_fail "--model-gate-timeout-sec must be non-negative integer"
  [[ "$SONAR_WAIT_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || exp_fail "--sonar-wait-timeout-sec must be non-negative integer"
  [[ "$SONAR_WAIT_POLL_SEC" =~ ^[0-9]+$ ]] || exp_fail "--sonar-wait-poll-sec must be non-negative integer"
  [[ "$SONAR_WAIT_POLL_SEC" -gt 0 ]] || exp_fail "--sonar-wait-poll-sec must be > 0"
  [[ "$TEST_PORT_MAX_ITER" =~ ^[0-9]+$ ]] || exp_fail "--test-port-max-iter must be non-negative integer"
  [[ -n "$EXPERIMENT_RUNS_ROOT" ]] || exp_fail "--runs-root must not be empty"
}
