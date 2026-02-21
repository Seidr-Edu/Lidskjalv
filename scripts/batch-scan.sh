#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"
  set +a
fi

export WORK_DIR="${WORK_DIR:-${ROOT_DIR}/.data/lidskjalv/work}"
export LOG_DIR="${LOG_DIR:-${ROOT_DIR}/.data/lidskjalv/logs}"
export STATE_FILE="${STATE_FILE:-${ROOT_DIR}/.data/lidskjalv/state/scan-state.json}"
export REPOS_ROOT="${REPOS_ROOT:-${ROOT_DIR}}"

exec "${ROOT_DIR}/tools/lidskjalv/scripts/batch-scan.sh" "$@"
