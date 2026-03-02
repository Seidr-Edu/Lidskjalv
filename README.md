# Lidskjalv

This repository contains four primary tools:

- `tools/lidskjalv`: batch scanning of Java repositories with SonarCloud
- `tools/andvari`: local diagram-to-Java reconstruction pipeline
- `tools/experiments`: orchestrated Andvari + Lidskjalv experiment harness
- `tools/test_port`: test-porting helper pipeline for experiment runs

## Layout

```text
.
├── tools/
│   ├── lidskjalv/
│   ├── andvari/
│   ├── experiments/
│   └── test_port/
├── scripts/                 # root wrappers for Lidskjalv commands
├── andvari-run.sh           # root wrapper for Andvari runner
├── experiment-run.sh        # root wrapper for experiment harness
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
- Experiments: `.data/experiments/`

You can override with env vars:

- `LIDSKJALV_DATA_DIR` (or `WORK_DIR`, `LOG_DIR`, `STATE_FILE`, `REPOS_ROOT`) for Lidskjalv
- `ANDVARI_RUNS_DIR` for Andvari
