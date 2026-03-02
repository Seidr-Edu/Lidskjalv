# Test-Port Tool

Standalone model-driven test adaptation/evaluation tool used by experiments.

## Purpose

- Run baseline tests on original and generated repos in isolated copies
- Port original tests into a generated repo copy using the Andvari adapter/Codex prompts
- Enforce tests-only write scope
- Preserve behavioral mismatch evidence
- Emit `test_port.json` and `summary.md`

## Entry points

- Root wrapper: `./test-port-run.sh`
- Internal script: `tools/test_port/test-port-run.sh`

## Example

```bash
./test-port-run.sh \
  --generated-repo /abs/path/to/generated-repo \
  --original-repo /abs/path/to/original-repo \
  --diagram /abs/path/to/diagram.puml
```

Artifacts are written to `.data/test-port/runs/<run-id>/` by default, or to `--run-dir`.
