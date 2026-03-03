#!/usr/bin/env bash
# tp_report.sh - standalone test-port JSON/markdown reporting.

set -euo pipefail

tp_write_reports() {
  local finished
  finished="$(tp_timestamp_iso_utc)"

  python3 - <<'PY' \
    "$TP_JSON_PATH" "$TP_SUMMARY_MD_PATH" "$TP_RUN_ID" "$TP_STARTED_AT" "$finished" \
    "$TP_GENERATED_REPO" "$TP_ORIGINAL_REPO" "$TP_ORIGINAL_SUBDIR" "$TP_ORIGINAL_EFFECTIVE_PATH" "$TP_DIAGRAM_PATH" \
    "$TP_ADAPTER" "$TP_MAX_ITER" "$TP_STRICT" "$TP_WRITE_SCOPE_POLICY" \
    "$TP_STATUS" "$TP_REASON" "$TP_FAILURE_CLASS" "$TP_ADAPTER_PREREQS_OK" \
    "$TP_BEHAVIORAL_VERDICT" "$TP_BEHAVIORAL_VERDICT_REASON" \
    "$TP_GENERATED_REPO_UNCHANGED" "$TP_GENERATED_BEFORE_HASH_PATH" "$TP_GENERATED_AFTER_HASH_PATH" \
    "$TP_WRITE_SCOPE_VIOLATION_COUNT" "$TP_WRITE_SCOPE_FAILURE_PATHS_FILE" "$TP_WRITE_SCOPE_DIFF_FILE" "$TP_WRITE_SCOPE_CHANGE_SET_PATH" \
    "$TP_WRITE_SCOPE_IGNORED_PREFIXES_CSV" \
    "$TP_BASELINE_ORIGINAL_STATUS" "$TP_BASELINE_ORIGINAL_RC" "$TP_BASELINE_ORIGINAL_LOG" \
    "$TP_BASELINE_GENERATED_STATUS" "$TP_BASELINE_GENERATED_RC" "$TP_BASELINE_GENERATED_LOG" \
    "$TP_PORTED_ORIGINAL_TESTS_STATUS" "$TP_PORTED_ORIGINAL_TESTS_EXIT_CODE" "$TP_PORTED_ORIGINAL_TESTS_LOG" \
    "$TP_ITERATIONS_USED" "$TP_ADAPTER_NONZERO_RUNS" \
    "$TP_ADAPTER_EVENTS_LOG" "$TP_ADAPTER_STDERR_LOG" "$TP_ADAPTER_LAST_MESSAGE" \
    "$TP_RUN_DIR" "$TP_LOG_DIR" "$TP_WORKSPACE_DIR" "$TP_OUTPUT_DIR" \
    "$TP_PORTED_REPO" "$TP_ORIGINAL_TESTS_SNAPSHOT"
import glob, json, os, sys
import xml.etree.ElementTree as ET

(
  json_path, summary_path, run_id, started_at, finished_at,
  generated_repo, original_repo, original_subdir, original_effective_path, diagram_path,
  adapter, max_iter, strict_b, write_scope_policy,
  status, reason, failure_class, adapter_prereqs_ok,
  behavioral_verdict, behavioral_verdict_reason,
  generated_unchanged, generated_before_hash_path, generated_after_hash_path,
  write_scope_violation_count, write_scope_fail_paths, write_scope_diff_path, write_scope_change_set_path,
  write_scope_ignored_prefixes_csv,
  baseline_orig_status, baseline_orig_rc, baseline_orig_log,
  baseline_gen_status, baseline_gen_rc, baseline_gen_log,
  ported_status, ported_rc, ported_log,
  iterations_used, adapter_nonzero_runs,
  adapter_events_log, adapter_stderr_log, adapter_last_message,
  run_dir, log_dir, workspace_dir, output_dir,
  ported_repo_dir, original_tests_snapshot_dir
) = sys.argv[1:]

def to_int(v, default=0):
    try:
        return int(v)
    except Exception:
        return default

def to_float(v):
    try:
        return float(v)
    except Exception:
        return None

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

def parse_prefixes(csv_value):
    if not csv_value:
        return []
    return [part for part in csv_value.split(":") if part]

def is_allowed_test_rel(rel):
    if rel.startswith("./src/test/") or rel.startswith("./test/") or rel.startswith("./tests/"):
        return True
    if rel.startswith("./src/"):
        parts = rel.split("/", 4)
        return len(parts) > 2 and "Test" in parts[2]
    return False

def count_allowed_test_files(repo_dir):
    if not repo_dir or not os.path.isdir(repo_dir):
        return 0
    excluded = {".git", "target", "build", ".gradle", ".scannerwork", "out"}
    count = 0
    for root, dirs, files in os.walk(repo_dir):
        rel_root = os.path.relpath(root, repo_dir)
        parts = [] if rel_root == "." else rel_root.split(os.sep)
        dirs[:] = [d for d in dirs if d not in excluded]
        if any(p in excluded for p in parts):
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

def collect_junit_failing_cases(repo_dir, max_cases=200):
    out = {
        "junit_report_count": 0,
        "junit_report_files": [],
        "failing_case_count": 0,
        "failing_cases": [],
        "truncated": False,
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
            if not os.path.isfile(path) or not path.lower().endswith(".xml"):
                continue
            if path in seen_files:
                continue
            seen_files.add(path)
            report_files.append(path)
    report_files.sort()
    out["junit_report_count"] = len(report_files)
    out["junit_report_files"] = [os.path.relpath(p, repo_dir).replace(os.sep, "/") for p in report_files]

    seen_cases = set()
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
                msg = (child.attrib.get("message") or "").strip()
                if not msg:
                    msg = " ".join((child.text or "").split())[:240]
                elif len(msg) > 240:
                    msg = msg[:237] + "..."
                kind = child.tag
                key = (classname, name, kind, msg)
                if key in seen_cases:
                    continue
                seen_cases.add(key)
                out["failing_case_count"] += 1
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
    return out

suite_changes = read_change_set_stats(write_scope_change_set_path)
orig_snapshot_file_count = count_all_files(original_tests_snapshot_dir)
final_ported_test_file_count = count_allowed_test_files(ported_repo_dir)
retention_ratio = None
if orig_snapshot_file_count > 0:
    retention_ratio = final_ported_test_file_count / orig_snapshot_file_count
behavioral_evidence = collect_junit_failing_cases(ported_repo_dir)

obj = {
    "version": 1,
    "run_id": run_id,
    "status": status or "skipped",
    "reason": reason,
    "failure_class": failure_class,
    "started_at": started_at,
    "finished_at": finished_at,
    "inputs": {
        "generated_repo": generated_repo,
        "original_repo": original_repo,
        "original_subdir": original_subdir,
        "original_effective_path": original_effective_path,
        "diagram_path": diagram_path,
        "adapter": adapter,
        "max_iter": to_int(max_iter, 0),
        "strict": strict_b == "true",
        "write_scope_policy": write_scope_policy,
    },
    "adapter_prereqs_ok": adapter_prereqs_ok == "true",
    "immutability": {
        "generated_repo_unchanged": generated_unchanged == "true",
        "before_hash_path": generated_before_hash_path,
        "after_hash_path": generated_after_hash_path,
    },
    "write_scope": {
        "policy": write_scope_policy,
        "violation_count": to_int(write_scope_violation_count, 0),
        "violations": read_violation_entries(write_scope_fail_paths),
        "violations_log_path": write_scope_fail_paths,
        "diff_path": write_scope_diff_path,
        "change_set_path": write_scope_change_set_path,
        "ignored_prefixes": parse_prefixes(write_scope_ignored_prefixes_csv),
    },
    "baseline_original_tests": {
        "status": baseline_orig_status,
        "exit_code": to_int(baseline_orig_rc, -1),
        "log_path": baseline_orig_log,
    },
    "baseline_generated_tests": {
        "status": baseline_gen_status,
        "exit_code": to_int(baseline_gen_rc, -1),
        "log_path": baseline_gen_log,
    },
    "ported_original_tests": {
        "status": ported_status,
        "exit_code": to_int(ported_rc, -1),
        "iterations_used": to_int(iterations_used, 0),
        "adapter_nonzero_runs": to_int(adapter_nonzero_runs, 0),
        "log_path": ported_log,
    },
    "behavioral_verdict": behavioral_verdict,
    "behavioral_verdict_reason": behavioral_verdict_reason,
    "behavioral_evidence": behavioral_evidence,
    "suite_changes": {
        "added": suite_changes["A"],
        "modified": suite_changes["M"],
        "deleted": suite_changes["D"],
        "total": suite_changes["total"],
    },
    "suite_shape": {
        "original_snapshot_file_count": orig_snapshot_file_count,
        "final_ported_test_file_count": final_ported_test_file_count,
        "retention_ratio": retention_ratio,
    },
    "adapter": {
        "events_log": adapter_events_log,
        "stderr_log": adapter_stderr_log,
        "last_message_path": adapter_last_message,
    },
    "artifacts": {
        "run_dir": run_dir,
        "logs_dir": log_dir,
        "workspace_dir": workspace_dir,
        "outputs_dir": output_dir,
        "summary_md": summary_path,
    },
}

os.makedirs(os.path.dirname(json_path), exist_ok=True)
with open(json_path, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=2)

summary_lines = [
    "# Test-Port Summary",
    "",
    f"- Run ID: {obj['run_id']}",
    f"- Generated repo: {obj['inputs']['generated_repo']}",
    f"- Original repo: {obj['inputs']['original_repo']}",
    f"- Original subdir: {obj['inputs']['original_subdir'] or '<none>'}",
    f"- Diagram: {obj['inputs']['diagram_path'] or '<none>'}",
    f"- Adapter: {obj['inputs']['adapter']}",
    f"- Status: **{obj['status']}**",
    f"- Reason: {obj.get('reason') or '<none>'}",
    f"- Failure classifier: {obj.get('failure_class') or '<none>'}",
    f"- Behavioral verdict: **{obj.get('behavioral_verdict') or '<none>'}**",
    f"- Behavioral verdict reason: {obj.get('behavioral_verdict_reason') or '<none>'}",
    f"- Adapter prereqs OK: **{str(obj.get('adapter_prereqs_ok', False)).lower()}**",
    f"- Generated repo unchanged: **{str(obj['immutability']['generated_repo_unchanged']).lower()}**",
    f"- Write-scope policy: **{obj['write_scope']['policy']}**",
    f"- Write-scope ignored prefixes: **{', '.join(obj['write_scope']['ignored_prefixes']) if obj['write_scope']['ignored_prefixes'] else '<none>'}**",
    f"- Write-scope violations: **{obj['write_scope']['violation_count']}**",
    f"- Suite changes (A/M/D/total): **{obj['suite_changes']['added']}/{obj['suite_changes']['modified']}/{obj['suite_changes']['deleted']}/{obj['suite_changes']['total']}**",
    f"- Test files (original snapshot -> final ported): **{obj['suite_shape']['original_snapshot_file_count']} -> {obj['suite_shape']['final_ported_test_file_count']}**",
    f"- Observed failing test cases (from JUnit reports): **{obj['behavioral_evidence']['failing_case_count']}**",
    f"- Iterations used: **{obj['ported_original_tests']['iterations_used']}**",
    f"- Adapter non-zero runs: **{obj['ported_original_tests']['adapter_nonzero_runs']}**",
    f"- Baseline original tests: **{obj['baseline_original_tests']['status']}** (exit {obj['baseline_original_tests']['exit_code']}) log: {obj['baseline_original_tests']['log_path'] or '<none>'}",
    f"- Baseline generated tests: **{obj['baseline_generated_tests']['status']}** (exit {obj['baseline_generated_tests']['exit_code']}) log: {obj['baseline_generated_tests']['log_path'] or '<none>'}",
    f"- Ported original tests: **{obj['ported_original_tests']['status']}** (exit {obj['ported_original_tests']['exit_code']}) log: {obj['ported_original_tests']['log_path'] or '<none>'}",
    "- Detailed failing cases are in `test_port.json` under `behavioral_evidence.failing_cases`.",
]

os.makedirs(os.path.dirname(summary_path), exist_ok=True)
with open(summary_path, "w", encoding="utf-8") as f:
    f.write("\n".join(summary_lines) + "\n")
PY
}
