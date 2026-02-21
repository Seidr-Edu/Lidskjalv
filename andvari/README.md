# Andvari

Andvari runs a local diagram-to-Java reconstruction pipeline using Codex CLI.

Input: PlantUML (`.puml`)  
Output: isolated reconstructed repository, gate logs, and run report

## Single command

```bash
./andvari-run.sh --diagram /path/to/diagram.puml --run-id optional-id --max-iter 8
```

## Key options

- `--diagram` (required): path to input diagram.
- `--run-id` (optional): explicit run id (defaults to UTC timestamp).
- `--max-iter` (optional): max repair loops after first implementation attempt.
- `--gating-mode model|fixed` (optional):
  - `model` (default): adaptive self-gating with model-defined outcomes/gates.
  - `fixed`: legacy `gate_recon.sh` flow.
- `--max-gate-revisions` (optional, model mode): max revisions after `gates.v1` (default `3`).
- `--model-gate-timeout-sec` (optional, model mode): timeout for replaying `completion/run_all_gates.sh` (default `120`).

## Model mode flow (default)

1. Creates run workspace:
   - `runs/<run_id>/input`
   - `runs/<run_id>/new_repo`
   - `runs/<run_id>/logs`
   - `runs/<run_id>/outputs`
2. Copies diagram to `runs/<run_id>/input/diagram.puml`.
3. Copies runner policy/scripts into `new_repo`:
   - strategy-selected AGENTS template as `new_repo/AGENTS.md`
   - `gate_hard.sh`
   - `scripts/verify_outcome_coverage.sh`
   - `gate_recon.sh` (legacy compatibility)
4. Runs declaration phase via Codex:
   - model creates `completion/outcomes.initial.json`
   - model creates `completion/gates.v1.json`
   - model creates `completion/run_all_gates.sh`
5. Runner locks hash of `completion/outcomes.initial.json`.
6. Runs implementation phase via Codex.
7. Runner evaluates acceptance:
   - `./gate_hard.sh`
   - `./scripts/verify_outcome_coverage.sh --max-gate-revisions <N> --model-gate-timeout-sec <S>`
8. If acceptance fails, runner loops repair iterations up to `--max-iter`.

`verify_outcome_coverage.sh` enforces:
- locked `outcomes.initial.json` was not mutated
- latest `gates.vN.json` does not exceed revision budget
- model gate runner (`completion/run_all_gates.sh`) replays successfully
- `results.vN.json` exists and covers every gate in latest `gates.vN.json`
- every initial outcome is covered by latest gates
- every core outcome has at least one passing gate

## Fixed mode flow (legacy)

`--gating-mode fixed` preserves current behavior:
- initial reconstruction prompt
- run `./gate_recon.sh`
- summarize failures and iterate repairs up to `--max-iter`

## Artifacts

Per run:

- `runs/<run_id>/logs/codex_events.jsonl`
- `runs/<run_id>/logs/codex_stderr.log`
- `runs/<run_id>/logs/gate.log`
- `runs/<run_id>/outputs/run_report.md`

## AGENTS templates

- `AGENTS.model.md`: used when `--gating-mode model`
- `AGENTS.fixed.md`: used when `--gating-mode fixed`
- `AGENTS.md`: repository-level index that points to the strategy templates

### Required artifacts in generated repositories

All reconstruction modes require the following artifacts:
- `README.md` (build/test/run instructions)
- `docs/ASSUMPTIONS.md` (documented assumptions and design decisions)
- `docs/ARCHITECTURE.md` (architectural overview)
- `docs/USAGE.md` (comprehensive usage guide including how to build artifacts for deployment, integrate the project, and use it in production scenarios)
- `run_demo.sh` (executable demo script)

Model-mode generated repo artifacts (inside `new_repo`):

- `completion/outcomes.initial.json`
- `completion/gates.vN.json`
- `completion/run_all_gates.sh`
- `completion/proof/results.vN.json`
- `completion/proof/logs/*.log`

## Prerequisites

- `codex` CLI installed and on `PATH`
- active Codex auth (`codex login status` must succeed)
- Bash
- Java + build tooling required by the generated project
- `rg`
- `perl` (used for JSON proof validation in `verify_outcome_coverage.sh`)

The runner fails fast with actionable errors if Codex CLI is missing, unauthenticated, or cannot write its local session directory.

## Adapter design

The runner uses an adapter entrypoint:

- `scripts/adapters/adapter.sh`
- `scripts/adapters/codex.sh`

Codex adapter supports both fixed mode (legacy initial/fix prompts) and model mode (declaration + implementation prompts).
