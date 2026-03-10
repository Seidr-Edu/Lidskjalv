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

  local repo_root="${LIDSKJALV_ROOT:-$project_root}"

  export LIDSKJALV_ROOT="$repo_root"
  export LIDSKJALV_MONOREPO_ROOT="${LIDSKJALV_MONOREPO_ROOT:-$repo_root}"
  export LIDSKJALV_DATA_DIR="${LIDSKJALV_DATA_DIR:-${repo_root}/.data/lidskjalv}"

  export WORK_DIR="${WORK_DIR:-${LIDSKJALV_DATA_DIR}/work}"
  export LOG_DIR="${LOG_DIR:-${LIDSKJALV_DATA_DIR}/logs}"
  export STATE_FILE="${STATE_FILE:-${LIDSKJALV_DATA_DIR}/state/scan-state.json}"
  export REPOS_ROOT="${REPOS_ROOT:-${repo_root}}"

  if [[ "${LIDSKJALV_SKIP_ENV_LOAD:-false}" != "true" ]]; then
    # Load environment from the first matching candidate.
    local -a env_candidates=()
    if [[ -n "${LIDSKJALV_ENV_FILE:-}" ]]; then
      env_candidates+=("${LIDSKJALV_ENV_FILE}")
    fi
    env_candidates+=(
      "${original_cwd}/.env"
      "${repo_root}/.env"
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
  fi
}
