Adaptive self-gating implementation phase.

Source diagram:
../input/diagram.puml

Policy:
- Follow AGENTS.md in this repository as the authoritative requirements document.
- If any instruction in this prompt appears to conflict with AGENTS.md, AGENTS.md wins.

Mode details:
- completion/outcomes.initial.json is immutable after declaration.
- You may evolve verification strategy by adding/replacing completion/gates.vN.json.
- Allowed gate versions are v1 through v${MAX_GATE_VERSION}.
- The latest gate version must still map every initial outcome id to at least one gate.

Execution loop (continue until green):
1. Read the failure summary below.
2. Implement/fix the repository from the diagram.
3. Update completion/run_all_gates.sh and completion/proof/results.vN.json behavior as needed.
4. Run ./gate_hard.sh.
5. Run ./scripts/verify_outcome_coverage.sh --max-gate-revisions ${MAX_GATE_REVISIONS} --model-gate-timeout-sec ${MODEL_GATE_TIMEOUT_SEC}
6. If either command fails, continue fixing and rerunning until both pass.

Scope constraints:
- Operate only inside this run repository.
- Use ../input/diagram.puml as read-only input.
- Do not inspect or modify any other run directories.

Failure summary:
