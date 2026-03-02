# Lidskjalv

This repository contains two tools:

- `tools/lidskjalv`: batch scanning of Java repositories with SonarCloud
- `tools/andvari`: local diagram-to-Java reconstruction pipeline
- `tools/experiments`: orchestrated Andvari + Lidskjalv experiment harness

## Layout

```text
.
├── tools/
│   ├── lidskjalv/
│   └── andvari/
├── scripts/                 # root wrappers for Lidskjalv commands
├── andvari-run.sh           # root wrapper for Andvari runner
└── .data/                   # generated runtime artifacts (ignored)
```

## Quickstart

From repo root:

```bash
# Lidskjalv
./scripts/batch-scan.sh --dry-run
./scripts/scan-one.sh --help
./scripts/create-projects.sh --help

# Andvari
./andvari-run.sh --help

# Experiments
./experiment-run.sh --help
```

## Tool Docs

- Lidskjalv docs: `tools/lidskjalv/README.md`
- Andvari docs: `tools/andvari/README.md`
- Experiments docs: `tools/experiments/README.md`

## Runtime Data

Root wrappers write generated data into:

- Lidskjalv: `.data/lidskjalv/`
- Andvari: `.data/andvari/`

You can override with env vars:

- `LIDSKJALV_DATA_DIR` (or `WORK_DIR`, `LOG_DIR`, `STATE_FILE`, `REPOS_ROOT`) for Lidskjalv
- `ANDVARI_RUNS_DIR` for Andvari
