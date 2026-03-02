// cSpell:disable
# Lidskjalv

Batch scanning tool for analyzing Java repositories with SonarCloud.

This README assumes commands are run from `tools/lidskjalv/`.
From monorepo root, use wrapper commands in `scripts/`.
Runtime data defaults to `<monorepo>/.data/lidskjalv/` in both cases.

## Architecture

- **SonarCloud**: Cloud-hosted static code analysis with persistent storage
- **Batch Scanner**: Shell scripts for automated multi-repository scanning

### Orchestrator modules

- `scripts/batch-scan.sh`: thin entrypoint that initializes environment, sources libs, and dispatches orchestration.
- `scripts/lib/batch_cli.sh`: CLI defaults, usage, and argument parsing.
- `scripts/lib/batch_repo_selection.sh`: repository input loading and dry-run planning output.
- `scripts/lib/batch_execution.sh`: per-repository processing loop, time-limit checks, and counters.
- `scripts/lib/batch_summary.sh`: post-run summary generation.

## Prerequisites

**Required tools:**
- `git` - Repository cloning
- `jq` - JSON processing for state management
- `curl` - API calls to SonarQube

**Build tools (at least one):**
- `mvn` (Maven) - For Maven projects
- Gradle projects typically include a wrapper (`./gradlew`)

**JDKs (at least one, more is better):**
- JDK 21 (recommended default for modern projects)
- JDK 17 (widely compatible fallback)
- JDK 25 (for newest projects/toolchains)
- JDK 11, 8 (legacy compatibility)

### Installation

**macOS (Homebrew):**
```bash
# Required tools
brew install jq

# Build tools
brew install maven

# JDKs (install what you need)
brew install openjdk openjdk@21 openjdk@17 openjdk@11 openjdk@8
```

**Linux (apt):**
```bash
# Required tools
sudo apt install jq curl git

# Build tools
sudo apt install maven

# JDKs (install what you need)
sudo apt install openjdk-25-jdk openjdk-21-jdk openjdk-17-jdk openjdk-11-jdk openjdk-8-jdk
```

**Verify setup:**
```bash
which git jq curl mvn java
./scripts/batch-scan.sh --dry-run  # Shows discovered JDKs
```

## Quick Start

### 1. Set Up SonarCloud

1. Go to [sonarcloud.io](https://sonarcloud.io) and log in (via GitHub, GitLab, etc.)
2. Create or select an organization
3. Note your **organization key** from the URL: `sonarcloud.io/organizations/<org-key>`

### 2. Generate API Token

1. Click your profile icon (top right) → **My Account**
2. Go to the **Security** tab
3. Under "Generate Tokens":
   - **Name**: `lidskjalv` (or any name)
   - **Type**: User Token
   - **Expires**: Set as needed
4. Click **Generate** and copy the token

### 3. Configure Environment

Create a `.env` file in the project root:

```bash
SONAR_HOST_URL=https://sonarcloud.io
SONAR_TOKEN=your_generated_token_here
SONAR_ORGANIZATION=your_organization_key
```

Replace the values with your actual token and organization key from steps 1-2.

## Scanning Repositories

### Batch Scan (Recommended)

Scan all repositories from `repos.txt` with automatic build detection and JDK selection:

```bash
./scripts/batch-scan.sh
```

**Features:**
- Automatic Maven/Gradle detection
- Multi-JDK support (tries JDK 25, 21, 17, 11, 8 based on strategy)
- Wrapper safety checks (ignores non-standard `mvnw`/`gradlew` scripts)
- Subdirectory-aware wrapper discovery (can use wrapper from parent directories)
- State persistence (resume where you left off)
- Detailed logging per repository
- Failure classification and reporting
- SonarCloud project visibility enforcement (`public`)

**Options:**
```bash
./scripts/batch-scan.sh --help           # Show all options
./scripts/batch-scan.sh --dry-run        # Preview what would run
./scripts/batch-scan.sh --force          # Reprocess all repos
./scripts/batch-scan.sh --repo path:repos/my-repo
./scripts/batch-scan.sh --repos-root /opt/repos
./scripts/batch-scan.sh --skip-sonar     # Build only, skip analysis
```

### Single Repository Scan

Scan a single repository (URL or local path):

```bash
./scripts/scan-one.sh                                    # First repo from repos.txt
./scripts/scan-one.sh https://github.com/org/repo.git   # Specific repo
./scripts/scan-one.sh --path repos/PRDownloader         # Local path
./scripts/scan-one.sh --jdk 17 https://github.com/...   # Force JDK 17
./scripts/scan-one.sh --project-key my_key --path repos/PRDownloader
./scripts/scan-one.sh --path repos/monorepo --subdir service-a
```

### Pre-create Projects (Optional)

To pre-create SonarQube projects before scanning:

```bash
./scripts/create-projects.sh
```

This is optional - projects are auto-created during the first scan.

## State and Logs

The scanner maintains state to enable resumable runs:

- **State file**: `.data/lidskjalv/state/scan-state.json` - Tracks status of each repository
- **Logs**: `.data/lidskjalv/logs/{project-key}/` - Detailed logs for each repository
  - `clone.log` - Git clone output
  - `detect.log` - Build system detection
  - `build-attempt-*.log` - Build attempts with different strategies
  - `sonar.log` - SonarCloud submission

## Useful Commands

```bash
# View scan state
cat .data/lidskjalv/state/scan-state.json | jq '.repositories | to_entries[] | {key: .key, status: .value.status}'

# View failed repos
cat .data/lidskjalv/state/scan-state.json | jq '.repositories | to_entries[] | select(.value.status == "failed")'

# Reset state (start fresh)
rm -f .data/lidskjalv/state/scan-state.json
```

## Configuration

### Repositories List

Edit `repos.txt` to specify repositories to scan (one per line):

```
https://github.com/org1/repo1.git
url:https://github.com/org2/repo2.git
path:repos/local-repo
# Comments are supported
https://github.com/org3/repo3.git # jdk=11
path:repos/org4-repo4 # subdir=backend, jdk=17, key=custom_key, name=Custom Name
```

**Per-repo hints** (optional):
- `jdk=XX` - Force specific JDK version
- `subdir=path` - Build from subdirectory
- `key=value` - Override Sonar project key
- `name=value` - Override Sonar project name

`subdir` behavior:
- If the hinted subdir has build markers, it is used.
- If the hinted subdir is missing or has no build markers, Lidskjalv falls back to detected build path.

### Runtime paths

Default runtime root is `.data/lidskjalv/`. Override with:
- `LIDSKJALV_DATA_DIR` (recommended single override)
- or `WORK_DIR`, `LOG_DIR`, `STATE_FILE`, `REPOS_ROOT` for fine-grained control

### Quality Profiles

- By default, Java projects use the "Sonar way" quality profile
- To change: Go to **Quality Profiles** in SonarQube UI
- Customize rules or set a different profile as default

## Troubleshooting

### "Unauthorized" errors during scan
- Verify your token is valid at sonarcloud.io → My Account → Security
- Ensure `SONAR_TOKEN` in `.env` is correct
- Check that `SONAR_ORGANIZATION` matches your organization key

### Build failures
- Check logs: `cat .data/lidskjalv/logs/{project-key}/build-attempt-*.log`
- Try forcing a specific JDK: `./scripts/scan-one.sh --jdk 17 <url>`
- Common issues documented in `docs/scanning-considerations.md`

Common guarded failures:
- `invalid_project_layout` for Maven `packaging=pom` projects with `src/main` sources but no `<modules>`
- `invalid_project_layout` for Gradle projects without build markers and without a valid wrapper

### Sonar submission succeeds but indexes no main code
Lidskjalv fails submission when Sonar reports `No "Main" source files to scan` but `src/main` contains source files.
This usually indicates a mismatched build model (for example aggregator-style `pom.xml` with real sources in module root).

### Missing JDK versions
The scanner automatically discovers installed JDKs. Install additional versions:
- **macOS**: `brew install openjdk@17 openjdk@11`
- **Linux**: `apt install openjdk-17-jdk openjdk-11-jdk`

### Resuming failed batch
The batch scanner automatically skips successful repos:
```bash
./scripts/batch-scan.sh              # Continues from where it left off
./scripts/batch-scan.sh --force      # Start fresh
```

## Documentation

- `docs/scanning-considerations.md` - Common build failures and solutions
