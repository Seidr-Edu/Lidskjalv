// cSpell:disable
# Lidskjalv

SonarQube analysis setup for batch scanning Java repositories with persistent PostgreSQL storage.

## Architecture

- **SonarQube**: Community LTS edition for static code analysis
- **PostgreSQL**: Database for persistent storage of analysis results
- **Docker Compose**: Orchestrates both services with health checks

## Prerequisites

- Docker
- Docker Compose v2 (`docker compose`)
- macOS, Linux, or Windows
- Java & Maven (for scanning Java projects)

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

## Creating projects
To pre-create SonarQube projects (recommended before the first scan), run:

```bash
./scripts/create-projects.sh
```

This script reads `repos.txt`, derives a project key and name for each repository, and creates the corresponding projects in SonarQube using the API. If a project already exists, it is skipped without error.



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
```

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

