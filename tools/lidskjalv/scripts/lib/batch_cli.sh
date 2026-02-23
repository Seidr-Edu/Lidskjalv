#!/usr/bin/env bash
# batch_cli.sh - CLI argument parsing and defaults for batch scanner
# Handles command-line option parsing and default initialization

batch_init_defaults() {
  FORCE_RERUN=false
  DRY_RUN=false
  SINGLE_REPO=""
  REPOS_FILE="repos.txt"
  REPOS_ROOT="${REPOS_ROOT:-$PROJECT_ROOT}"
  SKIP_SONAR=false
  CLEANUP_AFTER=false
  RETRY_SONAR_FAILED=false
}

batch_print_usage() {
  cat << USAGE_EOF
Usage: $(basename "$0") [OPTIONS]

Batch scan Java repositories with SonarQube.

Options:
  -f, --force              Reprocess all repos (ignore previous success and sonar failures)
  -n, --dry-run            Show what would be processed without running
  -r, --repo <ref>         Process only this repository (URL, url:<...>, or path:<...>)
  -i, --input <file>       Use specified repos file (default: repos.txt)
  --repos-root <dir>       Base directory for resolving relative path:<...> entries
  --skip-sonar             Build only, skip SonarQube submission
  --cleanup                Remove cloned URL repos after successful analysis
  --retry-sonar-failed     Retry repos that previously failed SonarQube submission
  -h, --help               Show this help message

Examples:
  $(basename "$0")                                       # Process all pending repos
  $(basename "$0") --force                               # Reprocess everything
  $(basename "$0") --repo https://github.com/org/repo.git
  $(basename "$0") --repo path:repos/PRDownloader
  $(basename "$0") --repos-root /opt/repos --dry-run

State is persisted in: ${STATE_FILE}
Logs are saved in: ${LOG_DIR}/
USAGE_EOF
}

batch_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        FORCE_RERUN=true
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -r|--repo)
        SINGLE_REPO="$2"
        shift 2
        ;;
      -i|--input)
        REPOS_FILE="$2"
        shift 2
        ;;
      --repos-root)
        REPOS_ROOT="$2"
        shift 2
        ;;
      --skip-sonar)
        SKIP_SONAR=true
        shift
        ;;
      --cleanup)
        CLEANUP_AFTER=true
        shift
        ;;
      --retry-sonar-failed)
        RETRY_SONAR_FAILED=true
        shift
        ;;
      -h|--help)
        batch_print_usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        batch_print_usage
        exit 1
        ;;
    esac
  done
}
