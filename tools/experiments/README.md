# Experiments Tooling

This tool orchestrates diagram-driven reconstruction experiments:

1. Run Andvari against a diagram.
2. Scan the original source and generated repo with Lidskjalv.
3. Invoke the standalone test-port tool for isolated test adaptation/evaluation.

## Entrypoint

- Root wrapper: `./experiment-run.sh`
- Internal runner: `tools/experiments/scripts/run-diagram-compare.sh`
- Batch runner: `./experiment-batch-run.sh`

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
