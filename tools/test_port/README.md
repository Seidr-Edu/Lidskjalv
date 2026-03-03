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

## Write-scope behavior

Write-scope policy remains `tests-only`, but known runtime/internal paths are ignored by default:

- `./completion/proof/logs/`
- `./.mvn_repo/`

You can add more repo-relative ignored prefixes with:

- Repeatable CLI option: `--write-scope-ignore-prefix PATH`
- Env var: `TP_WRITE_SCOPE_IGNORE_PREFIXES` (colon-separated)

Example:

```bash
TP_WRITE_SCOPE_IGNORE_PREFIXES="tmp/cache:generated/reports" \
./test-port-run.sh \
  --generated-repo /abs/path/to/generated-repo \
  --original-repo /abs/path/to/original-repo \
  --write-scope-ignore-prefix completion/proof/logs
```

Ignored prefixes are reported in `test_port.json` under `write_scope.ignored_prefixes`.

## Maven local repository

When Maven is detected, test-port always runs Maven with:

`-Dmaven.repo.local=<run-dir>/workspace/.m2/repository`

This keeps dependency downloads out of copied repositories while reusing dependencies inside a single test-port run.
