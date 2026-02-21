#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ORIGINAL_CWD="$(pwd)"
cd "$PROJECT_ROOT"

source "${SCRIPT_DIR}/lib/bootstrap.sh"
lidskjalv_bootstrap "$PROJECT_ROOT" "$ORIGINAL_CWD"

source "${SCRIPT_DIR}/lib/common.sh"

SINGLE_SOURCE=""
REPOS_FILE="repos.txt"
REPOS_ROOT="${REPOS_ROOT:-$PROJECT_ROOT}"

print_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [REPO_OR_FILE]

Create Sonar projects from a single repo reference or repos file.

Options:
  --repos-root <dir>   Base directory for resolving relative path:<...> entries
  -h, --help           Show this help

Examples:
  $(basename "$0")                                     # Use repos.txt
  $(basename "$0") repos.txt                           # Specific file
  $(basename "$0") https://github.com/org/repo.git    # Single URL
  $(basename "$0") path:repos/PRDownloader             # Single local path source
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos-root)
      REPOS_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      if [[ -n "$SINGLE_SOURCE" || "$REPOS_FILE" != "repos.txt" ]]; then
        echo "Only one positional argument is supported"
        exit 1
      fi

      if [[ "$1" == http://* || "$1" == https://* || "$1" == url:* || "$1" == path:* ]]; then
        SINGLE_SOURCE="$1"
      else
        REPOS_FILE="$1"
      fi
      shift
      ;;
  esac
done

REPOS_ROOT="$(resolve_repo_path "$REPOS_ROOT" "$ORIGINAL_CWD")"
load_env

: "${SONAR_HOST_URL:?Missing SONAR_HOST_URL (set it in .env)}"
: "${SONAR_TOKEN:?Missing SONAR_TOKEN (set it in .env)}"
: "${SONAR_ORGANIZATION:?Missing SONAR_ORGANIZATION (set it in .env)}"

create_project() {
  local source_type="$1"
  local source_ref="$2"
  local key_override="${3:-}"
  local name_override="${4:-}"

  local normalized_ref
  normalized_ref="$(normalize_source_ref "$source_type" "$source_ref" "$REPOS_ROOT")"

  local project_key
  project_key="$(derive_source_key "$source_type" "$normalized_ref" "$key_override")"
  local project_name
  project_name="$(derive_source_display_name "$source_type" "$normalized_ref" "$name_override")"

  echo "Creating project: $project_key ($project_name)"

  local response
  response="$(curl -sS -u "$SONAR_TOKEN:" \
    -X POST "$SONAR_HOST_URL/api/projects/create" \
    --data-urlencode "project=$project_key" \
    --data-urlencode "name=$project_name" \
    --data-urlencode "organization=$SONAR_ORGANIZATION" \
    --data-urlencode "visibility=public" \
    2>&1)" || true

  if echo "$response" | grep -q '"project"'; then
    echo "  Created: $project_key"
  elif echo "$response" | grep -q 'already exists'; then
    echo "  Already exists: $project_key"
  else
    echo "  Error: $response"
  fi
}

if [[ -n "$SINGLE_SOURCE" ]]; then
  parsed_source="$(parse_repo_source "$SINGLE_SOURCE" 2>/dev/null || true)"
  if [[ -z "$parsed_source" ]]; then
    echo "Invalid source entry: $SINGLE_SOURCE"
    echo "Use URL, url:<...>, or path:<...>"
    exit 1
  fi
  IFS='|' read -r source_type source_ref <<< "$parsed_source"
  create_project "$source_type" "$source_ref"
else
  if [[ ! -f "$REPOS_FILE" ]]; then
    echo "Repo list not found: $REPOS_FILE"
    exit 1
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r source_type source_ref jdk subdir key_override name_override <<< "$entry"
    create_project "$source_type" "$source_ref" "$key_override" "$name_override"
  done < <(parse_repos_file "$REPOS_FILE")
fi

echo "Done. Check SonarCloud -> Projects."
