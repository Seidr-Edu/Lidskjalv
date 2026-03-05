# Experiments Tooling

This tool orchestrates diagram-driven reconstruction experiments:

1. Run Andvari against a diagram.
2. Scan the original source and generated repo with Lidskjalv.
3. Invoke the standalone test-port tool for isolated test adaptation/evaluation.

## Entrypoint

- Root wrapper: `./experiment-run.sh`
- Internal runner: `tools/experiments/scripts/run-diagram-compare.sh`
- Batch runner: `./experiment-batch-run.sh`
- Sonar metadata backfill: `tools/experiments/scripts/refresh-sonar-metadata.sh`

## Orchestrator modules

- `scripts/lib/exp_common.sh`: shared logging, hashing, copy helpers.
- `scripts/lib/exp_cli.sh`: CLI parsing and validation.
- `scripts/lib/exp_naming.sh`: source identity and experiment/scan naming derivation.
- `scripts/lib/exp_sources.sh`: source materialization and metadata capture.
- `scripts/lib/exp_andvari.sh`: Andvari stage invocation and outputs.
- `scripts/lib/exp_lidskjalv.sh`: original/generated scan orchestration.
- `scripts/lib/exp_test_port_client.sh`: standalone test-port tool invocation and result import.
- `scripts/lib/exp_report.sh`: machine/human report generation.

## Related tool

- Standalone test-port entrypoint: `./test-port-run.sh`
- Tool docs: `tools/test_port/README.md`

## Artifact root

- `.data/experiments/runs/<experiment_id>/`

## Batch runsets

- Runset manifests live under `tools/experiments/runsets/`
- Example manifest: `tools/experiments/runsets/batch-7-multi-repo.json`

Run all entries in a manifest:

```bash
./experiment-batch-run.sh --manifest tools/experiments/runsets/batch-7-multi-repo.json
```

Dry run (print commands only):

```bash
./experiment-batch-run.sh --manifest tools/experiments/runsets/batch-7-multi-repo.json --dry-run
```

Rerun a batch without codegen (reuse latest compatible prior generated repo for each case):

```bash
./experiment-batch-run.sh --manifest tools/experiments/runsets/batch-7-multi-repo.json --reuse-codegen-auto
```

### Codegen Reuse Resolution

`--reuse-codegen-auto` resolves prior runs from `.data/experiments/runs/*/outputs/experiment.json` by exact match on:

- absolute `inputs.diagram_path`
- `inputs.source_repo.raw`
- `inputs.source_repo.subdir` (empty when unset)

A prior run is considered reusable when:

- `andvari.exit_code == 0`
- `andvari.run_dir` exists
- `<andvari.run_dir>/new_repo` exists and is non-empty

Selection is deterministic: latest `finished_at`, then latest `started_at`, then highest `experiment_id` lexicographically.

If no compatible reusable run is found, the batch case fails with `detail=no-reusable-codegen` and batch execution continues unless `--fail-fast` is set.

## Sonar metadata timing

Sonar measures can be unavailable immediately after scan submission because compute engine
processing may still be in progress. The experiment runner supports bounded waiting:

- `--sonar-wait on|off` (default `on`)
- `--sonar-wait-timeout-sec <n>` (default `300`)
- `--sonar-wait-poll-sec <n>` (default `5`)

The experiment JSON includes per-scan status fields:

- `scan_data_status` (`complete`, `pending`, `failed`, `unavailable`, `skipped`)
- `sonar_task_id`
- `ce_task_status`

Backfill existing runs after Sonar processing completes:

```bash
tools/experiments/scripts/refresh-sonar-metadata.sh
```

Refresh one run:

```bash
tools/experiments/scripts/refresh-sonar-metadata.sh --run-id <experiment_id>
```

### Measures fetched

By default, experiments fetch these Sonar metrics into `scans.*.measures`:

- `bugs`
- `vulnerabilities`
- `code_smells`
- `coverage`
- `duplicated_lines_density`
- `reliability_rating`
- `security_rating`
- `sqale_rating` (maintainability rating)
- `ncloc`
- `sqale_index`

Override the metric list with:

```bash
EXP_SONAR_METRIC_KEYS="bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density,reliability_rating,security_rating,sqale_rating"
```

## Run Inspector Frontend

A local frontend can visualize exported experiment runs (status, codegen, test-port, and sonar original vs generated).

### 1) Export frontend data

```bash
tools/experiments/scripts/export-frontend-data.sh --dataset-id local --all
```

This writes JSON payloads under:

- `tools/experiments/frontend-data/datasets.json`
- `tools/experiments/frontend-data/<dataset_id>/runs/index.json`
- `tools/experiments/frontend-data/<dataset_id>/runs/<run_id>.json`

### 2) Start the frontend

```bash
cd tools/experiments/frontend
npm install
npm run dev
```

The app runs as a static SPA and reads data from `/frontend-data` (served from sibling `tools/experiments/frontend-data` by Vite middleware).  
You can override the base path with `VITE_DATA_BASE`.

### 3) Deep links

The UI supports query params for direct navigation:

- `?dataset=<dataset_id>`
- `?dataset=<dataset_id>&run=<run_id>`
