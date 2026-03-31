#!/usr/bin/env bash
# detect-build.sh - Build system detection module
# Detects Maven or Gradle projects, including subdirectory layouts

# Ensure common.sh is sourced
if [[ -z "${WORK_DIR:-}" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
fi

# ============================================================================
# Build system detection
# ============================================================================

# Detect the build system for a repository
# Usage: detect_build_system <repo_dir> [project_key]
# Output format: maven | gradle | maven:subdir | gradle:subdir | unknown
# Detection markers:
# - Maven: pom.xml or mvnw
# - Gradle: build.gradle(.kts) or gradlew
# Returns: 0 if detected, 1 if unknown
detect_build_system() {
  local repo_dir="$1"
  local key="${2:-}"
  local log_file=""
  
  if [[ -n "$key" ]]; then
    # shellcheck disable=SC2153  # LOG_DIR comes from common.sh at runtime.
    local log_dir="${LOG_DIR}/${key}"
    ensure_dir "$log_dir"
    log_file="${log_dir}/detect.log"
    
    {
      echo "========================================"
      echo "Build System Detection"
      echo "Timestamp: $(timestamp)"
      echo "Repository: $repo_dir"
      echo "========================================"
      echo ""
    } > "$log_file"
  fi
  
  local result="unknown"
  
  # Check root directory first
  if [[ -f "${repo_dir}/pom.xml" ]]; then
    result="maven"
    _log_detect "$log_file" "Found pom.xml at root -> maven"
  elif [[ -f "${repo_dir}/build.gradle" ]] || [[ -f "${repo_dir}/build.gradle.kts" ]]; then
    result="gradle"
    _log_detect "$log_file" "Found build.gradle at root -> gradle"
  elif [[ -f "${repo_dir}/mvnw" ]]; then
    result="maven"
    _log_detect "$log_file" "Found mvnw at root -> maven"
  elif [[ -f "${repo_dir}/gradlew" ]]; then
    result="gradle"
    _log_detect "$log_file" "Found gradlew at root -> gradle"
  else
    # Search subdirectories (max depth 2)
    _log_detect "$log_file" "No build file at root, searching subdirectories..."
    
    local subdir_pom subdir_gradle subdir_mvnw subdir_gradlew
    
    # Find pom.xml in subdirectories
    subdir_pom="$(find "$repo_dir" -maxdepth 2 -name "pom.xml" -type f 2>/dev/null | head -1)"
    
    # Find build.gradle in subdirectories
    subdir_gradle="$(find "$repo_dir" -maxdepth 2 \( -name "build.gradle" -o -name "build.gradle.kts" \) -type f 2>/dev/null | head -1)"
    
    # Find wrapper scripts in subdirectories
    subdir_mvnw="$(find "$repo_dir" -maxdepth 2 -name "mvnw" -type f 2>/dev/null | head -1)"
    subdir_gradlew="$(find "$repo_dir" -maxdepth 2 -name "gradlew" -type f 2>/dev/null | head -1)"
    
    if [[ -n "$subdir_pom" ]]; then
      local subdir
      subdir="$(dirname "$subdir_pom")"
      subdir="${subdir#"$repo_dir"/}"
      result="maven:${subdir}"
      _log_detect "$log_file" "Found pom.xml in subdir: $subdir -> maven:$subdir"
    elif [[ -n "$subdir_gradle" ]]; then
      local subdir
      subdir="$(dirname "$subdir_gradle")"
      subdir="${subdir#"$repo_dir"/}"
      result="gradle:${subdir}"
      _log_detect "$log_file" "Found build.gradle in subdir: $subdir -> gradle:$subdir"
    elif [[ -n "$subdir_mvnw" ]]; then
      local subdir
      subdir="$(dirname "$subdir_mvnw")"
      subdir="${subdir#"$repo_dir"/}"
      result="maven:${subdir}"
      _log_detect "$log_file" "Found mvnw in subdir: $subdir -> maven:$subdir"
    elif [[ -n "$subdir_gradlew" ]]; then
      local subdir
      subdir="$(dirname "$subdir_gradlew")"
      subdir="${subdir#"$repo_dir"/}"
      result="gradle:${subdir}"
      _log_detect "$log_file" "Found gradlew in subdir: $subdir -> gradle:$subdir"
    else
      _log_detect "$log_file" "No build markers found (pom.xml/build.gradle/mvnw/gradlew)"
    fi
  fi
  
  if [[ -n "$log_file" ]]; then
    {
      echo ""
      echo "========================================"
      echo "Result: $result"
      echo "========================================"
    } >> "$log_file"
  fi
  
  echo "$result"
  [[ "$result" != "unknown" ]]
}

# Helper to log detection messages
_log_detect() {
  local log_file="$1"
  local message="$2"
  
  if [[ -n "$log_file" ]]; then
    echo "$message" >> "$log_file"
  fi
}

# Parse build tool and subdir from detection result
# Usage: parse_build_result <result>
# Sets: BUILD_TOOL and BUILD_SUBDIR
parse_build_result() {
  local result="$1"
  
  if [[ "$result" == *":"* ]]; then
    BUILD_TOOL="${result%%:*}"
    BUILD_SUBDIR="${result#*:}"
  else
    BUILD_TOOL="$result"
    BUILD_SUBDIR=""
  fi
  
  export BUILD_TOOL BUILD_SUBDIR
}

# Get effective build directory
# Usage: get_build_dir <repo_dir> <build_result>
get_build_dir() {
  local repo_dir="$1"
  local build_result="$2"
  
  parse_build_result "$build_result"
  
  if [[ -n "$BUILD_SUBDIR" ]]; then
    echo "${repo_dir}/${BUILD_SUBDIR}"
  else
    echo "$repo_dir"
  fi
}

# Check if repository uses Maven
# Usage: is_maven <build_result>
is_maven() {
  local result="$1"
  [[ "$result" == "maven" || "$result" == maven:* ]]
}

# Check if repository uses Gradle
# Usage: is_gradle <build_result>
is_gradle() {
  local result="$1"
  [[ "$result" == "gradle" || "$result" == gradle:* ]]
}

# ============================================================================
# Build file analysis
# ============================================================================

# Extract Java version hint from Maven pom.xml
# Usage: extract_maven_java_version <pom_file>
# Returns: version number or empty
extract_maven_java_version() {
  local pom_file="$1"
  local version=""

  for pattern in \
    "maven.compiler.release" \
    "maven.compiler.source" \
    "maven.compiler.target" \
    "java.version" \
    "jdk.version" \
    "java.source.version" \
    "java.target.version"; do
    version="$(sed -n "s/.*<${pattern}>\([^<]*\)<.*/\1/p" "$pom_file" 2>/dev/null | head -1)"
    if [[ -n "$version" ]]; then
      version="$(_normalize_java_version "$version")"
      [[ -n "$version" ]] && break
    fi
  done

  if [[ -z "$version" ]]; then
    version="$(sed -n 's/.*<release>\([^<]*\)<.*/\1/p' "$pom_file" 2>/dev/null | head -1)"
    [[ -n "$version" ]] && version="$(_normalize_java_version "$version")"
  fi

  if [[ -z "$version" ]]; then
    version="$(sed -n 's/.*<source>\([^<]*\)<.*/\1/p' "$pom_file" 2>/dev/null | head -1)"
    [[ -n "$version" ]] && version="$(_normalize_java_version "$version")"
  fi

  if [[ -z "$version" ]]; then
    version="$(sed -n 's/.*<target>\([^<]*\)<.*/\1/p' "$pom_file" 2>/dev/null | head -1)"
    [[ -n "$version" ]] && version="$(_normalize_java_version "$version")"
  fi

  echo "$version"
}

extract_maven_java_version_from_jvm_config() {
  local jvm_config="$1"
  local version=""

  [[ -f "$jvm_config" ]] || {
    echo ""
    return 0
  }

  version="$(grep -Eo 'maven\.compiler\.(release|source|target)=[^[:space:]]+' "$jvm_config" 2>/dev/null | head -1 | cut -d'=' -f2)"
  if [[ -z "$version" ]]; then
    version="$(grep -Eo '(java|jdk)\.version=[^[:space:]]+' "$jvm_config" 2>/dev/null | head -1 | cut -d'=' -f2)"
  fi

  if [[ -n "$version" ]]; then
    version="$(_normalize_java_version "$version")"
  fi

  echo "$version"
}

find_maven_jvm_config() {
  local repo_dir="$1"
  local build_dir="$2"
  local dir="$build_dir"

  while [[ -n "$dir" ]]; do
    if [[ -f "${dir}/.mvn/jvm.config" ]]; then
      echo "${dir}/.mvn/jvm.config"
      return 0
    fi

    [[ "$dir" == "$repo_dir" ]] && break
    local parent
    parent="$(dirname "$dir")"
    [[ "$parent" == "$dir" ]] && break
    dir="$parent"
  done

  echo ""
}

# Extract Java version hint from Gradle build file
# Usage: extract_gradle_java_version <build_file>
# Returns: version number or empty
extract_gradle_java_version() {
  local build_file="$1"
  local version=""

  version="$(sed -n "s/.*sourceCompatibility[[:space:]]*=[[:space:]]*['\"\`]*\([0-9.]*\).*/\1/p" "$build_file" 2>/dev/null | head -1)"

  if [[ -z "$version" ]]; then
    version="$(sed -n "s/.*targetCompatibility[[:space:]]*=[[:space:]]*['\"\`]*\([0-9.]*\).*/\1/p" "$build_file" 2>/dev/null | head -1)"
  fi

  if [[ -z "$version" ]]; then
    version="$(sed -n 's/.*JavaLanguageVersion\.of[[:space:]]*([[:space:]]*\([0-9][0-9]*\).*/\1/p' "$build_file" 2>/dev/null | tail -1)"
  fi

  if [[ -z "$version" ]]; then
    version="$(sed -n 's/.*languageVersion[[:space:]]*=[[:space:]]*JavaLanguageVersion\.of[[:space:]]*([[:space:]]*\([0-9][0-9]*\).*/\1/p' "$build_file" 2>/dev/null | tail -1)"
  fi

  if [[ -z "$version" ]]; then
    version="$(sed -n 's/.*jvmToolchain[[:space:]]*([[:space:]]*\([0-9][0-9]*\).*/\1/p' "$build_file" 2>/dev/null | head -1)"
  fi

  if [[ -z "$version" ]]; then
    version="$(sed -n 's/.*JavaVersion\.VERSION_\([0-9_]*\).*/\1/p' "$build_file" 2>/dev/null | head -1 | tr -d '_')"
  fi

  if [[ -n "$version" ]]; then
    version="$(_normalize_java_version "$version")"
  fi

  echo "$version"
}

# Normalize Java version string
# 1.8 -> 8, 1.11 -> 11, 17 -> 17
_normalize_java_version() {
  local version="$1"

  if [[ "$version" =~ ^1\.([0-9]+) ]]; then
    version="${BASH_REMATCH[1]}"
  fi

  version="${version%%[^0-9]*}"

  echo "$version"
}

detect_gradle_wrapper_java_version_hint() {
  local build_dir="$1"
  local version_info=""
  local gradle_major=""
  local wrapper_file="${build_dir}/gradle/wrapper/gradle-wrapper.properties"

  [[ -f "$wrapper_file" ]] || {
    echo ""
    return 0
  }

  version_info="$(grep -E "distributionUrl" "$wrapper_file" 2>/dev/null | grep -oE 'gradle-[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/gradle-//')"
  gradle_major="${version_info%%.*}"

  case "$gradle_major" in
    9|8) echo "17" ;;
    7) echo "11" ;;
    *) echo "" ;;
  esac
}

# Detect Java version requirement for a repository
# Usage: detect_java_version <repo_dir> <build_tool> [subdir]
# Returns: version number or empty
detect_java_version() {
  local repo_dir="$1"
  local build_tool="$2"
  local subdir="${3:-}"

  local build_dir="$repo_dir"
  if [[ -n "$subdir" ]]; then
    build_dir="${repo_dir}/${subdir}"
  fi

  local version=""

  case "$build_tool" in
    maven)
      if [[ -f "${build_dir}/pom.xml" ]]; then
        version="$(extract_maven_java_version "${build_dir}/pom.xml")"
      fi
      if [[ -z "$version" ]]; then
        local jvm_config=""
        jvm_config="$(find_maven_jvm_config "$repo_dir" "$build_dir")"
        if [[ -n "$jvm_config" ]]; then
          version="$(extract_maven_java_version_from_jvm_config "$jvm_config")"
        fi
      fi
      ;;
    gradle)
      if [[ -f "${build_dir}/build.gradle" ]]; then
        version="$(extract_gradle_java_version "${build_dir}/build.gradle")"
      elif [[ -f "${build_dir}/build.gradle.kts" ]]; then
        version="$(extract_gradle_java_version "${build_dir}/build.gradle.kts")"
      fi
      if [[ -z "$version" ]]; then
        version="$(detect_gradle_wrapper_java_version_hint "$build_dir")"
      fi
      ;;
  esac

  echo "$version"
}

# ============================================================================
# Android project detection
# ============================================================================

# Check if a project is an Android project
# Usage: is_android_project <build_dir>
# Returns: 0 if Android, 1 if not
is_android_project() {
  local build_dir="$1"
  
  # Check for Android Gradle Plugin in build files
  if [[ -f "${build_dir}/build.gradle" ]]; then
    if grep -qE "com\.android\.(application|library|test|dynamic-feature)" "${build_dir}/build.gradle" 2>/dev/null; then
      return 0
    fi
  fi
  
  if [[ -f "${build_dir}/build.gradle.kts" ]]; then
    if grep -qE "com\.android\.(application|library|test|dynamic-feature)" "${build_dir}/build.gradle.kts" 2>/dev/null; then
      return 0
    fi
  fi
  
  # Check for AndroidManifest.xml
  if [[ -f "${build_dir}/src/main/AndroidManifest.xml" ]] || [[ -f "${build_dir}/AndroidManifest.xml" ]]; then
    return 0
  fi
  
  return 1
}
