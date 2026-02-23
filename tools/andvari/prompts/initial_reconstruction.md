Reconstruct this Java repository from the source-of-truth diagram at:
../input/diagram.puml

Policy:
- Follow AGENTS.md in this repository as the authoritative requirements document.
- If any instruction in this prompt appears to conflict with AGENTS.md, AGENTS.md wins.

Execution:
1. Read ../input/diagram.puml.
2. Reconstruct the repo accordingly.
3. Run ./gate_recon.sh.
4. If gate fails, fix and rerun until it passes.

Scope constraints:
- Operate only inside this run repository.
- Use ../input/diagram.puml as read-only input.
- Do not inspect or modify any other run directories.

Return a concise summary including final gate result.
