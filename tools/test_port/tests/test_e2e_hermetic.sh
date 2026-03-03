#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FIXTURES_DIR="${SCRIPT_DIR}/fixtures"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/testlib.sh"

setup_fake_tools() {
  local root="$1"
  local fake_bin="${root}/bin"
  mkdir -p "$fake_bin"

  cat > "${fake_bin}/codex" <<'CODEX'
#!/usr/bin/env bash
set -euo pipefail

subcommand="${1:-}"
case "$subcommand" in
  login)
    if [[ "${2:-}" == "status" ]]; then
      exit 0
    fi
    ;;
  exec)
    shift
    output_last=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output-last-message)
          output_last="${2:-}"
          shift 2
          ;;
        --add-dir)
          shift 2
          ;;
        --json|--skip-git-repo-check|--full-auto|-)
          shift
          ;;
        *)
          shift
          ;;
      esac
    done

    if [[ -n "$output_last" ]]; then
      printf 'fake adapter message\n' > "$output_last"
    fi

    case "${TPT_CODEX_SCENARIO:-}" in
      ignored-writes)
        mkdir -p completion/proof/logs .mvn_repo/runtime src/test/java
        printf 'replayed\n' >> completion/proof/logs/hard-repo-compliance.log
        printf 'cache\n' > .mvn_repo/runtime/dependency.txt
        printf '// adapted\n' >> src/test/java/OriginalFixtureTest.java
        ;;
      prod-write)
        mkdir -p src/main/java
        printf '// disallowed\n' >> src/main/java/Prod.java
        ;;
      *)
        ;;
    esac

    printf '%s\n' '{"type":"response.output_text","text":"ok"}'
    exit 0
    ;;
esac

printf 'unsupported fake codex invocation\n' >&2
exit 1
CODEX

  cat > "${fake_bin}/mvn" <<'MVN'
#!/usr/bin/env bash
set -euo pipefail

repo_local=""
for arg in "$@"; do
  case "$arg" in
    -Dmaven.repo.local=*) repo_local="${arg#*=}" ;;
  esac
done

if [[ -z "$repo_local" ]]; then
  printf 'missing maven.repo.local\n' >&2
  exit 12
fi

mkdir -p "$repo_local" target/surefire-reports
printf 'downloaded\n' > "$repo_local/dependency.txt"
cat > target/surefire-reports/TEST-fake.xml <<'XML'
<testsuite tests="1" failures="0" errors="0"><testcase classname="fake" name="ok"/></testsuite>
XML
MVN

  chmod +x "${fake_bin}/codex" "${fake_bin}/mvn"

  export PATH="${fake_bin}:$PATH"
  export CODEX_HOME="${root}/codex-home"
  mkdir -p "${CODEX_HOME}/sessions"
}

prepare_fixture_repos() {
  local root="$1"
  local original_repo="${root}/original"
  local generated_repo="${root}/generated"

  cp -R "${FIXTURES_DIR}/original_repo" "$original_repo"
  cp -R "${FIXTURES_DIR}/generated_repo" "$generated_repo"

  printf '%s\t%s\n' "$original_repo" "$generated_repo"
}

run_test_port_case() {
  local scenario="$1"
  local root="$2"

  local original_repo generated_repo run_dir json_path
  IFS=$'\t' read -r original_repo generated_repo < <(prepare_fixture_repos "$root")
  run_dir="${root}/run"
  json_path="${run_dir}/outputs/test_port.json"

  export TPT_CODEX_SCENARIO="$scenario"

  "${REPO_ROOT}/test-port-run.sh" \
    --generated-repo "$generated_repo" \
    --original-repo "$original_repo" \
    --run-dir "$run_dir" \
    --max-iter 0 \
    > "${root}/test-port.log" 2>&1

  tpt_assert_file_exists "$json_path" "test-port json output must exist"

  printf '%s\t%s\n' "$json_path" "$run_dir"
}

case_ignored_runtime_writes_do_not_fail() {
  local tmp json_path run_dir
  tmp="$(tpt_mktemp_dir)"

  setup_fake_tools "$tmp"
  IFS=$'\t' read -r json_path run_dir < <(run_test_port_case "ignored-writes" "$tmp")

  python3 - <<'PY' "$json_path"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    obj = json.load(f)
if obj.get("status") != "passed":
    raise SystemExit(f"expected passed status, got {obj.get('status')}")
if obj.get("write_scope", {}).get("violation_count") != 0:
    raise SystemExit(f"expected zero violations, got {obj.get('write_scope', {}).get('violation_count')}")
ignored = obj.get("write_scope", {}).get("ignored_prefixes", [])
for expected in ("./completion/proof/logs/", "./.mvn_repo/"):
    if expected not in ignored:
        raise SystemExit(f"missing ignored prefix: {expected}")
PY

  tpt_assert_file_exists "${run_dir}/workspace/.m2/repository/dependency.txt" "maven local repo should be rooted in run workspace"
}

case_disallowed_source_write_fails() {
  local tmp json_path
  tmp="$(tpt_mktemp_dir)"

  setup_fake_tools "$tmp"
  IFS=$'\t' read -r json_path _ < <(run_test_port_case "prod-write" "$tmp")

  python3 - <<'PY' "$json_path"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    obj = json.load(f)
if obj.get("status") != "failed":
    raise SystemExit(f"expected failed status, got {obj.get('status')}")
if obj.get("reason") != "write-scope-violation":
    raise SystemExit(f"expected write-scope-violation reason, got {obj.get('reason')}")
violations = obj.get("write_scope", {}).get("violations", [])
paths = [item.get("path", "") for item in violations]
if "./src/main/java/Prod.java" not in paths:
    raise SystemExit(f"expected ./src/main/java/Prod.java violation, got {paths}")
PY
}

tpt_run_case "ignored runtime writes do not fail write-scope" case_ignored_runtime_writes_do_not_fail
tpt_run_case "disallowed source writes fail write-scope" case_disallowed_source_write_fails

tpt_finish_suite
