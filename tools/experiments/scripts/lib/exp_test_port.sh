#!/usr/bin/env bash
# exp_test_port.sh - compatibility shim; standalone test-port tool is now used via client.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/exp_test_port_client.sh"
