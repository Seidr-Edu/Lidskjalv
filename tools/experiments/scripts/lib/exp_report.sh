#!/usr/bin/env bash
# exp_report.sh - experiment JSON and markdown reporting.

set -euo pipefail

exp_write_reports() {
  local finished
  finished="$(exp_timestamp_iso_utc)"

  python3 - <<'PY' \
    "$EXP_JSON" "$RUN_ID" "$EXP_STARTED_AT" "$finished" "$DIAGRAM_PATH" "$DIAGRAM_SHA" \
    "$SOURCE_REPO_RAW" "$SOURCE_TYPE" "$SOURCE_REF" "$SOURCE_SUBDIR" "$ORIGINAL_SOURCE_KEY" "$ORIGINAL_DISPLAY_NAME" \
    "$ORIGINAL_GIT_COMMIT" "$ORIGINAL_GIT_REMOTE" \
    "$ANDVARI_RUN_DIR" "$ANDVARI_EXIT_CODE" "$ANDVARI_RUN_REPORT" "$ANDVARI_RUN_REPORT_JSON" \
    "${ANDVARI_REUSED:-false}" "${ANDVARI_REUSE_SOURCE_RUN_ID:-}" "${ANDVARI_REUSE_GENERATED_REPO:-}" \
    "$SCAN_ORIGINAL_MODE" "$ORIGINAL_SCAN_STATUS" "$ORIGINAL_SCAN_REUSED" "$ORIGINAL_SCAN_KEY" "$ORIGINAL_SCAN_DISPLAY_NAME" \
    "$ORIGINAL_SCAN_SONAR_URL" "$ORIGINAL_SCAN_QUALITY_GATE" "$ORIGINAL_SCAN_MEASURES_JSON" "$ORIGINAL_SCAN_STATE_LOG_DIR" \
    "$ORIGINAL_SCAN_SONAR_TASK_ID" "$ORIGINAL_SCAN_CE_TASK_STATUS" "$ORIGINAL_SCAN_DATA_STATUS" \
    "$ORIGINAL_SCAN_BUILD_TOOL" "$ORIGINAL_SCAN_BUILD_JDK" "$ORIGINAL_SCAN_FAILURE_REASON" "$ORIGINAL_SCAN_FAILURE_MESSAGE" \
    "$GENERATED_SCAN_STATUS" "$GENERATED_SONAR_KEY" "$GENERATED_DISPLAY_NAME" \
    "$GENERATED_SCAN_SONAR_URL" "$GENERATED_SCAN_QUALITY_GATE" "$GENERATED_SCAN_MEASURES_JSON" "$GENERATED_SCAN_STATE_LOG_DIR" \
    "$GENERATED_SCAN_SONAR_TASK_ID" "$GENERATED_SCAN_CE_TASK_STATUS" "$GENERATED_SCAN_DATA_STATUS" \
    "$GENERATED_SCAN_BUILD_TOOL" "$GENERATED_SCAN_BUILD_JDK" "$GENERATED_SCAN_FAILURE_REASON" "$GENERATED_SCAN_FAILURE_MESSAGE" \
    "$TEST_PORT_MODE" "$STRICT_TEST_PORT" "$TEST_PORT_STATUS" "$TEST_PORT_REASON" "$TEST_PORT_FAILURE_CLASS" "$TEST_PORT_ADAPTER_PREREQS_OK" \
    "$TEST_PORT_NEW_REPO_UNCHANGED" "$TEST_PORT_WRITE_SCOPE_POLICY" "$TEST_PORT_WRITE_SCOPE_VIOLATION_COUNT" \
    "$TEST_PORT_WRITE_SCOPE_FAILURE_PATHS_FILE" "$TEST_PORT_WRITE_SCOPE_DIFF_FILE" \
    "$TEST_PORT_ITERATIONS_USED" "$TEST_PORT_ADAPTER_NONZERO" \
    "$BASELINE_ORIGINAL_STATUS" "$BASELINE_ORIGINAL_RC" "$BASELINE_ORIGINAL_LOG_PATH" \
    "$BASELINE_GENERATED_STATUS" "$BASELINE_GENERATED_RC" "$BASELINE_GENERATED_LOG_PATH" \
    "$PORTED_ORIGINAL_TESTS_STATUS" "$PORTED_ORIGINAL_TESTS_EXIT_CODE" "$PORTED_ORIGINAL_TESTS_LOG_PATH" \
    "$EVENTS_LOG" "$ADAPTER_STDERR_LOG" "$OUTPUT_LAST_MESSAGE" \
    "$TEST_PORT_TOOL_RUN_DIR" "$TEST_PORT_TOOL_JSON_PATH" "$TEST_PORT_TOOL_SUMMARY_PATH" "$TEST_PORT_TOOL_LOG_PATH" \
    "$EXP_SUMMARY_MD"
import glob, json, os, sys
import xml.etree.ElementTree as ET

(
 exp_json, exp_id, started_at, finished_at, diagram, diagram_sha,
 src_raw, src_type, src_ref, src_subdir, src_key, src_name,
 src_commit, src_remote,
 andvari_dir, andvari_exit, andvari_report, andvari_report_json,
 andvari_reused, andvari_reuse_source_run_id, andvari_reuse_generated_repo,
 scan_orig_mode, scan_orig_status, scan_orig_reused, scan_orig_key, scan_orig_name,
 scan_orig_url, scan_orig_qg, scan_orig_measures_json, scan_orig_state_log_dir,
 scan_orig_task_id, scan_orig_ce_status, scan_orig_data_status,
 scan_orig_build_tool, scan_orig_build_jdk, scan_orig_failure_reason, scan_orig_failure_message,
 scan_gen_status, scan_gen_key, scan_gen_name,
 scan_gen_url, scan_gen_qg, scan_gen_measures_json, scan_gen_state_log_dir,
 scan_gen_task_id, scan_gen_ce_status, scan_gen_data_status,
 scan_gen_build_tool, scan_gen_build_jdk, scan_gen_failure_reason, scan_gen_failure_message,
 test_port_mode, strict_tp, test_port_status, test_port_reason, test_port_failure_class, test_port_adapter_prereqs_ok,
 new_repo_unchanged, write_scope_policy, write_scope_violations_count,
 write_scope_fail_paths_file, write_scope_diff_file,
 tp_iters, tp_nonzero,
 baseline_orig_status, baseline_orig_rc, baseline_orig_log,
 baseline_gen_status, baseline_gen_rc, baseline_gen_log,
 ported_status, ported_rc, ported_log,
 adapter_events_log, adapter_stderr_log, adapter_last_message,
 test_port_tool_run_dir, test_port_tool_json_path, test_port_tool_summary_path, test_port_tool_log_path,
 summary_md
) = sys.argv[1:]

def parse_json_obj(raw):
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except Exception:
        return {}
    return parsed if isinstance(parsed, dict) else {}

def load_json_file(path):
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            parsed = json.load(f)
    except Exception:
        return None
    return parsed if isinstance(parsed, dict) else None

def read_violation_entries(path):
    out = []
    if not path or not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                out.append({"kind": parts[0], "path": parts[1]})
            else:
                out.append({"kind": "", "path": line})
    return out

def read_change_set_stats(path):
    stats = {"A": 0, "M": 0, "D": 0, "total": 0}
    if not path or not os.path.exists(path):
        return stats
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t", 1)
            kind = parts[0] if parts else ""
            if kind in stats:
                stats[kind] += 1
            stats["total"] += 1
    return stats

def is_allowed_test_rel(rel):
    if (
        rel.startswith("./src/test/") or
        rel.startswith("./test/") or
        rel.startswith("./tests/")
    ):
        return True
    if rel.startswith("./src/"):
        parts = rel.split("/", 4)
        return len(parts) > 2 and "Test" in parts[2]
    return False

def count_allowed_test_files(repo_dir):
    if not repo_dir or not os.path.isdir(repo_dir):
        return 0
    excluded_parts = {".git", "target", "build", ".gradle", ".scannerwork", "out"}
    count = 0
    for root, dirs, files in os.walk(repo_dir):
        rel_root = os.path.relpath(root, repo_dir)
        parts = [] if rel_root == "." else rel_root.split(os.sep)
        dirs[:] = [d for d in dirs if d not in excluded_parts]
        if any(p in excluded_parts for p in parts):
            continue
        for name in files:
            rel = "./" + (name if rel_root == "." else os.path.join(rel_root, name))
            rel = rel.replace(os.sep, "/")
            if is_allowed_test_rel(rel):
                count += 1
    return count

def count_all_files(path):
    if not path or not os.path.isdir(path):
        return 0
    total = 0
    for _, _, files in os.walk(path):
        total += len(files)
    return total

def to_int(value, default=0):
    try:
        return int(value)
    except Exception:
        return default

def collect_junit_failing_cases(repo_dir, max_cases=200, max_groups=500, max_sample_reports=3):
    out = {
        "junit_report_count": 0,
        "junit_report_files": [],
        "failing_case_count": 0,
        "failing_case_unique_count": 0,
        "failing_case_occurrence_count": 0,
        "failing_cases": [],
        "grouped_failing_cases": [],
        "truncated": False,
        "grouped_truncated": False,
    }
    if not repo_dir or not os.path.isdir(repo_dir):
        return out

    patterns = [
        "target/surefire-reports/*.xml",
        "target/failsafe-reports/*.xml",
        "build/test-results/test/*.xml",
        "build/test-results/**/*.xml",
    ]
    report_files = []
    seen_files = set()
    for pat in patterns:
        for path in glob.glob(os.path.join(repo_dir, pat), recursive=True):
            if not os.path.isfile(path):
                continue
            if path in seen_files:
                continue
            if not path.lower().endswith(".xml"):
                continue
            seen_files.add(path)
            report_files.append(path)

    report_files.sort()
    out["junit_report_count"] = len(report_files)
    out["junit_report_files"] = [
        os.path.relpath(p, repo_dir).replace(os.sep, "/") for p in report_files
    ]

    grouped_index = {}
    unique_case_count = 0
    for report_path in report_files:
        rel_report = os.path.relpath(report_path, repo_dir).replace(os.sep, "/")
        try:
            root = ET.parse(report_path).getroot()
        except Exception:
            continue

        for tc in root.iter("testcase"):
            classname = tc.attrib.get("classname") or ""
            name = tc.attrib.get("name") or ""
            for child in list(tc):
                if child.tag not in {"failure", "error"}:
                    continue
                out["failing_case_occurrence_count"] += 1
                kind = child.tag
                msg = (child.attrib.get("message") or "").strip()
                if not msg:
                    text = (child.text or "").strip()
                    msg = " ".join(text.split())[:240]
                elif len(msg) > 240:
                    msg = msg[:237] + "..."

                key = (classname, name, kind, msg)
                group_idx = grouped_index.get(key)
                if group_idx is None:
                    unique_case_count += 1
                    if len(out["grouped_failing_cases"]) < max_groups:
                        out["grouped_failing_cases"].append({
                            "class": classname,
                            "name": name,
                            "kind": kind,
                            "message": msg,
                            "occurrence_count": 1,
                            "sample_report_files": [rel_report],
                        })
                        group_idx = len(out["grouped_failing_cases"]) - 1
                        grouped_index[key] = group_idx
                    else:
                        out["grouped_truncated"] = True

                    if len(out["failing_cases"]) < max_cases:
                        out["failing_cases"].append({
                            "class": classname,
                            "name": name,
                            "kind": kind,
                            "message": msg,
                            "report_file": rel_report,
                        })
                    else:
                        out["truncated"] = True
                else:
                    group = out["grouped_failing_cases"][group_idx]
                    group["occurrence_count"] += 1
                    samples = group["sample_report_files"]
                    if rel_report not in samples and len(samples) < max_sample_reports:
                        samples.append(rel_report)

    out["failing_case_unique_count"] = unique_case_count
    out["failing_case_count"] = unique_case_count
    return out

andvari_exit_i = to_int(andvari_exit, -1)
andvari_metrics = load_json_file(andvari_report_json) or {}
strict_tp_b = strict_tp == "true"
tp_enabled = test_port_mode == "on"
tp_informational = not strict_tp_b
tp_status = test_port_status or "skipped"

core_failed = (
    andvari_exit_i != 0 or
    scan_orig_status not in {"success", "skipped"} or
    scan_gen_status not in {"success", "skipped"}
)
strict_tp_failed = tp_enabled and strict_tp_b and tp_status != "passed"
tp_warn = tp_enabled and (not strict_tp_b) and tp_status not in {"passed", "skipped"}

if core_failed or strict_tp_failed:
    overall_status = "failed"
elif tp_warn:
    overall_status = "completed_with_warnings"
else:
    overall_status = "completed"

if andvari_exit_i == 0:
    andvari_status = "passed"
elif os.path.isdir(os.path.join(andvari_dir, "new_repo")):
    andvari_status = "partial"
else:
    andvari_status = "failed"

tp_root = ""
write_guard_dir = os.path.dirname(write_scope_diff_file) if write_scope_diff_file else ""
if write_guard_dir:
    tp_root = os.path.dirname(write_guard_dir)

change_set_path = os.path.join(write_guard_dir, "ported-protected-change-set.tsv") if write_guard_dir else ""
ported_repo_dir = os.path.join(tp_root, "ported-tests-repo") if tp_root else ""
snapshot_dir = os.path.join(tp_root, "original-tests-snapshot") if tp_root else ""

tp_change_stats = read_change_set_stats(change_set_path)
tp_original_snapshot_file_count = count_all_files(snapshot_dir)
tp_final_test_file_count = count_allowed_test_files(ported_repo_dir)
tp_behavioral_evidence = collect_junit_failing_cases(ported_repo_dir)
tp_retention_ratio = None
if tp_original_snapshot_file_count > 0:
    tp_retention_ratio = tp_final_test_file_count / tp_original_snapshot_file_count

if tp_status == "failed" and test_port_reason == "write-scope-violation":
    tp_behavioral_verdict = "invalid"
    tp_behavioral_verdict_reason = "write-scope-violation"
elif tp_status == "failed" and test_port_reason == "insufficient-test-evidence":
    tp_behavioral_verdict = "invalid"
    tp_behavioral_verdict_reason = test_port_failure_class or "insufficient-test-evidence"
elif tp_status == "failed" and (
    tp_behavioral_evidence.get("failing_case_count", 0) > 0
    or test_port_reason == "behavioral-difference-evidence"
    or test_port_failure_class == "behavioral-mismatch"
):
    tp_behavioral_verdict = "difference_detected"
    tp_behavioral_verdict_reason = "assertion-mismatch-evidence"
elif tp_status == "failed" and test_port_reason == "tests-failed":
    tp_behavioral_verdict = "inconclusive"
    tp_behavioral_verdict_reason = test_port_failure_class or "ported-tests-failed"
elif tp_status == "passed":
    if tp_original_snapshot_file_count > 0 and tp_final_test_file_count < tp_original_snapshot_file_count:
        tp_behavioral_verdict = "inconclusive"
        tp_behavioral_verdict_reason = "suite-reduced-during-adaptation"
    else:
        tp_behavioral_verdict = "no_difference_detected"
        tp_behavioral_verdict_reason = "retained-ported-tests-pass"
elif tp_status == "skipped":
    tp_behavioral_verdict = "skipped"
    tp_behavioral_verdict_reason = test_port_reason or "stage-skipped"
else:
    tp_behavioral_verdict = "inconclusive"
    tp_behavioral_verdict_reason = test_port_reason or "stage-failed"

obj = {
  "version": 1,
  "experiment_id": exp_id,
  "status": overall_status,
  "started_at": started_at,
  "finished_at": finished_at,
  "inputs": {
    "diagram_path": diagram,
    "diagram_sha256": diagram_sha,
    "source_repo": {
      "raw": src_raw,
      "type": src_type,
      "normalized_ref": src_ref,
      "subdir": src_subdir,
      "key": src_key,
      "display_name": src_name,
      "git": {
        "commit": src_commit,
        "remote": src_remote
      }
    }
  },
  "andvari": {
    "run_id": exp_id,
    "run_dir": andvari_dir,
    "exit_code": andvari_exit_i,
    "status": andvari_status,
    "reused": andvari_reused == "true",
    "reuse_source_run_id": andvari_reuse_source_run_id,
    "reuse_generated_repo": andvari_reuse_generated_repo,
    "run_report_path": andvari_report,
    "run_report_json_path": andvari_report_json,
    "metrics": andvari_metrics
  },
  "scans": {
    "original": {
      "mode": scan_orig_mode,
      "reused": scan_orig_reused == "true",
      "project_key": scan_orig_key,
      "project_name": scan_orig_name,
      "status": scan_orig_status,
      "sonar_url": scan_orig_url,
      "quality_gate": scan_orig_qg,
      "sonar_task_id": scan_orig_task_id,
      "ce_task_status": scan_orig_ce_status,
      "scan_data_status": scan_orig_data_status,
      "measures": parse_json_obj(scan_orig_measures_json),
      "state_log_dir": scan_orig_state_log_dir,
      "build_tool": scan_orig_build_tool,
      "build_jdk": scan_orig_build_jdk,
      "failure_reason": scan_orig_failure_reason,
      "failure_message": scan_orig_failure_message
    },
    "generated": {
      "project_key": scan_gen_key,
      "project_name": scan_gen_name,
      "status": scan_gen_status,
      "sonar_url": scan_gen_url,
      "quality_gate": scan_gen_qg,
      "sonar_task_id": scan_gen_task_id,
      "ce_task_status": scan_gen_ce_status,
      "scan_data_status": scan_gen_data_status,
      "measures": parse_json_obj(scan_gen_measures_json),
      "state_log_dir": scan_gen_state_log_dir,
      "build_tool": scan_gen_build_tool,
      "build_jdk": scan_gen_build_jdk,
      "failure_reason": scan_gen_failure_reason,
      "failure_message": scan_gen_failure_message
    }
  },
  "test_port": {
    "enabled": tp_enabled,
    "informational": tp_informational,
    "status": tp_status,
    "reason": test_port_reason,
    "failure_class": test_port_failure_class,
    "adapter_prereqs_ok": test_port_adapter_prereqs_ok == "true",
    "new_repo_unchanged": new_repo_unchanged == "true",
    "write_scope": {
      "policy": write_scope_policy,
      "violation_count": to_int(write_scope_violations_count, 0),
      "violations": read_violation_entries(write_scope_fail_paths_file),
      "violations_log_path": write_scope_fail_paths_file,
      "diff_path": write_scope_diff_file
    },
    "behavioral_verdict": tp_behavioral_verdict,
    "behavioral_verdict_reason": tp_behavioral_verdict_reason,
    "behavioral_evidence": tp_behavioral_evidence,
    "suite_changes": {
      "change_set_path": change_set_path,
      "added": tp_change_stats["A"],
      "modified": tp_change_stats["M"],
      "deleted": tp_change_stats["D"],
      "total": tp_change_stats["total"]
    },
    "suite_shape": {
      "original_snapshot_file_count": tp_original_snapshot_file_count,
      "final_ported_test_file_count": tp_final_test_file_count,
      "retention_ratio": tp_retention_ratio
    },
    "baseline_original_tests": {
      "status": baseline_orig_status,
      "exit_code": to_int(baseline_orig_rc, -1),
      "log_path": baseline_orig_log
    },
    "baseline_generated_tests": {
      "status": baseline_gen_status,
      "exit_code": to_int(baseline_gen_rc, -1),
      "log_path": baseline_gen_log
    },
    "ported_original_tests": {
      "status": ported_status,
      "exit_code": to_int(ported_rc, -1),
      "iterations_used": to_int(tp_iters, 0),
      "adapter_nonzero_runs": to_int(tp_nonzero, 0),
      "log_path": ported_log
    },
    "adapter": {
      "events_log": adapter_events_log,
      "stderr_log": adapter_stderr_log,
      "last_message_path": adapter_last_message
    }
  },
  "artifacts": {
    "summary_md": summary_md
  }
}

tp_tool_obj = load_json_file(test_port_tool_json_path)
if tp_tool_obj is not None:
    tp_tool_obj = dict(tp_tool_obj)
    tp_tool_obj.setdefault("enabled", tp_enabled)
    tp_tool_obj.setdefault("informational", tp_informational)
    if isinstance(tp_tool_obj.get("immutability"), dict):
        tp_tool_obj.setdefault("new_repo_unchanged", tp_tool_obj["immutability"].get("generated_repo_unchanged"))
    tp_tool_obj["tool_run_dir"] = test_port_tool_run_dir
    tp_tool_obj["tool_json_path"] = test_port_tool_json_path
    tp_tool_obj["tool_summary_path"] = test_port_tool_summary_path
    if test_port_tool_log_path:
        tp_tool_obj["tool_log_path"] = test_port_tool_log_path
    obj["test_port"] = tp_tool_obj

if isinstance(obj.get("test_port"), dict):
    obj["test_port"].setdefault("tool_run_dir", test_port_tool_run_dir)
    obj["test_port"].setdefault("tool_json_path", test_port_tool_json_path)
    obj["test_port"].setdefault("tool_summary_path", test_port_tool_summary_path)
    if test_port_tool_log_path:
        obj["test_port"].setdefault("tool_log_path", test_port_tool_log_path)

with open(exp_json, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)
PY

  local tp_change_set_path=""
  local tp_add=0
  local tp_mod=0
  local tp_del=0
  local tp_total_changes=0
  local tp_orig_snapshot_files=0
  local tp_final_test_files=0
  local tp_retained_original_files=0
  local tp_removed_original_files=0
  local tp_retained_modified_files=0
  local tp_retained_unchanged_files=0
  local tp_assertion_line_change_count=0
  local tp_behavioral_verdict="inconclusive"
  local tp_behavioral_verdict_reason="unknown"
  local tp_status_detail=""
  local tp_behavioral_case_count=0
  local tp_failure_class_legacy=""
  local tp_runner_preflight_runner=""
  local tp_runner_preflight_supported=""
  local tp_runner_preflight_missing=""
  local tp_runner_preflight_frameworks=""
  local tp_runner_preflight_module_root=""
  local tp_ported_exec_tests_executed=0
  local tp_baseline_original_exec_tests_executed=0
  local tp_baseline_generated_exec_tests_executed=0
  local tp_retention_policy_mode="maximize-retained-original-tests"
  local tp_undocumented_removed_count=0

  tp_change_set_path="${TEST_PORT_WRITE_SCOPE_CHANGE_SET_PATH:-}"
  tp_add="${TEST_PORT_SUITE_CHANGES_ADDED:-0}"
  tp_mod="${TEST_PORT_SUITE_CHANGES_MODIFIED:-0}"
  tp_del="${TEST_PORT_SUITE_CHANGES_DELETED:-0}"
  tp_total_changes="${TEST_PORT_SUITE_CHANGES_TOTAL:-0}"
  tp_orig_snapshot_files="${TEST_PORT_SUITE_SHAPE_ORIGINAL_SNAPSHOT_FILE_COUNT:-0}"
  tp_final_test_files="${TEST_PORT_SUITE_SHAPE_FINAL_PORTED_TEST_FILE_COUNT:-0}"
  tp_retained_original_files="${TEST_PORT_SUITE_SHAPE_RETAINED_ORIGINAL_TEST_FILE_COUNT:-0}"
  tp_removed_original_files="${TEST_PORT_SUITE_SHAPE_REMOVED_ORIGINAL_TEST_FILE_COUNT:-0}"
  tp_retained_modified_files="${TEST_PORT_SUITE_SHAPE_RETAINED_MODIFIED_COUNT:-0}"
  tp_retained_unchanged_files="${TEST_PORT_SUITE_SHAPE_RETAINED_UNCHANGED_COUNT:-0}"
  tp_assertion_line_change_count="${TEST_PORT_SUITE_SHAPE_ASSERTION_LINE_CHANGE_COUNT:-0}"
  tp_behavioral_verdict="${TEST_PORT_BEHAVIORAL_VERDICT:-inconclusive}"
  tp_behavioral_verdict_reason="${TEST_PORT_BEHAVIORAL_VERDICT_REASON:-unknown}"
  tp_status_detail="${TEST_PORT_STATUS_DETAIL:-}"
  tp_behavioral_case_count="${TEST_PORT_BEHAVIORAL_FAILING_CASE_COUNT:-0}"
  tp_failure_class_legacy="${TEST_PORT_FAILURE_CLASS_LEGACY:-}"
  tp_runner_preflight_runner="${TEST_PORT_RUNNER_PREFLIGHT_RUNNER:-}"
  tp_runner_preflight_supported="${TEST_PORT_RUNNER_PREFLIGHT_SUPPORTED:-}"
  tp_runner_preflight_missing="${TEST_PORT_RUNNER_PREFLIGHT_MISSING:-}"
  tp_runner_preflight_frameworks="${TEST_PORT_RUNNER_PREFLIGHT_FRAMEWORKS:-}"
  tp_runner_preflight_module_root="${TEST_PORT_RUNNER_PREFLIGHT_MODULE_ROOT:-}"
  tp_ported_exec_tests_executed="${PORTED_EXEC_TESTS_EXECUTED:-0}"
  tp_baseline_original_exec_tests_executed="${BASELINE_ORIGINAL_EXEC_TESTS_EXECUTED:-0}"
  tp_baseline_generated_exec_tests_executed="${BASELINE_GENERATED_EXEC_TESTS_EXECUTED:-0}"
  tp_retention_policy_mode="${TEST_PORT_RETENTION_POLICY_MODE:-maximize-retained-original-tests}"
  tp_undocumented_removed_count="${TEST_PORT_RETENTION_UNDOCUMENTED_REMOVED_TEST_COUNT:-0}"

  cat > "$EXP_SUMMARY_MD" <<MD
# Experiment Summary

- Experiment ID: ${RUN_ID}
- Diagram: ${DIAGRAM_PATH}
- Source: ${SOURCE_REPO_RAW}
- Source subdir: ${SOURCE_SUBDIR:-<none>}
- Andvari exit code: ${ANDVARI_EXIT_CODE}
- Andvari reused: **${ANDVARI_REUSED:-false}**
- Andvari reuse source run id: ${ANDVARI_REUSE_SOURCE_RUN_ID:-<none>}
- Andvari reuse generated repo: ${ANDVARI_REUSE_GENERATED_REPO:-<none>}
- Andvari report: ${ANDVARI_RUN_REPORT}

## Scans
- Original scan mode: ${SCAN_ORIGINAL_MODE}
- Original key: ${ORIGINAL_SCAN_KEY} (status: **${ORIGINAL_SCAN_STATUS}**, reused: **${ORIGINAL_SCAN_REUSED}**)
- Original Sonar URL: ${ORIGINAL_SCAN_SONAR_URL:-<none>}
- Original quality gate: ${ORIGINAL_SCAN_QUALITY_GATE:-<unknown>}
- Original scan data status: **${ORIGINAL_SCAN_DATA_STATUS:-unavailable}**
- Original Sonar task ID: ${ORIGINAL_SCAN_SONAR_TASK_ID:-<none>}
- Original CE task status: ${ORIGINAL_SCAN_CE_TASK_STATUS:-<none>}
- Generated key: ${GENERATED_SONAR_KEY} (status: **${GENERATED_SCAN_STATUS}**)
- Generated Sonar URL: ${GENERATED_SCAN_SONAR_URL:-<none>}
- Generated quality gate: ${GENERATED_SCAN_QUALITY_GATE:-<unknown>}
- Generated scan data status: **${GENERATED_SCAN_DATA_STATUS:-unavailable}**
- Generated Sonar task ID: ${GENERATED_SCAN_SONAR_TASK_ID:-<none>}
- Generated CE task status: ${GENERATED_SCAN_CE_TASK_STATUS:-<none>}

## Test-port
- Enabled: **${TEST_PORT_MODE}**
- Status: **${TEST_PORT_STATUS}**
- Status detail: ${tp_status_detail:-<none>}
- Behavioral verdict: **${tp_behavioral_verdict}**
- Behavioral verdict reason: ${tp_behavioral_verdict_reason}
- Reason: ${TEST_PORT_REASON:-<none>}
- Failure classifier: ${TEST_PORT_FAILURE_CLASS:-<none>}
- Failure classifier (legacy): ${tp_failure_class_legacy:-<none>}
- Observed failing test cases (from JUnit reports): **${tp_behavioral_case_count}**
- Runner preflight: runner=${tp_runner_preflight_runner:-<none>}, supported=${tp_runner_preflight_supported:-<none>}, module_root=${tp_runner_preflight_module_root:-<none>}
- Runner missing capabilities: ${tp_runner_preflight_missing:-<none>}
- Runner frameworks detected: ${tp_runner_preflight_frameworks:-<none>}
- Adapter prereqs OK: **${TEST_PORT_ADAPTER_PREREQS_OK}**
- Tool run dir: ${TEST_PORT_TOOL_RUN_DIR:-<none>}
- Tool summary: ${TEST_PORT_TOOL_SUMMARY_PATH:-<none>}
- Tool JSON: ${TEST_PORT_TOOL_JSON_PATH:-<none>}
- Tool log: ${TEST_PORT_TOOL_LOG_PATH:-<none>}
- New repo unchanged: **${TEST_PORT_NEW_REPO_UNCHANGED}**
- Write-scope policy: **${TEST_PORT_WRITE_SCOPE_POLICY}**
- Write-scope violations: **${TEST_PORT_WRITE_SCOPE_VIOLATION_COUNT}**
- Retention policy: **${tp_retention_policy_mode}**
- Suite changes (A/M/D/total): **${tp_add}/${tp_mod}/${tp_del}/${tp_total_changes}**
- Test files (original snapshot -> final ported): **${tp_orig_snapshot_files} -> ${tp_final_test_files}**
- Retained original tests: **${tp_retained_original_files}**
- Removed original tests: **${tp_removed_original_files}**
- Retained modified/unchanged: **${tp_retained_modified_files}/${tp_retained_unchanged_files}**
- Assertion line changes in retained tests: **${tp_assertion_line_change_count}**
- Undocumented removed tests: **${tp_undocumented_removed_count}**
- Iterations used: **${TEST_PORT_ITERATIONS_USED}**
- Adapter non-zero runs: **${TEST_PORT_ADAPTER_NONZERO}**
- Baseline original tests: **${BASELINE_ORIGINAL_STATUS}** (exit ${BASELINE_ORIGINAL_RC}) log: ${BASELINE_ORIGINAL_LOG_PATH:-<none>}
- Baseline original executed tests: **${tp_baseline_original_exec_tests_executed}**
- Baseline generated tests: **${BASELINE_GENERATED_STATUS}** (exit ${BASELINE_GENERATED_RC}) log: ${BASELINE_GENERATED_LOG_PATH:-<none>}
- Baseline generated executed tests: **${tp_baseline_generated_exec_tests_executed}**
- Ported original tests: **${PORTED_ORIGINAL_TESTS_STATUS}** (exit ${PORTED_ORIGINAL_TESTS_EXIT_CODE}) log: ${PORTED_ORIGINAL_TESTS_LOG_PATH:-<none>}
- Ported executed tests: **${tp_ported_exec_tests_executed}**
- Note: test-port \`Status\` is execution status of the adapted suite; \`Behavioral verdict\` estimates evidentiary strength for functional equivalence/difference. Detailed failing cases are in \`experiment.json\` under \`test_port.behavioral_evidence.failing_cases\`.
MD
}
