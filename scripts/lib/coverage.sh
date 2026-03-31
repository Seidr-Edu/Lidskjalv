#!/usr/bin/env bash
# coverage.sh - Shared JaCoCo coverage helpers

if [[ -z "${WORK_DIR:-}" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# shellcheck disable=SC2034
# Shared coverage metadata is consumed across sourced scripts.
COVERAGE_STATUS=""
COVERAGE_REASON=""
COVERAGE_JACOCO_VERSION=""
COVERAGE_JAVA_TARGET=""
COVERAGE_JDK=""
COVERAGE_MODE=""
COVERAGE_COMMAND=""
COVERAGE_REPORT_KIND=""
COVERAGE_REPORT_PATHS_CSV=""
COVERAGE_REPORTS_FOUND=0
COVERAGE_ATTEMPTED="false"
COVERAGE_TESTS_FORCED="false"
# shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
COVERAGE_BUILD_DIR=""
# shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
COVERAGE_SUPPORT_DIR=""

coverage_reset_metadata() {
  COVERAGE_STATUS=""
  COVERAGE_REASON=""
  COVERAGE_JACOCO_VERSION=""
  COVERAGE_JAVA_TARGET=""
  COVERAGE_JDK=""
  COVERAGE_MODE=""
  COVERAGE_COMMAND=""
  COVERAGE_REPORT_KIND=""
  COVERAGE_REPORT_PATHS_CSV=""
  COVERAGE_REPORTS_FOUND=0
  COVERAGE_ATTEMPTED="false"
  COVERAGE_TESTS_FORCED="false"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_BUILD_DIR=""
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_SUPPORT_DIR=""
}

coverage_mark_skipped() {
  COVERAGE_STATUS="skipped"
  COVERAGE_REASON="${1:-skip_sonar}"
  COVERAGE_JACOCO_VERSION=""
  COVERAGE_JAVA_TARGET=""
  COVERAGE_JDK=""
  COVERAGE_MODE=""
  COVERAGE_COMMAND=""
  COVERAGE_REPORT_KIND=""
  COVERAGE_REPORT_PATHS_CSV=""
  COVERAGE_REPORTS_FOUND=0
  COVERAGE_ATTEMPTED="false"
  COVERAGE_TESTS_FORCED="false"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_BUILD_DIR=""
}

coverage_mark_fallback() {
  COVERAGE_STATUS="fallback"
  COVERAGE_REASON="$1"
  COVERAGE_REPORT_KIND=""
  COVERAGE_REPORT_PATHS_CSV=""
  COVERAGE_REPORTS_FOUND=0
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_BUILD_DIR=""
}

coverage_mark_available() {
  local jacoco_version="$1"
  local java_target="$2"
  local coverage_jdk="$3"
  local report_paths_csv="$4"
  local reports_found="${5:-0}"

  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_STATUS="available"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_REASON=""
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_JACOCO_VERSION="$jacoco_version"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_JAVA_TARGET="$java_target"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_JDK="$coverage_jdk"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_REPORT_KIND="${COVERAGE_REPORT_KIND:-$(coverage_report_kind_for_count "$reports_found")}"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_REPORT_PATHS_CSV="$report_paths_csv"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_REPORTS_FOUND="$reports_found"
}

coverage_mark_attempted() {
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_ATTEMPTED="true"
}

coverage_mark_tests_forced() {
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_TESTS_FORCED="true"
}

coverage_set_plan_metadata() {
  local mode="${1:-}"
  local command="${2:-}"

  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_MODE="$mode"
  # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
  COVERAGE_COMMAND="$command"
}

coverage_count_report_paths() {
  local report_paths_csv="${1:-}"
  local path=""
  local count=0

  if [[ -z "$report_paths_csv" ]]; then
    echo "0"
    return 0
  fi

  local -a coverage_paths=()
  IFS=',' read -r -a coverage_paths <<< "$report_paths_csv"
  for path in "${coverage_paths[@]}"; do
    [[ -n "$path" ]] || continue
    ((count += 1))
  done

  echo "$count"
}

coverage_report_kind_for_count() {
  local count="${1:-0}"
  if [[ -z "$count" ]] || (( count <= 0 )); then
    echo ""
  elif (( count == 1 )); then
    echo "single_report"
  else
    echo "multi_report"
  fi
}

coverage_classify_missing_reports() {
  local log_file="$1"

  if grep -Eiq "Tests are skipped|maven\.test\.skip|Skipping execution due to missing execution data file|NO-SOURCE" "$log_file" 2>/dev/null; then
    echo "tests_skipped_by_config"
  else
    echo "coverage_report_missing"
  fi
}

coverage_normalize_java_version() {
  local version="${1:-}"
  [[ -n "$version" ]] || return 1

  if [[ "$version" =~ ^1\.([0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
  fi

  version="${version%%[^0-9]*}"
  [[ -n "$version" ]] || return 1
  echo "$version"
}

coverage_class_file_java_version() {
  local class_file="$1"
  python3 - <<'PY' "$class_file"
import sys

path = sys.argv[1]
with open(path, "rb") as fh:
    header = fh.read(8)

if len(header) < 8 or header[:4] != b"\xca\xfe\xba\xbe":
    raise SystemExit(1)

major = int.from_bytes(header[6:8], byteorder="big")
if major < 45:
    raise SystemExit(1)

print(major - 44)
PY
}

coverage_detect_java_target() {
  local build_dir="$1"
  local java_version_hint="${2:-}"
  local build_jdk="${3:-}"
  local version=""
  local class_file=""

  class_file="$(find "$build_dir" -type f -name "*.class" \
    \( -path "*/target/classes/*" -o -path "*/build/classes/*/main/*" -o -path "*/build/classes/main/*" \) \
    -print -quit 2>/dev/null || true)"

  if [[ -n "$class_file" ]]; then
    version="$(coverage_class_file_java_version "$class_file" 2>/dev/null || true)"
    if [[ -n "$version" ]]; then
      echo "$version"
      return 0
    fi
    log_warn "Could not infer Java version from compiled class: $class_file"
  fi

  version="$(coverage_normalize_java_version "$java_version_hint" 2>/dev/null || true)"
  if [[ -n "$version" ]]; then
    echo "$version"
    return 0
  fi

  version="$(coverage_normalize_java_version "$build_jdk" 2>/dev/null || true)"
  if [[ -n "$version" ]]; then
    echo "$version"
    return 0
  fi

  echo ""
}

coverage_select_jacoco_version() {
  local java_target="${1:-}"
  local normalized=""

  normalized="$(coverage_normalize_java_version "$java_target" 2>/dev/null || true)"
  if [[ -z "$normalized" ]]; then
    log_warn "Java target could not be determined; defaulting JaCoCo to 0.8.14"
    echo "0.8.14"
    return 0
  fi

  if (( normalized <= 14 )); then
    echo "0.8.6"
  elif (( normalized <= 16 )); then
    echo "0.8.7"
  elif (( normalized <= 18 )); then
    echo "0.8.8"
  elif (( normalized <= 20 )); then
    echo "0.8.9"
  elif (( normalized == 21 )); then
    echo "0.8.11"
  elif (( normalized == 22 )); then
    echo "0.8.12"
  elif (( normalized <= 24 )); then
    echo "0.8.13"
  elif (( normalized == 25 )); then
    echo "0.8.14"
  else
    log_warn "Java target ${normalized} is newer than the JaCoCo support table; using 0.8.14"
    echo "0.8.14"
  fi
}

coverage_report_is_aggregate() {
  local report_path="$1"
  local base_name=""
  local parent_name=""

  [[ -n "$report_path" ]] || return 1

  base_name="$(basename "$report_path")"
  parent_name="$(basename "$(dirname "$report_path")")"

  case "$report_path" in
    */jacoco-aggregate/*)
      return 0
      ;;
  esac

  case "$base_name" in
    *aggregate*.xml|*CodeCoverageReport.xml)
      return 0
      ;;
  esac

  case "$parent_name" in
    *aggregate*|*CodeCoverageReport)
      return 0
      ;;
  esac

  return 1
}

coverage_select_preferred_reports() {
  local report_path=""
  local -a aggregate_reports=()
  local -a standard_reports=()
  local -a selected_reports=()

  for report_path in "$@"; do
    [[ -n "$report_path" ]] || continue
    if coverage_report_is_aggregate "$report_path"; then
      aggregate_reports+=("$report_path")
    else
      standard_reports+=("$report_path")
    fi
  done

  if [[ ${#aggregate_reports[@]} -gt 0 ]]; then
    selected_reports=("${aggregate_reports[@]}")
    # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
    COVERAGE_REPORT_KIND="aggregate"
  else
    selected_reports=("${standard_reports[@]}")
    # shellcheck disable=SC2034  # Shared coverage metadata is consumed across sourced scripts.
    COVERAGE_REPORT_KIND="$(coverage_report_kind_for_count "${#selected_reports[@]}")"
  fi

  printf '%s\n' "${selected_reports[@]}"
}

coverage_find_xml_reports() {
  local build_dir="$1"
  find "$build_dir" -type f \
    \( -path "*/target/site/jacoco/*.xml" \
       -o -path "*/target/site/jacoco-it/*.xml" \
       -o -path "*/target/site/jacoco-aggregate/*.xml" \
       -o -path "*/build/reports/jacoco/*.xml" \
       -o -path "*/build/reports/jacoco/*/*.xml" \
       -o -path "*/build/reports/jacoco/*/*/*.xml" \
       -o -path "*/build/reports/jacoco/*CodeCoverageReport/*.xml" \
       -o -path "*/build/reports/jacoco/*aggregate*/*.xml" \
       -o -name "jacoco.xml" \
       -o -name "jacoco*.xml" \
       -o -name "*CodeCoverageReport.xml" \) \
    -print 2>/dev/null | sort -u
}

coverage_format_report_paths() {
  local base_dir="$1"
  shift || true

  if [[ $# -eq 0 ]]; then
    echo ""
    return 0
  fi

  python3 - <<'PY' "$base_dir" "$@"
import os
import sys

base_dir = os.path.abspath(sys.argv[1])
paths = []

for raw_path in sys.argv[2:]:
    abs_path = os.path.abspath(raw_path)
    paths.append(os.path.relpath(abs_path, base_dir))

print(",".join(paths))
PY
}
