#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for test_file in \
  "${ROOT_DIR}/tests/test_cli.sh" \
  "${ROOT_DIR}/tests/test_coverage.sh" \
  "${ROOT_DIR}/tests/test_service.sh" \
  "${ROOT_DIR}/tests/test_service_reports.sh"; do
  printf 'Running %s\n' "$(basename "$test_file")"
  bash "$test_file"
done
