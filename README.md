# Lidskjalv

Lidskjalv is the scanner service for the pipeline. It analyzes one staged Java
repository per invocation, writes scan artifacts under `artifacts/scans/`, and
emits a machine-readable run report under `outputs/`.

The repo also keeps the existing human/local scan workflows:

- `scripts/scan-one.sh` for a single local path or URL
- `scripts/batch-scan.sh` for `repos.txt` batch runs
- `scripts/create-projects.sh` for local Sonar project pre-creation

## Layout

```text
.
├── docs/
├── scripts/
│   ├── batch-scan.sh
│   ├── create-projects.sh
│   ├── scan-one.sh
│   ├── lib/
│   └── strategies/
├── tests/
├── lidskjalv-service.sh
├── Dockerfile
├── docker-compose.yml
└── repos.txt
```

## Local CLI

Commands are run from repo root:

```bash
./scripts/scan-one.sh --help
./scripts/batch-scan.sh --help
./scripts/create-projects.sh --help
```

Examples:

```bash
./scripts/scan-one.sh --path /abs/path/to/repo --skip-sonar
./scripts/scan-one.sh https://github.com/org/repo.git --project-key my_key
./scripts/batch-scan.sh --skip-sonar
```

Local runs default to `.data/lidskjalv/` for logs, state, and cloned URL
sources. Batch mode still uses resumable shared state in
`.data/lidskjalv/state/scan-state.json`.

## Service Mode

`lidskjalv-service.sh` is the container entrypoint. It scans one staged repo at
`/input/repo`, copies it into an isolated workspace under `/run`, and writes:

- `/run/outputs/run_report.json`
- `/run/outputs/summary.md`
- `/run/artifacts/scans/<scan_label>/logs/`
- `/run/artifacts/scans/<scan_label>/workspace/repo/`
- `/run/artifacts/scans/<scan_label>/metadata/`

Required mount contract:

- Read-only: `/input/repo`
- Read-only: `/run/config`
- Writable: `/run`

Manifest path: `/run/config/manifest.json`

```json
{
  "version": 1,
  "run_id": "20260310T120000Z__example",
  "scan_label": "original",
  "project_key": "pipeline_example_original",
  "project_name": "Example (original)",
  "repo_subdir": "app",
  "skip_sonar": false,
  "sonar_wait_timeout_sec": 300,
  "sonar_wait_poll_sec": 5
}
```

Runtime Sonar credentials remain env-driven:

- `SONAR_HOST_URL`
- `SONAR_TOKEN`
- `SONAR_ORGANIZATION`

`run_report.json` uses schema `lidskjalv_service_report.v1` and includes
top-level run status, input paths, artifact paths, build metadata, Sonar task
state, quality gate status, and fetched measures.

## Docker

Build the local image:

```bash
docker build -t lidskjalv:local .
docker run --rm lidskjalv:local --help
```

The image runs as a non-root `lidskjalv` user and includes Bash, Python, `jq`,
`curl`, `git`, Maven, Gradle, and JDK 17/21.

## Tests

Run the shell regression suite:

```bash
bash tests/run.sh
```

The tests cover:

- local path and URL scans
- batch state reuse
- service manifest validation
- service output layout
- skip-Sonar end-to-end service scans
- Sonar verdict/report mapping with mocked responses

## Local SonarQube

`docker-compose.yml` is kept for local SonarQube/Postgres bring-up when you need
to validate scanner behavior against a local server instead of SonarCloud.
