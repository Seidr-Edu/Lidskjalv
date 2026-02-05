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
: "${SONAR_ORGANIZATION:?Missing SONAR_ORGANIZATION (set it in .env)}"

# Check if argument is a URL or a file
SINGLE_URL=""
REPOS_FILE=""

if [[ -n "${1:-}" ]]; then
  if [[ "$1" =~ ^https?:// ]]; then
    # Argument is a URL - create single project
    SINGLE_URL="$1"
  else
    # Argument is a file path
    REPOS_FILE="$1"
  fi
else
  REPOS_FILE="repos.txt"
fi

if [[ -z "$SINGLE_URL" && ! -f "$REPOS_FILE" ]]; then
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

# Function to create a single project
create_project() {
  local repo_url="$1"
  
  projectKey="$(derive_key "$repo_url")"
  projectName="$(basename "$repo_url")"
  projectName="${projectName%.git}"

  echo "Creating project: $projectKey ($projectName)"

  # Create project via SonarCloud API
  response=$(curl -sS -u "$SONAR_TOKEN:" \
    -X POST "$SONAR_HOST_URL/api/projects/create" \
    --data-urlencode "project=$projectKey" \
    --data-urlencode "name=$projectName" \
    --data-urlencode "organization=$SONAR_ORGANIZATION" \
    --data-urlencode "visibility=public"
    2>&1) || true
  
  # Check response for success or expected errors
  if echo "$response" | grep -q '"project"'; then
    echo "  Created: $projectKey"
  elif echo "$response" | grep -q 'already exists'; then
    echo "  Already exists: $projectKey"
  else
    echo "  Error: $response"
  fi
}

# Main: process single URL or file
if [[ -n "$SINGLE_URL" ]]; then
  create_project "$SINGLE_URL"
else
  while IFS= read -r repo_url; do
    [[ -z "$repo_url" ]] && continue
    [[ "$repo_url" =~ ^# ]] && continue
    create_project "$repo_url"
  done < "$REPOS_FILE"
fi

echo "Done. Check SonarCloud → Projects."
