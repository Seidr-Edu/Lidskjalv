#!/usr/bin/env bash
# bootstrap.sh - Unified runtime/env bootstrap for Lidskjalv entrypoints

[[ -n "${_LIDSKJALV_BOOTSTRAP_SH_LOADED:-}" ]] && return 0
_LIDSKJALV_BOOTSTRAP_SH_LOADED=1

# Bootstrap runtime environment.
# Usage: lidskjalv_bootstrap [project_root] [original_cwd]
lidskjalv_bootstrap() {
  local project_root_input="${1:-}"
  local original_cwd_input="${2:-}"

  local project_root="$project_root_input"
  if [[ -z "$project_root" ]]; then
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    project_root="$(cd "${lib_dir}/../.." && pwd)"
  fi

  local original_cwd="$original_cwd_input"
  if [[ -z "$original_cwd" ]]; then
    original_cwd="$(pwd)"
  fi

  local monorepo_root="${LIDSKJALV_MONOREPO_ROOT:-}"
  if [[ -z "$monorepo_root" ]]; then
    local candidate
    candidate="$(cd "${project_root}/../.." 2>/dev/null && pwd -P || true)"
    if [[ -n "$candidate" && -d "${candidate}/tools/lidskjalv" ]]; then
      monorepo_root="$candidate"
    else
      monorepo_root="$project_root"
    fi
  fi

  export LIDSKJALV_MONOREPO_ROOT="$monorepo_root"
  export LIDSKJALV_DATA_DIR="${LIDSKJALV_DATA_DIR:-${monorepo_root}/.data/lidskjalv}"

  export WORK_DIR="${WORK_DIR:-${LIDSKJALV_DATA_DIR}/work}"
  export LOG_DIR="${LOG_DIR:-${LIDSKJALV_DATA_DIR}/logs}"
  export STATE_FILE="${STATE_FILE:-${LIDSKJALV_DATA_DIR}/state/scan-state.json}"
  export REPOS_ROOT="${REPOS_ROOT:-${monorepo_root}}"

  # Load environment from the first matching candidate.
  local -a env_candidates=()
  if [[ -n "${LIDSKJALV_ENV_FILE:-}" ]]; then
    env_candidates+=("${LIDSKJALV_ENV_FILE}")
  fi
  env_candidates+=(
    "${original_cwd}/.env"
    "${monorepo_root}/.env"
    "${project_root}/.env"
  )

  local env_candidate
  for env_candidate in "${env_candidates[@]}"; do
    [[ -f "$env_candidate" ]] || continue
    set -a
    # shellcheck source=/dev/null
    source "$env_candidate"
    set +a
    export LIDSKJALV_ENV_LOADED_FROM="$env_candidate"
    break
  done
}
