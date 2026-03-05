#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
from typing import Any, Dict, List, Optional


def load_json(path: Path) -> Optional[Dict[str, Any]]:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def sanitize(value: Any) -> Any:
    if isinstance(value, str) and value.startswith("/"):
        return None
    if isinstance(value, dict):
        return {k: sanitize(v) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize(v) for v in value]
    return value


def to_float_or_none(value: Any) -> Optional[float]:
    try:
        if value is None or value == "":
            return None
        return float(value)
    except Exception:
        return None


def sonar_delta(orig: Dict[str, Any], gen: Dict[str, Any]) -> Dict[str, Any]:
    metrics = ["bugs", "vulnerabilities", "code_smells", "coverage", "duplicated_lines_density", "ncloc", "sqale_index"]
    out: Dict[str, Any] = {}
    for m in metrics:
        o = to_float_or_none((orig.get("measures") or {}).get(m) if isinstance(orig.get("measures"), dict) else None)
        g = to_float_or_none((gen.get("measures") or {}).get(m) if isinstance(gen.get("measures"), dict) else None)
        out[m] = None if o is None or g is None else g - o
    return out


def as_dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def as_list(value: Any) -> List[Any]:
    return value if isinstance(value, list) else []


def to_int_or_none(value: Any) -> Optional[int]:
    try:
        if value is None or value == "":
            return None
        return int(value)
    except Exception:
        return None


def normalize_rel_ref(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    text = text.replace("\\", "/")
    while text.startswith("./"):
        text = text[2:]
    while "//" in text:
        text = text.replace("//", "/")
    while text.endswith("/"):
        text = text[:-1]
    if text in {"", "."}:
        return None
    parts = text.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        return None
    return text


def to_run_relative_ref(value: Any, run_root: Path) -> Optional[str]:
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    if text.startswith("/"):
        try:
            rel = Path(text).resolve().relative_to(run_root.resolve())
        except Exception:
            return None
        return normalize_rel_ref(rel.as_posix())
    return normalize_rel_ref(text)


def normalize_fail_grouped_cases(groups: Any) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for item in as_list(groups):
        group = as_dict(item)
        sample_files: List[str] = []
        for ref in as_list(group.get("sample_report_files")):
            normalized = normalize_rel_ref(ref)
            if normalized and normalized not in sample_files:
                sample_files.append(normalized)
            if len(sample_files) >= 3:
                break

        out.append({
            "class": group.get("class"),
            "name": group.get("name"),
            "kind": group.get("kind"),
            "message": group.get("message"),
            "occurrence_count": group.get("occurrence_count"),
            "sample_report_files": sample_files,
        })
    return out


def normalize_fail_cases(cases: Any) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for item in as_list(cases):
        case = as_dict(item)
        out.append({
            "class": case.get("class"),
            "name": case.get("name"),
            "kind": case.get("kind"),
            "message": case.get("message"),
            "report_file": normalize_rel_ref(case.get("report_file")),
        })
    return out


def normalize_write_scope_violations(violations: Any) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for item in as_list(violations):
        row = as_dict(item)
        out.append({
            "kind": row.get("kind"),
            "path": row.get("path"),
        })
    return out


def normalize_string_list(value: Any) -> List[str]:
    out: List[str] = []
    for item in as_list(value):
        if not isinstance(item, str):
            continue
        text = item.strip()
        if not text:
            continue
        out.append(text)
    return out


def normalize_execution_summary(summary: Any) -> Dict[str, Any]:
    src = as_dict(summary)
    return {
        "tests_discovered": to_int_or_none(src.get("tests_discovered")),
        "tests_executed": to_int_or_none(src.get("tests_executed")),
        "tests_failed": to_int_or_none(src.get("tests_failed")),
        "tests_errors": to_int_or_none(src.get("tests_errors")),
        "tests_skipped": to_int_or_none(src.get("tests_skipped")),
        "junit_reports_found": to_int_or_none(src.get("junit_reports_found")),
    }


def normalize_run(exp: Dict[str, Any], run_id: str, source_root: Path) -> Dict[str, Any]:
    run_root = (source_root / run_id).resolve()

    scans = as_dict(exp.get("scans"))
    orig = as_dict(scans.get("original"))
    gen = as_dict(scans.get("generated"))
    test_port = as_dict(exp.get("test_port"))
    andvari = as_dict(exp.get("andvari"))

    suite_shape = as_dict(test_port.get("suite_shape"))
    suite_changes = as_dict(test_port.get("suite_changes"))
    write_scope = as_dict(test_port.get("write_scope"))
    baseline_original_tests = as_dict(test_port.get("baseline_original_tests"))
    baseline_generated_tests = as_dict(test_port.get("baseline_generated_tests"))
    ported_original_tests = as_dict(test_port.get("ported_original_tests"))
    retention_policy = as_dict(test_port.get("retention_policy"))
    adapter = as_dict(test_port.get("adapter"))
    artifacts = as_dict(test_port.get("artifacts"))
    behavioral_evidence = as_dict(test_port.get("behavioral_evidence"))
    runner_preflight = as_dict(test_port.get("runner_preflight"))
    failure_diagnostics = as_dict(test_port.get("failure_diagnostics"))

    tool_run_dir = to_run_relative_ref(test_port.get("tool_run_dir"), run_root)
    tool_json_path = to_run_relative_ref(test_port.get("tool_json_path"), run_root)
    tool_summary_path = to_run_relative_ref(test_port.get("tool_summary_path"), run_root)
    tool_log_path = to_run_relative_ref(test_port.get("tool_log_path"), run_root)
    run_dir = to_run_relative_ref(artifacts.get("run_dir"), run_root)
    logs_dir = to_run_relative_ref(artifacts.get("logs_dir"), run_root)
    workspace_dir = to_run_relative_ref(artifacts.get("workspace_dir"), run_root)
    outputs_dir = to_run_relative_ref(artifacts.get("outputs_dir"), run_root)
    summary_md = to_run_relative_ref(artifacts.get("summary_md"), run_root)

    record = {
        "schema_version": "run.v1",
        "run_id": run_id,
        "started_at": exp.get("started_at"),
        "finished_at": exp.get("finished_at"),
        "status": exp.get("status"),
        "source": (exp.get("inputs") or {}).get("source_repo") if isinstance(exp.get("inputs"), dict) else {},
        "diagram": {
            "sha256": ((exp.get("inputs") or {}).get("diagram_sha256") if isinstance(exp.get("inputs"), dict) else None),
            "path": None,
        },
        "stages": {
            "codegen": {
                "status": andvari.get("status"),
                "exit_code": andvari.get("exit_code"),
                "metrics": andvari.get("metrics") if isinstance(andvari.get("metrics"), dict) else {},
            },
            "test_port": {
                "enabled": test_port.get("enabled"),
                "informational": test_port.get("informational"),
                "status": test_port.get("status"),
                "reason": test_port.get("reason"),
                "status_detail": test_port.get("status_detail"),
                "failure_class": test_port.get("failure_class"),
                "failure_class_legacy": test_port.get("failure_class_legacy"),
                "behavioral_verdict": test_port.get("behavioral_verdict"),
                "behavioral_verdict_reason": test_port.get("behavioral_verdict_reason"),
                "adapter_prereqs_ok": test_port.get("adapter_prereqs_ok"),
                "new_repo_unchanged": test_port.get("new_repo_unchanged"),
                "runner_preflight": {
                    "detected_runner": runner_preflight.get("detected_runner"),
                    "supported": runner_preflight.get("supported"),
                    "missing_capabilities": normalize_string_list(runner_preflight.get("missing_capabilities")),
                    "module_root": to_run_relative_ref(runner_preflight.get("module_root"), run_root),
                    "frameworks_detected": normalize_string_list(runner_preflight.get("frameworks_detected")),
                },
                "failure_diagnostics": {
                    "phase": failure_diagnostics.get("phase"),
                    "subclass": failure_diagnostics.get("subclass"),
                    "first_failure_line": failure_diagnostics.get("first_failure_line"),
                    "log_excerpt_path": to_run_relative_ref(failure_diagnostics.get("log_excerpt_path"), run_root),
                },
                "suite_shape": {
                    "original_snapshot_file_count": suite_shape.get("original_snapshot_file_count", 0),
                    "final_ported_test_file_count": suite_shape.get("final_ported_test_file_count", 0),
                    "retained_original_test_file_count": suite_shape.get("retained_original_test_file_count"),
                    "removed_original_test_file_count": suite_shape.get("removed_original_test_file_count"),
                    "retention_ratio": suite_shape.get("retention_ratio"),
                    "retained_modified_count": suite_shape.get("retained_modified_count"),
                    "retained_unchanged_count": suite_shape.get("retained_unchanged_count"),
                    "assertion_line_change_count": suite_shape.get("assertion_line_change_count"),
                },
                "suite_changes": {
                    "added": suite_changes.get("added", 0),
                    "modified": suite_changes.get("modified", 0),
                    "deleted": suite_changes.get("deleted", 0),
                    "total": suite_changes.get("total", 0),
                },
                "write_scope": {
                    "policy": write_scope.get("policy"),
                    "violation_count": write_scope.get("violation_count"),
                    "violations": normalize_write_scope_violations(write_scope.get("violations")),
                    "ignored_prefixes": as_list(write_scope.get("ignored_prefixes")),
                    "violations_log_path": to_run_relative_ref(write_scope.get("violations_log_path"), run_root),
                    "diff_path": to_run_relative_ref(write_scope.get("diff_path"), run_root),
                    "change_set_path": to_run_relative_ref(write_scope.get("change_set_path"), run_root),
                },
                "baseline_original_tests": {
                    "status": baseline_original_tests.get("status"),
                    "exit_code": baseline_original_tests.get("exit_code"),
                    "strategy": baseline_original_tests.get("strategy"),
                    "failure_class": baseline_original_tests.get("failure_class"),
                    "failure_class_legacy": baseline_original_tests.get("failure_class_legacy"),
                    "failure_type": baseline_original_tests.get("failure_type"),
                    "failure_diagnostics": {
                        "phase": as_dict(baseline_original_tests.get("failure_diagnostics")).get("phase"),
                        "subclass": as_dict(baseline_original_tests.get("failure_diagnostics")).get("subclass"),
                        "first_failure_line": as_dict(baseline_original_tests.get("failure_diagnostics")).get("first_failure_line"),
                    },
                    "execution_summary": normalize_execution_summary(baseline_original_tests.get("execution_summary")),
                    "log_path": to_run_relative_ref(baseline_original_tests.get("log_path"), run_root),
                },
                "baseline_generated_tests": {
                    "status": baseline_generated_tests.get("status"),
                    "exit_code": baseline_generated_tests.get("exit_code"),
                    "strategy": baseline_generated_tests.get("strategy"),
                    "failure_class": baseline_generated_tests.get("failure_class"),
                    "failure_class_legacy": baseline_generated_tests.get("failure_class_legacy"),
                    "failure_type": baseline_generated_tests.get("failure_type"),
                    "failure_diagnostics": {
                        "phase": as_dict(baseline_generated_tests.get("failure_diagnostics")).get("phase"),
                        "subclass": as_dict(baseline_generated_tests.get("failure_diagnostics")).get("subclass"),
                        "first_failure_line": as_dict(baseline_generated_tests.get("failure_diagnostics")).get("first_failure_line"),
                    },
                    "execution_summary": normalize_execution_summary(baseline_generated_tests.get("execution_summary")),
                    "log_path": to_run_relative_ref(baseline_generated_tests.get("log_path"), run_root),
                },
                "ported_original_tests": {
                    "status": ported_original_tests.get("status"),
                    "exit_code": ported_original_tests.get("exit_code"),
                    "iterations_used": ported_original_tests.get("iterations_used"),
                    "adapter_nonzero_runs": ported_original_tests.get("adapter_nonzero_runs"),
                    "execution_summary": normalize_execution_summary(ported_original_tests.get("execution_summary")),
                    "log_path": to_run_relative_ref(ported_original_tests.get("log_path"), run_root),
                },
                "retention_policy": {
                    "mode": retention_policy.get("mode"),
                    "documented_removals_required": retention_policy.get("documented_removals_required"),
                    "manifest_rel_path": normalize_rel_ref(retention_policy.get("manifest_rel_path")),
                    "undocumented_removed_test_count": retention_policy.get("undocumented_removed_test_count"),
                },
                "removed_original_tests": as_list(test_port.get("removed_original_tests")),
                "behavioral_evidence": {
                    "junit_report_count": behavioral_evidence.get("junit_report_count"),
                    "junit_report_files": [
                        normalized
                        for normalized in (normalize_rel_ref(item) for item in as_list(behavioral_evidence.get("junit_report_files")))
                        if normalized
                    ],
                    "failing_case_count": behavioral_evidence.get("failing_case_count"),
                    "failing_case_unique_count": behavioral_evidence.get("failing_case_unique_count", behavioral_evidence.get("failing_case_count")),
                    "failing_case_occurrence_count": behavioral_evidence.get("failing_case_occurrence_count", behavioral_evidence.get("failing_case_count")),
                    "truncated": behavioral_evidence.get("truncated"),
                    "grouped_truncated": behavioral_evidence.get("grouped_truncated"),
                    "failing_cases": normalize_fail_cases(behavioral_evidence.get("failing_cases")),
                    "grouped_failing_cases": normalize_fail_grouped_cases(behavioral_evidence.get("grouped_failing_cases")),
                },
                "adapter": {
                    "events_log": to_run_relative_ref(adapter.get("events_log"), run_root),
                    "stderr_log": to_run_relative_ref(adapter.get("stderr_log"), run_root),
                    "last_message_path": to_run_relative_ref(adapter.get("last_message_path"), run_root),
                },
                "artifacts": {
                    "tool_run_dir": tool_run_dir or run_dir,
                    "tool_json_path": tool_json_path,
                    "tool_summary_path": tool_summary_path or summary_md,
                    "tool_log_path": tool_log_path,
                    "run_dir": run_dir,
                    "logs_dir": logs_dir,
                    "workspace_dir": workspace_dir,
                    "outputs_dir": outputs_dir,
                    "summary_md": summary_md,
                    "adapter_events_log": to_run_relative_ref(adapter.get("events_log"), run_root),
                    "adapter_stderr_log": to_run_relative_ref(adapter.get("stderr_log"), run_root),
                    "adapter_last_message_path": to_run_relative_ref(adapter.get("last_message_path"), run_root),
                },
            },
            "sonar": {
                "original": orig,
                "generated": gen,
            },
        },
        "derived": {
            "sonar_delta": sonar_delta(orig, gen),
        },
        "provenance": {
            "source_root": str(source_root),
            "source_run_file": f"{run_id}/outputs/experiment.json",
        },
        "extensions": {},
    }
    return sanitize(record)


def write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(obj, indent=2, sort_keys=True)
    path.write_text(text + "\n", encoding="utf-8")


def collect_run_ids(source_root: Path, explicit_ids: List[str], all_runs: bool) -> List[str]:
    if explicit_ids:
        return sorted(set(explicit_ids))
    if all_runs:
        out = []
        for child in source_root.iterdir() if source_root.exists() else []:
            if not child.is_dir():
                continue
            if (child / "outputs" / "experiment.json").exists():
                out.append(child.name)
        return sorted(out)
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-id", required=True)
    parser.add_argument("--runs-root", required=True)
    parser.add_argument("--out-root", required=True)
    parser.add_argument("--run-id", action="append", default=[])
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--prune", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    source_root = Path(args.runs_root).resolve()
    out_root = Path(args.out_root).resolve()
    ds_root = out_root / args.dataset_id
    runs_out = ds_root / "runs"

    run_ids = collect_run_ids(source_root, args.run_id, args.all or not args.run_id)
    index_runs: List[Dict[str, Any]] = []
    exported = set()

    for run_id in run_ids:
        exp_path = source_root / run_id / "outputs" / "experiment.json"
        exp = load_json(exp_path)
        if exp is None:
            continue
        record = normalize_run(exp, run_id, source_root)
        index_runs.append({
            "run_id": run_id,
            "started_at": record.get("started_at"),
            "finished_at": record.get("finished_at"),
            "status": record.get("status"),
            "source": ((record.get("source") or {}).get("display_name") if isinstance(record.get("source"), dict) else None),
            "diagram_sha256": ((record.get("diagram") or {}).get("sha256") if isinstance(record.get("diagram"), dict) else None),
            "codegen_status": (((record.get("stages") or {}).get("codegen") or {}).get("status") if isinstance(record.get("stages"), dict) else None),
            "test_port_status": (((record.get("stages") or {}).get("test_port") or {}).get("status") if isinstance(record.get("stages"), dict) else None),
            "sonar_delta": ((record.get("derived") or {}).get("sonar_delta") if isinstance(record.get("derived"), dict) else {}),
        })
        exported.add(run_id)
        if not args.dry_run:
            write_json(runs_out / f"{run_id}.json", record)

    index_runs.sort(key=lambda x: (x.get("started_at") or "", x["run_id"]))

    index_obj = {"schema_version": "index.v1", "dataset_id": args.dataset_id, "runs": index_runs}
    dataset_obj = {"dataset_id": args.dataset_id, "schema_versions": {"run": "run.v1", "index": "index.v1"}, "run_count": len(index_runs)}

    if not args.dry_run:
        write_json(runs_out / "index.json", index_obj)
        write_json(ds_root / "dataset.json", dataset_obj)

        if args.prune and runs_out.exists():
            for f in runs_out.glob("*.json"):
                if f.name == "index.json":
                    continue
                if f.stem not in exported:
                    f.unlink()

    print(json.dumps({"dataset_id": args.dataset_id, "exported_runs": len(index_runs), "dry_run": args.dry_run}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
