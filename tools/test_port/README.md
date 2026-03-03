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

## Retention policy

Test-port maximizes retained original tests across iterations:

- It does not stop at the first passing adaptation if original tests were removed.
- It keeps iterating (up to `--max-iter`) and selects the best valid iteration with the highest retained original-test count.
- It stops early only when full retention is reached.

Retained/removed metrics are reported in `test_port.json` under `suite_shape`:

- `retained_original_test_file_count`
- `removed_original_test_file_count`
- `retention_ratio` (`retained_original/original_snapshot`)

## Removed-test manifest contract

If an original test file is removed, it must be documented in:

`./completion/proof/logs/test-port-removed-tests.tsv`

Format (tab-separated):

`<repo-relative-test-path>\t<category>\t<reason>`

Allowed categories:

- `unportable`
- `missing-target-feature`

Undocumented removed original tests fail the iteration with:

- `reason=insufficient-test-evidence`
- `failure_class=undocumented-test-removal`

Detailed entries are reported in `test_port.json` under `removed_original_tests`.

## JUnit evidence guard

An adaptation run that exits `0` but produces zero JUnit XML reports is treated as invalid evidence:

- `reason=insufficient-test-evidence`
- `failure_class=missing-junit-reports`

The pipeline keeps iterating so the adapter can recover a valid, evidence-producing run.
