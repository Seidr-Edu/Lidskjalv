#!/usr/bin/env bash
set -euo pipefail

if [[ -f ".env" ]]; then
  set -a
  source .env
  set +a
fi

: "${SONAR_HOST_URL:?Missing SONAR_HOST_URL (set it in .env)}"
: "${SONAR_TOKEN:?Missing SONAR_TOKEN (set it in .env)}"
: "${SONAR_ORGANIZATION:?Missing SONAR_ORGANIZATION (set it in .env)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SINGLE_URL=""
REPOS_FILE=""

if [[ -n "${1:-}" ]]; then
  if [[ "$1" =~ ^https?:// ]]; then
    SINGLE_URL="$1"
  else
    REPOS_FILE="$1"
  fi
else
  REPOS_FILE="repos.txt"
fi

if [[ -z "$SINGLE_URL" && ! -f "$REPOS_FILE" ]]; then
  echo "Repo list not found: $REPOS_FILE"
  exit 1
fi

create_project() {
  local repo_url="$1"
  
  projectKey="$(derive_key "$repo_url")"
  projectName="$(basename "$repo_url")"
  projectName="${projectName%.git}"

  echo "Creating project: $projectKey ($projectName)"

  response=$(curl -sS -u "$SONAR_TOKEN:" \
    -X POST "$SONAR_HOST_URL/api/projects/create" \
    --data-urlencode "project=$projectKey" \
    --data-urlencode "name=$projectName" \
    --data-urlencode "organization=$SONAR_ORGANIZATION" \
    --data-urlencode "visibility=public"
    2>&1) || true
  
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
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r url jdk subdir <<< "$entry"
    create_project "$url"
  done < <(parse_repos_file "$REPOS_FILE")
fi

echo "Done. Check SonarCloud → Projects."
