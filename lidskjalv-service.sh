#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_CWD="$(pwd)"
export LIDSKJALV_SKIP_ENV_LOAD=true

# shellcheck source=/dev/null
source "${ROOT_DIR}/scripts/lib/bootstrap.sh"
lidskjalv_bootstrap "$ROOT_DIR" "$ORIGINAL_CWD"

source "${ROOT_DIR}/scripts/lib/common.sh"
source "${ROOT_DIR}/scripts/lib/state.sh"
source "${ROOT_DIR}/scripts/lib/pipeline.sh"
source "${ROOT_DIR}/scripts/lib/submit-sonar.sh"

LIDSKJALV_SERVICE_SCHEMA_VERSION="lidskjalv_service_report.v1"
LIDSKJALV_SERVICE_RUN_ID=""
LIDSKJALV_SERVICE_STATUS="error"
LIDSKJALV_SERVICE_FAILURE_SCOPE="service"
LIDSKJALV_SERVICE_REASON="unknown"
LIDSKJALV_SERVICE_STATUS_DETAIL=""
LIDSKJALV_SERVICE_SCAN_LABEL=""
LIDSKJALV_SERVICE_PROJECT_KEY=""
LIDSKJALV_SERVICE_PROJECT_NAME=""
LIDSKJALV_SERVICE_INPUT_REPO=""
LIDSKJALV_SERVICE_INPUT_SUBDIR=""
LIDSKJALV_SERVICE_RUN_DIR=""
LIDSKJALV_SERVICE_SCAN_DIR=""
LIDSKJALV_SERVICE_LOGS_DIR=""
LIDSKJALV_SERVICE_WORKSPACE_DIR=""
LIDSKJALV_SERVICE_WORKSPACE_REPO=""
LIDSKJALV_SERVICE_METADATA_DIR=""
LIDSKJALV_SERVICE_OUTPUT_DIR=""
LIDSKJALV_SERVICE_STARTED_AT=""
LIDSKJALV_SERVICE_FINISHED_AT=""
LIDSKJALV_SERVICE_REPORT_PATH=""
LIDSKJALV_SERVICE_SUMMARY_PATH=""
LIDSKJALV_SERVICE_SCAN_BUILD_TOOL=""
LIDSKJALV_SERVICE_SCAN_BUILD_JDK=""
LIDSKJALV_SERVICE_SCAN_BUILD_SUBDIR=""
LIDSKJALV_SERVICE_SCAN_JAVA_VERSION_HINT=""
LIDSKJALV_SERVICE_SCAN_ATTEMPTED_JDKS_CSV=""
LIDSKJALV_SERVICE_SONAR_TASK_ID=""
LIDSKJALV_SERVICE_CE_TASK_STATUS=""
LIDSKJALV_SERVICE_QUALITY_GATE_STATUS=""
LIDSKJALV_SERVICE_DATA_STATUS="unavailable"
LIDSKJALV_SERVICE_MEASURES_JSON="{}"

lidskjalv_service_usage() {
  cat <<'EOF'
Usage: lidskjalv-service.sh

Container contract:
  Read-only:
    /input/repo
    /run/config
  Writable:
    /run

Environment:
  LIDSKJALV_MANIFEST                 Optional manifest path override (default: /run/config/manifest.yaml)
  LIDSKJALV_INPUT_REPO               Optional input repo override (default: /input/repo)
  LIDSKJALV_RUN_DIR                  Optional run dir override (default: /run)
  SONAR_HOST_URL                     Required when skip_sonar=false
  SONAR_TOKEN                        Required when skip_sonar=false
  SONAR_ORGANIZATION                 Required when skip_sonar=false

Service scan config is manifest-owned in container mode. Manifest fields are
not overridden from environment variables.

Manifest v1 YAML fields:
  version
  run_id
  scan_label
  project_key
  project_name
  repo_subdir
  skip_sonar
EOF
}

lidskjalv_service_timestamp_compact_utc() {
  date -u +"%Y%m%dT%H%M%SZ"
}

lidskjalv_service_abs_path() {
  local raw="$1"
  if [[ "$raw" = /* ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s/%s\n' "$ROOT_DIR" "$raw"
  fi
}

lidskjalv_service_normalize_rel_path() {
  local raw="$1"
  [[ -n "$raw" ]] || return 1
  [[ "$raw" != /* ]] || return 1
  [[ "$raw" != *:* ]] || return 1

  while [[ "$raw" == ./* ]]; do
    raw="${raw#./}"
  done

  raw="$(printf '%s' "$raw" | sed -E 's#/+#/#g')"

  while [[ "$raw" == */ ]]; do
    raw="${raw%/}"
  done

  [[ -n "$raw" ]] || return 1
  case "$raw" in
    .|..|../*|*/..|*/../*|./*|*/.|*/./*)
      return 1
      ;;
  esac

  printf '%s\n' "$raw"
}

lidskjalv_service_load_manifest() {
  local manifest_path="$1"
  python3 - <<'PY' "$manifest_path"
import json
import re
import shlex
import sys

path = sys.argv[1]

try:
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read()
except Exception as exc:
    print(f"invalid manifest YAML: {exc}", file=sys.stderr)
    raise SystemExit(1)

try:
    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        def parse_scalar(raw_value):
            value = raw_value.strip()
            if not value or value in {"null", "~"}:
                return None
            if value.startswith('"'):
                closing = 1
                escaped = False
                while closing < len(value):
                    char = value[closing]
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == '"':
                        break
                    closing += 1
                if closing >= len(value) or value[closing] != '"':
                    print("invalid manifest YAML quoted string", file=sys.stderr)
                    raise SystemExit(1)
                remainder = value[closing + 1 :].strip()
                if remainder and not remainder.startswith("#"):
                    print("invalid manifest YAML quoted string suffix", file=sys.stderr)
                    raise SystemExit(1)
                return json.loads(value[: closing + 1])
            if value.startswith("'"):
                closing = 1
                while closing < len(value):
                    if value[closing] == "'":
                        if closing + 1 < len(value) and value[closing + 1] == "'":
                            closing += 2
                            continue
                        break
                    closing += 1
                if closing >= len(value) or value[closing] != "'":
                    print("invalid manifest YAML quoted string", file=sys.stderr)
                    raise SystemExit(1)
                remainder = value[closing + 1 :].strip()
                if remainder and not remainder.startswith("#"):
                    print("invalid manifest YAML quoted string suffix", file=sys.stderr)
                    raise SystemExit(1)
                return value[1:closing].replace("''", "'")
            if value == "true":
                return True
            if value == "false":
                return False
            if re.fullmatch(r"[0-9]+", value):
                return int(value)
            for index, char in enumerate(value):
                if char == "#" and (index == 0 or value[index - 1].isspace()):
                    value = value[:index].rstrip()
                    break
            return value

        obj = {}
        for line_no, line in enumerate(raw.splitlines(), start=1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if line != line.lstrip(" \t"):
                print(f"manifest YAML only supports top-level keys (line {line_no})", file=sys.stderr)
                raise SystemExit(1)
            if ":" not in line:
                print(f"invalid manifest YAML line {line_no}: expected key: value", file=sys.stderr)
                raise SystemExit(1)
            key, value = line.split(":", 1)
            key = key.strip()
            if not key:
                print(f"invalid manifest YAML line {line_no}: missing key", file=sys.stderr)
                raise SystemExit(1)
            if key in obj:
                print(f"duplicate manifest field: {key}", file=sys.stderr)
                raise SystemExit(1)
            obj[key] = parse_scalar(value)
except Exception as exc:
    print(f"invalid manifest YAML: {exc}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(obj, dict):
    print("manifest must be a YAML mapping", file=sys.stderr)
    raise SystemExit(1)

allowed = {
    "version",
    "run_id",
    "scan_label",
    "project_key",
    "project_name",
    "repo_subdir",
    "skip_sonar",
    "sonar_wait_timeout_sec",
    "sonar_wait_poll_sec",
}

unknown = sorted(set(obj.keys()) - allowed)
if unknown:
    print(f"unknown manifest fields: {', '.join(unknown)}", file=sys.stderr)
    raise SystemExit(1)

version = obj.get("version")
if version != 1:
    print(f"unsupported manifest version: {version!r}", file=sys.stderr)
    raise SystemExit(1)

def opt_str(name):
    value = obj.get(name)
    if value is None:
        return ""
    if not isinstance(value, str):
        print(f"manifest field {name!r} must be a string", file=sys.stderr)
        raise SystemExit(1)
    return value

def req_str(name):
    value = opt_str(name)
    if not value:
        print(f"manifest field {name!r} is required", file=sys.stderr)
        raise SystemExit(1)
    return value

def opt_bool(name):
    value = obj.get(name)
    if value is None:
        return ""
    if not isinstance(value, bool):
        print(f"manifest field {name!r} must be a boolean", file=sys.stderr)
        raise SystemExit(1)
    return "true" if value else "false"

def opt_int(name):
    value = obj.get(name)
    if value is None:
        return ""
    if not isinstance(value, int) or value < 0:
        print(f"manifest field {name!r} must be a non-negative integer", file=sys.stderr)
        raise SystemExit(1)
    return str(value)

assignments = {
    "LIDSKJALV_SERVICE_MANIFEST_RUN_ID": opt_str("run_id"),
    "LIDSKJALV_SERVICE_MANIFEST_SCAN_LABEL": req_str("scan_label"),
    "LIDSKJALV_SERVICE_MANIFEST_PROJECT_KEY": req_str("project_key"),
    "LIDSKJALV_SERVICE_MANIFEST_PROJECT_NAME": opt_str("project_name"),
    "LIDSKJALV_SERVICE_MANIFEST_REPO_SUBDIR": opt_str("repo_subdir"),
    "LIDSKJALV_SERVICE_MANIFEST_SKIP_SONAR": opt_bool("skip_sonar"),
    "LIDSKJALV_SERVICE_MANIFEST_SONAR_WAIT_TIMEOUT_SEC": opt_int("sonar_wait_timeout_sec"),
    "LIDSKJALV_SERVICE_MANIFEST_SONAR_WAIT_POLL_SEC": opt_int("sonar_wait_poll_sec"),
}

for key, value in assignments.items():
    print(f"{key}={shlex.quote(value)}")
PY
}

lidskjalv_service_parse_bool() {
  local raw="${1:-}"
  case "$raw" in
    true|TRUE|True|1|yes|YES|on|ON) printf 'true\n' ;;
    false|FALSE|False|0|no|NO|off|OFF|'') printf 'false\n' ;;
    *)
      return 1
      ;;
  esac
}

lidskjalv_service_check_dependencies() {
  local missing=()
  local cmd
  for cmd in git jq python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'missing dependencies: %s\n' "${missing[*]}" >&2
    return 1
  fi

  if [[ -n "${SONAR_HOST_URL:-}" || -n "${SONAR_TOKEN:-}" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      printf 'missing dependency: curl\n' >&2
      return 1
    fi
  fi
}

lidskjalv_service_prepare_output_dir() {
  local probe
  mkdir -p "$LIDSKJALV_SERVICE_OUTPUT_DIR" >/dev/null 2>&1 || return 1
  probe="${LIDSKJALV_SERVICE_OUTPUT_DIR}/.lidskjalv-write-test.$$"
  : > "$probe" >/dev/null 2>&1 || return 1
  rm -f "$probe"
}

lidskjalv_service_prepare_scan_dirs() {
  local dir
  local probe
  mkdir -p \
    "$LIDSKJALV_SERVICE_LOGS_DIR" \
    "$LIDSKJALV_SERVICE_WORKSPACE_DIR" \
    "$LIDSKJALV_SERVICE_METADATA_DIR" \
    "$LIDSKJALV_SERVICE_OUTPUT_DIR" >/dev/null 2>&1 || return 1

  for dir in \
    "$LIDSKJALV_SERVICE_LOGS_DIR" \
    "$LIDSKJALV_SERVICE_WORKSPACE_DIR" \
    "$LIDSKJALV_SERVICE_METADATA_DIR"; do
    probe="${dir}/.lidskjalv-write-test.$$"
    : > "$probe" >/dev/null 2>&1 || return 1
    rm -f "$probe"
  done
}

lidskjalv_service_write_report() {
  local report_path="$LIDSKJALV_SERVICE_REPORT_PATH"
  local summary_path="$LIDSKJALV_SERVICE_SUMMARY_PATH"

  mkdir -p "$(dirname "$report_path")" >/dev/null 2>&1 || return 1

  LIDSKJALV_SERVICE_SCHEMA_VERSION="$LIDSKJALV_SERVICE_SCHEMA_VERSION" \
  LIDSKJALV_SERVICE_RUN_ID="$LIDSKJALV_SERVICE_RUN_ID" \
  LIDSKJALV_SERVICE_STATUS="$LIDSKJALV_SERVICE_STATUS" \
  LIDSKJALV_SERVICE_FAILURE_SCOPE="$LIDSKJALV_SERVICE_FAILURE_SCOPE" \
  LIDSKJALV_SERVICE_REASON="$LIDSKJALV_SERVICE_REASON" \
  LIDSKJALV_SERVICE_STATUS_DETAIL="$LIDSKJALV_SERVICE_STATUS_DETAIL" \
  LIDSKJALV_SERVICE_SCAN_LABEL="$LIDSKJALV_SERVICE_SCAN_LABEL" \
  LIDSKJALV_SERVICE_PROJECT_KEY="$LIDSKJALV_SERVICE_PROJECT_KEY" \
  LIDSKJALV_SERVICE_PROJECT_NAME="$LIDSKJALV_SERVICE_PROJECT_NAME" \
  LIDSKJALV_SERVICE_STARTED_AT="$LIDSKJALV_SERVICE_STARTED_AT" \
  LIDSKJALV_SERVICE_FINISHED_AT="$LIDSKJALV_SERVICE_FINISHED_AT" \
  LIDSKJALV_SERVICE_INPUT_REPO="$LIDSKJALV_SERVICE_INPUT_REPO" \
  LIDSKJALV_SERVICE_INPUT_SUBDIR="$LIDSKJALV_SERVICE_INPUT_SUBDIR" \
  LIDSKJALV_SERVICE_SCAN_DIR="$LIDSKJALV_SERVICE_SCAN_DIR" \
  LIDSKJALV_SERVICE_LOGS_DIR="$LIDSKJALV_SERVICE_LOGS_DIR" \
  LIDSKJALV_SERVICE_WORKSPACE_DIR="" \
  LIDSKJALV_SERVICE_METADATA_DIR="$LIDSKJALV_SERVICE_METADATA_DIR" \
  LIDSKJALV_SERVICE_SCAN_BUILD_TOOL="$LIDSKJALV_SERVICE_SCAN_BUILD_TOOL" \
  LIDSKJALV_SERVICE_SCAN_BUILD_JDK="$LIDSKJALV_SERVICE_SCAN_BUILD_JDK" \
  LIDSKJALV_SERVICE_SCAN_BUILD_SUBDIR="$LIDSKJALV_SERVICE_SCAN_BUILD_SUBDIR" \
  LIDSKJALV_SERVICE_SCAN_JAVA_VERSION_HINT="$LIDSKJALV_SERVICE_SCAN_JAVA_VERSION_HINT" \
  LIDSKJALV_SERVICE_SCAN_ATTEMPTED_JDKS_CSV="$LIDSKJALV_SERVICE_SCAN_ATTEMPTED_JDKS_CSV" \
  LIDSKJALV_SERVICE_SONAR_TASK_ID="$LIDSKJALV_SERVICE_SONAR_TASK_ID" \
  LIDSKJALV_SERVICE_CE_TASK_STATUS="$LIDSKJALV_SERVICE_CE_TASK_STATUS" \
  LIDSKJALV_SERVICE_QUALITY_GATE_STATUS="$LIDSKJALV_SERVICE_QUALITY_GATE_STATUS" \
  LIDSKJALV_SERVICE_DATA_STATUS="$LIDSKJALV_SERVICE_DATA_STATUS" \
  LIDSKJALV_SERVICE_MEASURES_JSON="$LIDSKJALV_SERVICE_MEASURES_JSON" \
  LIDSKJALV_REPORT_PATH="$report_path" \
  LIDSKJALV_SUMMARY_PATH="$summary_path" \
  python3 - <<'PY'
import json
import os

def env(name, default=""):
    return os.environ.get(name, default)

def env_json(name, default):
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        return json.loads(raw)
    except Exception:
        return default

def nullable(name):
    value = os.environ.get(name, "")
    return value if value else None

def split_csv(name):
    value = os.environ.get(name, "")
    if not value:
        return []
    return [item for item in value.split(":") if item]

report = {
    "service_schema_version": env("LIDSKJALV_SERVICE_SCHEMA_VERSION"),
    "run_id": env("LIDSKJALV_SERVICE_RUN_ID"),
    "status": env("LIDSKJALV_SERVICE_STATUS"),
    "failure_scope": nullable("LIDSKJALV_SERVICE_FAILURE_SCOPE"),
    "reason": nullable("LIDSKJALV_SERVICE_REASON"),
    "status_detail": nullable("LIDSKJALV_SERVICE_STATUS_DETAIL"),
    "scan_label": env("LIDSKJALV_SERVICE_SCAN_LABEL"),
    "project_key": env("LIDSKJALV_SERVICE_PROJECT_KEY"),
    "project_name": env("LIDSKJALV_SERVICE_PROJECT_NAME"),
    "started_at": env("LIDSKJALV_SERVICE_STARTED_AT"),
    "finished_at": env("LIDSKJALV_SERVICE_FINISHED_AT"),
    "inputs": {
        "repo_path": env("LIDSKJALV_SERVICE_INPUT_REPO"),
        "repo_subdir": nullable("LIDSKJALV_SERVICE_INPUT_SUBDIR"),
    },
    "artifacts": {
        "scan_dir": env("LIDSKJALV_SERVICE_SCAN_DIR"),
        "logs_dir": env("LIDSKJALV_SERVICE_LOGS_DIR"),
        "workspace_dir": nullable("LIDSKJALV_SERVICE_WORKSPACE_DIR"),
        "metadata_dir": env("LIDSKJALV_SERVICE_METADATA_DIR"),
    },
    "scan": {
        "build_tool": nullable("LIDSKJALV_SERVICE_SCAN_BUILD_TOOL"),
        "build_jdk": nullable("LIDSKJALV_SERVICE_SCAN_BUILD_JDK"),
        "build_subdir": nullable("LIDSKJALV_SERVICE_SCAN_BUILD_SUBDIR"),
        "java_version_hint": nullable("LIDSKJALV_SERVICE_SCAN_JAVA_VERSION_HINT"),
        "attempted_jdks": split_csv("LIDSKJALV_SERVICE_SCAN_ATTEMPTED_JDKS_CSV"),
        "sonar_task_id": nullable("LIDSKJALV_SERVICE_SONAR_TASK_ID"),
        "ce_task_status": nullable("LIDSKJALV_SERVICE_CE_TASK_STATUS"),
        "quality_gate_status": nullable("LIDSKJALV_SERVICE_QUALITY_GATE_STATUS"),
        "data_status": env("LIDSKJALV_SERVICE_DATA_STATUS", "unavailable"),
        "measures": env_json("LIDSKJALV_SERVICE_MEASURES_JSON", {}),
    },
}

with open(os.environ["LIDSKJALV_REPORT_PATH"], "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2, sort_keys=False)
    f.write("\n")

summary_lines = [
    "# Lidskjalv Service Run Report",
    "",
    "| Field | Value |",
    "|---|---|",
    f"| run_id | {report['run_id']} |",
    f"| status | {report['status']} |",
    f"| failure_scope | {report['failure_scope'] or ''} |",
    f"| reason | {report['reason'] or ''} |",
    f"| scan_label | {report['scan_label']} |",
    f"| project_key | {report['project_key']} |",
    f"| project_name | {report['project_name']} |",
    f"| repo_path | {report['inputs']['repo_path']} |",
    f"| repo_subdir | {report['inputs']['repo_subdir'] or ''} |",
    f"| build_tool | {report['scan']['build_tool'] or ''} |",
    f"| build_jdk | {report['scan']['build_jdk'] or ''} |",
    f"| build_subdir | {report['scan']['build_subdir'] or ''} |",
    f"| java_version_hint | {report['scan']['java_version_hint'] or ''} |",
    f"| attempted_jdks | {', '.join(report['scan']['attempted_jdks']) if report['scan']['attempted_jdks'] else ''} |",
    f"| sonar_task_id | {report['scan']['sonar_task_id'] or ''} |",
    f"| ce_task_status | {report['scan']['ce_task_status'] or ''} |",
    f"| quality_gate_status | {report['scan']['quality_gate_status'] or ''} |",
    f"| data_status | {report['scan']['data_status']} |",
    f"| started_at | {report['started_at']} |",
    f"| finished_at | {report['finished_at']} |",
]

with open(os.environ["LIDSKJALV_SUMMARY_PATH"], "w", encoding="utf-8") as f:
    f.write("\n".join(summary_lines) + "\n")
PY
}

lidskjalv_service_cleanup_workspace() {
  [[ -n "${LIDSKJALV_SERVICE_WORKSPACE_DIR:-}" ]] || return 0
  [[ -e "$LIDSKJALV_SERVICE_WORKSPACE_DIR" ]] || return 0
  rm -rf "$LIDSKJALV_SERVICE_WORKSPACE_DIR"
}

lidskjalv_service_finalize_run() {
  lidskjalv_service_write_report || return 1
  if ! lidskjalv_service_cleanup_workspace; then
    printf 'warning: failed to clean workspace dir: %s\n' "$LIDSKJALV_SERVICE_WORKSPACE_DIR" >&2
  fi
}

lidskjalv_service_load_scan_metadata() {
  local project_key="$1"
  local skip_sonar="$2"
  local task_id=""
  task_id="$(state_get "$project_key" "sonar_task_id" 2>/dev/null || true)"
  local build_tool=""
  build_tool="${PIPELINE_BUILD_TOOL:-$(state_get "$project_key" "build_tool" 2>/dev/null || true)}"
  local build_jdk=""
  build_jdk="${PIPELINE_BUILD_JDK:-$(state_get "$project_key" "jdk_version" 2>/dev/null || true)}"

  LIDSKJALV_SERVICE_SCAN_BUILD_TOOL="$build_tool"
  LIDSKJALV_SERVICE_SCAN_BUILD_JDK="$build_jdk"
  LIDSKJALV_SERVICE_SCAN_BUILD_SUBDIR="${PIPELINE_BUILD_SUBDIR:-}"
  LIDSKJALV_SERVICE_SCAN_JAVA_VERSION_HINT="${PIPELINE_JAVA_VERSION_HINT:-}"
  LIDSKJALV_SERVICE_SCAN_ATTEMPTED_JDKS_CSV="${PIPELINE_ATTEMPTED_JDKS_CSV:-}"
  LIDSKJALV_SERVICE_SONAR_TASK_ID="$task_id"
  LIDSKJALV_SERVICE_QUALITY_GATE_STATUS=""
  LIDSKJALV_SERVICE_CE_TASK_STATUS=""
  LIDSKJALV_SERVICE_MEASURES_JSON="{}"

  if [[ "$skip_sonar" == "true" ]]; then
    LIDSKJALV_SERVICE_CE_TASK_STATUS=""
    LIDSKJALV_SERVICE_QUALITY_GATE_STATUS="skipped"
    LIDSKJALV_SERVICE_DATA_STATUS="skipped"
    return 0
  fi

  if [[ -z "$task_id" ]]; then
    return 1
  fi

  LIDSKJALV_SERVICE_CE_TASK_STATUS=""
  LIDSKJALV_SERVICE_QUALITY_GATE_STATUS=""
  LIDSKJALV_SERVICE_DATA_STATUS="pending"
  return 0
}

lidskjalv_service_prepare_workspace_copy() {
  local input_repo="$1"
  rm -rf "$LIDSKJALV_SERVICE_WORKSPACE_REPO"
  mkdir -p "$LIDSKJALV_SERVICE_WORKSPACE_REPO"
  cp -a "${input_repo}/." "$LIDSKJALV_SERVICE_WORKSPACE_REPO/"
}

lidskjalv_service_apply_service_error() {
  local reason="$1"
  local detail="$2"
  LIDSKJALV_SERVICE_STATUS="error"
  LIDSKJALV_SERVICE_FAILURE_SCOPE="service"
  LIDSKJALV_SERVICE_REASON="$reason"
  LIDSKJALV_SERVICE_STATUS_DETAIL="$detail"
}

lidskjalv_service_apply_scan_result() {
  local success="$1"
  local skip_sonar="$2"

  if [[ "$success" != "true" ]]; then
    lidskjalv_service_load_scan_metadata \
      "$LIDSKJALV_SERVICE_PROJECT_KEY" \
      "$skip_sonar" || true
    local failure_reason=""
    failure_reason="$(state_get "$LIDSKJALV_SERVICE_PROJECT_KEY" "failure_reason" 2>/dev/null || true)"
    local failure_message=""
    failure_message="$(state_get "$LIDSKJALV_SERVICE_PROJECT_KEY" "failure_message" 2>/dev/null || true)"

    LIDSKJALV_SERVICE_STATUS="failed"
    LIDSKJALV_SERVICE_FAILURE_SCOPE="scan"
    LIDSKJALV_SERVICE_REASON="${failure_reason:-scan_failed}"
    LIDSKJALV_SERVICE_STATUS_DETAIL="$failure_message"
    LIDSKJALV_SERVICE_QUALITY_GATE_STATUS=""
    LIDSKJALV_SERVICE_DATA_STATUS="unavailable"
    return 0
  fi

  if ! lidskjalv_service_load_scan_metadata \
    "$LIDSKJALV_SERVICE_PROJECT_KEY" \
    "$skip_sonar"; then
    LIDSKJALV_SERVICE_STATUS="failed"
    LIDSKJALV_SERVICE_FAILURE_SCOPE="scan"
    LIDSKJALV_SERVICE_REASON="missing-sonar-task-id"
    LIDSKJALV_SERVICE_STATUS_DETAIL="SonarQube submission completed without a persisted task ID"
    return 0
  fi

  LIDSKJALV_SERVICE_STATUS="passed"
  LIDSKJALV_SERVICE_FAILURE_SCOPE=""
  LIDSKJALV_SERVICE_REASON=""
  LIDSKJALV_SERVICE_STATUS_DETAIL=""
}

lidskjalv_service_main() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h|--help)
        lidskjalv_service_usage
        return 0
        ;;
      *)
        printf 'lidskjalv-service.sh does not accept positional arguments; use env vars or LIDSKJALV_MANIFEST.\n' >&2
        return 1
        ;;
    esac
  fi

  local manifest_path="${LIDSKJALV_MANIFEST:-/run/config/manifest.yaml}"
  local resolved_input_repo="${LIDSKJALV_INPUT_REPO:-/input/repo}"
  local resolved_run_dir="${LIDSKJALV_RUN_DIR:-/run}"
  local manifest_scan_label=""
  local manifest_project_key=""
  local manifest_project_name=""
  local manifest_repo_subdir=""
  local manifest_skip_sonar=""
  local manifest_run_id=""
  local manifest_timeout=""
  local manifest_poll=""
  local resolved_scan_label=""
  local resolved_project_key=""
  local resolved_project_name=""
  local resolved_repo_subdir=""
  local resolved_skip_sonar="false"
  local resolved_timeout="300"
  local resolved_poll="5"
  LIDSKJALV_SERVICE_RUN_DIR="$(lidskjalv_service_abs_path "$resolved_run_dir")"
  LIDSKJALV_SERVICE_OUTPUT_DIR="${LIDSKJALV_SERVICE_RUN_DIR}/outputs"
  LIDSKJALV_SERVICE_REPORT_PATH="${LIDSKJALV_SERVICE_OUTPUT_DIR}/run_report.json"
  LIDSKJALV_SERVICE_SUMMARY_PATH="${LIDSKJALV_SERVICE_OUTPUT_DIR}/summary.md"
  LIDSKJALV_SERVICE_STARTED_AT="$(timestamp)"
  LIDSKJALV_SERVICE_FINISHED_AT="$LIDSKJALV_SERVICE_STARTED_AT"

  if ! lidskjalv_service_check_dependencies; then
    return 1
  fi

  if ! lidskjalv_service_prepare_output_dir; then
    printf 'service outputs dir is not writable: %s\n' "$LIDSKJALV_SERVICE_OUTPUT_DIR" >&2
    return 1
  fi

  manifest_path="$(lidskjalv_service_abs_path "$manifest_path")"
  if [[ ! -f "$manifest_path" ]]; then
    lidskjalv_service_apply_service_error "missing-service-manifest" "manifest_not_found"
    LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
    lidskjalv_service_finalize_run || return 1
    return 0
  fi

  local manifest_assignments
  if ! manifest_assignments="$(lidskjalv_service_load_manifest "$manifest_path")"; then
    lidskjalv_service_apply_service_error "invalid-service-manifest" "invalid_manifest"
    LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
    lidskjalv_service_finalize_run || return 1
    return 0
  fi
  eval "$manifest_assignments"
  manifest_run_id="${LIDSKJALV_SERVICE_MANIFEST_RUN_ID:-}"
  manifest_scan_label="${LIDSKJALV_SERVICE_MANIFEST_SCAN_LABEL:-}"
  manifest_project_key="${LIDSKJALV_SERVICE_MANIFEST_PROJECT_KEY:-}"
  manifest_project_name="${LIDSKJALV_SERVICE_MANIFEST_PROJECT_NAME:-}"
  manifest_repo_subdir="${LIDSKJALV_SERVICE_MANIFEST_REPO_SUBDIR:-}"
  manifest_skip_sonar="${LIDSKJALV_SERVICE_MANIFEST_SKIP_SONAR:-}"
  manifest_timeout="${LIDSKJALV_SERVICE_MANIFEST_SONAR_WAIT_TIMEOUT_SEC:-}"
  manifest_poll="${LIDSKJALV_SERVICE_MANIFEST_SONAR_WAIT_POLL_SEC:-}"

  LIDSKJALV_SERVICE_RUN_ID="${manifest_run_id:-$(lidskjalv_service_timestamp_compact_utc)__service__lidskjalv}"

  resolved_scan_label="${manifest_scan_label}"
  resolved_project_key="${manifest_project_key}"
  resolved_project_name="${manifest_project_name}"
  resolved_repo_subdir="${manifest_repo_subdir}"
  [[ -n "$manifest_skip_sonar" ]] && resolved_skip_sonar="$manifest_skip_sonar"
  [[ -n "$manifest_timeout" ]] && resolved_timeout="$manifest_timeout"
  [[ -n "$manifest_poll" ]] && resolved_poll="$manifest_poll"

  if [[ "$resolved_scan_label" != "original" && "$resolved_scan_label" != "generated" ]]; then
    lidskjalv_service_apply_service_error "invalid-service-config" "scan_label must be original or generated"
    LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
    lidskjalv_service_finalize_run || return 1
    return 0
  fi

  [[ -n "$resolved_project_key" ]] || {
    lidskjalv_service_apply_service_error "invalid-service-config" "project_key is required"
    LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
    lidskjalv_service_finalize_run || return 1
    return 0
  }

  if [[ -n "$resolved_repo_subdir" ]]; then
    if ! resolved_repo_subdir="$(lidskjalv_service_normalize_rel_path "$resolved_repo_subdir")"; then
      lidskjalv_service_apply_service_error "invalid-service-config" "repo_subdir must be a safe relative path"
      LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
      lidskjalv_service_finalize_run || return 1
      return 0
    fi
  fi

  if ! [[ "$resolved_timeout" =~ ^[0-9]+$ && "$resolved_poll" =~ ^[0-9]+$ ]]; then
    lidskjalv_service_apply_service_error "invalid-service-config" "sonar wait settings must be non-negative integers"
    LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
    lidskjalv_service_finalize_run || return 1
    return 0
  fi

  if [[ -z "$resolved_project_name" ]]; then
    resolved_project_name="$resolved_project_key"
  fi

  LIDSKJALV_SERVICE_SCAN_LABEL="$resolved_scan_label"
  LIDSKJALV_SERVICE_PROJECT_KEY="$resolved_project_key"
  LIDSKJALV_SERVICE_PROJECT_NAME="$resolved_project_name"
  LIDSKJALV_SERVICE_INPUT_REPO="$(lidskjalv_service_abs_path "$resolved_input_repo")"
  LIDSKJALV_SERVICE_INPUT_SUBDIR="$resolved_repo_subdir"
  LIDSKJALV_SERVICE_SCAN_DIR="${LIDSKJALV_SERVICE_RUN_DIR}/artifacts/scans/${resolved_scan_label}"
  LIDSKJALV_SERVICE_LOGS_DIR="${LIDSKJALV_SERVICE_SCAN_DIR}/logs"
  LIDSKJALV_SERVICE_WORKSPACE_DIR="${LIDSKJALV_SERVICE_SCAN_DIR}/workspace"
  LIDSKJALV_SERVICE_WORKSPACE_REPO="${LIDSKJALV_SERVICE_WORKSPACE_DIR}/repo"
  LIDSKJALV_SERVICE_METADATA_DIR="${LIDSKJALV_SERVICE_SCAN_DIR}/metadata"

  if ! lidskjalv_service_prepare_scan_dirs; then
    lidskjalv_service_apply_service_error "run-dir-not-writable" "run_artifacts_not_writable"
    LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
    lidskjalv_service_finalize_run || return 1
    return 0
  fi

  if [[ ! -d "$LIDSKJALV_SERVICE_INPUT_REPO" ]]; then
    lidskjalv_service_apply_service_error "missing-input-repo" "input_repo_missing"
    LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
    lidskjalv_service_finalize_run || return 1
    return 0
  fi

  if [[ "$resolved_skip_sonar" != "true" ]]; then
    if [[ -z "${SONAR_HOST_URL:-}" || -z "${SONAR_TOKEN:-}" || -z "${SONAR_ORGANIZATION:-}" ]]; then
      lidskjalv_service_apply_service_error "missing-sonar-env" "sonar_env_required"
      LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
      lidskjalv_service_finalize_run || return 1
      return 0
    fi
  fi

  if ! lidskjalv_service_prepare_workspace_copy "$LIDSKJALV_SERVICE_INPUT_REPO"; then
    lidskjalv_service_apply_service_error "workspace-copy-failed" "input_repo_copy_failed"
    LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
    lidskjalv_service_finalize_run || return 1
    return 0
  fi

  export WORK_DIR="$LIDSKJALV_SERVICE_WORKSPACE_DIR"
  export LOG_DIR="$LIDSKJALV_SERVICE_LOGS_DIR"
  export STATE_FILE="${LIDSKJALV_SERVICE_METADATA_DIR}/scan-state.json"
  export LIDSKJALV_DATA_DIR="$LIDSKJALV_SERVICE_RUN_DIR"
  resolve_config_paths

  state_init
  state_init_repo "$LIDSKJALV_SERVICE_PROJECT_KEY" "path" "$LIDSKJALV_SERVICE_INPUT_REPO"

  local scan_rc=0
  set +e
  run_scan_for_prepared_repo \
    "$LIDSKJALV_SERVICE_PROJECT_KEY" \
    "$LIDSKJALV_SERVICE_PROJECT_NAME" \
    "path" \
    "$LIDSKJALV_SERVICE_INPUT_REPO" \
    "$LIDSKJALV_SERVICE_WORKSPACE_REPO" \
    "" \
    "$resolved_repo_subdir" \
    "$resolved_skip_sonar" \
    "failed" \
    "false"
  scan_rc=$?
  set -e

  if [[ "$scan_rc" -eq 0 ]]; then
    lidskjalv_service_apply_scan_result "true" "$resolved_skip_sonar"
  else
    lidskjalv_service_apply_scan_result "false" "$resolved_skip_sonar"
  fi

  LIDSKJALV_SERVICE_FINISHED_AT="$(timestamp)"
  lidskjalv_service_finalize_run || return 1

  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  lidskjalv_service_main "$@"
fi
