#!/usr/bin/env bash
# gradle.sh - Gradle build strategies
# Defines build configurations to try for Gradle projects

# ============================================================================
# Gradle Build Strategies
# ============================================================================

# Each strategy is: "JDK_VERSION|BUILD_ARGS"
# Strategies are tried in order until one succeeds

GRADLE_STRATEGIES=(
  # Modern JDKs with test skipping
  "21|build -x test -x check -x integrationTest"
  "17|build -x test -x check -x integrationTest"
  
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
  
  # Run the build
  # shellcheck disable=SC2086
  local exit_code=0
  run_logged "$log_file" $gradle_cmd $strategy_args --stacktrace || exit_code=$?
  
  popd >/dev/null
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
  
  # Detect Gradle version for SonarQube plugin compatibility
  # The compatibility issue is between SonarQube plugin and Gradle version, not JDK version
  local gradle_major_version=8
  if [[ -f "${build_dir}/gradle/wrapper/gradle-wrapper.properties" ]]; then
    local gradle_dist_url=$(grep -E "distributionUrl" "${build_dir}/gradle/wrapper/gradle-wrapper.properties" 2>/dev/null | cut -d'=' -f2)
    if [[ -n "$gradle_dist_url" ]]; then
      # Extract version like "8.14.3" or "9.2.1" from URL
      gradle_major_version=$(echo "$gradle_dist_url" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d'.' -f1)
    fi
  fi
  
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
  
  # Check if project has sonarqube plugin configured
  if grep -qE "sonarqube|org.sonarqube" build.gradle* 2>/dev/null; then
    # Use project's sonar task (sonarqube is deprecated)
    # shellcheck disable=SC2086
    run_logged "$log_file" $gradle_cmd sonar $sonar_args -x test || exit_code=$?
  else
    # Fall back to sonar-scanner CLI if available
    if command -v sonar-scanner &>/dev/null; then
      run_logged "$log_file" sonar-scanner \
        -Dsonar.host.url="$SONAR_HOST_URL" \
        -Dsonar.token="$SONAR_TOKEN" \
        -Dsonar.projectKey="$project_key" \
        -Dsonar.organization="$SONAR_ORGANIZATION" \
        -Dsonar.projectBaseDir="$build_dir" \
        -Dsonar.sources=src/main \
        -Dsonar.java.binaries=build/classes || exit_code=$?
    else
      # Try adding sonarqube plugin dynamically via init script
      # Plugin version selected based on Java version (see above)
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
  fi
  
  popd >/dev/null
  return $exit_code
}

# Parse Gradle build error for classification
# Usage: parse_gradle_error <log_file>
# Returns: error classification code
parse_gradle_error() {
  local log_file="$1"
  
  if grep -q "Unsupported class file major version" "$log_file" 2>/dev/null; then
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
  
  # Try to find the most relevant error line
  local error_line
  error_line="$(grep -m1 -A2 "FAILURE:" "$log_file" 2>/dev/null | tail -1 | head -c 200)"
  
  if [[ -z "$error_line" ]]; then
    error_line="$(grep -m1 -E "^> .*" "$log_file" 2>/dev/null | head -c 200)"
  fi
  
  if [[ -z "$error_line" ]]; then
    error_line="Build failed (see log for details)"
  fi
  
  echo "$error_line"
}
