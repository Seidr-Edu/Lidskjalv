#!/usr/bin/env bash
# runner_report.sh - Run report generation and final exit handling
# Creates markdown run reports and prints final status messages

andvari_write_run_report() {
  END_TIME="$(andvari_timestamp_utc)"
  END_EPOCH="$(date -u +%s)"
  DURATION_SECONDS=$((END_EPOCH - START_EPOCH))
  LATEST_GATE_VERSION="$(andvari_latest_gate_version)"

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

- Adapter events log: \`runs/${RUN_ID}/logs/adapter_events.jsonl\`
- Adapter stderr log: \`runs/${RUN_ID}/logs/adapter_stderr.log\`
- Gate log: \`runs/${RUN_ID}/logs/gate.log\`
- Report: \`runs/${RUN_ID}/outputs/run_report.md\`
REPORT_EOF

  python3 - <<'PY' \
    "$RUN_REPORT_JSON" "$RUN_ID" "$ADAPTER" "$GATING_MODE" "$STATUS" \
    "$START_TIME" "$END_TIME" "$DURATION_SECONDS" "$MAX_ITER" "$REPAIR_ITERATIONS_USED" \
    "$MAX_GATE_REVISIONS" "$MODEL_GATE_TIMEOUT_SEC" "$LATEST_GATE_VERSION" "$ADAPTER_FAILURES" \
    "$RUN_DIR"
import json
import os
import sys

(
  out_path, run_id, adapter, gating_mode, status,
  started_at, finished_at, duration_seconds, max_iter, repair_iterations_used,
  max_gate_revisions, model_gate_timeout_sec, latest_gate_version, adapter_nonzero_runs,
  run_dir,
) = sys.argv[1:]

completion_dir = os.path.join(run_dir, "new_repo", "completion")

def to_int(value, default=0):
    try:
        return int(str(value))
    except Exception:
        return default

def load_json(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None

outcomes_total = 0
outcomes_core = 0
outcomes_non_core = 0
gates_total = 0
gates_passed = 0
gates_failed = 0

outcomes = load_json(os.path.join(completion_dir, "outcomes.initial.json"))
if isinstance(outcomes, list):
    outcomes_total = len(outcomes)
    for item in outcomes:
        if not isinstance(item, dict):
            continue
        if item.get("priority") == "core":
            outcomes_core += 1
        else:
            outcomes_non_core += 1

latest_version_num = 0
if isinstance(latest_gate_version, str) and latest_gate_version.startswith("v"):
    latest_version_num = to_int(latest_gate_version[1:], 0)

if latest_version_num > 0:
    gates_obj = load_json(os.path.join(completion_dir, f"gates.v{latest_version_num}.json"))
    if isinstance(gates_obj, list):
        gates_total = len(gates_obj)

    results_obj = load_json(os.path.join(completion_dir, "proof", f"results.v{latest_version_num}.json"))
    if isinstance(results_obj, list) and results_obj:
        for item in results_obj:
            if not isinstance(item, dict):
                continue
            status_value = str(item.get("status", "")).lower()
            if status_value == "pass" and str(item.get("exit_code")) == "0":
                gates_passed += 1
            else:
                gates_failed += 1
        if gates_total == 0:
            gates_total = len(results_obj)
    elif gates_total > 0:
        gates_failed = gates_total

if gates_total > 0 and gates_passed + gates_failed == 0:
    gates_failed = gates_total
elif gates_total == 0 and gates_passed + gates_failed > 0:
    gates_total = gates_passed + gates_failed

obj = {
    "schema_version": "run_report.v1",
    "run_id": run_id,
    "adapter": adapter,
    "status": status,
    "exit_code": 0 if status == "passed" else 1,
    "duration_seconds": to_int(duration_seconds, 0),
    "gating_mode": gating_mode,
    "repair_iterations_used": to_int(repair_iterations_used, 0),
    "max_iter": to_int(max_iter, 0),
    "max_gate_revisions": to_int(max_gate_revisions, 0),
    "model_gate_timeout_sec": to_int(model_gate_timeout_sec, 0),
    "latest_gate_version": latest_gate_version,
    "adapter_nonzero_runs": to_int(adapter_nonzero_runs, 0),
    "gates": {
        "total": gates_total,
        "passed": gates_passed,
        "failed": gates_failed,
    },
    "outcomes": {
        "total": outcomes_total,
        "core": outcomes_core,
        "non_core": outcomes_non_core,
    },
    "started_at": started_at,
    "finished_at": finished_at,
}

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(obj, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

andvari_print_final_status_and_exit() {
  if [[ "$STATUS" == "passed" ]]; then
    echo "[andvari] status: PASS"
    echo "[andvari] run folder: ${RUN_DIR}"
    exit 0
  fi

  echo "[andvari] status: FAIL"
  echo "[andvari] run folder: ${RUN_DIR}"
  echo "[andvari] see logs: ${GATE_LOG}, ${ADAPTER_STDERR_LOG}, ${EVENTS_LOG}"
  exit 1
}
