#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ANDVARI_RUNS_DIR="${ANDVARI_RUNS_DIR:-${ROOT_DIR}/.data/andvari/runs}"

exec "${ROOT_DIR}/tools/andvari/andvari-run.sh" "$@"
