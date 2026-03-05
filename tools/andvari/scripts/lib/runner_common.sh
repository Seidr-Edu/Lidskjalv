#!/usr/bin/env bash
# runner_common.sh - Shared utilities for Andvari runner
# Provides common helper functions for usage output, error handling, timestamps, validation, and SHA256 computation

andvari_usage() {
  cat <<'USAGE'
Usage:
  ./andvari-run.sh --diagram /path/to/diagram.puml --adapter NAME [--run-id RUN_ID] [--max-iter N] [--gating-mode model|fixed] [--max-gate-revisions N] [--model-gate-timeout-sec N]

Options:
  --diagram                 Path to the PlantUML diagram (.puml). Required.
  --run-id                  Optional run id. Auto-generated (UTC timestamp) if omitted.
  --max-iter                Maximum repair iterations after first implementation attempt. Default: 8.
  --adapter                 Adapter backend. Required.
  --gating-mode             Gating strategy: model (default) or fixed.
  --max-gate-revisions      In model mode, maximum revisions after gates.v1 (default: 3).
  --model-gate-timeout-sec  In model mode, timeout for completion/run_all_gates.sh replay (default: 120).
  -h, --help                Show this help.
USAGE
}

andvari_fail() {
  echo "error: $*" >&2
  exit 1
}

andvari_timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

andvari_validate_run_id() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
}

andvari_require_file() {
  local path="$1"
  [[ -f "$path" ]] || andvari_fail "File not found: $path"
}

andvari_compute_sha256() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi

  andvari_fail "Neither sha256sum nor shasum is available"
}
