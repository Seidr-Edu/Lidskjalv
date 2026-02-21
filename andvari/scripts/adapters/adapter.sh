#!/usr/bin/env bash
set -euo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${ADAPTER_DIR}/codex.sh"

adapter_check_prereqs() {
  local adapter="$1"
  case "$adapter" in
    codex)
      codex_check_prereqs
      ;;
    *)
      echo "Unsupported adapter: ${adapter}" >&2
      return 1
      ;;
  esac
}

adapter_run_initial_reconstruction() {
  local adapter="$1"
  shift

  case "$adapter" in
    codex)
      codex_run_initial_reconstruction "$@"
      ;;
    *)
      echo "Unsupported adapter: ${adapter}" >&2
      return 1
      ;;
  esac
}

adapter_run_fix_iteration() {
  local adapter="$1"
  shift

  case "$adapter" in
    codex)
      codex_run_fix_iteration "$@"
      ;;
    *)
      echo "Unsupported adapter: ${adapter}" >&2
      return 1
      ;;
  esac
}

adapter_run_gate_declaration() {
  local adapter="$1"
  shift

  case "$adapter" in
    codex)
      codex_run_gate_declaration "$@"
      ;;
    *)
      echo "Unsupported adapter: ${adapter}" >&2
      return 1
      ;;
  esac
}

adapter_run_implementation_iteration() {
  local adapter="$1"
  shift

  case "$adapter" in
    codex)
      codex_run_implementation_iteration "$@"
      ;;
    *)
      echo "Unsupported adapter: ${adapter}" >&2
      return 1
      ;;
  esac
}
