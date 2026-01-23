#!/usr/bin/env bash
set -euo pipefail

# Load .env if present
if [[ -f ".env" ]]; then
  set -a
  source .env
  set +a
fi

: "${SONAR_HOST_URL:?Missing SONAR_HOST_URL (set it in .env)}"
: "${SONAR_TOKEN:?Missing SONAR_TOKEN (set it in .env)}"

REPO_URL="${1:-}"
if [[ -z "$REPO_URL" ]]; then
  REPO_URL="$(grep -v '^\s*#' repos.txt | head -n 1 | tr -d '\r')"
fi

derive_key() {
  local url="$1"
  local path
  path="$(echo "$url" | sed -E 's#https?://[^/]+/##')"
  local org repo
  org="$(echo "$path" | cut -d/ -f1)"
  repo="$(echo "$path" | cut -d/ -f2 | sed -E 's#\.git$##')"
  local key="${org}_${repo}"
  key="$(echo "$key" | sed -E 's#[^a-zA-Z0-9_.-]#_#g')"
  echo "$key"
}

projectKey="$(derive_key "$REPO_URL")"
projectName="$(basename "$REPO_URL")"
projectName="${projectName%.git}"

WORKDIR="_work/$projectKey"
rm -rf "$WORKDIR"

echo "==> Cloning $REPO_URL"
git clone --depth 1 "$REPO_URL" "$WORKDIR" >/dev/null

cd "$WORKDIR"

if [[ ! -f "pom.xml" ]]; then
  echo "❌ No pom.xml found at repo root. (Multi-module/subdir repo?)"
  exit 1
fi

echo "==> Scanning as projectKey=$projectKey"
mvn -DskipTests=true -q clean verify \
  org.sonarsource.scanner.maven:sonar-maven-plugin:sonar \
  -Dsonar.host.url="$SONAR_HOST_URL" \
  -Dsonar.token="$SONAR_TOKEN" \
  -Dsonar.projectKey="$projectKey" \
  -Dsonar.projectName="$projectName"

echo "✅ Scan submitted. Check SonarQube UI for project: $projectKey"
