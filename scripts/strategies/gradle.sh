#!/usr/bin/env bash
# gradle.sh - Gradle build strategies
# Defines build configurations to try for Gradle projects

# ============================================================================
# Gradle Build Strategies
# ============================================================================

# Each strategy is: "JDK_VERSION|BUILD_ARGS"
# Strategies are tried in order until one succeeds

# shellcheck disable=SC2034  # Referenced by build.sh after sourcing this file.
GRADLE_STRATEGIES=(
  # Modern JDKs with test skipping (no -x integrationTest: Gradle 8.9+ fails on non-existent tasks)
  "21|build -x test -x check"
  "17|build -x test -x check"
  
  # Try just assemble (compile without tests)
  "21|assemble"
  "17|assemble"
  "11|assemble"
  
  # Older JDKs with more flags
  "11|build -x test -x check --no-daemon"
  "8|build -x test -x check --no-daemon"

  # Fallback: classes only
  "17|classes testClasses"
  "11|classes testClasses"

  # Wrapper-only projects may expose a smaller task surface but still support Java compilation.
  "21|compileJava"
  "17|compileJava"
)

GRADLE_COVERAGE_REASON=""

# Get Gradle command for a build
# Usage: get_gradle_command <build_dir>
# Returns: gradle command (./gradlew or gradle)
gradle_wrapper_kind() {
  local wrapper_path="$1"
  [[ -f "$wrapper_path" ]] || return 1

  if grep -q "org.gradle.wrapper.GradleWrapperMain" "$wrapper_path" 2>/dev/null; then
    echo "standard"
    return 0
  fi

  if [[ -x "$wrapper_path" ]] || head -n 1 "$wrapper_path" 2>/dev/null | grep -q '^#!'; then
    echo "custom"
    return 0
  fi

  return 1
}

find_gradle_wrapper_upward() {
  local dir="$1"

  while [[ -n "$dir" ]]; do
    local candidate="${dir}/gradlew"
    if [[ -f "$candidate" ]]; then
      local wrapper_kind=""
      if wrapper_kind="$(gradle_wrapper_kind "$candidate")"; then
        [[ -x "$candidate" ]] || chmod +x "$candidate" 2>/dev/null || true
        if [[ "$wrapper_kind" == "custom" ]]; then
          log_info "Using custom gradlew script at $candidate"
        fi
        echo "$candidate"
        return 0
      fi
      log_warn "Ignoring unusable gradlew script at $candidate; using system gradle"
    fi

    local parent
    parent="$(dirname "$dir")"
    [[ "$parent" == "$dir" ]] && break
    dir="$parent"
  done

  return 1
}

gradle_has_build_marker() {
  local build_dir="$1"
  [[ -f "${build_dir}/build.gradle" ]] ||
    [[ -f "${build_dir}/build.gradle.kts" ]] ||
    [[ -f "${build_dir}/settings.gradle" ]] ||
    [[ -f "${build_dir}/settings.gradle.kts" ]]
}

gradle_validate_project_layout() {
  local build_dir="$1"
  local log_file="${2:-}"

  if gradle_has_build_marker "$build_dir"; then
    return 0
  fi

  if find_gradle_wrapper_upward "$build_dir" >/dev/null 2>&1; then
    return 0
  fi

  local msg="Invalid Gradle layout: no build.gradle(.kts)/settings.gradle(.kts) found in $build_dir and no valid Gradle wrapper found in parent directories."
  if [[ -n "$log_file" ]]; then
    printf '[ERROR] %s\n' "$msg" >> "$log_file"
  fi
  log_error "$msg"
  return 1
}

get_gradle_command() {
  local build_dir="$1"
  local wrapper_path=""
  if wrapper_path="$(find_gradle_wrapper_upward "$build_dir")"; then
    echo "$wrapper_path"
    return 0
  fi

  echo "gradle"
}

gradle_run_command() {
  local log_file="$1"
  local gradle_user_home="$2"
  local gradle_cmd="$3"
  shift 3

  local exit_code=0
  run_logged "$log_file" env "GRADLE_USER_HOME=$gradle_user_home" "$gradle_cmd" "$@" --stacktrace || exit_code=$?

  if [[ $exit_code -ne 0 ]] && [[ "$(basename "$gradle_cmd")" == "gradlew" ]]; then
    if grep -Eq "Unsupported task: --stacktrace|Unknown option.*--stacktrace" "$log_file" 2>/dev/null; then
      log_warn "Custom gradlew detected (no --stacktrace support), retrying without --stacktrace"
      exit_code=0
      run_logged "$log_file" env "GRADLE_USER_HOME=$gradle_user_home" "$gradle_cmd" "$@" || exit_code=$?
    fi
  fi

  return $exit_code
}

gradle_detect_version_info() {
  local build_dir="$1"
  local gradle_major_version=8
  local gradle_full_version="unknown"

  if [[ -f "${build_dir}/gradle/wrapper/gradle-wrapper.properties" ]]; then
    local gradle_dist_url=""
    gradle_dist_url="$(grep -E "distributionUrl" "${build_dir}/gradle/wrapper/gradle-wrapper.properties" 2>/dev/null | cut -d'=' -f2)"
    if [[ -n "$gradle_dist_url" ]]; then
      gradle_full_version="$(echo "$gradle_dist_url" | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -1)"
      gradle_major_version="$(echo "$gradle_full_version" | cut -d'.' -f1)"
    fi
  fi

  echo "${gradle_full_version}|${gradle_major_version}"
}

gradle_select_sonar_plugin_version() {
  local gradle_major_version="${1:-8}"

  if [[ "$gradle_major_version" -le 6 ]]; then
    echo "4.4.1.3373"
  elif [[ "$gradle_major_version" -le 8 ]]; then
    echo "6.3.1.5724"
  else
    echo "7.2.3.7755"
  fi
}

gradle_build_file_matches() {
  local build_dir="$1"
  local pattern="$2"
  local build_file=""

  for build_file in \
    "${build_dir}/build.gradle" \
    "${build_dir}/build.gradle.kts" \
    "${build_dir}/settings.gradle" \
    "${build_dir}/settings.gradle.kts"; do
    if [[ -f "$build_file" ]] && grep -Eq "$pattern" "$build_file" 2>/dev/null; then
      return 0
    fi
  done

  return 1
}

gradle_has_sonarqube_plugin() {
  local build_dir="$1"
  gradle_build_file_matches "$build_dir" "org\\.sonarqube|\\bsonarqube\\b"
}

gradle_has_jacoco_plugin() {
  local build_dir="$1"
  gradle_build_file_matches "$build_dir" "id[[:space:]]*['\"]jacoco['\"]|apply[[:space:]]+plugin:[[:space:]]*['\"]jacoco['\"]|\\bjacoco[[:space:]]*\\{"
}

gradle_write_jacoco_init_script() {
  local init_script="$1"
  local jacoco_version="$2"

  cat > "$init_script" <<GRADLE_INIT
import org.gradle.api.tasks.testing.Test
import org.gradle.testing.jacoco.plugins.JacocoPluginExtension
import org.gradle.testing.jacoco.tasks.JacocoReport

gradle.rootProject {
    if (tasks.findByName("lidskjalvCoverage") == null) {
        tasks.register("lidskjalvCoverage")
    }
}

allprojects { project ->
    project.pluginManager.withPlugin("java") {
        def hadJacoco = project.plugins.hasPlugin("jacoco")
        if (!hadJacoco) {
            project.pluginManager.apply("jacoco")
        }
        def jacocoExtension = project.extensions.findByType(JacocoPluginExtension)
        if (jacocoExtension != null && (!hadJacoco || !jacocoExtension.toolVersion)) {
            jacocoExtension.toolVersion = "${jacoco_version}"
        }

        project.tasks.withType(Test).configureEach { testTask ->
            def capitalized = testTask.name.substring(0, 1).toUpperCase() + testTask.name.substring(1)
            def reportTaskName = "lidskjalvJacoco\${capitalized}Report"
            if (project.tasks.findByName(reportTaskName) == null) {
                project.tasks.register(reportTaskName, JacocoReport) { reportTask ->
                    dependsOn(testTask)
                    executionData(testTask)
                    if (project.extensions.findByName("sourceSets") != null) {
                        def mainSourceSet = project.sourceSets.findByName("main")
                        if (mainSourceSet != null) {
                            sourceDirectories.from(mainSourceSet.allSource.srcDirs)
                            additionalSourceDirs.from(mainSourceSet.allSource.srcDirs)
                            classDirectories.from(mainSourceSet.output)
                        }
                    }
                    reports {
                        xml.required = true
                        html.required = false
                        csv.required = false
                        xml.outputLocation = project.layout.buildDirectory.file("reports/jacoco/\${testTask.name}/\${reportTaskName}.xml")
                    }
                    onlyIf {
                        executionData.files.any { it.exists() }
                    }
                }
            }
            testTask.finalizedBy(reportTaskName)
            gradle.rootProject.tasks.named("lidskjalvCoverage").configure {
                dependsOn(testTask)
                dependsOn(project.tasks.named(reportTaskName))
            }
        }
    }
}
GRADLE_INIT
}

gradle_write_sonar_init_script() {
  local init_script="$1"
  local sonar_plugin_version="$2"

  cat > "$init_script" <<GRADLE_INIT
initscript {
    repositories {
        maven { url = uri("https://plugins.gradle.org/m2/") }
    }
    dependencies {
        classpath "org.sonarsource.scanner.gradle:sonarqube-gradle-plugin:${sonar_plugin_version}"
    }
}
allprojects {
    apply plugin: org.sonarqube.gradle.SonarQubePlugin
}
GRADLE_INIT
}

gradle_prepare_coverage() {
  local build_dir="$1"
  local jacoco_version="$2"
  local log_file="$3"
  local support_dir="$4"

  GRADLE_COVERAGE_REASON=""

  if ! gradle_validate_project_layout "$build_dir" "$log_file"; then
    GRADLE_COVERAGE_REASON="gradle_coverage_invalid_project_layout"
    return 1
  fi

  local gradle_cmd
  gradle_cmd="$(get_gradle_command "$build_dir")"
  local gradle_user_home="${build_dir}/.gradle-user-home"
  ensure_dir "$gradle_user_home"
  ensure_dir "$support_dir"

  local init_script="${support_dir}/jacoco-init.gradle"
  gradle_write_jacoco_init_script "$init_script" "$jacoco_version"

  pushd "$build_dir" >/dev/null || {
    GRADLE_COVERAGE_REASON="gradle_coverage_workspace_unavailable"
    return 1
  }

  local exit_code=0
  gradle_run_command "$log_file" "$gradle_user_home" "$gradle_cmd" --init-script "$init_script" lidskjalvCoverage || exit_code=$?

  popd >/dev/null || true

  if [[ $exit_code -ne 0 ]]; then
    GRADLE_COVERAGE_REASON="gradle_coverage_test_failed"
    return 1
  fi

  return 0
}

# Build Gradle project with specific strategy
# Usage: gradle_build <build_dir> <strategy_args> <log_file>
# Returns: 0 on success, non-zero on failure
gradle_build() {
  local build_dir="$1"
  local strategy_args="$2"
  local log_file="$3"

  if ! gradle_validate_project_layout "$build_dir" "$log_file"; then
    return 1
  fi
  
  local gradle_cmd
  gradle_cmd="$(get_gradle_command "$build_dir")"
  local gradle_user_home="${build_dir}/.gradle-user-home"
  ensure_dir "$gradle_user_home"
  local -a strategy_parts=()
  read -r -a strategy_parts <<< "$strategy_args"
  
  # Save and restore working directory
  pushd "$build_dir" >/dev/null || return 1
  
  local exit_code=0
  gradle_run_command "$log_file" "$gradle_user_home" "$gradle_cmd" "${strategy_parts[@]}" || exit_code=$?
  
  popd >/dev/null || return 1
  return $exit_code
}

# Run native SonarQube analysis for Gradle project.
# Usage: gradle_sonar <build_dir> <project_key> <log_file> [coverage_report_paths] [support_dir] [java_jdk_home]
gradle_sonar() {
  local build_dir="$1"
  local project_key="$2"
  local log_file="$3"
  local coverage_report_paths="${4:-}"
  local support_dir="${5:-}"
  local java_jdk_home="${6:-}"
  local created_support_dir="false"

  if ! gradle_validate_project_layout "$build_dir" "$log_file"; then
    return 1
  fi
  
  local gradle_cmd
  gradle_cmd="$(get_gradle_command "$build_dir")"
  local gradle_user_home="${build_dir}/.gradle-user-home"
  ensure_dir "$gradle_user_home"
  
  # Save and restore working directory
  pushd "$build_dir" >/dev/null || return 1
  
  local exit_code=0
  
  local -a sonar_args=(
    "-Dsonar.host.url=$SONAR_HOST_URL"
    "-Dsonar.token=$SONAR_TOKEN"
    "-Dsonar.projectKey=$project_key"
    "-Dsonar.organization=$SONAR_ORGANIZATION"
    -Dsonar.gradle.skipCompile=true
  )
  if [[ -n "$coverage_report_paths" ]]; then
    sonar_args+=("-Dsonar.coverage.jacoco.xmlReportPaths=$coverage_report_paths")
  fi
  if [[ -n "$java_jdk_home" ]]; then
    sonar_args+=("-Dsonar.java.jdkHome=$java_jdk_home")
  fi
  if [[ "${SONAR_SCM_EXCLUSIONS_DISABLED:-}" == "true" ]]; then
    sonar_args+=(-Dsonar.scm.exclusions.disabled=true)
  fi
  if [[ "${SONAR_SCM_DISABLED:-}" == "true" ]]; then
    sonar_args+=(-Dsonar.scm.disabled=true)
  fi
  
  local version_info=""
  version_info="$(gradle_detect_version_info "$build_dir")"
  local gradle_full_version="${version_info%%|*}"
  local gradle_major_version="${version_info#*|}"
  
  log_info "Detected Gradle version: ${gradle_full_version} (major: ${gradle_major_version})"
  
  local sonar_plugin_version=""
  sonar_plugin_version="$(gradle_select_sonar_plugin_version "$gradle_major_version")"
  
  log_info "Selected SonarQube plugin version: ${sonar_plugin_version} for Gradle ${gradle_major_version}.x"
  
  if gradle_has_sonarqube_plugin "$build_dir"; then
    log_info "Project has SonarQube plugin configured, using 'sonar' task"
    gradle_run_command "$log_file" "$gradle_user_home" "$gradle_cmd" sonar "${sonar_args[@]}" -x test || exit_code=$?
  else
    log_info "No SonarQube plugin found, injecting via init script"
    if [[ -z "$support_dir" ]]; then
      ensure_dir "$WORK_DIR"
      support_dir="$(mktemp -d "${WORK_DIR%/}/gradle-sonar-${project_key}.XXXXXX")"
      created_support_dir="true"
    fi
    ensure_dir "$support_dir"
    local init_script="${support_dir}/sonar-init.gradle"
    gradle_write_sonar_init_script "$init_script" "$sonar_plugin_version"
    gradle_run_command "$log_file" "$gradle_user_home" "$gradle_cmd" --init-script "$init_script" sonar "${sonar_args[@]}" -x test || exit_code=$?
  fi
  
  popd >/dev/null || return 1
  if [[ "$created_support_dir" == "true" ]] && [[ -d "$support_dir" ]]; then
    rm -rf "$support_dir"
  fi
  return $exit_code
}

# Parse Gradle build error for classification
# Usage: parse_gradle_error <log_file>
# Returns: error classification code
parse_gradle_error() {
  local log_file="$1"
  
  if grep -q "Invalid Gradle layout:" "$log_file" 2>/dev/null; then
    echo "invalid_project_layout"
  elif grep -q "Could not create parent directory for lock file" "$log_file" 2>/dev/null; then
    echo "environment_permission"
  elif grep -q "SDK location not found" "$log_file" 2>/dev/null; then
    echo "sdk_not_found"
  elif grep -q "com/android/build/gradle" "$log_file" 2>/dev/null; then
    echo "android_plugin_incompatibility"
  elif grep -q "Task .* not found in root project" "$log_file" 2>/dev/null; then
    echo "task_not_found"
  elif grep -q "Unsupported class file major version" "$log_file" 2>/dev/null; then
    echo "build_jdk_mismatch"
  elif grep -qE "Could not determine java version|UnsupportedClassVersionError" "$log_file" 2>/dev/null; then
    echo "build_jdk_mismatch"
  elif grep -qE "Incompatible .* version" "$log_file" 2>/dev/null; then
    echo "build_jdk_mismatch"
  elif grep -qE "(Cannot resolve|Could not resolve)" "$log_file" 2>/dev/null; then
    echo "dependency_failure"
  elif grep -qE "(401|403|Unauthorized)" "$log_file" 2>/dev/null; then
    echo "dependency_failure"
  elif grep -q "Compilation failed" "$log_file" 2>/dev/null; then
    echo "compilation_failure"
  elif grep -qE "BUILD FAILED" "$log_file" 2>/dev/null; then
    echo "build_failure"
  else
    echo "unknown"
  fi
}

# Extract error message from Gradle log
# Usage: extract_gradle_error_message <log_file>
extract_gradle_error_message() {
  local log_file="$1"
  
  local error_line
  
  if grep -q "Invalid Gradle layout:" "$log_file" 2>/dev/null; then
    error_line="$(grep -m1 "Invalid Gradle layout:" "$log_file" 2>/dev/null | head -c 200)"
  elif grep -q "Could not create parent directory for lock file" "$log_file" 2>/dev/null; then
    error_line="$(grep -m1 "Could not create parent directory for lock file" "$log_file" 2>/dev/null | head -c 200)"
  elif grep -q "SDK location not found" "$log_file" 2>/dev/null; then
    error_line="Android SDK not found (set ANDROID_HOME or sdk.dir in local.properties)"
  elif grep -q "Task .* not found in root project" "$log_file" 2>/dev/null; then
    error_line="$(grep -m1 "Task .* not found" "$log_file" 2>/dev/null | head -c 200)"
  elif grep -q "What went wrong:" "$log_file" 2>/dev/null; then
    error_line="$(grep -A2 "What went wrong:" "$log_file" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' | head -c 200)"
  elif grep -q "FAILURE:" "$log_file" 2>/dev/null; then
    error_line="$(grep -m1 -A2 "FAILURE:" "$log_file" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' | head -c 200)"
  # Try generic error markers
  elif grep -qE "^> .*" "$log_file" 2>/dev/null; then
    error_line="$(grep -m1 -E "^> .*" "$log_file" 2>/dev/null | head -c 200)"
  fi
  
  if [[ -z "$error_line" || "$error_line" =~ ^[[:space:]]*$ ]]; then
    error_line="Build failed (see log for details)"
  fi
  
  echo "$error_line"
}

gradle_classify_sonar_failure() {
  local log_file="$1"

  if grep -Eiq "UnsupportedClassVersionError|Could not determine java version|class file version [0-9]+" "$log_file" 2>/dev/null; then
    echo "scanner_runtime_mismatch"
  elif grep -Eiq "Fail to download|Unable to download|PKIX path building failed|Could not GET" "$log_file" 2>/dev/null; then
    echo "native_scanner_server_download_failure"
  elif grep -Eiq "com/android/build/gradle|configuration-cache|Plugin with id 'org\.sonarqube' not found|No signature of method: .*sonar|Could not create task ':sonar'" "$log_file" 2>/dev/null; then
    echo "native_scanner_incompatible"
  else
    echo "native_scanner_incompatible"
  fi
}
