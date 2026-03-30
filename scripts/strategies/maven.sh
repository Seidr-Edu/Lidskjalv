#!/usr/bin/env bash
# maven.sh - Maven build strategies
# Defines build configurations to try for Maven projects

# ============================================================================
# Maven Build Strategies
# ============================================================================

# shellcheck disable=SC2034  # Referenced by submit-sonar.sh after sourcing this file.
MAVEN_COVERAGE_BUILD_DIR=""
# shellcheck disable=SC2034  # Referenced by submit-sonar.sh after sourcing this file.
MAVEN_COVERAGE_REASON=""
MAVEN_SONAR_PLUGIN_VERSION="5.5.0.6356"

# Each strategy is: "JDK_VERSION|BUILD_ARGS"
# Strategies are tried in order until one succeeds

# shellcheck disable=SC2034  # Referenced by build.sh after sourcing this file.
MAVEN_STRATEGIES=(
  # Modern JDKs with standard test skipping
  "25|-DskipTests=true -Dmaven.test.skip=true"
  "21|-DskipTests=true -Dmaven.test.skip=true"
  "17|-DskipTests=true -Dmaven.test.skip=true"
  
  # Older JDKs with more aggressive skipping
  "11|-DskipTests=true -Dmaven.test.skip=true -Dmaven.javadoc.skip=true"
  "8|-DskipTests=true -Dmaven.test.skip=true -Dmaven.javadoc.skip=true -Denforcer.skip=true"
  
  # Fallback: try with checkstyle/spotbugs disabled
  "17|-DskipTests=true -Dmaven.test.skip=true -Dcheckstyle.skip=true -Dspotbugs.skip=true -Dpmd.skip=true"
  "11|-DskipTests=true -Dmaven.test.skip=true -Dcheckstyle.skip=true -Dspotbugs.skip=true -Dpmd.skip=true -Denforcer.skip=true"
)

# Get Maven command for a build
# Usage: get_maven_command <build_dir>
# Returns: maven command (mvn or ./mvnw)
maven_wrapper_kind() {
  local wrapper_path="$1"
  [[ -f "$wrapper_path" ]] || return 1

  if grep -q "org.apache.maven.wrapper.MavenWrapperMain" "$wrapper_path" 2>/dev/null; then
    echo "standard"
    return 0
  fi

  if [[ -x "$wrapper_path" ]] || head -n 1 "$wrapper_path" 2>/dev/null | grep -q '^#!'; then
    echo "custom"
    return 0
  fi

  return 1
}

find_maven_wrapper_upward() {
  local dir="$1"

  while [[ -n "$dir" ]]; do
    local candidate="${dir}/mvnw"
    if [[ -f "$candidate" ]]; then
      local wrapper_kind=""
      if wrapper_kind="$(maven_wrapper_kind "$candidate")"; then
        [[ -x "$candidate" ]] || chmod +x "$candidate" 2>/dev/null || true
        if [[ "$wrapper_kind" == "custom" ]]; then
          log_info "Using custom mvnw script at $candidate"
        fi
        echo "$candidate"
        return 0
      fi
      log_warn "Ignoring unusable mvnw script at $candidate; using system mvn"
    fi

    local parent
    parent="$(dirname "$dir")"
    [[ "$parent" == "$dir" ]] && break
    dir="$parent"
  done

  return 1
}

get_maven_command() {
  local build_dir="$1"
  local wrapper_path=""
  if wrapper_path="$(find_maven_wrapper_upward "$build_dir")"; then
    echo "$wrapper_path"
    return 0
  fi

  echo "mvn"
}

maven_has_pom_packaging() {
  local pom_path="$1"
  [[ -f "$pom_path" ]] || return 1
  grep -Eiq '<packaging>[[:space:]]*pom[[:space:]]*</packaging>' "$pom_path"
}

maven_has_modules_declared() {
  local pom_path="$1"
  [[ -f "$pom_path" ]] || return 1
  grep -Eiq '<module>[[:space:]]*[^<[:space:]][^<]*</module>' "$pom_path"
}

maven_has_main_sources() {
  local build_dir="$1"
  find "$build_dir" -type f \
    \( -name "*.java" -o -name "*.kt" -o -name "*.groovy" -o -name "*.scala" \) \
    -path "*/src/main/*" -print -quit 2>/dev/null | grep -q .
}

maven_validate_project_layout() {
  local build_dir="$1"
  local log_file="${2:-}"
  local pom_path="${build_dir}/pom.xml"

  [[ -f "$pom_path" ]] || return 0

  if maven_has_pom_packaging "$pom_path" && ! maven_has_modules_declared "$pom_path" && maven_has_main_sources "$build_dir"; then
    local msg="Invalid Maven layout: pom.xml uses <packaging>pom</packaging> with no <modules>, but main sources exist under src/main. Use <packaging>jar</packaging> (or declare modules)."
    if [[ -n "$log_file" ]]; then
      printf '[ERROR] %s\n' "$msg" >> "$log_file"
    fi
    log_error "$msg"
    return 1
  fi

  return 0
}

# Build Maven project with specific strategy
# Usage: maven_build <build_dir> <strategy_args> <log_file>
# Returns: 0 on success, non-zero on failure
maven_build() {
  local build_dir="$1"
  local strategy_args="$2"
  local log_file="$3"

  if ! maven_validate_project_layout "$build_dir" "$log_file"; then
    return 1
  fi
  
  local mvn_cmd
  mvn_cmd="$(get_maven_command "$build_dir")"
  local maven_user_home="${build_dir}/.m2"
  local maven_repo_local="${maven_user_home}/repository"
  ensure_dir "$maven_repo_local"
  
  # Base command: clean compile (we don't need to run verify for SonarQube)
  # SonarQube needs compiled classes, not packaged artifacts
  local base_args="clean compile"
  
  # Save and restore working directory
  pushd "$build_dir" >/dev/null || return 1
  
  # Run the build
  local exit_code=0
  # shellcheck disable=SC2086
  run_logged "$log_file" env "MAVEN_USER_HOME=$maven_user_home" $mvn_cmd $base_args $strategy_args "-Dmaven.repo.local=$maven_repo_local" -B || exit_code=$?
  
  popd >/dev/null || return 1
  return $exit_code
}

# Run native SonarQube analysis for Maven project.
# Usage: maven_sonar <build_dir> <project_key> <log_file> [coverage_report_paths] [java_jdk_home]
maven_sonar() {
  local build_dir="$1"
  local project_key="$2"
  local log_file="$3"
  local coverage_report_paths="${4:-}"
  local java_jdk_home="${5:-}"

  if ! maven_validate_project_layout "$build_dir" "$log_file"; then
    return 1
  fi
  
  local mvn_cmd
  mvn_cmd="$(get_maven_command "$build_dir")"
  local maven_user_home="${build_dir}/.m2"
  local maven_repo_local="${maven_user_home}/repository"
  ensure_dir "$maven_repo_local"
  
  # Save and restore working directory
  pushd "$build_dir" >/dev/null || return 1
  
  # Run sonar analysis (classes should already be compiled)
  local exit_code=0
  local -a sonar_cmd=(
    "$mvn_cmd"
    "org.sonarsource.scanner.maven:sonar-maven-plugin:${MAVEN_SONAR_PLUGIN_VERSION}:sonar"
    "-Dsonar.host.url=$SONAR_HOST_URL"
    "-Dsonar.token=$SONAR_TOKEN"
    "-Dsonar.projectKey=$project_key"
    "-Dsonar.organization=$SONAR_ORGANIZATION"
    "-Dmaven.repo.local=$maven_repo_local"
    -DskipTests=true
    -B
  )
  if [[ -n "$coverage_report_paths" ]]; then
    sonar_cmd+=("-Dsonar.coverage.jacoco.xmlReportPaths=$coverage_report_paths")
  fi
  if [[ -n "$java_jdk_home" ]]; then
    sonar_cmd+=("-Dsonar.java.jdkHome=$java_jdk_home")
  fi
  if [[ "${SONAR_SCM_EXCLUSIONS_DISABLED:-}" == "true" ]]; then
    sonar_cmd+=(-Dsonar.scm.exclusions.disabled=true)
  fi
  if [[ "${SONAR_SCM_DISABLED:-}" == "true" ]]; then
    sonar_cmd+=(-Dsonar.scm.disabled=true)
  fi
  run_logged "$log_file" env "MAVEN_USER_HOME=$maven_user_home" "${sonar_cmd[@]}" || exit_code=$?
  
  popd >/dev/null || return 1
  return $exit_code
}

# Parse Maven build error for classification
# Usage: parse_maven_error <log_file>
# Returns: error classification code
parse_maven_error() {
  local log_file="$1"
  
  if grep -q "Invalid Maven layout: pom.xml uses <packaging>pom</packaging>" "$log_file" 2>/dev/null; then
    echo "invalid_project_layout"
  elif grep -q "release version .* not supported" "$log_file" 2>/dev/null; then
    echo "build_jdk_mismatch"
  elif grep -q "Unsupported class file major version" "$log_file" 2>/dev/null; then
    echo "build_jdk_mismatch"
  elif grep -qE "(Cannot resolve|Could not find artifact)" "$log_file" 2>/dev/null; then
    echo "dependency_failure"
  elif grep -qE "(401|403|Unauthorized)" "$log_file" 2>/dev/null; then
    echo "dependency_failure"
  elif grep -q "Compilation failure" "$log_file" 2>/dev/null; then
    echo "compilation_failure"
  elif grep -qE "BUILD FAILURE" "$log_file" 2>/dev/null; then
    echo "build_failure"
  else
    echo "unknown"
  fi
}

# Extract error message from Maven log
# Usage: extract_maven_error_message <log_file>
extract_maven_error_message() {
  local log_file="$1"
  
  # Try to find the most relevant error line
  local error_line
  error_line="$(grep -m1 -E "(ERROR|FATAL|\[ERROR\])" "$log_file" 2>/dev/null | head -c 200)"
  
  if [[ -z "$error_line" ]]; then
    error_line="$(grep -m1 "BUILD FAILURE" "$log_file" 2>/dev/null)"
  fi
  
  if [[ -z "$error_line" ]]; then
    error_line="Build failed (see log for details)"
  fi
  
  echo "$error_line"
}

maven_repo_declares_jacoco() {
  local repo_dir="$1"
  find "$repo_dir" -type f -name "pom.xml" -print0 2>/dev/null | \
    xargs -0 grep -l "jacoco-maven-plugin" >/dev/null 2>&1
}

maven_has_jacoco_xml_reports() {
  local build_dir="$1"
  find "$build_dir" -type f -path "*/target/site/jacoco/*.xml" -print -quit 2>/dev/null | grep -q .
}

maven_requires_submission_prep() {
  local build_dir="$1"
  local pom_path="${build_dir}/pom.xml"

  [[ -f "$pom_path" ]] || return 1
  maven_has_modules_declared "$pom_path" || maven_has_pom_packaging "$pom_path"
}

maven_prepare_submission() {
  local build_dir="$1"
  local log_file="$2"

  if ! maven_validate_project_layout "$build_dir" "$log_file"; then
    return 1
  fi

  local mvn_cmd
  mvn_cmd="$(get_maven_command "$build_dir")"
  local maven_user_home="${build_dir}/.m2"
  local maven_repo_local="${maven_user_home}/repository"
  ensure_dir "$maven_repo_local"

  pushd "$build_dir" >/dev/null || return 1

  local exit_code=0
  local -a prep_cmd=(
    "$mvn_cmd"
    install
    "-Dmaven.repo.local=$maven_repo_local"
    -DskipTests=true
    -B
  )
  run_logged "$log_file" env "MAVEN_USER_HOME=$maven_user_home" "${prep_cmd[@]}" || exit_code=$?

  popd >/dev/null || return 1
  return $exit_code
}

maven_inject_lidskjalv_coverage_profile() {
  local pom_path="$1"
  local jacoco_version="$2"

  python3 - <<'PY' "$pom_path" "$jacoco_version"
import sys
import xml.etree.ElementTree as ET

pom_path = sys.argv[1]
jacoco_version = sys.argv[2]
profile_id = "lidskjalv-coverage"

ET.register_namespace("", "http://maven.apache.org/POM/4.0.0")
tree = ET.parse(pom_path)
root = tree.getroot()

namespace = ""
if root.tag.startswith("{") and "}" in root.tag:
    namespace = root.tag[1:].split("}", 1)[0]

def q(name: str) -> str:
    return f"{{{namespace}}}{name}" if namespace else name

profiles = root.find(q("profiles"))
if profiles is None:
    profiles = ET.SubElement(root, q("profiles"))

for profile in profiles.findall(q("profile")):
    profile_name = profile.find(q("id"))
    if profile_name is not None and (profile_name.text or "").strip() == profile_id:
        print(f"Profile {profile_id!r} already exists", file=sys.stderr)
        raise SystemExit(2)

profile = ET.SubElement(profiles, q("profile"))
ET.SubElement(profile, q("id")).text = profile_id
build = ET.SubElement(profile, q("build"))
plugins = ET.SubElement(build, q("plugins"))
plugin = ET.SubElement(plugins, q("plugin"))
ET.SubElement(plugin, q("groupId")).text = "org.jacoco"
ET.SubElement(plugin, q("artifactId")).text = "jacoco-maven-plugin"
ET.SubElement(plugin, q("version")).text = jacoco_version
executions = ET.SubElement(plugin, q("executions"))

prepare_execution = ET.SubElement(executions, q("execution"))
ET.SubElement(prepare_execution, q("id")).text = "prepare-agent"
prepare_goals = ET.SubElement(prepare_execution, q("goals"))
ET.SubElement(prepare_goals, q("goal")).text = "prepare-agent"

report_execution = ET.SubElement(executions, q("execution"))
ET.SubElement(report_execution, q("id")).text = "report"
ET.SubElement(report_execution, q("phase")).text = "test"
report_goals = ET.SubElement(report_execution, q("goals"))
ET.SubElement(report_goals, q("goal")).text = "report"
report_config = ET.SubElement(report_execution, q("configuration"))
formats = ET.SubElement(report_config, q("formats"))
ET.SubElement(formats, q("format")).text = "XML"

tree.write(pom_path, encoding="utf-8", xml_declaration=True)
PY
}

maven_prepare_coverage() {
  local repo_dir="$1"
  local build_dir="$2"
  local jacoco_version="$3"
  local log_file="$4"
  local support_dir="$5"
  local effective_build_dir="$build_dir"
  local injected_profile=""
  local repo_declares_jacoco="false"
  local needs_submission_prep="false"

  # shellcheck disable=SC2034  # Read by submit-sonar.sh after sourcing.
  MAVEN_COVERAGE_BUILD_DIR="$build_dir"
  # shellcheck disable=SC2034  # Read by submit-sonar.sh after sourcing.
  MAVEN_COVERAGE_REASON=""

  if ! maven_validate_project_layout "$build_dir" "$log_file"; then
    # shellcheck disable=SC2034  # Read by submit-sonar.sh after sourcing.
    MAVEN_COVERAGE_REASON="maven_coverage_invalid_project_layout"
    return 1
  fi

  if maven_repo_declares_jacoco "$repo_dir"; then
    repo_declares_jacoco="true"
  else
    local temp_repo_dir="${support_dir}/repo"
    local relative_build_dir=""

    rm -rf "$temp_repo_dir"
    mkdir -p "$temp_repo_dir"
    cp -a "${repo_dir}/." "$temp_repo_dir/"

    if [[ "$build_dir" != "$repo_dir" ]]; then
      relative_build_dir="${build_dir#"$repo_dir"/}"
      effective_build_dir="${temp_repo_dir}/${relative_build_dir}"
    else
      effective_build_dir="$temp_repo_dir"
    fi

    if ! maven_inject_lidskjalv_coverage_profile "${effective_build_dir}/pom.xml" "$jacoco_version" 2>>"$log_file"; then
      # shellcheck disable=SC2034  # Read by submit-sonar.sh after sourcing.
      MAVEN_COVERAGE_REASON="maven_coverage_profile_injection_failed"
      return 1
    fi

    injected_profile="lidskjalv-coverage"
  fi

  local mvn_cmd
  mvn_cmd="$(get_maven_command "$effective_build_dir")"
  local maven_user_home="${effective_build_dir}/.m2"
  local maven_repo_local="${maven_user_home}/repository"
  ensure_dir "$maven_repo_local"

  pushd "$effective_build_dir" >/dev/null || {
    # shellcheck disable=SC2034  # Read by submit-sonar.sh after sourcing.
    MAVEN_COVERAGE_REASON="maven_coverage_workspace_unavailable"
    return 1
  }

  local exit_code=0
  local -a test_cmd=(
    "$mvn_cmd"
    test
    "-Dmaven.repo.local=$maven_repo_local"
    -DskipTests=false
    -Dmaven.test.skip=false
    -B
  )
  if [[ -n "$injected_profile" ]]; then
    test_cmd+=(-P "$injected_profile")
  fi

  run_logged "$log_file" env "MAVEN_USER_HOME=$maven_user_home" "${test_cmd[@]}" || exit_code=$?

  popd >/dev/null || true

  if [[ $exit_code -ne 0 ]]; then
    # shellcheck disable=SC2034  # Read by submit-sonar.sh after sourcing.
    MAVEN_COVERAGE_REASON="maven_coverage_test_failed"
    return 1
  fi

  if maven_requires_submission_prep "$effective_build_dir"; then
    needs_submission_prep="true"
  fi
  if [[ "$repo_declares_jacoco" == "true" ]] && ! maven_has_jacoco_xml_reports "$effective_build_dir"; then
    needs_submission_prep="true"
  fi

  if [[ "$needs_submission_prep" == "true" ]]; then
    log_info "Running Maven install -DskipTests to prepare Sonar submission"
    if ! maven_prepare_submission "$effective_build_dir" "$log_file"; then
      # shellcheck disable=SC2034  # Read by submit-sonar.sh after sourcing.
      MAVEN_COVERAGE_REASON="maven_coverage_submission_prep_failed"
      return 1
    fi
  fi

  # shellcheck disable=SC2034  # Read by submit-sonar.sh after sourcing.
  MAVEN_COVERAGE_BUILD_DIR="$effective_build_dir"
  return 0
}

maven_classify_sonar_failure() {
  local log_file="$1"

  if grep -Eiq "UnsupportedClassVersionError|has been compiled by a more recent version of the Java Runtime|class file version [0-9]+" "$log_file" 2>/dev/null; then
    echo "scanner_runtime_mismatch"
  elif grep -Eiq "Fail to download libraries from server|Failed to download|Index [0-9]+ out of bounds" "$log_file" 2>/dev/null; then
    echo "native_scanner_server_download_failure"
  elif grep -Eiq "ClassRealm|NoClassDefFoundError|NoSuchMethodError|PluginContainerException|Unable to load the mojo|Could not find goal 'sonar'" "$log_file" 2>/dev/null; then
    echo "native_scanner_incompatible"
  else
    echo "native_scanner_incompatible"
  fi
}

maven_classify_coverage_missing_reports() {
  local log_file="$1"

  if grep -Eiq "Tests are skipped|maven\.test\.skip|Skipping execution due to missing execution data file" "$log_file" 2>/dev/null; then
    echo "tests_skipped_by_config"
  else
    echo "coverage_report_missing"
  fi
}
