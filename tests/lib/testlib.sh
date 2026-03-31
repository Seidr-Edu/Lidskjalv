#!/usr/bin/env bash
set -euo pipefail

test_fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="${3:-values differ}"
  if [[ "$expected" != "$actual" ]]; then
    test_fail "${message}: expected '${expected}', got '${actual}'"
  fi
}

assert_file_exists() {
  local path="$1"
  local message="${2:-missing file}"
  [[ -f "$path" ]] || test_fail "${message}: ${path}"
}

assert_dir_exists() {
  local path="$1"
  local message="${2:-missing directory}"
  [[ -d "$path" ]] || test_fail "${message}: ${path}"
}

assert_not_exists() {
  local path="$1"
  local message="${2:-path should not exist}"
  [[ ! -e "$path" ]] || test_fail "${message}: ${path}"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="${3:-missing substring}"
  if [[ "$haystack" != *"$needle"* ]]; then
    test_fail "${message}: '${needle}'"
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local message="${3:-unexpected substring}"
  if [[ "$haystack" == *"$needle"* ]]; then
    test_fail "${message}: '${needle}'"
  fi
}

assert_json_value() {
  local file="$1"
  local jq_expr="$2"
  local expected="$3"
  local message="${4:-unexpected json value}"
  local actual
  actual="$(jq -r "$jq_expr" "$file")"
  assert_eq "$expected" "$actual" "$message"
}

assert_json_path_exists() {
  local file="$1"
  local jq_expr="$2"
  local message="${3:-missing json path}"
  if ! jq -e "$jq_expr" "$file" >/dev/null; then
    test_fail "${message}: ${jq_expr}"
  fi
}

file_checksum() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    printf 'missing\n'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    sha256sum "$path" | awk '{print $1}'
  fi
}

make_fake_build_bin() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"

  cat > "${fake_bin}/mvn" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"clean compile"* ]]; then
  mkdir -p target/classes
  : > target/classes/App.class
  exit 0
fi
case "$*" in
  *org.sonarsource.scanner.maven:sonar-maven-plugin:*:sonar*)
  mkdir -p .scannerwork
  printf 'ceTaskId=%s\n' "${FAKE_SONAR_TASK_ID:-fake-task}" > .scannerwork/report-task.txt
  exit 0
  ;;
esac
exit 0
EOF
  chmod +x "${fake_bin}/mvn"

  cat > "${fake_bin}/gradle" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/classes/java/main
: > build/classes/java/main/App.class
exit 0
EOF
  chmod +x "${fake_bin}/gradle"
}
