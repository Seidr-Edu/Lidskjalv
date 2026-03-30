#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/tests/lib/testlib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_fake_sonar_bin() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"

  cat > "${fake_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'mvn|%s|%s\n' "$PWD" "$*" >> "${FAKE_COMMAND_LOG:?}"

has_arg() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

has_sonar_goal() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      org.sonarsource.scanner.maven:sonar-maven-plugin:*:sonar)
        return 0
        ;;
    esac
  done
  return 1
}

write_class_file() {
  local path="$1"
  local major="${2:-61}"
  python3 - <<'PY' "$path" "$major"
import sys

path = sys.argv[1]
major = int(sys.argv[2])

with open(path, "wb") as fh:
    fh.write(bytes.fromhex("cafebabe0000"))
    fh.write(major.to_bytes(2, byteorder="big"))
PY
}

if has_arg clean "$@" && has_arg compile "$@"; then
  mkdir -p target/classes
  write_class_file target/classes/App.class "${FAKE_CLASS_MAJOR:-61}"
  exit 0
fi

if has_arg test "$@"; then
  if grep -q '<id>lidskjalv-coverage</id>' pom.xml 2>/dev/null && ! has_arg -P "$@"; then
    printf '%s\n' "missing -P for injected coverage profile" >&2
    exit 92
  fi
  if [[ "${FAKE_REQUIRE_MAVEN_COVERAGE_PROFILE:-false}" == "true" ]] && ! grep -q '<id>lidskjalv-coverage</id>' pom.xml 2>/dev/null; then
    printf '%s\n' "coverage profile was not injected" >&2
    exit 93
  fi
  if [[ "${FAKE_FORBID_INJECTED_PROFILE:-false}" == "true" ]] && has_arg -P "$@" && [[ "$*" == *"lidskjalv-coverage"* ]]; then
    printf '%s\n' "unexpected injected coverage profile" >&2
    exit 94
  fi
  if [[ -n "${FAKE_MAVEN_TEST_EXIT_CODE:-}" ]]; then
    exit "${FAKE_MAVEN_TEST_EXIT_CODE}"
  fi
  if [[ "${FAKE_MAVEN_COVERAGE_REPORT_MODE:-present}" == "present" ]]; then
    mkdir -p target/site/jacoco
    printf '%s\n' '<report name="fake"/>' > target/site/jacoco/jacoco.xml
  fi
  exit 0
fi

if has_arg install "$@"; then
  if [[ -n "${FAKE_MAVEN_INSTALL_EXIT_CODE:-}" ]]; then
    exit "${FAKE_MAVEN_INSTALL_EXIT_CODE}"
  fi
  if [[ "${FAKE_MAVEN_COVERAGE_REPORT_MODE:-present}" == "late" ]]; then
    mkdir -p target/site/jacoco
    printf '%s\n' '<report name="fake"/>' > target/site/jacoco/jacoco.xml
  fi
  exit 0
fi

if has_sonar_goal "$@"; then
  if [[ "${FAKE_REQUIRE_COVERAGE_REPORT_PATHS:-false}" == "true" && "$*" != *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
    printf '%s\n' "missing coverage report paths" >&2
    exit 95
  fi
  if [[ "${FAKE_FORBID_COVERAGE_REPORT_PATHS:-false}" == "true" && "$*" == *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
    printf '%s\n' "unexpected coverage report paths" >&2
    exit 96
  fi
  if [[ -n "${FAKE_SONAR_SUBMIT_EXIT_CODE:-}" ]]; then
    exit "${FAKE_SONAR_SUBMIT_EXIT_CODE}"
  fi
  mkdir -p .scannerwork
  printf 'ceTaskId=%s\n' "${FAKE_SONAR_TASK_ID:-fake-task}" > .scannerwork/report-task.txt
  exit 0
fi

exit 0
EOF
  chmod +x "${fake_bin}/mvn"

  cat > "${fake_bin}/gradle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'gradle|%s|%s\n' "$PWD" "$*" >> "${FAKE_COMMAND_LOG:?}"

has_arg() {
  local needle="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

extract_init_script() {
  local previous=""
  local arg
  for arg in "$@"; do
    if [[ "$previous" == "--init-script" ]]; then
      printf '%s\n' "$arg"
      return 0
    fi
    previous="$arg"
  done
  printf '%s\n' ""
}

write_class_file() {
  local path="$1"
  local major="${2:-61}"
  python3 - <<'PY' "$path" "$major"
import sys

path = sys.argv[1]
major = int(sys.argv[2])

with open(path, "wb") as fh:
    fh.write(bytes.fromhex("cafebabe0000"))
    fh.write(major.to_bytes(2, byteorder="big"))
PY
}

has_jacoco="false"
if grep -Eq "id[[:space:]]*['\"]jacoco['\"]|apply[[:space:]]+plugin:[[:space:]]*['\"]jacoco['\"]|\\bjacoco[[:space:]]*\\{" build.gradle* 2>/dev/null; then
  has_jacoco="true"
fi

has_sonar="false"
if grep -Eq "org\\.sonarqube|\\bsonarqube\\b" build.gradle* settings.gradle* 2>/dev/null; then
  has_sonar="true"
fi

init_script="$(extract_init_script "$@")"
if [[ "${FAKE_REQUIRE_INIT_OUTSIDE_REPO:-false}" == "true" && -n "$init_script" && "$init_script" == "$PWD/"* ]]; then
  printf '%s\n' "init script should not be written inside the repo" >&2
  exit 97
fi

if has_arg build "$@" || has_arg assemble "$@" || has_arg classes "$@" || has_arg testClasses "$@" || has_arg compileJava "$@"; then
  mkdir -p build/classes/java/main
  write_class_file build/classes/java/main/App.class "${FAKE_CLASS_MAJOR:-61}"
  exit 0
fi

if has_arg sonar "$@"; then
  if [[ "$has_sonar" != "true" && -z "$init_script" ]]; then
    printf '%s\n' "missing init script for Sonar injection" >&2
    exit 99
  fi
  if [[ "${FAKE_REQUIRE_COVERAGE_REPORT_PATHS:-false}" == "true" && "$*" != *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
    printf '%s\n' "missing coverage report paths" >&2
    exit 100
  fi
  if [[ "${FAKE_FORBID_COVERAGE_REPORT_PATHS:-false}" == "true" && "$*" == *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
    printf '%s\n' "unexpected coverage report paths" >&2
    exit 101
  fi
  if [[ -n "${FAKE_GRADLE_SONAR_EXIT_CODE:-}" ]]; then
    exit "${FAKE_GRADLE_SONAR_EXIT_CODE}"
  fi
  mkdir -p build/sonar
  printf 'ceTaskId=%s\n' "${FAKE_SONAR_TASK_ID:-fake-task}" > build/sonar/report-task.txt
  exit 0
fi

if has_arg jacocoTestReport "$@" || has_arg test "$@"; then
  if [[ "$has_jacoco" != "true" && -z "$init_script" ]]; then
    printf '%s\n' "missing init script for JaCoCo injection" >&2
    exit 98
  fi
  if [[ -n "${FAKE_GRADLE_TEST_EXIT_CODE:-}" ]]; then
    exit "${FAKE_GRADLE_TEST_EXIT_CODE}"
  fi
  if [[ "${FAKE_GRADLE_COVERAGE_REPORT_MODE:-present}" != "missing" ]]; then
    mkdir -p build/reports/jacoco/test
    printf '%s\n' '<report name="fake"/>' > build/reports/jacoco/test/jacocoTestReport.xml
  fi
  exit 0
fi

exit 0
EOF
  chmod +x "${fake_bin}/gradle"

  cat > "${fake_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${*: -1}"

case "$url" in
  */api/system/status)
    printf '%s\n' '{"status":"UP"}'
    ;;
  */api/projects/search*)
    printf '%s\n' '{"paging":{"total":1}}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
EOF
  chmod +x "${fake_bin}/curl"
}

run_scan() {
  local data_dir="$1"
  local repo_path="$2"
  local project_key="$3"
  local fake_bin="$4"

  PATH="${fake_bin}:$PATH" \
  LIDSKJALV_SKIP_ENV_LOAD=true \
  SONAR_HOST_URL="https://sonar.example.test" \
  SONAR_TOKEN="token" \
  SONAR_ORGANIZATION="org" \
  LIDSKJALV_DATA_DIR="$data_dir" \
  WORK_DIR="" \
  LOG_DIR="" \
  STATE_FILE="" \
  ./scripts/scan-one.sh \
    --path "$repo_path" \
    --project-key "$project_key" \
    --project-name "$project_key" >/dev/null
}

pushd "$ROOT_DIR" >/dev/null

source "${ROOT_DIR}/scripts/lib/coverage.sh"

assert_eq "0.8.6" "$(coverage_select_jacoco_version 14)" "JaCoCo version mapping for Java 14 mismatch"
assert_eq "0.8.7" "$(coverage_select_jacoco_version 16)" "JaCoCo version mapping for Java 16 mismatch"
assert_eq "0.8.8" "$(coverage_select_jacoco_version 17)" "JaCoCo version mapping for Java 17 mismatch"
assert_eq "0.8.9" "$(coverage_select_jacoco_version 20)" "JaCoCo version mapping for Java 20 mismatch"
assert_eq "0.8.11" "$(coverage_select_jacoco_version 21)" "JaCoCo version mapping for Java 21 mismatch"
assert_eq "0.8.12" "$(coverage_select_jacoco_version 22)" "JaCoCo version mapping for Java 22 mismatch"
assert_eq "0.8.13" "$(coverage_select_jacoco_version 24)" "JaCoCo version mapping for Java 24 mismatch"
assert_eq "0.8.14" "$(coverage_select_jacoco_version 25)" "JaCoCo version mapping for Java 25 mismatch"

resolver_build_dir="${tmp}/resolver-build"
mkdir -p "${resolver_build_dir}/target/classes"
python3 - <<'PY' "${resolver_build_dir}/target/classes/App.class"
import sys

with open(sys.argv[1], "wb") as fh:
    fh.write(bytes.fromhex("cafebabe00000045"))
PY
assert_eq "25" "$(coverage_detect_java_target "$resolver_build_dir" "17" "21")" "class-file Java target detection should win over hints"

fake_bin="${tmp}/fake-bin"
make_fake_sonar_bin "$fake_bin"

maven_injected_repo="${tmp}/maven-injected"
cp -a "${ROOT_DIR}/tests/fixtures/maven_app/." "$maven_injected_repo/"
maven_injected_checksum="$(file_checksum "${maven_injected_repo}/pom.xml")"
maven_injected_log="${tmp}/maven-injected.log"
maven_injected_data="${tmp}/maven-injected-data"
FAKE_COMMAND_LOG="$maven_injected_log" \
FAKE_REQUIRE_MAVEN_COVERAGE_PROFILE="true" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
run_scan "$maven_injected_data" "$maven_injected_repo" "maven_injected" "$fake_bin"

assert_json_value "${maven_injected_data}/state/scan-state.json" '.repositories["maven_injected"].status' "success" "injected Maven scan should succeed"
assert_json_value "${maven_injected_data}/state/scan-state.json" '.repositories["maven_injected"].coverage_status' "available" "injected Maven scan should record available coverage"
assert_json_value "${maven_injected_data}/state/scan-state.json" '.repositories["maven_injected"].coverage_report_paths' "target/site/jacoco/jacoco.xml" "injected Maven coverage report path mismatch"
assert_eq "$maven_injected_checksum" "$(file_checksum "${maven_injected_repo}/pom.xml")" "local path Maven scan should not mutate pom.xml"
assert_contains "lidskjalv-coverage" "$(cat "$maven_injected_log")" "injected Maven run should activate the temporary coverage profile"

maven_existing_repo="${tmp}/maven-existing"
mkdir -p "${maven_existing_repo}/src/main/java/example"
cat > "${maven_existing_repo}/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>example</groupId>
  <artifactId>maven-existing-jacoco</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
  </properties>
  <build>
    <plugins>
      <plugin>
        <groupId>org.jacoco</groupId>
        <artifactId>jacoco-maven-plugin</artifactId>
        <version>0.8.8</version>
      </plugin>
    </plugins>
  </build>
</project>
EOF
cat > "${maven_existing_repo}/src/main/java/example/App.java" <<'EOF'
package example;

class App {}
EOF
maven_existing_log="${tmp}/maven-existing.log"
maven_existing_data="${tmp}/maven-existing-data"
FAKE_COMMAND_LOG="$maven_existing_log" \
FAKE_FORBID_INJECTED_PROFILE="true" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
run_scan "$maven_existing_data" "$maven_existing_repo" "maven_existing" "$fake_bin"

assert_json_value "${maven_existing_data}/state/scan-state.json" '.repositories["maven_existing"].coverage_status' "available" "existing Maven JaCoCo should be reused"
if grep -q "lidskjalv-coverage" "$maven_existing_log"; then
  test_fail "existing Maven JaCoCo configuration should not trigger injected coverage profile"
fi
assert_contains "org.sonarsource.scanner.maven:sonar-maven-plugin:3.11.0.3922:sonar" "$(cat "$maven_existing_log")" "Maven Sonar submission should pin the scanner version"

maven_existing_late_repo="${tmp}/maven-existing-late"
mkdir -p "${maven_existing_late_repo}/src/main/java/example"
cat > "${maven_existing_late_repo}/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>example</groupId>
  <artifactId>maven-existing-late-jacoco</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
  </properties>
  <build>
    <plugins>
      <plugin>
        <groupId>org.jacoco</groupId>
        <artifactId>jacoco-maven-plugin</artifactId>
        <version>0.8.8</version>
      </plugin>
    </plugins>
  </build>
</project>
EOF
cat > "${maven_existing_late_repo}/src/main/java/example/App.java" <<'EOF'
package example;

class App {}
EOF
maven_existing_late_log="${tmp}/maven-existing-late.log"
maven_existing_late_data="${tmp}/maven-existing-late-data"
FAKE_COMMAND_LOG="$maven_existing_late_log" \
FAKE_FORBID_INJECTED_PROFILE="true" \
FAKE_MAVEN_COVERAGE_REPORT_MODE="late" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
run_scan "$maven_existing_late_data" "$maven_existing_late_repo" "maven_existing_late" "$fake_bin"

assert_json_value "${maven_existing_late_data}/state/scan-state.json" '.repositories["maven_existing_late"].coverage_status' "available" "existing Maven JaCoCo should become available after submission prep"
assert_contains "mvn|" "$(cat "$maven_existing_late_log")" "late-report Maven scenario should log executed commands"
assert_contains "|install -Dmaven.repo.local=" "$(cat "$maven_existing_late_log")" "late-report Maven scenario should run install preparation before Sonar"

gradle_repo="${tmp}/gradle-coverage"
cp -a "${ROOT_DIR}/tests/fixtures/gradle_app/." "$gradle_repo/"
gradle_log="${tmp}/gradle.log"
gradle_data="${tmp}/gradle-data"
FAKE_COMMAND_LOG="$gradle_log" \
FAKE_REQUIRE_INIT_OUTSIDE_REPO="true" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
run_scan "$gradle_data" "$gradle_repo" "gradle_coverage" "$fake_bin"

assert_json_value "${gradle_data}/state/scan-state.json" '.repositories["gradle_coverage"].coverage_status' "available" "Gradle coverage scan should record available coverage"
assert_json_value "${gradle_data}/state/scan-state.json" '.repositories["gradle_coverage"].coverage_report_paths' "build/reports/jacoco/test/jacocoTestReport.xml" "Gradle coverage report path mismatch"
assert_not_exists "${gradle_repo}/sonar-init.gradle" "Gradle Sonar init script should not be written into the repository"
assert_not_exists "${gradle_repo}/jacoco-init.gradle" "Gradle JaCoCo init script should not be written into the repository"

popd >/dev/null
