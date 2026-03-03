#!/usr/bin/env bash
# refresh-sonar-metadata.sh - backfill Sonar measures into experiment JSON outputs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TOOLS_DIR}/../.." && pwd)"
ORIGINAL_CWD="$(pwd)"

source "${REPO_ROOT}/tools/lidskjalv/scripts/lib/bootstrap.sh"
lidskjalv_bootstrap "${REPO_ROOT}/tools/lidskjalv" "$ORIGINAL_CWD"

usage() {
  cat <<'USAGE'
Usage: ./refresh-sonar-metadata.sh [options]

Options:
  --runs-root <path>              Root containing experiment run directories
                                  (default: .data/experiments/runs)
  --run-id <id>                   Refresh a single run ID
  --sonar-wait <on|off>           Wait for CE task completion before fetching (default: on)
  --sonar-wait-timeout-sec <n>    Max wait time per scan (default: 300)
  --sonar-wait-poll-sec <n>       Poll interval in seconds (default: 5)
  --dry-run                       Print what would be changed without writing files
  -h, --help                      Show this help
USAGE
}

log_info() { printf '[exp-refresh][INFO] %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; }
log_warn() { printf '[exp-refresh][WARN] %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; }
log_err() { printf '[exp-refresh][ERROR] %s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*" >&2; }
fail() { log_err "$*"; exit 1; }

abs_path() {
  python3 - <<'PY' "$1"
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

sonar_get_task_status() {
  local task_id="$1"
  local response
  response="$(curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/ce/task?id=${task_id}" 2>/dev/null || true)"
  if [[ -z "$response" ]]; then
    echo "UNKNOWN"
    return 0
  fi
  echo "$response" | jq -r '.task.status // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN"
}

sonar_wait_task() {
  local task_id="$1"
  local timeout_sec="$2"
  local poll_sec="$3"

  local elapsed=0
  local status="UNKNOWN"
  while true; do
    status="$(sonar_get_task_status "$task_id")"
    case "$status" in
      SUCCESS|FAILED|CANCELED)
        echo "$status"
        return 0
        ;;
    esac

    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      echo "TIMEOUT"
      return 1
    fi

    sleep "$poll_sec"
    elapsed=$((elapsed + poll_sec))
  done
}

fetch_measures_json() {
  local project_key="$1"
  local metric_keys
  metric_keys="${EXP_SONAR_METRIC_KEYS:-bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density,reliability_rating,security_rating,sqale_rating,ncloc,sqale_index}"
  curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/measures/component?component=${project_key}&metricKeys=${metric_keys}" \
    2>/dev/null \
    | jq -c 'reduce (.component.measures // [])[] as $m ({}; .[$m.metric]=$m.value)' 2>/dev/null || echo "{}"
}

lookup_task_id_from_state() {
  local project_key="$1"
  if [[ ! -f "${STATE_FILE:-}" ]]; then
    echo ""
    return 0
  fi
  jq -r --arg key "$project_key" '.repositories[$key].sonar_task_id // empty' "$STATE_FILE" 2>/dev/null || true
}

update_scan_section() {
  local json_path="$1"
  local section="$2"
  local project_key="$3"
  local task_id="$4"
  local ce_status="$5"
  local data_status="$6"
  local measures_json="$7"

  local tmp
  tmp="$(mktemp)"
  jq \
    --arg section "$section" \
    --arg sonar_url "${SONAR_HOST_URL}/dashboard?id=${project_key}" \
    --arg task_id "$task_id" \
    --arg ce_status "$ce_status" \
    --arg data_status "$data_status" \
    --argjson measures "$measures_json" \
    '
    .scans[$section].sonar_url = $sonar_url |
    .scans[$section].sonar_task_id = $task_id |
    .scans[$section].ce_task_status = $ce_status |
    .scans[$section].scan_data_status = $data_status |
    .scans[$section].measures = $measures
    ' \
    "$json_path" > "$tmp"
  mv "$tmp" "$json_path"
}

refresh_scan_section() {
  local json_path="$1"
  local section="$2"

  local project_key
  project_key="$(jq -r --arg section "$section" '.scans[$section].project_key // empty' "$json_path")"

  if [[ -z "$project_key" ]]; then
    return 0
  fi

  local task_id ce_status measures_json data_status
  task_id="$(jq -r --arg section "$section" '.scans[$section].sonar_task_id // empty' "$json_path")"
  if [[ -z "$task_id" ]]; then
    task_id="$(lookup_task_id_from_state "$project_key")"
  fi

  ce_status=""
  if [[ -n "$task_id" ]]; then
    if [[ "$SONAR_WAIT" == "on" ]]; then
      ce_status="$(sonar_wait_task "$task_id" "$SONAR_WAIT_TIMEOUT_SEC" "$SONAR_WAIT_POLL_SEC" || true)"
    else
      ce_status="$(sonar_get_task_status "$task_id")"
    fi
  fi

  measures_json="$(fetch_measures_json "$project_key")"
  if [[ "$measures_json" != "{}" ]]; then
    data_status="complete"
  else
    case "$ce_status" in
      PENDING|IN_PROGRESS|TIMEOUT) data_status="pending" ;;
      FAILED|CANCELED) data_status="failed" ;;
      *) data_status="unavailable" ;;
    esac
  fi

  if $DRY_RUN; then
    log_info "dry-run ${json_path} scans.${section}: key=${project_key} task=${task_id:-<none>} ce=${ce_status:-<none>} data=${data_status} measures=${measures_json}"
    return 0
  fi

  update_scan_section "$json_path" "$section" "$project_key" "$task_id" "$ce_status" "$data_status" "$measures_json"
  log_info "updated ${json_path} scans.${section}: key=${project_key} task=${task_id:-<none>} ce=${ce_status:-<none>} data=${data_status}"
}

RUNS_ROOT="${REPO_ROOT}/.data/experiments/runs"
RUN_ID=""
SONAR_WAIT="on"
SONAR_WAIT_TIMEOUT_SEC="300"
SONAR_WAIT_POLL_SEC="5"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs-root) RUNS_ROOT="${2:-}"; shift 2 ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    --sonar-wait) SONAR_WAIT="${2:-}"; shift 2 ;;
    --sonar-wait-timeout-sec) SONAR_WAIT_TIMEOUT_SEC="${2:-}"; shift 2 ;;
    --sonar-wait-poll-sec) SONAR_WAIT_POLL_SEC="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$SONAR_WAIT" in
  on|off) ;;
  *) fail "--sonar-wait must be on|off" ;;
esac
[[ "$SONAR_WAIT_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || fail "--sonar-wait-timeout-sec must be non-negative integer"
[[ "$SONAR_WAIT_POLL_SEC" =~ ^[0-9]+$ ]] || fail "--sonar-wait-poll-sec must be non-negative integer"
[[ "$SONAR_WAIT_POLL_SEC" -gt 0 ]] || fail "--sonar-wait-poll-sec must be > 0"

RUNS_ROOT="$(abs_path "$RUNS_ROOT")"

require_cmd jq
require_cmd curl
require_cmd python3
[[ -n "${SONAR_HOST_URL:-}" ]] || fail "SONAR_HOST_URL is required"
[[ -n "${SONAR_TOKEN:-}" ]] || fail "SONAR_TOKEN is required"

if [[ -n "$RUN_ID" ]]; then
  json_path="${RUNS_ROOT}/${RUN_ID}/outputs/experiment.json"
  [[ -f "$json_path" ]] || fail "experiment json not found for run-id ${RUN_ID}: ${json_path}"
  refresh_scan_section "$json_path" "original"
  refresh_scan_section "$json_path" "generated"
  exit 0
fi

if [[ ! -d "$RUNS_ROOT" ]]; then
  fail "runs root not found: ${RUNS_ROOT}"
fi

count=0
while IFS= read -r json_path; do
  [[ -n "$json_path" ]] || continue
  refresh_scan_section "$json_path" "original"
  refresh_scan_section "$json_path" "generated"
  count=$((count + 1))
done < <(find "$RUNS_ROOT" -type f -path '*/outputs/experiment.json' | LC_ALL=C sort)

log_info "processed experiment json files: ${count}"
