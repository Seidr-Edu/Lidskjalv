#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_LIB="${ROOT_DIR}/scripts/adapters/adapter.sh"

usage() {
  cat <<'USAGE'
Usage:
  ./andvari-run.sh --diagram /path/to/diagram.puml [--run-id RUN_ID] [--max-iter N] [--gating-mode model|fixed] [--max-gate-revisions N] [--model-gate-timeout-sec N]

Options:
  --diagram                 Path to the PlantUML diagram (.puml). Required.
  --run-id                  Optional run id. Auto-generated (UTC timestamp) if omitted.
  --max-iter                Maximum repair iterations after first implementation attempt. Default: 8.
  --gating-mode             Gating strategy: model (default) or fixed.
  --max-gate-revisions      In model mode, maximum revisions after gates.v1 (default: 3).
  --model-gate-timeout-sec  In model mode, timeout for completion/run_all_gates.sh replay (default: 120).
  -h, --help                Show this help.
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

validate_run_id() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "File not found: $path"
}

compute_sha256() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi

  fail "Neither sha256sum nor shasum is available"
}

if [[ ! -f "$ADAPTER_LIB" ]]; then
  fail "Missing adapter library: $ADAPTER_LIB"
fi

# shellcheck source=/dev/null
source "$ADAPTER_LIB"

DIAGRAM_PATH=""
RUN_ID=""
MAX_ITER="8"
GATING_MODE="${ANDVARI_GATING_MODE:-model}"
MAX_GATE_REVISIONS="${ANDVARI_MAX_GATE_REVISIONS:-3}"
MODEL_GATE_TIMEOUT_SEC="${ANDVARI_MODEL_GATE_TIMEOUT_SEC:-120}"
ADAPTER="${ANDVARI_ADAPTER:-codex}"
AGENTS_TEMPLATE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diagram)
      [[ $# -ge 2 ]] || fail "--diagram requires a value"
      DIAGRAM_PATH="$2"
      shift 2
      ;;
    --run-id)
      [[ $# -ge 2 ]] || fail "--run-id requires a value"
      RUN_ID="$2"
      shift 2
      ;;
    --max-iter)
      [[ $# -ge 2 ]] || fail "--max-iter requires a value"
      MAX_ITER="$2"
      shift 2
      ;;
    --gating-mode)
      [[ $# -ge 2 ]] || fail "--gating-mode requires a value"
      GATING_MODE="$2"
      shift 2
      ;;
    --max-gate-revisions)
      [[ $# -ge 2 ]] || fail "--max-gate-revisions requires a value"
      MAX_GATE_REVISIONS="$2"
      shift 2
      ;;
    --model-gate-timeout-sec)
      [[ $# -ge 2 ]] || fail "--model-gate-timeout-sec requires a value"
      MODEL_GATE_TIMEOUT_SEC="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "$DIAGRAM_PATH" ]] || fail "--diagram is required"
require_file "$DIAGRAM_PATH"

if [[ -z "$RUN_ID" ]]; then
  RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
fi

validate_run_id "$RUN_ID" || fail "Invalid --run-id '$RUN_ID' (allowed: letters, numbers, ., _, -)"
[[ "$MAX_ITER" =~ ^[0-9]+$ ]] || fail "--max-iter must be a non-negative integer"
[[ "$MAX_GATE_REVISIONS" =~ ^[0-9]+$ ]] || fail "--max-gate-revisions must be a non-negative integer"
[[ "$MODEL_GATE_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || fail "--model-gate-timeout-sec must be a non-negative integer"
MAX_ITER=$((10#$MAX_ITER))
MAX_GATE_REVISIONS=$((10#$MAX_GATE_REVISIONS))
MODEL_GATE_TIMEOUT_SEC=$((10#$MODEL_GATE_TIMEOUT_SEC))

case "$GATING_MODE" in
  model|fixed)
    ;;
  *)
    fail "--gating-mode must be one of: model, fixed"
    ;;
esac

if [[ "$GATING_MODE" == "model" ]]; then
  AGENTS_TEMPLATE_PATH="${ROOT_DIR}/AGENTS.model.md"
else
  AGENTS_TEMPLATE_PATH="${ROOT_DIR}/AGENTS.fixed.md"
fi

RUNS_DIR="${ROOT_DIR}/runs"
RUN_DIR="${RUNS_DIR}/${RUN_ID}"
INPUT_DIR="${RUN_DIR}/input"
NEW_REPO_DIR="${RUN_DIR}/new_repo"
LOGS_DIR="${RUN_DIR}/logs"
OUTPUTS_DIR="${RUN_DIR}/outputs"

if [[ -e "$RUN_DIR" ]]; then
  fail "Run directory already exists: $RUN_DIR. Use a different --run-id."
fi

require_file "${ROOT_DIR}/AGENTS.md"
require_file "${ROOT_DIR}/AGENTS.model.md"
require_file "${ROOT_DIR}/AGENTS.fixed.md"
require_file "${ROOT_DIR}/gate_recon.sh"
require_file "${ROOT_DIR}/gate_hard.sh"
require_file "${ROOT_DIR}/scripts/verify_outcome_coverage.sh"
adapter_check_prereqs "$ADAPTER"

mkdir -p "$INPUT_DIR" "$NEW_REPO_DIR" "$LOGS_DIR" "$OUTPUTS_DIR" "${NEW_REPO_DIR}/scripts"
cp "$DIAGRAM_PATH" "${INPUT_DIR}/diagram.puml"
cp "$AGENTS_TEMPLATE_PATH" "${NEW_REPO_DIR}/AGENTS.md"
cp "${ROOT_DIR}/gate_recon.sh" "${NEW_REPO_DIR}/gate_recon.sh"
cp "${ROOT_DIR}/gate_hard.sh" "${NEW_REPO_DIR}/gate_hard.sh"
cp "${ROOT_DIR}/scripts/verify_outcome_coverage.sh" "${NEW_REPO_DIR}/scripts/verify_outcome_coverage.sh"
chmod +x "${NEW_REPO_DIR}/gate_recon.sh" "${NEW_REPO_DIR}/gate_hard.sh" "${NEW_REPO_DIR}/scripts/verify_outcome_coverage.sh"

EVENTS_LOG="${LOGS_DIR}/codex_events.jsonl"
CODEX_STDERR_LOG="${LOGS_DIR}/codex_stderr.log"
GATE_LOG="${LOGS_DIR}/gate.log"
LAST_FIXED_GATE_OUTPUT="${LOGS_DIR}/gate_fixed_last.log"
LAST_HARD_GATE_OUTPUT="${LOGS_DIR}/gate_hard_last.log"
LAST_MODEL_VERIFY_OUTPUT="${LOGS_DIR}/gate_model_verify_last.log"
GATE_SUMMARY_FILE="${LOGS_DIR}/gate_summary.txt"
RUN_REPORT="${OUTPUTS_DIR}/run_report.md"

touch "$EVENTS_LOG" "$CODEX_STDERR_LOG" "$GATE_LOG"

START_TIME="$(timestamp_utc)"
START_EPOCH="$(date -u +%s)"
STATUS="failed"
REPAIR_ITERATIONS_USED=0
ADAPTER_FAILURES=0

run_fixed_gate() {
  local label="$1"
  local run_time
  run_time="$(timestamp_utc)"

  echo "=== ${label} @ ${run_time} ===" >> "$GATE_LOG"

  set +e
  (
    cd "$NEW_REPO_DIR"
    ./gate_recon.sh
  ) > "$LAST_FIXED_GATE_OUTPUT" 2>&1
  local gate_status=$?
  set -e

  cat "$LAST_FIXED_GATE_OUTPUT" | tee -a "$GATE_LOG"
  echo >> "$GATE_LOG"

  return "$gate_status"
}

run_model_acceptance() {
  local label="$1"
  local run_time
  run_time="$(timestamp_utc)"

  echo "=== ${label}/hard @ ${run_time} ===" >> "$GATE_LOG"
  set +e
  (
    cd "$NEW_REPO_DIR"
    ./gate_hard.sh
  ) > "$LAST_HARD_GATE_OUTPUT" 2>&1
  local hard_status=$?
  set -e

  cat "$LAST_HARD_GATE_OUTPUT" | tee -a "$GATE_LOG"
  echo >> "$GATE_LOG"

  if [[ "$hard_status" -ne 0 ]]; then
    return 1
  fi

  echo "=== ${label}/model @ ${run_time} ===" >> "$GATE_LOG"
  set +e
  (
    cd "$NEW_REPO_DIR"
    ./scripts/verify_outcome_coverage.sh \
      --max-gate-revisions "$MAX_GATE_REVISIONS" \
      --model-gate-timeout-sec "$MODEL_GATE_TIMEOUT_SEC"
  ) > "$LAST_MODEL_VERIFY_OUTPUT" 2>&1
  local model_status=$?
  set -e

  cat "$LAST_MODEL_VERIFY_OUTPUT" | tee -a "$GATE_LOG"
  echo >> "$GATE_LOG"

  return "$model_status"
}

summarize_last_gate_failure() {
  tail -n 200 "$LAST_FIXED_GATE_OUTPUT" > "$GATE_SUMMARY_FILE"
}

summarize_model_gate_failure() {
  {
    echo "----- HARD GATE FAILURE (last ~200 lines) -----"
    tail -n 200 "$LAST_HARD_GATE_OUTPUT" || true
    echo "----- MODEL VERIFICATION FAILURE (last ~200 lines) -----"
    tail -n 200 "$LAST_MODEL_VERIFY_OUTPUT" || true
  } > "$GATE_SUMMARY_FILE"
}

lock_initial_outcomes() {
  local completion_dir="${NEW_REPO_DIR}/completion"
  local outcomes_file="${completion_dir}/outcomes.initial.json"
  local gates_file="${completion_dir}/gates.v1.json"
  local gate_runner_file="${completion_dir}/run_all_gates.sh"
  local locked_dir="${completion_dir}/locked"

  [[ -f "$outcomes_file" ]] || fail "Declaration phase did not create completion/outcomes.initial.json"
  [[ -f "$gates_file" ]] || fail "Declaration phase did not create completion/gates.v1.json"
  [[ -f "$gate_runner_file" ]] || fail "Declaration phase did not create completion/run_all_gates.sh"

  chmod +x "$gate_runner_file"
  mkdir -p "$locked_dir"
  cp "$outcomes_file" "${locked_dir}/outcomes.initial.json"
  cp "$gates_file" "${locked_dir}/gates.v1.json"
  printf '%s\n' "$(compute_sha256 "$outcomes_file")" > "${locked_dir}/outcomes.initial.sha256"
}

latest_gate_version() {
  local completion_dir="${NEW_REPO_DIR}/completion"
  local latest=0
  local file
  local base
  local version

  if [[ ! -d "$completion_dir" ]]; then
    echo "none"
    return
  fi

  shopt -s nullglob
  for file in "$completion_dir"/gates.v*.json; do
    base="$(basename "$file")"
    if [[ "$base" =~ ^gates\.v([0-9]+)\.json$ ]]; then
      version=$((10#${BASH_REMATCH[1]}))
      if (( version > latest )); then
        latest="$version"
      fi
    fi
  done
  shopt -u nullglob

  if (( latest == 0 )); then
    echo "none"
  else
    echo "v${latest}"
  fi
}

echo "[andvari] run id: ${RUN_ID}"
echo "[andvari] run dir: ${RUN_DIR}"
echo "[andvari] adapter: ${ADAPTER}"
echo "[andvari] gating mode: ${GATING_MODE}"
echo "[andvari] agents template: ${AGENTS_TEMPLATE_PATH}"

if [[ "$GATING_MODE" == "fixed" ]]; then
  echo "[andvari] starting fixed-gate reconstruction..."

  if ! adapter_run_initial_reconstruction \
    "$ADAPTER" \
    "$NEW_REPO_DIR" \
    "${INPUT_DIR}/diagram.puml" \
    "$EVENTS_LOG" \
    "$CODEX_STDERR_LOG" \
    "${OUTPUTS_DIR}/codex_last_message_initial.txt"; then
    ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
    echo "[andvari] warning: initial adapter run returned non-zero status"
  fi

  if run_fixed_gate "gate-initial"; then
    STATUS="passed"
  else
    for ((iter = 1; iter <= MAX_ITER; iter++)); do
      REPAIR_ITERATIONS_USED="$iter"
      summarize_last_gate_failure
      echo "[andvari] fixed gate failed, running repair iteration ${iter}/${MAX_ITER}..."

      if ! adapter_run_fix_iteration \
        "$ADAPTER" \
        "$NEW_REPO_DIR" \
        "${INPUT_DIR}/diagram.puml" \
        "$GATE_SUMMARY_FILE" \
        "$EVENTS_LOG" \
        "$CODEX_STDERR_LOG" \
        "${OUTPUTS_DIR}/codex_last_message_iter_${iter}.txt" \
        "$iter"; then
        ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
        echo "[andvari] warning: adapter repair iteration ${iter} returned non-zero status"
      fi

      if run_fixed_gate "gate-retry-${iter}"; then
        STATUS="passed"
        break
      fi
    done
  fi
else
  echo "[andvari] starting model-gate declaration phase..."
  if ! adapter_run_gate_declaration \
    "$ADAPTER" \
    "$NEW_REPO_DIR" \
    "${INPUT_DIR}/diagram.puml" \
    "$EVENTS_LOG" \
    "$CODEX_STDERR_LOG" \
    "${OUTPUTS_DIR}/codex_last_message_declaration.txt" \
    "$MAX_GATE_REVISIONS"; then
    ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
    echo "[andvari] warning: declaration phase returned non-zero status"
  fi

  lock_initial_outcomes

  echo "Initial implementation run. No prior gate failure summary." > "$GATE_SUMMARY_FILE"
  echo "[andvari] starting model-gate implementation phase..."
  if ! adapter_run_implementation_iteration \
    "$ADAPTER" \
    "$NEW_REPO_DIR" \
    "${INPUT_DIR}/diagram.puml" \
    "$GATE_SUMMARY_FILE" \
    "$EVENTS_LOG" \
    "$CODEX_STDERR_LOG" \
    "${OUTPUTS_DIR}/codex_last_message_initial_implementation.txt" \
    "0" \
    "$MAX_GATE_REVISIONS" \
    "$MODEL_GATE_TIMEOUT_SEC"; then
    ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
    echo "[andvari] warning: initial implementation phase returned non-zero status"
  fi

  if run_model_acceptance "gate-initial"; then
    STATUS="passed"
  else
    for ((iter = 1; iter <= MAX_ITER; iter++)); do
      REPAIR_ITERATIONS_USED="$iter"
      summarize_model_gate_failure
      echo "[andvari] model gate failed, running repair iteration ${iter}/${MAX_ITER}..."

      if ! adapter_run_implementation_iteration \
        "$ADAPTER" \
        "$NEW_REPO_DIR" \
        "${INPUT_DIR}/diagram.puml" \
        "$GATE_SUMMARY_FILE" \
        "$EVENTS_LOG" \
        "$CODEX_STDERR_LOG" \
        "${OUTPUTS_DIR}/codex_last_message_iter_${iter}.txt" \
        "$iter" \
        "$MAX_GATE_REVISIONS" \
        "$MODEL_GATE_TIMEOUT_SEC"; then
        ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
        echo "[andvari] warning: adapter repair iteration ${iter} returned non-zero status"
      fi

      if run_model_acceptance "gate-retry-${iter}"; then
        STATUS="passed"
        break
      fi
    done
  fi
fi

END_TIME="$(timestamp_utc)"
END_EPOCH="$(date -u +%s)"
DURATION_SECONDS=$((END_EPOCH - START_EPOCH))
LATEST_GATE_VERSION="$(latest_gate_version)"

cat > "$RUN_REPORT" <<REPORT_EOF
# Run Report

- Run ID: \`${RUN_ID}\`
- Adapter: \`${ADAPTER}\`
- Diagram: \`runs/${RUN_ID}/input/diagram.puml\`
- Gating Mode: \`${GATING_MODE}\`
- AGENTS Template: \`${AGENTS_TEMPLATE_PATH##*/}\`
- Status: \`${STATUS}\`
- Max Repair Iterations: \`${MAX_ITER}\`
- Repair Iterations Used: \`${REPAIR_ITERATIONS_USED}\`
- Max Gate Revisions: \`${MAX_GATE_REVISIONS}\`
- Model Gate Timeout (seconds): \`${MODEL_GATE_TIMEOUT_SEC}\`
- Latest Gate Version Observed: \`${LATEST_GATE_VERSION}\`
- Adapter Non-zero Runs: \`${ADAPTER_FAILURES}\`
- Started (UTC): \`${START_TIME}\`
- Finished (UTC): \`${END_TIME}\`
- Duration (seconds): \`${DURATION_SECONDS}\`

## Artifacts

- Codex events log: \`runs/${RUN_ID}/logs/codex_events.jsonl\`
- Codex stderr log: \`runs/${RUN_ID}/logs/codex_stderr.log\`
- Gate log: \`runs/${RUN_ID}/logs/gate.log\`
- Report: \`runs/${RUN_ID}/outputs/run_report.md\`
REPORT_EOF

if [[ "$STATUS" == "passed" ]]; then
  echo "[andvari] status: PASS"
  echo "[andvari] run folder: ${RUN_DIR}"
  exit 0
fi

echo "[andvari] status: FAIL"
echo "[andvari] run folder: ${RUN_DIR}"
echo "[andvari] see logs: ${GATE_LOG}, ${CODEX_STDERR_LOG}, ${EVENTS_LOG}"
exit 1
