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

# --- Run tests ---
if [[ "$USE_GRADLE" == "true" ]]; then
  info "Running: ./gradlew test"
  ./gradlew test
fi

if [[ "$USE_MAVEN" == "true" ]]; then
  command -v mvn >/dev/null 2>&1 || fail "Maven build detected but 'mvn' not found."
  info "Running: mvn -q test"
  mvn -q test
fi

# --- Minimal test presence sanity check ---
info "Checking tests exist..."
TEST_FILES_COUNT=0
if [[ -d src/test ]]; then
  TEST_FILES_COUNT="$(find src/test -type f \( -name "*Test.java" -o -name "*Tests.java" \) 2>/dev/null | wc -l | tr -d ' ')"
fi

# If project uses nonstandard test layout, at least require *some* test directory.
if [[ "$TEST_FILES_COUNT" -lt 1 ]]; then
  # Try Maven default layout as well
  if [[ -d src/test/java ]]; then
    TEST_FILES_COUNT="$(find src/test/java -type f -name "*Test.java" 2>/dev/null | wc -l | tr -d ' ')"
  fi
fi

[[ "$TEST_FILES_COUNT" -ge 1 ]] || fail "No test files found (expected at least one *Test.java under src/test)."

info "Found $TEST_FILES_COUNT test file(s)."

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
