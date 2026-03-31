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

printf 'mvn|%s|%s|%s\n' "$PWD" "${JAVA_HOME:-}" "$*" >> "${FAKE_COMMAND_LOG:?}"

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

emit_xml_report() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '<report name="fake"/>' > "$path"
}

assert_expected_coverage_report_paths() {
  local args="$1"
  if [[ -n "${FAKE_EXPECT_COVERAGE_REPORT_PATHS:-}" && "$args" != *"-Dsonar.coverage.jacoco.xmlReportPaths=${FAKE_EXPECT_COVERAGE_REPORT_PATHS}"* ]]; then
    printf '%s\n' "coverage report paths mismatch" >&2
    exit 90
  fi
}

emit_maven_reports() {
  local goal="$1"
  local mode="${FAKE_MAVEN_COVERAGE_REPORT_MODE:-present}"

  case "$mode" in
    present)
      emit_xml_report target/site/jacoco/jacoco.xml
      ;;
    integration)
      if [[ "$goal" == "verify" ]]; then
        emit_xml_report target/site/jacoco/jacoco.xml
        emit_xml_report target/site/jacoco-it/jacoco.xml
      fi
      ;;
    aggregate)
      if [[ "$goal" == "verify" ]]; then
        emit_xml_report target/site/jacoco/jacoco.xml
        emit_xml_report target/site/jacoco-aggregate/jacoco.xml
      fi
      ;;
    late|missing)
      ;;
  esac
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

if has_arg test "$@" || has_arg verify "$@"; then
  goal="test"
  if has_arg verify "$@"; then
    goal="verify"
  fi
  if [[ -n "${FAKE_EXPECT_MAVEN_COVERAGE_GOAL:-}" && "$goal" != "${FAKE_EXPECT_MAVEN_COVERAGE_GOAL}" ]]; then
    printf '%s\n' "unexpected Maven coverage goal: $goal" >&2
    exit 91
  fi
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
  emit_maven_reports "$goal"
  exit 0
fi

if has_arg install "$@"; then
  if [[ -n "${FAKE_MAVEN_INSTALL_EXIT_CODE:-}" ]]; then
    exit "${FAKE_MAVEN_INSTALL_EXIT_CODE}"
  fi
  if [[ "${FAKE_MAVEN_COVERAGE_REPORT_MODE:-present}" == "late" ]]; then
    emit_xml_report target/site/jacoco/jacoco.xml
  fi
  exit 0
fi

if has_sonar_goal "$@"; then
  assert_expected_coverage_report_paths "$*"
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

printf 'gradle|%s|%s|%s\n' "$PWD" "${JAVA_HOME:-}" "$*" >> "${FAKE_COMMAND_LOG:?}"

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

emit_xml_report() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '<report name="fake"/>' > "$path"
}

assert_expected_coverage_report_paths() {
  local args="$1"
  if [[ -n "${FAKE_EXPECT_COVERAGE_REPORT_PATHS:-}" && "$args" != *"-Dsonar.coverage.jacoco.xmlReportPaths=${FAKE_EXPECT_COVERAGE_REPORT_PATHS}"* ]]; then
    printf '%s\n' "coverage report paths mismatch" >&2
    exit 102
  fi
}

emit_gradle_reports() {
  local mode="${FAKE_GRADLE_COVERAGE_REPORT_MODE:-present}"
  case "$mode" in
    present)
      emit_xml_report build/reports/jacoco/test/lidskjalvJacocoTestReport.xml
      ;;
    multi)
      emit_xml_report build/reports/jacoco/test/lidskjalvJacocoTestReport.xml
      emit_xml_report build/reports/jacoco/integrationTest/lidskjalvJacocoIntegrationTestReport.xml
      ;;
    aggregate)
      emit_xml_report build/reports/jacoco/test/lidskjalvJacocoTestReport.xml
      emit_xml_report build/reports/jacoco/testCodeCoverageReport/testCodeCoverageReport.xml
      ;;
    missing)
      ;;
  esac
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
  assert_expected_coverage_report_paths "$*"
  if [[ "${FAKE_REQUIRE_COVERAGE_REPORT_PATHS:-false}" == "true" && "$*" != *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
    printf '%s\n' "missing coverage report paths" >&2
    exit 100
  fi
  if [[ "${FAKE_FORBID_COVERAGE_REPORT_PATHS:-false}" == "true" && "$*" == *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
    printf '%s\n' "unexpected coverage report paths" >&2
    exit 101
  fi
  if [[ -n "${FAKE_GRADLE_NATIVE_SONAR_EXIT_CODE:-}" ]]; then
    exit "${FAKE_GRADLE_NATIVE_SONAR_EXIT_CODE}"
  fi
  mkdir -p build/sonar
  printf 'ceTaskId=%s\n' "${FAKE_SONAR_TASK_ID:-fake-task}" > build/sonar/report-task.txt
  exit 0
fi

if has_arg lidskjalvCoverage "$@" || has_arg jacocoTestReport "$@" || has_arg test "$@"; then
  if [[ "$has_jacoco" != "true" && -z "$init_script" ]]; then
    printf '%s\n' "missing init script for JaCoCo injection" >&2
    exit 98
  fi
  if [[ -n "${FAKE_GRADLE_TEST_EXIT_CODE:-}" ]]; then
    exit "${FAKE_GRADLE_TEST_EXIT_CODE}"
  fi
  emit_gradle_reports
  exit 0
fi

exit 0
EOF
  chmod +x "${fake_bin}/gradle"

  cat > "${fake_bin}/sonar-scanner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'sonar-scanner|%s|%s|%s\n' "$PWD" "${JAVA_HOME:-}" "$*" >> "${FAKE_COMMAND_LOG:?}"

project_base_dir="$PWD"
arg=""
for arg in "$@"; do
  case "$arg" in
    -Dsonar.projectBaseDir=*)
      project_base_dir="${arg#-Dsonar.projectBaseDir=}"
      ;;
  esac
done

if [[ "${FAKE_REQUIRE_COVERAGE_REPORT_PATHS:-false}" == "true" && "$*" != *"-Dsonar.coverage.jacoco.xmlReportPaths="* ]]; then
  printf '%s\n' "missing coverage report paths" >&2
  exit 102
fi
if [[ -n "${FAKE_EXPECT_COVERAGE_REPORT_PATHS:-}" && "$*" != *"-Dsonar.coverage.jacoco.xmlReportPaths=${FAKE_EXPECT_COVERAGE_REPORT_PATHS}"* ]]; then
  printf '%s\n' "coverage report paths mismatch" >&2
  exit 103
fi
if [[ -n "${FAKE_SONAR_SCANNER_EXIT_CODE:-}" ]]; then
  exit "${FAKE_SONAR_SCANNER_EXIT_CODE}"
fi

mkdir -p "${project_base_dir}/.scannerwork"
printf 'ceTaskId=%s\n' "${FAKE_SONAR_TASK_ID:-fake-task}" > "${project_base_dir}/.scannerwork/report-task.txt"
exit 0
EOF
  chmod +x "${fake_bin}/sonar-scanner"

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
source "${ROOT_DIR}/scripts/strategies/maven.sh"
source "${ROOT_DIR}/scripts/strategies/gradle.sh"

assert_eq "0.8.6" "$(coverage_select_jacoco_version 14)" "JaCoCo version mapping for Java 14 mismatch"
assert_eq "0.8.7" "$(coverage_select_jacoco_version 16)" "JaCoCo version mapping for Java 16 mismatch"
assert_eq "0.8.8" "$(coverage_select_jacoco_version 17)" "JaCoCo version mapping for Java 17 mismatch"
assert_eq "0.8.9" "$(coverage_select_jacoco_version 20)" "JaCoCo version mapping for Java 20 mismatch"
assert_eq "0.8.11" "$(coverage_select_jacoco_version 21)" "JaCoCo version mapping for Java 21 mismatch"
assert_eq "0.8.12" "$(coverage_select_jacoco_version 22)" "JaCoCo version mapping for Java 22 mismatch"
assert_eq "0.8.13" "$(coverage_select_jacoco_version 24)" "JaCoCo version mapping for Java 24 mismatch"
assert_eq "0.8.14" "$(coverage_select_jacoco_version 25)" "JaCoCo version mapping for Java 25 mismatch"

generated_gradle_init="${tmp}/jacoco-init.gradle"
gradle_write_jacoco_init_script "$generated_gradle_init" "0.8.8"
generated_gradle_init_contents="$(cat "$generated_gradle_init")"
assert_contains "gradle.projectsEvaluated {" "$generated_gradle_init_contents" "Gradle JaCoCo init script should defer report wiring until all projects are evaluated"
assert_contains "\"java-base\"" "$generated_gradle_init_contents" "Gradle JaCoCo init script should activate for java-base projects"
assert_contains "\"org.jetbrains.kotlin.jvm\"" "$generated_gradle_init_contents" "Gradle JaCoCo init script should activate for Kotlin/JVM projects"
assert_contains "CodeCoverageReport" "$generated_gradle_init_contents" "Gradle JaCoCo init script should recognize aggregate coverage task names"
assert_not_contains "project.tasks.withType(Test).configureEach { testTask ->" "$generated_gradle_init_contents" "Gradle JaCoCo init script should not register report tasks from inside configureEach"

maven_failsafe_plan="$(maven_analyze_coverage_plan "${ROOT_DIR}/tests/fixtures/maven_failsafe_app" "${ROOT_DIR}/tests/fixtures/maven_failsafe_app")"
assert_contains "repo_declares_jacoco=true" "$maven_failsafe_plan" "Maven coverage plan should detect repo-owned JaCoCo"
assert_contains "coverage_mode=verify" "$maven_failsafe_plan" "Maven coverage plan should choose verify when Failsafe/aggregate coverage is configured"

coverage_reset_metadata
selected_reports_file="${tmp}/selected-reports.txt"
coverage_select_preferred_reports \
  "/tmp/example/target/site/jacoco/jacoco.xml" \
  "/tmp/example/target/site/jacoco-aggregate/jacoco.xml" > "${selected_reports_file}"
selected_reports="$(cat "${selected_reports_file}")"
assert_eq "/tmp/example/target/site/jacoco-aggregate/jacoco.xml" "$selected_reports" "aggregate coverage reports should be preferred over per-module reports"
assert_eq "aggregate" "$COVERAGE_REPORT_KIND" "aggregate report selection should record aggregate report kind"

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
assert_json_value "${maven_injected_data}/state/scan-state.json" '.repositories["maven_injected"].coverage_mode' "maven_test" "unit-only Maven coverage should record test mode"
assert_json_value "${maven_injected_data}/state/scan-state.json" '.repositories["maven_injected"].coverage_command' "mvn test" "unit-only Maven coverage command mismatch"
assert_json_value "${maven_injected_data}/state/scan-state.json" '.repositories["maven_injected"].coverage_report_kind' "single_report" "unit-only Maven coverage report kind mismatch"
assert_json_value "${maven_injected_data}/state/scan-state.json" '.repositories["maven_injected"].scanner_mode' "native_maven" "injected Maven scan should use native Maven submission"
assert_json_value "${maven_injected_data}/state/scan-state.json" '.repositories["maven_injected"].coverage_report_paths' "target/site/jacoco/jacoco.xml" "injected Maven coverage report path mismatch"
assert_eq "$maven_injected_checksum" "$(file_checksum "${maven_injected_repo}/pom.xml")" "local path Maven scan should not mutate pom.xml"
assert_contains "lidskjalv-coverage" "$(cat "$maven_injected_log")" "injected Maven run should activate the temporary coverage profile"

maven_verify_injected_repo="${tmp}/maven-verify-injected"
cp -a "${ROOT_DIR}/tests/fixtures/maven_app/." "$maven_verify_injected_repo/"
mkdir -p "${maven_verify_injected_repo}/src/integrationTest/java/example"
cat > "${maven_verify_injected_repo}/src/integrationTest/java/example/AppIT.java" <<'EOF'
package example;

class AppIT {}
EOF
maven_verify_injected_log="${tmp}/maven-verify-injected.log"
maven_verify_injected_data="${tmp}/maven-verify-injected-data"
FAKE_COMMAND_LOG="$maven_verify_injected_log" \
FAKE_EXPECT_MAVEN_COVERAGE_GOAL="verify" \
FAKE_REQUIRE_MAVEN_COVERAGE_PROFILE="true" \
FAKE_MAVEN_COVERAGE_REPORT_MODE="integration" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
run_scan "$maven_verify_injected_data" "$maven_verify_injected_repo" "maven_verify_injected" "$fake_bin"

assert_json_value "${maven_verify_injected_data}/state/scan-state.json" '.repositories["maven_verify_injected"].coverage_mode' "maven_verify" "integration-aware Maven coverage should use verify mode"
assert_json_value "${maven_verify_injected_data}/state/scan-state.json" '.repositories["maven_verify_injected"].coverage_command' "mvn verify" "integration-aware Maven coverage command mismatch"
assert_json_value "${maven_verify_injected_data}/state/scan-state.json" '.repositories["maven_verify_injected"].coverage_report_kind' "multi_report" "integration-aware Maven coverage should keep both unit and integration reports"
assert_json_value "${maven_verify_injected_data}/state/scan-state.json" '.repositories["maven_verify_injected"].coverage_reports_found' "2" "integration-aware Maven coverage should record both reports"
assert_contains "|verify -Dmaven.repo.local=" "$(cat "$maven_verify_injected_log")" "integration-aware Maven coverage should run verify"
assert_contains "target/site/jacoco-it/jacoco.xml" "$(jq -r '.repositories["maven_verify_injected"].coverage_report_paths' "${maven_verify_injected_data}/state/scan-state.json")" "integration-aware Maven coverage should include integration reports"

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
assert_json_value "${maven_existing_data}/state/scan-state.json" '.repositories["maven_existing"].coverage_mode' "maven_test" "existing unit-only Maven JaCoCo should keep test mode"
if grep -q "lidskjalv-coverage" "$maven_existing_log"; then
  test_fail "existing Maven JaCoCo configuration should not trigger injected coverage profile"
fi
assert_contains "org.sonarsource.scanner.maven:sonar-maven-plugin:5.5.0.6356:sonar" "$(cat "$maven_existing_log")" "Maven Sonar submission should pin the scanner version"
assert_json_value "${maven_existing_data}/state/scan-state.json" '.repositories["maven_existing"].scanner_version' "5.5.0.6356" "Maven scanner version metadata mismatch"

maven_failsafe_repo="${tmp}/maven-failsafe"
cp -a "${ROOT_DIR}/tests/fixtures/maven_failsafe_app/." "$maven_failsafe_repo/"
maven_failsafe_log="${tmp}/maven-failsafe.log"
maven_failsafe_data="${tmp}/maven-failsafe-data"
FAKE_COMMAND_LOG="$maven_failsafe_log" \
FAKE_EXPECT_MAVEN_COVERAGE_GOAL="verify" \
FAKE_FORBID_INJECTED_PROFILE="true" \
FAKE_MAVEN_COVERAGE_REPORT_MODE="aggregate" \
FAKE_EXPECT_COVERAGE_REPORT_PATHS="target/site/jacoco-aggregate/jacoco.xml" \
run_scan "$maven_failsafe_data" "$maven_failsafe_repo" "maven_failsafe" "$fake_bin"

assert_json_value "${maven_failsafe_data}/state/scan-state.json" '.repositories["maven_failsafe"].coverage_mode' "maven_verify" "Failsafe Maven coverage should use verify mode"
assert_json_value "${maven_failsafe_data}/state/scan-state.json" '.repositories["maven_failsafe"].coverage_report_kind' "aggregate" "aggregate Maven coverage should record aggregate report kind"
assert_json_value "${maven_failsafe_data}/state/scan-state.json" '.repositories["maven_failsafe"].coverage_report_paths' "target/site/jacoco-aggregate/jacoco.xml" "aggregate Maven coverage should submit only aggregate reports"

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

legacy_maven_repo="${tmp}/maven-legacy-runtime"
mkdir -p "${legacy_maven_repo}/src/main/java/example"
cat > "${legacy_maven_repo}/pom.xml" <<'EOF'
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>example</groupId>
  <artifactId>maven-legacy-runtime</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.source>1.8</maven.compiler.source>
    <maven.compiler.target>1.8</maven.compiler.target>
  </properties>
</project>
EOF
cat > "${legacy_maven_repo}/src/main/java/example/App.java" <<'EOF'
package example;

class App {}
EOF
legacy_maven_log="${tmp}/maven-legacy-runtime.log"
legacy_maven_data="${tmp}/maven-legacy-runtime-data"
FAKE_COMMAND_LOG="$legacy_maven_log" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
run_scan "$legacy_maven_data" "$legacy_maven_repo" "maven_legacy_runtime" "$fake_bin"

assert_json_value "${legacy_maven_data}/state/scan-state.json" '.repositories["maven_legacy_runtime"].jdk_version' "11" "legacy Maven build should prefer JDK 11"
assert_json_value "${legacy_maven_data}/state/scan-state.json" '.repositories["maven_legacy_runtime"].coverage_jdk' "11" "coverage should stay on the build JDK"
assert_json_value "${legacy_maven_data}/state/scan-state.json" '.repositories["maven_legacy_runtime"].coverage_mode' "maven_test" "legacy Maven coverage should remain in test mode"
assert_json_value "${legacy_maven_data}/state/scan-state.json" '.repositories["maven_legacy_runtime"].scanner_mode' "native_maven" "legacy Maven scan should still use the native Maven scanner"
assert_json_value "${legacy_maven_data}/state/scan-state.json" '.repositories["maven_legacy_runtime"].scanner_jdk' "21" "legacy Maven scan should switch to the dedicated scanner JDK"
assert_json_value "${legacy_maven_data}/state/scan-state.json" '.repositories["maven_legacy_runtime"].coverage_tests_forced' "true" "Maven coverage should force tests back on"

gradle_repo="${tmp}/gradle-multi-suite"
cp -a "${ROOT_DIR}/tests/fixtures/gradle_multi_suite/." "$gradle_repo/"
gradle_log="${tmp}/gradle.log"
gradle_data="${tmp}/gradle-data"
FAKE_COMMAND_LOG="$gradle_log" \
FAKE_REQUIRE_INIT_OUTSIDE_REPO="true" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
FAKE_GRADLE_COVERAGE_REPORT_MODE="multi" \
run_scan "$gradle_data" "$gradle_repo" "gradle_coverage" "$fake_bin"

assert_json_value "${gradle_data}/state/scan-state.json" '.repositories["gradle_coverage"].coverage_status' "available" "Gradle coverage scan should record available coverage"
assert_json_value "${gradle_data}/state/scan-state.json" '.repositories["gradle_coverage"].coverage_mode' "gradle_jvm_tasks" "Gradle coverage should record JVM task mode"
assert_json_value "${gradle_data}/state/scan-state.json" '.repositories["gradle_coverage"].coverage_command' "gradle lidskjalvCoverage" "Gradle coverage command mismatch"
assert_json_value "${gradle_data}/state/scan-state.json" '.repositories["gradle_coverage"].coverage_report_kind' "multi_report" "Gradle multi-task coverage should record multi-report kind"
assert_json_value "${gradle_data}/state/scan-state.json" '.repositories["gradle_coverage"].coverage_reports_found' "2" "Gradle multi-task coverage should record both reports"
assert_contains "build/reports/jacoco/integrationTest/lidskjalvJacocoIntegrationTestReport.xml" "$(jq -r '.repositories["gradle_coverage"].coverage_report_paths' "${gradle_data}/state/scan-state.json")" "Gradle multi-task coverage should include integration-test reports"
assert_json_value "${gradle_data}/state/scan-state.json" '.repositories["gradle_coverage"].scanner_mode' "native_gradle" "Gradle scan should use the native Gradle scanner when it succeeds"
assert_not_exists "${gradle_repo}/sonar-init.gradle" "Gradle Sonar init script should not be written into the repository"
assert_not_exists "${gradle_repo}/jacoco-init.gradle" "Gradle JaCoCo init script should not be written into the repository"

gradle_aggregate_repo="${tmp}/gradle-aggregate"
cp -a "${ROOT_DIR}/tests/fixtures/gradle_multi_suite/." "$gradle_aggregate_repo/"
gradle_aggregate_data="${tmp}/gradle-aggregate-data"
gradle_aggregate_log="${tmp}/gradle-aggregate.log"
FAKE_COMMAND_LOG="$gradle_aggregate_log" \
FAKE_REQUIRE_INIT_OUTSIDE_REPO="true" \
FAKE_GRADLE_COVERAGE_REPORT_MODE="aggregate" \
FAKE_EXPECT_COVERAGE_REPORT_PATHS="build/reports/jacoco/testCodeCoverageReport/testCodeCoverageReport.xml" \
run_scan "$gradle_aggregate_data" "$gradle_aggregate_repo" "gradle_aggregate" "$fake_bin"

assert_json_value "${gradle_aggregate_data}/state/scan-state.json" '.repositories["gradle_aggregate"].coverage_report_kind' "aggregate" "Gradle aggregate coverage should prefer aggregate reports"
assert_json_value "${gradle_aggregate_data}/state/scan-state.json" '.repositories["gradle_aggregate"].coverage_report_paths' "build/reports/jacoco/testCodeCoverageReport/testCodeCoverageReport.xml" "Gradle aggregate coverage should submit only aggregate reports"

gradle_kotlin_repo="${tmp}/gradle-kotlin"
cp -a "${ROOT_DIR}/tests/fixtures/gradle_kotlin_app/." "$gradle_kotlin_repo/"
gradle_kotlin_data="${tmp}/gradle-kotlin-data"
gradle_kotlin_log="${tmp}/gradle-kotlin.log"
FAKE_COMMAND_LOG="$gradle_kotlin_log" \
FAKE_REQUIRE_INIT_OUTSIDE_REPO="true" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
run_scan "$gradle_kotlin_data" "$gradle_kotlin_repo" "gradle_kotlin" "$fake_bin"

assert_json_value "${gradle_kotlin_data}/state/scan-state.json" '.repositories["gradle_kotlin"].status' "success" "Gradle Kotlin/JVM coverage scan should succeed"
assert_json_value "${gradle_kotlin_data}/state/scan-state.json" '.repositories["gradle_kotlin"].coverage_mode' "gradle_jvm_tasks" "Gradle Kotlin/JVM coverage should not be gated on the plain java plugin"

gradle_cli_repo="${tmp}/gradle-cli-fallback"
cp -a "${ROOT_DIR}/tests/fixtures/gradle_app/." "$gradle_cli_repo/"
gradle_cli_log="${tmp}/gradle-cli.log"
gradle_cli_data="${tmp}/gradle-cli-data"
FAKE_COMMAND_LOG="$gradle_cli_log" \
FAKE_REQUIRE_INIT_OUTSIDE_REPO="true" \
FAKE_REQUIRE_COVERAGE_REPORT_PATHS="true" \
FAKE_GRADLE_NATIVE_SONAR_EXIT_CODE="42" \
run_scan "$gradle_cli_data" "$gradle_cli_repo" "gradle_cli_fallback" "$fake_bin"

assert_json_value "${gradle_cli_data}/state/scan-state.json" '.repositories["gradle_cli_fallback"].status' "success" "Gradle CLI fallback scan should still succeed"
assert_json_value "${gradle_cli_data}/state/scan-state.json" '.repositories["gradle_cli_fallback"].scanner_mode' "cli_fallback" "Gradle fallback should record CLI submission mode"
assert_json_value "${gradle_cli_data}/state/scan-state.json" '.repositories["gradle_cli_fallback"].fallback_chain' "native_gradle,cli_fallback" "Gradle fallback chain mismatch"
assert_contains "sonar-scanner|" "$(cat "$gradle_cli_log")" "Gradle fallback should invoke sonar-scanner"

popd >/dev/null
