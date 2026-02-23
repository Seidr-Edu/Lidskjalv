Gate failed. Fix the repository and get gate_recon.sh to pass.

Source diagram:
../input/diagram.puml

Policy:
- Follow AGENTS.md in this repository as the authoritative requirements document.
- If any instruction in this prompt appears to conflict with AGENTS.md, AGENTS.md wins.

Actions:
1. Read the gate failure summary below.
2. Apply fixes in this repository.
3. Run ./gate_recon.sh.
4. If gate still fails, continue fixing and rerunning until it passes.
5. Return concise summary of root cause and fixes.

Gate failure summary (last ~200 lines):
