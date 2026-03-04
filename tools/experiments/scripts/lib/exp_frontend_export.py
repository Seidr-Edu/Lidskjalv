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


def normalize_run(exp: Dict[str, Any], run_id: str, source_root: Path) -> Dict[str, Any]:
    scans = exp.get("scans") if isinstance(exp.get("scans"), dict) else {}
    orig = scans.get("original") if isinstance(scans.get("original"), dict) else {}
    gen = scans.get("generated") if isinstance(scans.get("generated"), dict) else {}
    test_port = exp.get("test_port") if isinstance(exp.get("test_port"), dict) else {}
    andvari = exp.get("andvari") if isinstance(exp.get("andvari"), dict) else {}

    suite_shape = test_port.get("suite_shape") if isinstance(test_port.get("suite_shape"), dict) else {}
    suite_changes = test_port.get("suite_changes") if isinstance(test_port.get("suite_changes"), dict) else {}

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
                "status": test_port.get("status"),
                "reason": test_port.get("reason"),
                "failure_class": test_port.get("failure_class"),
                "behavioral_verdict": test_port.get("behavioral_verdict"),
                "suite_shape": {
                    "original_snapshot_file_count": suite_shape.get("original_snapshot_file_count", 0),
                    "final_ported_test_file_count": suite_shape.get("final_ported_test_file_count", 0),
                    "retention_ratio": suite_shape.get("retention_ratio"),
                },
                "suite_changes": {
                    "added": suite_changes.get("added", 0),
                    "modified": suite_changes.get("modified", 0),
                    "deleted": suite_changes.get("deleted", 0),
                    "total": suite_changes.get("total", 0),
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
