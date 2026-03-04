#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${TOOLS_DIR}/../.." && pwd)"

DATASET_ID=""
RUNS_ROOT="${EXPERIMENT_RUNS_ROOT:-${REPO_ROOT}/.data/experiments/runs}"
OUT_ROOT="${TOOLS_DIR}/frontend-data"
ALL=true
PRUNE=false
DRY_RUN=false
RUN_IDS=()

usage() {
  cat <<USAGE
Usage: ./export-frontend-data.sh --dataset-id <id> [options]

Options:
  --dataset-id <id>
  --runs-root <path>
  --out-root <path>
  --run-id <id>            (repeatable)
  --all                    (default)
  --prune
  --dry-run
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset-id) DATASET_ID="${2:-}"; shift 2 ;;
    --runs-root) RUNS_ROOT="${2:-}"; shift 2 ;;
    --out-root) OUT_ROOT="${2:-}"; shift 2 ;;
    --run-id) RUN_IDS+=("${2:-}"); ALL=false; shift 2 ;;
    --all) ALL=true; shift ;;
    --prune) PRUNE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$DATASET_ID" ]] || { echo "--dataset-id is required" >&2; exit 1; }

cmd=(python3 "${SCRIPT_DIR}/lib/exp_frontend_export.py" --dataset-id "$DATASET_ID" --runs-root "$RUNS_ROOT" --out-root "$OUT_ROOT")
if [[ "$ALL" == true ]]; then
  cmd+=(--all)
else
  for run_id in "${RUN_IDS[@]}"; do
    cmd+=(--run-id "$run_id")
  done
fi
[[ "$PRUNE" == true ]] && cmd+=(--prune)
[[ "$DRY_RUN" == true ]] && cmd+=(--dry-run)

"${cmd[@]}"

if [[ "$DRY_RUN" == true ]]; then
  exit 0
fi

DATASETS_FILE="${OUT_ROOT}/datasets.json"
mkdir -p "$OUT_ROOT"
if [[ ! -f "$DATASETS_FILE" ]]; then
  printf '{\n  "datasets": []\n}\n' > "$DATASETS_FILE"
fi

python3 - <<'PY' "$DATASETS_FILE" "$DATASET_ID"
import json,sys
path,did=sys.argv[1:]
obj=json.load(open(path,encoding='utf-8'))
if not isinstance(obj,dict): obj={"datasets":[]}
arr=obj.get("datasets")
if not isinstance(arr,list): arr=[]
if did not in arr:
    arr.append(did)
arr=sorted(set(arr))
obj={"datasets":arr}
with open(path,'w',encoding='utf-8') as f:
    json.dump(obj,f,indent=2,sort_keys=True)
    f.write('\n')
PY
