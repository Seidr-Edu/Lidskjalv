#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TEST_PORT_RUNS_DIR="${TEST_PORT_RUNS_DIR:-${ROOT_DIR}/.data/test-port/runs}"

exec "${ROOT_DIR}/tools/test_port/test-port-run.sh" "$@"
