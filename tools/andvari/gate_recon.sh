#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "== gate_recon: starting =="
echo "Repo: $ROOT"

fail() {
  echo "== gate_recon: FAIL =="
  echo "$1" >&2
  exit 1
}

info() {
  echo "[gate] $1"
}

run_demo_with_optional_timeout() {
  local log_file="$1"
  if command -v timeout >/dev/null 2>&1; then
    timeout 60 ./run_demo.sh > "$log_file" 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 60 ./run_demo.sh > "$log_file" 2>&1
  else
    ./run_demo.sh > "$log_file" 2>&1
  fi
}

has_maven_pom_packaging() {
  local pom_path="$1"
  [[ -f "$pom_path" ]] || return 1
  grep -Eiq '<packaging>[[:space:]]*pom[[:space:]]*</packaging>' "$pom_path"
}

has_maven_modules() {
  local pom_path="$1"
  [[ -f "$pom_path" ]] || return 1
  grep -Eiq '<module>[[:space:]]*[^<[:space:]][^<]*</module>' "$pom_path"
}

cleanup_test_reports() {
  find . -type d \
    \( -path "*/target/surefire-reports" -o -path "*/target/failsafe-reports" -o -path "*/build/test-results" \) \
    -prune -exec rm -rf {} + 2>/dev/null || true
}

count_test_report_files() {
  # Counts JUnit XML reports from Maven surefire/failsafe and any Gradle
  # test-results subdir (covers standard 'test' as well as custom source sets
  # like 'jarFileTest', 'integrationTest', etc.).
  find . -type f \
    \( -path "*/target/surefire-reports/TEST-*.xml" \
       -o -path "*/target/failsafe-reports/TEST-*.xml" \
       -o -path "*/build/test-results/*/*.xml" \) \
    -print 2>/dev/null | wc -l | tr -d ' '
}

# Infer the Gradle test task to run. Returns 'test' for the standard layout;
# returns the custom source set name (e.g. 'jarFileTest') when the project
# uses a non-standard test source set instead of / in addition to src/test.
detect_gradle_test_task() {
  # Standard: src/test/java has Java files → default 'test' task
  if find src/test -name '*.java' -print -quit 2>/dev/null | grep -q .; then
    echo test
    return 0
  fi

  # Parse build.gradle / build.gradle.kts for source set declarations
  local custom=""
  for f in build.gradle build.gradle.kts; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      local name
      name="$(printf '%s' "$line" | grep -oE '^[[:space:]]+[A-Za-z][A-Za-z0-9_]+[[:space:]]*\{' \
             | grep -oE '[A-Za-z][A-Za-z0-9_]+' | head -1 || true)"
      if [[ -n "$name" && "$name" != main && "$name" != test && "$name" != java && "$name" != kotlin ]]; then
        if printf '%s' "$name" | grep -qiE '(test|spec|it$|integration|functional|e2e|acceptance|verification)'; then
          custom="$name"
          break
        fi
      fi
    done < "$f"
    [[ -n "$custom" ]] && break
  done

  [[ -n "$custom" ]] && { echo "$custom"; return 0; }

  # Fallback: first non-main/non-test src/ subdir containing Java files
  if [[ -d src ]]; then
    for d in src/*/; do
      [[ -d "$d" ]] || continue
      local name="${d%/}"; name="${name##*/}"
      [[ "$name" == main || "$name" == test ]] && continue
      if find "$d" -name '*.java' -print -quit 2>/dev/null | grep -q .; then
        echo "$name"
        return 0
      fi
    done
  fi

  echo test
}

# --- Required files ---
info "Checking required docs..."
[[ -f README.md ]] || fail "Missing README.md"
[[ -f docs/ASSUMPTIONS.md ]] || fail "Missing docs/ASSUMPTIONS.md"
[[ -f docs/ARCHITECTURE.md ]] || fail "Missing docs/ARCHITECTURE.md"
[[ -f docs/USAGE.md ]] || fail "Missing docs/USAGE.md"
[[ -f run_demo.sh ]] || fail "Missing run_demo.sh"
[[ -x run_demo.sh ]] || fail "run_demo.sh exists but is not executable"

info "Checking README demo instructions..."
rg -n "run_demo\\.sh" README.md >/dev/null 2>&1 || fail "README.md must document how to run ./run_demo.sh"

# --- No-stubs policy ---
info "Checking for forbidden stub markers..."
MARKER="TODO-""STUB:"
if rg -n --glob "!gate_recon.sh" "$MARKER" . >/dev/null 2>&1; then
  rg -n --glob "!gate_recon.sh" "$MARKER" . || true
  fail "Found ${MARKER} markers. Replace stubs with real implementations."
fi

# Optional: catch ultra-lazy stubs (tunable; keep conservative to avoid false positives)
# We only scan src/main (not tests, not build output).
if [[ -d src/main ]]; then
  info "Scanning src/main for obvious stub patterns (conservative)..."
  # This is intentionally light-touch: it flags the worst offenders.
  if rg -n --glob "src/main/**" \
      -e "return null;" \
      -e "throw new UnsupportedOperationException\\(" \
      -e "throw new NotImplementedError\\(" \
      . >/dev/null 2>&1; then
    rg -n --glob "src/main/**" \
      -e "return null;" \
      -e "throw new UnsupportedOperationException\\(" \
      -e "throw new NotImplementedError\\(" \
      . || true
    fail "Found obvious stub implementations in src/main (return null / UnsupportedOperationException / NotImplementedError). Implement properly or justify via real behavior."
  fi
fi

# --- Runnable entrypoint requirements ---
info "Checking for production main entrypoint..."
MAIN_COUNT=0
if [[ -d src/main/java ]]; then
  MAIN_COUNT="$(rg -n -g "*.java" \
    "public\\s+static\\s+void\\s+main\\s*\\(\\s*(final\\s+)?String(\\[\\]|\\.\\.\\.)\\s*[A-Za-z_][A-Za-z0-9_]*\\s*\\)" \
    src/main/java 2>/dev/null | wc -l | tr -d ' ')"
fi
[[ "$MAIN_COUNT" -ge 1 ]] || fail "No production main entrypoint found in src/main/java (expected public static void main(String[] args))."
info "Found $MAIN_COUNT production main entrypoint(s)."

# --- Detect build tool and run tests ---
info "Detecting build tool..."
USE_GRADLE="false"
USE_MAVEN="false"
HAS_GRADLE_FILES="false"
HAS_MAVEN_FILES="false"

if [[ -x ./gradlew ]]; then
  HAS_GRADLE_FILES="true"
elif [[ -f build.gradle || -f build.gradle.kts || -f settings.gradle || -f settings.gradle.kts ]]; then
  HAS_GRADLE_FILES="true"
fi

if [[ -f pom.xml ]]; then
  HAS_MAVEN_FILES="true"
fi

if [[ "$HAS_GRADLE_FILES" == "true" && "$HAS_MAVEN_FILES" == "true" ]]; then
  fail "Both Gradle and Maven build definitions detected. Choose exactly one build system."
fi

if [[ "$HAS_GRADLE_FILES" != "true" && "$HAS_MAVEN_FILES" != "true" ]]; then
  fail "No build system detected. Expected Gradle (with wrapper preferred) or Maven (pom.xml)."
fi

if [[ "$HAS_GRADLE_FILES" == "true" ]]; then
  [[ -x ./gradlew ]] || fail "Gradle build detected but executable ./gradlew is missing."
  USE_GRADLE="true"
fi

if [[ "$HAS_MAVEN_FILES" == "true" ]]; then
  USE_MAVEN="true"
fi

if [[ "$USE_MAVEN" == "true" ]] && has_maven_pom_packaging "pom.xml" && ! has_maven_modules "pom.xml" && find src/main/java -type f -name "*.java" -print -quit 2>/dev/null | grep -q .; then
  fail "Invalid Maven layout: pom.xml uses <packaging>pom</packaging> with no <modules>, but src/main/java contains sources. Use <packaging>jar</packaging> (or define modules)."
fi

# --- Minimal test presence sanity check ---
info "Checking tests exist..."
TEST_FILES_COUNT=0
# Search src/test and any non-main source set under src/ (e.g. src/jarFileTest)
for _test_dir in src/test src/*/; do
  [[ -d "$_test_dir" ]] || continue
  _name="${_test_dir%/}"; _name="${_name##*/}"
  [[ "$_name" == main ]] && continue
  _n="$(find "$_test_dir" -type f \( -name "*Test.java" -o -name "*Tests.java" \) 2>/dev/null | wc -l | tr -d ' ')"
  TEST_FILES_COUNT=$(( TEST_FILES_COUNT + _n ))
done
[[ -d test ]] && TEST_FILES_COUNT=$(( TEST_FILES_COUNT + $(find test -type f \( -name "*Test.java" -o -name "*Tests.java" \) 2>/dev/null | wc -l | tr -d ' ') ))
[[ -d tests ]] && TEST_FILES_COUNT=$(( TEST_FILES_COUNT + $(find tests -type f \( -name "*Test.java" -o -name "*Tests.java" \) 2>/dev/null | wc -l | tr -d ' ') ))

[[ "$TEST_FILES_COUNT" -ge 1 ]] || fail "No Java test files found (searched src/test, src/*/, test/, tests/)"
info "Found $TEST_FILES_COUNT test file(s)."

cleanup_test_reports

# --- Run tests ---
if [[ "$USE_GRADLE" == "true" ]]; then
  GRADLE_TEST_TASK="$(detect_gradle_test_task)"
  info "Running: ./gradlew $GRADLE_TEST_TASK"
  ./gradlew "$GRADLE_TEST_TASK"
  GRADLE_REPORT_COUNT="$(count_test_report_files)"
  [[ "$GRADLE_REPORT_COUNT" -ge 1 ]] || fail "Gradle '$GRADLE_TEST_TASK' task succeeded but produced no JUnit XML reports. Ensure the test source set is configured and tests are executed."
fi

if [[ "$USE_MAVEN" == "true" ]]; then
  command -v mvn >/dev/null 2>&1 || fail "Maven build detected but 'mvn' not found."
  info "Running: mvn -q test"
  mvn -q test
  MAVEN_REPORT_COUNT="$(count_test_report_files)"
  [[ "$MAVEN_REPORT_COUNT" -ge 1 ]] || fail "Maven test command succeeded but produced no Surefire/Failsafe XML reports. This usually indicates a no-op test phase."
fi

# --- Demo execution ---
info "Running demo smoke command: ./run_demo.sh"
DEMO_LOG="$(mktemp)"
set +e
run_demo_with_optional_timeout "$DEMO_LOG"
DEMO_STATUS=$?
set -e

cat "$DEMO_LOG"
rm -f "$DEMO_LOG"

[[ "$DEMO_STATUS" -eq 0 ]] || fail "Demo command failed (./run_demo.sh exit code: $DEMO_STATUS)."

echo "== gate_recon: PASS =="
