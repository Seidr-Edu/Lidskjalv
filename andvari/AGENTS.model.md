# AGENTS.md — Diagram-to-Java Reconstruction (Model Strategy)

## Mission
Reconstruct a complete, working Java repository from the provided PlantUML diagram (`.puml`).

## Non-negotiable outcomes
- Language: **Java**
- Build system: choose exactly one (**Gradle** or **Maven**)
- Tests: meaningful unit tests for core logic, plus integration tests when boundaries exist
- Buildable: project compiles and tests pass
- Usable: runnable demo entrypoint (`main`) and executable `run_demo.sh`
- Usage documentation: comprehensive guide in `docs/USAGE.md` covering how to build artifacts for deployment, integrate the project, and use it in production scenarios
- No placeholder stubs (`TODO-STUB`, `return null`, `UnsupportedOperationException`, `NotImplementedError` in production logic)

## Source of truth and scope
- Use only `../input/diagram.puml` as source of behavior/structure.
- Operate only inside this run repository.
- If underspecified, make reasonable choices and document them in `docs/ASSUMPTIONS.md`.

## Required repo artifacts
- `README.md` (build/test/run instructions)
- `docs/ASSUMPTIONS.md`
- `docs/ARCHITECTURE.md`
- `docs/USAGE.md`
- `run_demo.sh` (executable)

## Adaptive self-gating protocol
### 1) Declare outcomes first
Create:
- `completion/outcomes.initial.json`
- `completion/gates.v1.json`
- `completion/run_all_gates.sh` (executable)

Required shape:
- `outcomes.initial.json`: array of `{id, description, priority, diagram_rationale}` where `priority` is `core` or `non-core`
- `gates.v1.json`: array of `{id, description, command, outcome_ids}` with non-empty `outcome_ids`
- Every outcome id must be covered by at least one gate

### 2) Implement and iterate
- Implement the project from the diagram.
- You may evolve verification strategy with newer `gates.vN.json` versions.
- Do not mutate `completion/outcomes.initial.json` after declaration.
- Keep all initial outcomes covered in the latest gate version.

### 3) Produce proof
`completion/run_all_gates.sh` must execute the latest gate set and write:
- `completion/proof/results.vN.json` with `{gate_id, status, exit_code, log_path}`
- `completion/proof/logs/<gate-id>.log`

## Stop condition
Do not stop until both pass:
- `./gate_hard.sh`
- `./scripts/verify_outcome_coverage.sh`
