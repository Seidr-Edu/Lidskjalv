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
)

# Get Gradle command for a build
# Usage: get_gradle_command <build_dir>
# Returns: gradle command (./gradlew or gradle)
get_gradle_command() {
  local build_dir="$1"
  
  if [[ -x "${build_dir}/gradlew" ]]; then
    echo "./gradlew"
  elif [[ -f "${build_dir}/gradlew" ]]; then
    # Make it executable
    chmod +x "${build_dir}/gradlew"
    echo "./gradlew"
  else
    echo "gradle"
  fi
}

# Build Gradle project with specific strategy
# Usage: gradle_build <build_dir> <strategy_args> <log_file>
# Returns: 0 on success, non-zero on failure
gradle_build() {
  local build_dir="$1"
  local strategy_args="$2"
  local log_file="$3"
  
  local gradle_cmd
  gradle_cmd="$(get_gradle_command "$build_dir")"
  
  # Save and restore working directory
  pushd "$build_dir" >/dev/null || return 1
  
  # Run the build.
  # Prefer --stacktrace for standard Gradle, but retry without it for custom
  # wrapper scripts that only accept task names.
  local exit_code=0
  # shellcheck disable=SC2086
  run_logged "$log_file" $gradle_cmd $strategy_args --stacktrace || exit_code=$?

  if [[ $exit_code -ne 0 ]] && [[ "$gradle_cmd" == "./gradlew" ]]; then
    if grep -q "Unsupported task: --stacktrace" "$log_file" 2>/dev/null; then
      log_warn "Custom gradlew detected (no --stacktrace support), retrying without --stacktrace"
      exit_code=0
      # shellcheck disable=SC2086
      run_logged "$log_file" $gradle_cmd $strategy_args || exit_code=$?
    fi
  fi
  
  popd >/dev/null || return 1
  return $exit_code
}

# Run SonarQube analysis for Gradle project
# Usage: gradle_sonar <build_dir> <project_key> <log_file>
gradle_sonar() {
  local build_dir="$1"
  local project_key="$2"
  local log_file="$3"
  
  local gradle_cmd
  gradle_cmd="$(get_gradle_command "$build_dir")"
  
  # Save and restore working directory
  pushd "$build_dir" >/dev/null || return 1
  
  local exit_code=0
  
  # Common sonar args to skip recompilation (already built) and tests
  local sonar_args="-Dsonar.host.url=$SONAR_HOST_URL -Dsonar.token=$SONAR_TOKEN -Dsonar.projectKey=$project_key -Dsonar.organization=$SONAR_ORGANIZATION -Dsonar.gradle.skipCompile=true"
  if [[ "${SONAR_SCM_EXCLUSIONS_DISABLED:-}" == "true" ]]; then
    sonar_args="${sonar_args} -Dsonar.scm.exclusions.disabled=true"
  fi
  
  # Detect Gradle version for SonarQube plugin compatibility
  local gradle_major_version=8
  local gradle_full_version="unknown"
  if [[ -f "${build_dir}/gradle/wrapper/gradle-wrapper.properties" ]]; then
    local gradle_dist_url
    gradle_dist_url="$(grep -E "distributionUrl" "${build_dir}/gradle/wrapper/gradle-wrapper.properties" 2>/dev/null | cut -d'=' -f2)"
    if [[ -n "$gradle_dist_url" ]]; then
      gradle_full_version=$(echo "$gradle_dist_url" | grep -oE '[0-9]+\.[0-9]+\.?[0-9]*' | head -1)
      gradle_major_version=$(echo "$gradle_full_version" | cut -d'.' -f1)
    fi
  fi
  
  log_info "Detected Gradle version: ${gradle_full_version} (major: ${gradle_major_version})"
  
  # Select SonarQube Gradle plugin version based on Gradle version
  # Reference: https://docs.sonarsource.com/sonarqube/latest/analyzing-source-code/scanners/sonarscanner-for-gradle/#requirements
  # - Gradle 5.x-7.x: Use plugin 3.5.0.2730 (supports older Gradle APIs)
  # - Gradle 8.x: Use plugin 4.4.1.3373 (compatible with Gradle 8 APIs)
  # - Gradle 9.x+: Use plugin 5.1.0.4882 (supports latest Gradle APIs)
  local sonar_plugin_version="4.4.1.3373"
  if [[ "$gradle_major_version" -le 7 ]]; then
    sonar_plugin_version="3.5.0.2730"
  elif [[ "$gradle_major_version" -eq 8 ]]; then
    sonar_plugin_version="4.4.1.3373"
  else
    sonar_plugin_version="5.1.0.4882"
  fi
  
  log_info "Selected SonarQube plugin version: ${sonar_plugin_version} for Gradle ${gradle_major_version}.x"
  
  if grep -qE "sonarqube|org.sonarqube" build.gradle* 2>/dev/null; then
    log_info "Project has SonarQube plugin configured, using 'sonar' task"
    # shellcheck disable=SC2086
    run_logged "$log_file" $gradle_cmd sonar $sonar_args -x test || exit_code=$?
  else
    log_info "No SonarQube plugin found, injecting via init script"
    local init_script="${build_dir}/sonar-init.gradle"
    cat > "$init_script" << GRADLE_INIT
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
    
    # shellcheck disable=SC2086
    run_logged "$log_file" $gradle_cmd --init-script "$init_script" sonar $sonar_args -x test || exit_code=$?
    
    rm -f "$init_script"
  fi
  
  if [[ $exit_code -ne 0 ]]; then
    log_warn "Gradle-based SonarQube analysis failed (exit code: $exit_code)"
    
    if grep -q "com/android/build/gradle" "$log_file" 2>/dev/null; then
      log_warn "Detected Android Gradle Plugin incompatibility, trying sonar-scanner CLI fallback"
    fi
    
    if command -v sonar-scanner &>/dev/null; then
      log_info "Falling back to sonar-scanner CLI"
      # Reset exit status before fallback; otherwise a successful fallback can still
      # return the original Gradle failure code.
      exit_code=0
      
      local source_dirs=""
      local binary_dirs=""
      
      while IFS= read -r src_dir; do
        if [[ -n "$source_dirs" ]]; then
          source_dirs="${source_dirs},"
        fi
        local rel_path="${src_dir#"$build_dir"/}"
        source_dirs="${source_dirs}${rel_path}"
      done < <(find "$build_dir" -type d -path "*/src/main/java" 2>/dev/null)
      
      if [[ -z "$source_dirs" ]]; then
        while IFS= read -r src_dir; do
          if [[ -n "$source_dirs" ]]; then
            source_dirs="${source_dirs},"
          fi
          local rel_path="${src_dir#"$build_dir"/}"
          source_dirs="${source_dirs}${rel_path}"
        done < <(find "$build_dir" -type d -name "src" -maxdepth 3 2>/dev/null)
      fi
      
      while IFS= read -r class_dir; do
        if [[ -n "$binary_dirs" ]]; then
          binary_dirs="${binary_dirs},"
        fi
        local rel_path="${class_dir#"$build_dir"/}"
        binary_dirs="${binary_dirs}${rel_path}"
      done < <(find "$build_dir" -type d \( -path "*/build/*/classes" -o -path "*/build/classes" \) 2>/dev/null)
      
      if [[ -z "$source_dirs" ]]; then
        source_dirs="src/main/java"
        log_warn "No source directories auto-detected, using default: $source_dirs"
      else
        log_info "Auto-detected source directories: $source_dirs"
      fi
      
      if [[ -n "$binary_dirs" ]]; then
        log_info "Auto-detected binary directories: $binary_dirs"
      else
        log_warn "No compiled classes found - analysis will run without bytecode (reduced rule coverage)"
      fi
      
      # Build sonar-scanner command with optional binaries
      local sonar_cmd=(
        sonar-scanner
        -Dsonar.host.url="$SONAR_HOST_URL"
        -Dsonar.token="$SONAR_TOKEN"
        -Dsonar.projectKey="$project_key"
        -Dsonar.organization="$SONAR_ORGANIZATION"
        -Dsonar.projectBaseDir="$build_dir"
        -Dsonar.sources="$source_dirs"
      )
      
      # Only add binaries parameter if we found compiled classes
      if [[ -n "$binary_dirs" ]]; then
        sonar_cmd+=(-Dsonar.java.binaries="$binary_dirs")
      fi
      if [[ "${SONAR_SCM_EXCLUSIONS_DISABLED:-}" == "true" ]]; then
        sonar_cmd+=(-Dsonar.scm.exclusions.disabled=true)
      fi
      
      run_logged "$log_file" "${sonar_cmd[@]}" || exit_code=$?
      
      if [[ $exit_code -eq 0 ]]; then
        log_success "SonarQube analysis succeeded via CLI fallback"
        echo "CLI" > "${build_dir}/.sonar-analysis-method"
      else
        log_error "sonar-scanner CLI fallback failed (exit code: $exit_code)"
      fi
    else
      log_error "sonar-scanner CLI not available for fallback"
      log_error "Install with: brew install sonar-scanner"
      log_error "Or run this in CI where sonar-scanner is pre-installed"
    fi
  else
    echo "GRADLE" > "${build_dir}/.sonar-analysis-method"
  fi
  
  popd >/dev/null || return 1
  return $exit_code
}

# Parse Gradle build error for classification
# Usage: parse_gradle_error <log_file>
# Returns: error classification code
parse_gradle_error() {
  local log_file="$1"
  
  if grep -q "SDK location not found" "$log_file" 2>/dev/null; then
    echo "sdk_not_found"
  elif grep -q "com/android/build/gradle" "$log_file" 2>/dev/null; then
    echo "android_plugin_incompatibility"
  elif grep -q "Task .* not found in root project" "$log_file" 2>/dev/null; then
    echo "task_not_found"
  elif grep -q "Unsupported class file major version" "$log_file" 2>/dev/null; then
    echo "jdk_mismatch"
  elif grep -qE "Could not determine java version|UnsupportedClassVersionError" "$log_file" 2>/dev/null; then
    echo "jdk_mismatch"
  elif grep -qE "Incompatible .* version" "$log_file" 2>/dev/null; then
    echo "jdk_mismatch"
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
  
  if grep -q "SDK location not found" "$log_file" 2>/dev/null; then
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
