#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/.env"
  set +a
fi

export REPOS_ROOT="${REPOS_ROOT:-${ROOT_DIR}}"

exec "${ROOT_DIR}/tools/lidskjalv/scripts/create-projects.sh" "$@"
