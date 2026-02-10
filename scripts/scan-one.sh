#!/usr/bin/env bash
# scan-one.sh - Quick single-repository scanner
# A simplified interface for scanning a single repository
#
# Usage:
#   ./scripts/scan-one.sh [REPO_URL]
#   ./scripts/scan-one.sh https://github.com/org/repo.git
#   ./scripts/scan-one.sh                    # Uses first repo from repos.txt
#
# Options can be passed to the underlying batch scanner:
#   ./scripts/scan-one.sh --jdk 17 https://github.com/org/repo.git

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
REPO_URL=""
SKIP_SONAR=false
FORCE_RERUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--jdk)
      FORCED_JDK="$2"
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
  REPO_URL              Repository URL to scan (optional, uses first from repos.txt)

Options:
  -j, --jdk <version>   Force specific JDK version
  --skip-sonar          Build only, skip SonarQube submission
  -f, --force           Force rerun even if already successful
  -h, --help            Show this help

Examples:
  $(basename "$0")                                    # First repo from repos.txt
  $(basename "$0") https://github.com/org/repo.git   # Specific repo
  $(basename "$0") --jdk 17 https://github.com/...   # Force JDK 17
EOF
      exit 0
      ;;
    -*)
      log_error "Unknown option: $1"
      exit 1
      ;;
    *)
      REPO_URL="$1"
      shift
      ;;
  esac
done

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

# Get repo URL if not provided
if [[ -z "$REPO_URL" ]]; then
  if [[ ! -f "repos.txt" ]]; then
    log_error "No repository URL provided and repos.txt not found"
    exit 1
  fi
  
  REPO_URL="$(grep -v '^\s*#' repos.txt | grep -v '^\s*$' | head -n 1 | tr -d '\r')"
  
  if [[ -z "$REPO_URL" ]]; then
    log_error "No repository URL found in repos.txt"
    exit 1
  fi
fi

# Derive project key
PROJECT_KEY="$(derive_key "$REPO_URL")"
DISPLAY_NAME="$(derive_display_name "$REPO_URL")"

log_info "=========================================="
log_info "Scanning: $DISPLAY_NAME"
log_info "Project key: $PROJECT_KEY"
log_info "=========================================="

# Initialize state
state_init
state_init_repo "$PROJECT_KEY" "$REPO_URL"

# Check if already successful
if ! $FORCE_RERUN && state_is_success "$PROJECT_KEY"; then
  log_info "Repository already successfully analyzed"
  log_info "Use --force to rerun"
  exit 0
fi

# Discover JDKs
discover_jdks
log_info "Available JDKs: ${AVAILABLE_JDKS[*]:-none}"

# ---- CLONE ----
state_set_status "$PROJECT_KEY" "cloning"

if ! clone_repo "$REPO_URL" "$PROJECT_KEY"; then
  state_set_status "$PROJECT_KEY" "failed" "clone_failed" "Failed to clone repository"
  log_error "Failed to clone repository"
  exit 1
fi

REPO_DIR="$(clone_get_path "$PROJECT_KEY")"

# ---- DETECT BUILD SYSTEM ----
BUILD_RESULT="$(detect_build_system "$REPO_DIR" "$PROJECT_KEY")"

if [[ "$BUILD_RESULT" == "unknown" ]]; then
  state_set_status "$PROJECT_KEY" "skipped" "no_build_file" "No pom.xml or build.gradle found"
  log_error "No build system detected (no pom.xml or build.gradle)"
  exit 1
fi

parse_build_result "$BUILD_RESULT"
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

if ! build_project "$PROJECT_KEY" "$BUILD_DIR" "$BUILD_TOOL" "$FORCED_JDK"; then
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
  
  if ! submit_to_sonar "$PROJECT_KEY" "$BUILD_DIR" "$BUILD_TOOL"; then
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
