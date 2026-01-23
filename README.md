// cSpell:disable
# Lidskjalv

SonarQube analysis setup for batch scanning Java repositories with persistent PostgreSQL storage.

## Architecture

- **SonarQube**: Community LTS edition for static code analysis
- **PostgreSQL**: Database for persistent storage of analysis results
- **Docker Compose**: Orchestrates both services with health checks

## Prerequisites

### For SonarQube Server
- Docker
- Docker Compose v2 (`docker compose`)
- macOS, Linux, or Windows

### For Batch Scanning

**Required tools:**
- `git` - Repository cloning
- `jq` - JSON processing for state management
- `curl` - API calls to SonarQube

**Build tools (at least one):**
- `mvn` (Maven) - For Maven projects
- Gradle projects typically include a wrapper (`./gradlew`)

**JDKs (at least one, more is better):**
- JDK 17 (recommended - widely compatible)
- JDK 21 (for modern projects)
- JDK 11, 8 (for legacy projects)

### Installation

**macOS (Homebrew):**
```bash
# Required tools
brew install jq

# Build tools
brew install maven

# JDKs (install what you need)
brew install openjdk@21 openjdk@17 openjdk@11 openjdk@8
```

**Linux (apt):**
```bash
# Required tools
sudo apt install jq curl git

# Build tools
sudo apt install maven

# JDKs (install what you need)
sudo apt install openjdk-21-jdk openjdk-17-jdk openjdk-11-jdk openjdk-8-jdk
```

**Verify setup:**
```bash
which git jq curl mvn java
./scripts/batch-scan.sh --dry-run  # Shows discovered JDKs
```

## Quick Start

### 1. Start the Services

From the repository root:

```bash
docker compose up -d
```

This will:
- Start PostgreSQL and initialize the `sonarqube` database
- Wait for PostgreSQL to be healthy
- Start SonarQube and connect it to PostgreSQL
- Expose SonarQube UI at `http://localhost:9000`

**First startup takes ~1-2 minutes** while SonarQube initializes the database.

### 2. Initial Login

1. Open `http://localhost:9000` in your browser
2. Log in with default credentials:
   - **Username**: `admin`
   - **Password**: `admin`
3. **Change the password** when prompted (required on first login)

### 3. Generate API Token

To run analysis scripts, you need an authentication token:

1. Click your profile icon (top right) → **My Account**
2. Go to the **Security** tab
3. Under "Generate Tokens":
   - **Name**: `local-scanner` (or any name)
   - **Type**: User Token
   - **Expires**: Set far in future or "No expiration"
4. Click **Generate** and copy the token.

### 4. Configure Environment

Create a `.env` file in the project root:

```bash
SONAR_HOST_URL=http://localhost:9000
SONAR_TOKEN=squ_your_generated_token_here
```

Replace `squ_your_generated_token_here` with the token from step 3.

## Scanning Repositories

### Batch Scan (Recommended)

Scan all repositories from `repos.txt` with automatic build detection and JDK selection:

```bash
./scripts/batch-scan.sh
```

**Features:**
- Automatic Maven/Gradle detection
- Multi-JDK support (tries JDK 21, 17, 11, 8)
- State persistence (resume where you left off)
- Detailed logging per repository
- Failure classification and reporting

**Options:**
```bash
./scripts/batch-scan.sh --help           # Show all options
./scripts/batch-scan.sh --dry-run        # Preview what would run
./scripts/batch-scan.sh --force          # Reprocess all repos
./scripts/batch-scan.sh --jdk 17         # Force specific JDK
./scripts/batch-scan.sh --skip-sonar     # Build only, skip analysis
```

### Single Repository Scan

Scan a single repository:

```bash
./scripts/scan-one.sh                                    # First repo from repos.txt
./scripts/scan-one.sh https://github.com/org/repo.git   # Specific repo
./scripts/scan-one.sh --jdk 17 https://github.com/...   # Force JDK 17
```

### Pre-create Projects (Optional)

To pre-create SonarQube projects before scanning:

```bash
./scripts/create-projects.sh
```

This is optional - projects are auto-created during the first scan.

## State and Logs

The scanner maintains state to enable resumable runs:

- **State file**: `state/scan-state.json` - Tracks status of each repository
- **Logs**: `logs/{project-key}/` - Detailed logs for each repository
  - `clone.log` - Git clone output
  - `detect.log` - Build system detection
  - `build-attempt-*.log` - Build attempts with different strategies
  - `sonar.log` - SonarQube submission

View current state:
```bash
cat state/scan-state.json | jq '.repositories | to_entries[] | {key: .key, status: .value.status}'
```

## Useful Commands

```bash
# View logs
docker compose logs -f sonarqube
docker compose logs -f postgres

# Restart services
docker compose restart

# Stop services
docker compose down

# Stop and remove data (DESTRUCTIVE)
docker compose down -v
```

## Configuration

### Repositories List

Edit `repos.txt` to specify repositories to scan (one per line):

```
https://github.com/org1/repo1.git
https://github.com/org2/repo2.git
# Comments are supported
https://github.com/org3/repo3.git # jdk=11
https://github.com/org4/repo4.git # subdir=backend, jdk=17
```

**Per-repo hints** (optional):
- `jdk=XX` - Force specific JDK version
- `subdir=path` - Build from subdirectory

### Quality Profiles

- By default, Java projects use the "Sonar way" quality profile
- To change: Go to **Quality Profiles** in SonarQube UI
- Customize rules or set a different profile as default

## Troubleshooting

### SonarQube won't start
- Check logs: `docker compose logs sonarqube`
- Verify PostgreSQL is healthy: `docker compose ps`
- Wait 1-2 minutes for full initialization

### "Unauthorized" errors during scan
- Regenerate your API token in SonarQube UI
- Update the `SONAR_TOKEN` in `.env`

### Build failures
- Check logs: `cat logs/{project-key}/build-attempt-*.log`
- Try forcing a specific JDK: `./scripts/scan-one.sh --jdk 17 <url>`
- Common issues documented in `docs/scanning-considerations.md`

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

