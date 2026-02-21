# AGENTS.md — Diagram-to-Java Reconstruction (Fixed Strategy)

## Mission
Reconstruct a complete, working Java repository from the provided PlantUML diagram (`.puml`).

## Hard requirements
- Language: **Java**
- Build system: choose exactly one (**Gradle** or **Maven**)
- Use only `../input/diagram.puml` as source of truth
- No placeholder stubs
- Provide meaningful tests
- Provide runnable demo (`main` and executable `run_demo.sh`)
- Provide comprehensive usage documentation (`docs/USAGE.md`) covering how to build artifacts for deployment, integrate the project, and use it in production scenarios

## Required artifacts
- `README.md`
- `docs/ASSUMPTIONS.md`
- `docs/ARCHITECTURE.md`
- `docs/USAGE.md`
- `run_demo.sh`

## Working rules
- Operate only inside this run repository.
- Resolve ambiguity with reasonable assumptions and record them in `docs/ASSUMPTIONS.md`.
- Keep implementation deterministic where practical.

## Stop condition
Do not consider the task complete until `./gate_recon.sh` passes.
If it fails, fix and rerun until green.
