#!/usr/bin/env bash
# pipeline.sh - Shared scan pipeline used by batch and single-repo runners

# Ensure dependencies are sourced
_PIPELINE_SH_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [[ -z "${WORK_DIR:-}" ]]; then
  source "${_PIPELINE_SH_DIR}/common.sh"
fi
if ! declare -f state_set_status >/dev/null 2>&1; then
  source "${_PIPELINE_SH_DIR}/state.sh"
fi
if ! declare -f detect_build_system >/dev/null 2>&1; then
  source "${_PIPELINE_SH_DIR}/detect-build.sh"
fi
if ! declare -f build_project >/dev/null 2>&1; then
  source "${_PIPELINE_SH_DIR}/build.sh"
fi
if ! declare -f submit_to_sonar >/dev/null 2>&1; then
  source "${_PIPELINE_SH_DIR}/submit-sonar.sh"
fi

# Exported outputs from the last pipeline run
PIPELINE_REPO_DIR=""
PIPELINE_BUILD_DIR=""
PIPELINE_BUILD_TOOL=""
PIPELINE_BUILD_JDK=""

pipeline_detect_build_tool_for_dir() {
  local dir="$1"

  if [[ -f "${dir}/pom.xml" ]] || [[ -f "${dir}/mvnw" ]]; then
    echo "maven"
    return 0
  fi

  if [[ -f "${dir}/build.gradle" ]] || [[ -f "${dir}/build.gradle.kts" ]] || [[ -f "${dir}/settings.gradle" ]] || [[ -f "${dir}/settings.gradle.kts" ]] || [[ -f "${dir}/gradlew" ]]; then
    echo "gradle"
    return 0
  fi

  echo ""
}

pipeline_repo_has_git_work_tree() {
  local repo_dir="$1"

  command -v git >/dev/null 2>&1 || return 1
  git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Run full scan pipeline for an already prepared repository.
# Usage:
#   run_scan_for_prepared_repo <key> <display_name> <source_type> <source_ref> <repo_dir>
#                              [jdk_hint] [subdir_hint] [skip_sonar]
#                              [sonar_failure_status] [use_cached_build_jdk]
run_scan_for_prepared_repo() {
  local key="$1"
  local display_name="$2"
  local source_type="$3"
  local source_ref="$4"
  local repo_dir="$5"
  local jdk_hint="${6:-}"
  local subdir_hint="${7:-}"
  local skip_sonar="${8:-false}"
  local sonar_failure_status="${9:-failed}"
  local use_cached_build_jdk="${10:-false}"

  PIPELINE_REPO_DIR=""
  PIPELINE_BUILD_DIR=""
  PIPELINE_BUILD_TOOL=""
  PIPELINE_BUILD_JDK=""

  state_increment_attempts "$key"

  if [[ ! -d "$repo_dir" ]]; then
    state_set_status "$key" "failed" "missing_prepared_repo" "Prepared repository path does not exist"
    return 1
  fi
  PIPELINE_REPO_DIR="$repo_dir"

  local build_result
  build_result="$(detect_build_system "$repo_dir" "$key" || true)"
  if [[ "$build_result" == "unknown" ]]; then
    state_set_status "$key" "skipped" "no_build_file" "No supported build marker found (pom.xml, build.gradle(.kts), mvnw, gradlew)"
    log_warn "No build system detected (expected pom.xml, build.gradle(.kts), mvnw, or gradlew), skipping"
    return 1
  fi

  parse_build_result "$build_result"
  local detected_tool="$BUILD_TOOL"
  local detected_subdir="$BUILD_SUBDIR"
  local build_tool="$detected_tool"
  local build_subdir="$detected_subdir"

  if [[ -n "$subdir_hint" ]]; then
    local hinted_dir="${repo_dir}/${subdir_hint}"
    if [[ ! -d "$hinted_dir" ]]; then
      log_warn "Requested subdir '${subdir_hint}' does not exist; using detected build path instead"
    else
      local hinted_tool
      hinted_tool="$(pipeline_detect_build_tool_for_dir "$hinted_dir")"
      if [[ -n "$hinted_tool" ]]; then
        build_tool="$hinted_tool"
        build_subdir="$subdir_hint"
        if [[ "$hinted_tool" != "$detected_tool" ]]; then
          log_info "Subdir hint '${subdir_hint}' uses ${hinted_tool}; overriding detected ${detected_tool} build tool"
        fi
      else
        log_warn "Requested subdir '${subdir_hint}' has no build markers; using detected build path instead"
      fi
    fi
  fi

  local build_dir="$repo_dir"
  if [[ -n "$build_subdir" ]]; then
    build_dir="${repo_dir}/${build_subdir}"
  fi

  PIPELINE_BUILD_TOOL="$build_tool"
  PIPELINE_BUILD_DIR="$build_dir"

  log_info "Detected build system: $build_tool${build_subdir:+ (subdir: $build_subdir)}"

  if is_android_project "$build_dir"; then
    log_info "Detected Android project (may require special handling)"
  fi

  local effective_jdk="$jdk_hint"
  if [[ "$use_cached_build_jdk" == "true" ]]; then
    local cached_jdk
    cached_jdk="$(state_get_successful_build_version "$key")"
    if [[ -n "$cached_jdk" ]]; then
      effective_jdk="$cached_jdk"
      log_info "Using cached successful build version: JDK $cached_jdk"
    fi
  fi

  state_set_status "$key" "building"
  state_set_build_info "$key" "$build_tool" ""

  if ! build_project "$key" "$build_dir" "$build_tool" "$effective_jdk"; then
    state_set_status "$key" "failed" "$BUILD_RESULT_REASON" "$BUILD_RESULT_MESSAGE"
    return 1
  fi

  PIPELINE_BUILD_JDK="$BUILD_RESULT_JDK"
  state_set_build_info "$key" "$build_tool" "$BUILD_RESULT_JDK"
  state_set_successful_build "$key" "$build_tool" "$BUILD_RESULT_JDK"

  if [[ "$skip_sonar" == "true" ]]; then
    log_info "Skipping SonarQube submission (--skip-sonar)"
    state_set_status "$key" "success"
    state_set_scan_timestamp "$key"
    return 0
  fi

  state_set_status "$key" "submitting"
  sonar_create_project "$key" "$display_name"

  local sonar_scm_exclusions_disabled=""
  local sonar_scm_disabled=""
  if [[ "$source_type" == "path" ]]; then
    sonar_scm_exclusions_disabled="true"
    log_info "Path source detected: disabling Sonar SCM exclusions"
  fi

  if ! pipeline_repo_has_git_work_tree "$repo_dir"; then
    sonar_scm_disabled="true"
    log_info "Prepared repo is not a Git work tree: disabling Sonar SCM integration"
  fi

  if ! SONAR_SCM_EXCLUSIONS_DISABLED="$sonar_scm_exclusions_disabled" SONAR_SCM_DISABLED="$sonar_scm_disabled" submit_to_sonar "$key" "$build_dir" "$build_tool"; then
    state_set_status "$key" "$sonar_failure_status" "sonar_submission_failed" "SonarQube analysis failed"
    return 1
  fi

  if [[ -n "$SONAR_TASK_ID" ]]; then
    state_set_sonar_task "$key" "$SONAR_TASK_ID"
  fi

  state_set_status "$key" "success"
  state_set_scan_timestamp "$key"
  return 0
}

# Run full scan pipeline for one repository source. This is the local wrapper
# that retains URL/path source preparation and delegates to the prepared-repo
# scan flow used by service mode.
# Usage:
#   run_scan_pipeline <key> <display_name> <source_type> <normalized_ref> <repos_root>
#                     [jdk_hint] [subdir_hint] [skip_sonar] [sonar_failure_status]
#                     [use_cached_build_jdk]
run_scan_pipeline() {
  local key="$1"
  local display_name="$2"
  local source_type="$3"
  local normalized_ref="$4"
  local repos_root="$5"
  local jdk_hint="${6:-}"
  local subdir_hint="${7:-}"
  local skip_sonar="${8:-false}"
  local sonar_failure_status="${9:-failed}"
  local use_cached_build_jdk="${10:-false}"

  if ! declare -f prepare_repo_source >/dev/null 2>&1; then
    source "${_PIPELINE_SH_DIR}/clone.sh"
  fi

  state_set_status "$key" "cloning"

  local repo_dir
  if ! repo_dir="$(prepare_repo_source "$source_type" "$normalized_ref" "$key" "$repos_root")"; then
    state_set_status "$key" "failed" "source_prepare_failed" "Failed to prepare repository source"
    return 1
  fi

  run_scan_for_prepared_repo \
    "$key" \
    "$display_name" \
    "$source_type" \
    "$normalized_ref" \
    "$repo_dir" \
    "$jdk_hint" \
    "$subdir_hint" \
    "$skip_sonar" \
    "$sonar_failure_status" \
    "$use_cached_build_jdk"
}
