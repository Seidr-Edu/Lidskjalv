# Experiments Tooling

This tool orchestrates diagram-driven reconstruction experiments:

1. Run Andvari against a diagram.
2. Scan the original source and generated repo with Lidskjalv.
3. Run isolated test-port evaluation (original tests adapted to generated repo in a separate workspace).

## Entrypoint

- Root wrapper: `./experiment-run.sh`
- Internal runner: `tools/experiments/scripts/run-diagram-compare.sh`

## Orchestrator modules

- `scripts/lib/exp_common.sh`: shared logging, hashing, copy helpers.
- `scripts/lib/exp_cli.sh`: CLI parsing and validation.
- `scripts/lib/exp_naming.sh`: source identity and experiment/scan naming derivation.
- `scripts/lib/exp_sources.sh`: source materialization and metadata capture.
- `scripts/lib/exp_andvari.sh`: Andvari stage invocation and outputs.
- `scripts/lib/exp_lidskjalv.sh`: original/generated scan orchestration.
- `scripts/lib/exp_test_port.sh`: isolated test-port evaluation stage.
- `scripts/lib/exp_report.sh`: machine/human report generation.

## Artifact root

- `.data/experiments/runs/<experiment_id>/`
