#!/usr/bin/env bash
set -euo pipefail

# Load .env if present (so users don't need to export manually)
if [[ -f ".env" ]]; then
  set -a
  source .env
  set +a
fi

: "${SONAR_HOST_URL:?Missing SONAR_HOST_URL (set it in .env)}"
: "${SONAR_TOKEN:?Missing SONAR_TOKEN (set it in .env)}"

REPOS_FILE="${1:-repos.txt}"
if [[ ! -f "$REPOS_FILE" ]]; then
  echo "Repo list not found: $REPOS_FILE"
  exit 1
fi

# Derive projectKey from repo URL: <org>_<repo>
# Example: https://github.com/spring-projects/spring-petclinic.git -> spring-projects_spring-petclinic
derive_key() {
  local url="$1"
  local path="${url#*://*/}" 2>/dev/null || true
  # Safer parsing:
  path="$(echo "$url" | sed -E 's#https?://[^/]+/##')"
  local org="$(echo "$path" | cut -d/ -f1)"
  local repo="$(echo "$path" | cut -d/ -f2 | sed -E 's#\.git$##')"
  local key="${org}_${repo}"
  # Replace illegal chars with underscore
  key="$(echo "$key" | sed -E 's#[^a-zA-Z0-9_.-]#_#g')"
  echo "$key"
}

while IFS= read -r repo_url; do
  [[ -z "$repo_url" ]] && continue
  [[ "$repo_url" =~ ^# ]] && continue

  projectKey="$(derive_key "$repo_url")"
  projectName="$(basename "$repo_url")"
  projectName="${projectName%.git}"

  echo "Creating (or ensuring) project: $projectKey ($projectName)"

  # Create project. If it already exists, SonarQube returns an error; ignore it.
  curl -sS -u "$SONAR_TOKEN:" \
    -X POST "$SONAR_HOST_URL/api/projects/create" \
    --data-urlencode "project=$projectKey" \
    --data-urlencode "name=$projectName" \
    >/dev/null || true
done < "$REPOS_FILE"

echo "✅ Done. Check SonarQube UI → Projects."
