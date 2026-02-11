#!/usr/bin/env bash
# scan-one.sh - Quick single-repository scanner
# A simplified interface for scanning a single repository from URL or local path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to project root
cd "$PROJECT_ROOT"

# Source library modules
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/state.sh"
source "${SCRIPT_DIR}/lib/clone.sh"
source "${SCRIPT_DIR}/lib/detect-build.sh"
source "${SCRIPT_DIR}/lib/build.sh"
source "${SCRIPT_DIR}/lib/submit-sonar.sh"

# Resolve all config paths to absolute (prevents issues when cwd changes)
resolve_config_paths

# ============================================================================
# Argument Parsing
# ============================================================================

FORCED_JDK=""
REPO_ARG=""
PATH_ARG=""
PROJECT_KEY_OVERRIDE=""
PROJECT_NAME_OVERRIDE=""
SKIP_SONAR=false
FORCE_RERUN=false
REPOS_ROOT="$PROJECT_ROOT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--jdk)
      FORCED_JDK="$2"
      shift 2
      ;;
    --path)
      PATH_ARG="$2"
      shift 2
      ;;
    --project-key)
      PROJECT_KEY_OVERRIDE="$2"
      shift 2
      ;;
    --project-name)
      PROJECT_NAME_OVERRIDE="$2"
      shift 2
      ;;
    --skip-sonar)
      SKIP_SONAR=true
      shift
      ;;
    -f|--force)
      FORCE_RERUN=true
      shift
      ;;
    -h|--help)
      cat << EOF
Usage: $(basename "$0") [OPTIONS] [REPO_URL]

Scan a single Java repository with SonarQube.

Arguments:
  REPO_URL                 Repository URL to scan (optional, uses first from repos.txt)

Options:
  -j, --jdk <version>      Force specific JDK version
  --path <dir>             Scan local repository path instead of cloning
  --project-key <key>      Override derived Sonar project key
  --project-name <name>    Override Sonar project display name
  --skip-sonar             Build only, skip SonarQube submission
  -f, --force              Force rerun even if already successful
  -h, --help               Show this help

Examples:
  $(basename "$0")                                        # First entry from repos.txt
  $(basename "$0") https://github.com/org/repo.git       # Specific URL
  $(basename "$0") --path repos/PRDownloader             # Local path
  $(basename "$0") --project-key custom --path repos/x   # Override project key
EOF
      exit 0
      ;;
    -*)
      log_error "Unknown option: $1"
      exit 1
      ;;
    *)
      if [[ -n "$REPO_ARG" ]]; then
        log_error "Only one repository argument is supported"
        exit 1
      fi
      REPO_ARG="$1"
      shift
      ;;
  esac
done

if [[ -n "$REPO_ARG" && -n "$PATH_ARG" ]]; then
  log_error "Use either positional REPO_URL or --path, not both"
  exit 1
fi

# ============================================================================
# Main
# ============================================================================

# Load environment
load_env

# Check dependencies
check_dependencies

# Verify required env vars (unless skip sonar)
if ! $SKIP_SONAR; then
  require_env "SONAR_HOST_URL" "Set in .env file"
  require_env "SONAR_TOKEN" "Generate in SonarQube UI → My Account → Security"
fi

SOURCE_TYPE=""
SOURCE_REF=""
SOURCE_JDK_HINT=""
SOURCE_SUBDIR_HINT=""
SOURCE_KEY_HINT=""
SOURCE_NAME_HINT=""

if [[ -n "$PATH_ARG" ]]; then
  SOURCE_TYPE="path"
  SOURCE_REF="$PATH_ARG"
elif [[ -n "$REPO_ARG" ]]; then
  parsed_source="$(parse_repo_source "$REPO_ARG" 2>/dev/null || true)"
  if [[ -z "$parsed_source" ]]; then
    log_error "Invalid repository reference: $REPO_ARG"
    log_error "Use URL, url:<...>, or --path <dir>"
    exit 1
  fi
  IFS='|' read -r SOURCE_TYPE SOURCE_REF <<< "$parsed_source"
else
  if [[ ! -f "repos.txt" ]]; then
    log_error "No repository argument provided and repos.txt not found"
    exit 1
  fi

  first_entry="$(parse_repos_file "repos.txt" | head -n 1 | tr -d '\r')"
  if [[ -z "$first_entry" ]]; then
    log_error "No valid repository entry found in repos.txt"
    exit 1
  fi

  IFS='|' read -r SOURCE_TYPE SOURCE_REF SOURCE_JDK_HINT SOURCE_SUBDIR_HINT SOURCE_KEY_HINT SOURCE_NAME_HINT <<< "$first_entry"
fi

# Normalize path references now so key derivation and state are stable.
SOURCE_REF="$(normalize_source_ref "$SOURCE_TYPE" "$SOURCE_REF" "$REPOS_ROOT")"

if [[ -z "$PROJECT_KEY_OVERRIDE" ]]; then
  PROJECT_KEY_OVERRIDE="$SOURCE_KEY_HINT"
fi
if [[ -z "$PROJECT_NAME_OVERRIDE" ]]; then
  PROJECT_NAME_OVERRIDE="$SOURCE_NAME_HINT"
fi

PROJECT_KEY="$(derive_source_key "$SOURCE_TYPE" "$SOURCE_REF" "$PROJECT_KEY_OVERRIDE")"
DISPLAY_NAME="$(derive_source_display_name "$SOURCE_TYPE" "$SOURCE_REF" "$PROJECT_NAME_OVERRIDE")"

EFFECTIVE_JDK_HINT="$FORCED_JDK"
if [[ -z "$EFFECTIVE_JDK_HINT" ]]; then
  EFFECTIVE_JDK_HINT="$SOURCE_JDK_HINT"
fi

log_info "=========================================="
log_info "Scanning: $DISPLAY_NAME"
log_info "Project key: $PROJECT_KEY"
log_info "Source: $SOURCE_TYPE ($SOURCE_REF)"
log_info "=========================================="

# Initialize state
state_init
state_init_repo "$PROJECT_KEY" "$SOURCE_TYPE" "$SOURCE_REF"

# Check if already successful
if ! $FORCE_RERUN && state_is_success "$PROJECT_KEY"; then
  log_info "Repository already successfully analyzed"
  log_info "Use --force to rerun"
  exit 0
fi

# Discover JDKs
discover_jdks
log_info "Available JDKs: ${AVAILABLE_JDKS[*]:-none}"

# ---- PREPARE SOURCE ----
state_set_status "$PROJECT_KEY" "cloning"

if ! REPO_DIR="$(prepare_repo_source "$SOURCE_TYPE" "$SOURCE_REF" "$PROJECT_KEY" "$REPOS_ROOT")"; then
  state_set_status "$PROJECT_KEY" "failed" "source_prepare_failed" "Failed to prepare source"
  log_error "Failed to prepare repository source"
  exit 1
fi

# ---- DETECT BUILD SYSTEM ----
BUILD_RESULT="$(detect_build_system "$REPO_DIR" "$PROJECT_KEY" || true)"

if [[ "$BUILD_RESULT" == "unknown" ]]; then
  state_set_status "$PROJECT_KEY" "skipped" "no_build_file" "No supported build marker found (pom.xml, build.gradle(.kts), mvnw, gradlew)"
  log_error "No build system detected (expected pom.xml, build.gradle(.kts), mvnw, or gradlew)"
  exit 1
fi

parse_build_result "$BUILD_RESULT"
BUILD_SUBDIR="${SOURCE_SUBDIR_HINT:-$BUILD_SUBDIR}"
log_info "Detected: $BUILD_TOOL${BUILD_SUBDIR:+ (subdir: $BUILD_SUBDIR)}"

BUILD_DIR="$REPO_DIR"
if [[ -n "$BUILD_SUBDIR" ]]; then
  BUILD_DIR="${REPO_DIR}/${BUILD_SUBDIR}"
fi

# Check if this is an Android project
if is_android_project "$BUILD_DIR"; then
  log_info "Detected Android project (may require special handling)"
fi

# ---- BUILD ----
state_set_status "$PROJECT_KEY" "building"
state_increment_attempts "$PROJECT_KEY"

if ! build_project "$PROJECT_KEY" "$BUILD_DIR" "$BUILD_TOOL" "$EFFECTIVE_JDK_HINT"; then
  state_set_status "$PROJECT_KEY" "failed" "$BUILD_RESULT_REASON" "$BUILD_RESULT_MESSAGE"
  log_error "Build failed: $BUILD_RESULT_REASON"
  log_error "Message: $BUILD_RESULT_MESSAGE"
  log_error "See logs in: ${LOG_DIR}/${PROJECT_KEY}/"
  exit 1
fi

state_set_build_info "$PROJECT_KEY" "$BUILD_TOOL" "$BUILD_RESULT_JDK"
log_success "Build succeeded with JDK $BUILD_RESULT_JDK"

# ---- SONARQUBE ----
if $SKIP_SONAR; then
  log_info "Skipping SonarQube submission (--skip-sonar)"
  state_set_status "$PROJECT_KEY" "success"
  state_set_scan_timestamp "$PROJECT_KEY"
else
  state_set_status "$PROJECT_KEY" "submitting"
  sonar_create_project "$PROJECT_KEY" "$DISPLAY_NAME"

  # Local path scans may live under parent repos that ignore the path (e.g. repos/),
  # which would otherwise make Sonar index 0 files via SCM exclusions.
  sonar_scm_exclusions_disabled=""
  if [[ "$SOURCE_TYPE" == "path" ]]; then
    sonar_scm_exclusions_disabled="true"
    log_info "Path source detected: disabling Sonar SCM exclusions"
  fi

  if ! SONAR_SCM_EXCLUSIONS_DISABLED="$sonar_scm_exclusions_disabled" submit_to_sonar "$PROJECT_KEY" "$BUILD_DIR" "$BUILD_TOOL"; then
    state_set_status "$PROJECT_KEY" "failed" "sonar_submission_failed" "SonarQube analysis failed"
    log_error "SonarQube submission failed"
    log_error "See logs in: ${LOG_DIR}/${PROJECT_KEY}/sonar.log"
    exit 1
  fi

  if [[ -n "$SONAR_TASK_ID" ]]; then
    state_set_sonar_task "$PROJECT_KEY" "$SONAR_TASK_ID"
  fi

  state_set_status "$PROJECT_KEY" "success"
  state_set_scan_timestamp "$PROJECT_KEY"
fi

log_success "=========================================="
log_success "Scan complete: $DISPLAY_NAME"
log_success "Project key: $PROJECT_KEY"
if ! $SKIP_SONAR; then
  log_success "View results at: ${SONAR_HOST_URL}/dashboard?id=${PROJECT_KEY}"
fi
log_success "=========================================="
