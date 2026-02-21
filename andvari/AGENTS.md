# AGENTS Strategy Templates

This repository uses strategy-specific agent policy templates:

- `AGENTS.model.md` for adaptive self-gating mode (`--gating-mode model`)
- `AGENTS.fixed.md` for legacy fixed-gate mode (`--gating-mode fixed`)

`andvari-run.sh` copies the selected template into each run as `runs/<run_id>/new_repo/AGENTS.md`.
