#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MAX_GATE_REVISIONS="3"
MODEL_GATE_TIMEOUT_SEC="120"

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/verify_outcome_coverage.sh [--max-gate-revisions N] [--model-gate-timeout-sec N]

Options:
  --max-gate-revisions      Maximum revisions allowed after gates.v1 (default: 3)
  --model-gate-timeout-sec  Timeout for completion/run_all_gates.sh replay (default: 120)
USAGE
}

fail() {
  echo "== verify_outcome_coverage: FAIL =="
  echo "$1" >&2
  exit 1
}

info() {
  echo "[verify_outcome_coverage] $1"
}

compute_sha256() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi

  fail "Neither sha256sum nor shasum is available"
}

run_gate_with_optional_timeout() {
  local log_file="$1"

  if command -v timeout >/dev/null 2>&1; then
    timeout "$MODEL_GATE_TIMEOUT_SEC" ./completion/run_all_gates.sh > "$log_file" 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$MODEL_GATE_TIMEOUT_SEC" ./completion/run_all_gates.sh > "$log_file" 2>&1
  else
    ./completion/run_all_gates.sh > "$log_file" 2>&1
  fi
}

latest_gate_version() {
  local latest=0
  local file
  local base
  local version

  shopt -s nullglob
  for file in completion/gates.v*.json; do
    base="$(basename "$file")"
    if [[ "$base" =~ ^gates\.v([0-9]+)\.json$ ]]; then
      version=$((10#${BASH_REMATCH[1]}))
      if (( version > latest )); then
        latest="$version"
      fi
    fi
  done
  shopt -u nullglob

  echo "$latest"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-gate-revisions)
      [[ $# -ge 2 ]] || fail "--max-gate-revisions requires a value"
      MAX_GATE_REVISIONS="$2"
      shift 2
      ;;
    --model-gate-timeout-sec)
      [[ $# -ge 2 ]] || fail "--model-gate-timeout-sec requires a value"
      MODEL_GATE_TIMEOUT_SEC="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ "$MAX_GATE_REVISIONS" =~ ^[0-9]+$ ]] || fail "--max-gate-revisions must be a non-negative integer"
[[ "$MODEL_GATE_TIMEOUT_SEC" =~ ^[0-9]+$ ]] || fail "--model-gate-timeout-sec must be a non-negative integer"
MAX_GATE_REVISIONS=$((10#$MAX_GATE_REVISIONS))
MODEL_GATE_TIMEOUT_SEC=$((10#$MODEL_GATE_TIMEOUT_SEC))

OUTCOMES_FILE="completion/outcomes.initial.json"
LOCKED_HASH_FILE="completion/locked/outcomes.initial.sha256"
RUN_ALL_GATES_FILE="completion/run_all_gates.sh"

[[ -f "$OUTCOMES_FILE" ]] || fail "Missing completion/outcomes.initial.json"
[[ -f "$LOCKED_HASH_FILE" ]] || fail "Missing completion/locked/outcomes.initial.sha256"
[[ -f "$RUN_ALL_GATES_FILE" ]] || fail "Missing completion/run_all_gates.sh"
[[ -x "$RUN_ALL_GATES_FILE" ]] || fail "completion/run_all_gates.sh is not executable"

LOCKED_HASH="$(tr -d '[:space:]' < "$LOCKED_HASH_FILE")"
CURRENT_HASH="$(compute_sha256 "$OUTCOMES_FILE")"
[[ "$LOCKED_HASH" == "$CURRENT_HASH" ]] || fail "completion/outcomes.initial.json changed after lock"

LATEST_GATE_VERSION="$(latest_gate_version)"
[[ "$LATEST_GATE_VERSION" -ge 1 ]] || fail "No completion/gates.vN.json files found"

MAX_ALLOWED_GATE_VERSION=$((MAX_GATE_REVISIONS + 1))
if (( LATEST_GATE_VERSION > MAX_ALLOWED_GATE_VERSION )); then
  fail "Latest gate version v${LATEST_GATE_VERSION} exceeds allowed max v${MAX_ALLOWED_GATE_VERSION}"
fi

LATEST_GATE_FILE="completion/gates.v${LATEST_GATE_VERSION}.json"
RESULTS_FILE="completion/proof/results.v${LATEST_GATE_VERSION}.json"
[[ -f "$LATEST_GATE_FILE" ]] || fail "Missing ${LATEST_GATE_FILE}"

mkdir -p completion/proof/logs
REPLAY_LOG="completion/proof/logs/runner_replay.log"

# Force proof regeneration on each replay so stale artifacts cannot be reused.
rm -f "$RESULTS_FILE"
find completion/proof/logs -mindepth 1 -maxdepth 1 -type f -name "*.log" -delete

info "Replaying model gates via completion/run_all_gates.sh"
set +e
run_gate_with_optional_timeout "$REPLAY_LOG"
REPLAY_STATUS=$?
set -e
cat "$REPLAY_LOG"
[[ "$REPLAY_STATUS" -eq 0 ]] || fail "completion/run_all_gates.sh failed with exit code ${REPLAY_STATUS}"

[[ -f "$RESULTS_FILE" ]] || fail "Missing ${RESULTS_FILE}"
[[ -s "$RESULTS_FILE" ]] || fail "Empty ${RESULTS_FILE}"

perl - "$OUTCOMES_FILE" "$LATEST_GATE_FILE" "$RESULTS_FILE" "$ROOT" <<'PERL_EOF'
use strict;
use warnings;
use JSON::PP qw(decode_json);

my ($outcomes_path, $gates_path, $results_path, $repo_root) = @ARGV;

sub fail_with {
  my ($msg) = @_;
  print STDERR "== verify_outcome_coverage: FAIL ==\n";
  die "$msg\n";
}

sub slurp {
  my ($path) = @_;
  open my $fh, '<', $path or fail_with("cannot open $path: $!");
  local $/;
  my $content = <$fh>;
  close $fh;
  return $content;
}

my $outcomes = eval { decode_json(slurp($outcomes_path)) };
fail_with("invalid JSON in $outcomes_path: $@") if $@;
fail_with("$outcomes_path must be a non-empty JSON array") if ref($outcomes) ne 'ARRAY' || scalar(@$outcomes) < 1;

my %outcome_priority;
for my $item (@$outcomes) {
  fail_with("each outcome entry must be an object") if ref($item) ne 'HASH';

  my $id = $item->{id} // '';
  $id =~ s/^\s+|\s+$//g;
  fail_with("outcome id is missing") if $id eq '';
  fail_with("duplicate outcome id '$id'") if exists $outcome_priority{$id};

  my $priority = $item->{priority} // '';
  fail_with("outcome '$id' has invalid priority '$priority' (expected core|non-core)")
    if $priority ne 'core' && $priority ne 'non-core';

  $outcome_priority{$id} = $priority;
}

my $gates = eval { decode_json(slurp($gates_path)) };
fail_with("invalid JSON in $gates_path: $@") if $@;
fail_with("$gates_path must be a non-empty JSON array") if ref($gates) ne 'ARRAY' || scalar(@$gates) < 1;

my %gate_outcome_ids;
my %outcome_gate_count;
for my $gate (@$gates) {
  fail_with("each gate entry must be an object") if ref($gate) ne 'HASH';

  my $gate_id = $gate->{id} // '';
  $gate_id =~ s/^\s+|\s+$//g;
  fail_with("gate id is missing") if $gate_id eq '';
  fail_with("duplicate gate id '$gate_id' in $gates_path") if exists $gate_outcome_ids{$gate_id};

  my $command = $gate->{command} // '';
  $command =~ s/^\s+|\s+$//g;
  fail_with("gate '$gate_id' has empty command") if $command eq '';

  my $outcome_ids = $gate->{outcome_ids};
  fail_with("gate '$gate_id' must include non-empty outcome_ids array")
    if ref($outcome_ids) ne 'ARRAY' || scalar(@$outcome_ids) < 1;

  my %seen_gate_outcomes;
  my @resolved_outcomes;
  for my $outcome_id (@$outcome_ids) {
    fail_with("gate '$gate_id' has non-string outcome id") if ref($outcome_id);
    $outcome_id =~ s/^\s+|\s+$//g;
    fail_with("gate '$gate_id' has empty outcome id") if $outcome_id eq '';
    fail_with("gate '$gate_id' references unknown outcome '$outcome_id'")
      if !exists $outcome_priority{$outcome_id};
    next if $seen_gate_outcomes{$outcome_id};

    $seen_gate_outcomes{$outcome_id} = 1;
    push @resolved_outcomes, $outcome_id;
    $outcome_gate_count{$outcome_id} = ($outcome_gate_count{$outcome_id} // 0) + 1;
  }

  fail_with("gate '$gate_id' did not resolve any unique outcome ids") if scalar(@resolved_outcomes) < 1;
  $gate_outcome_ids{$gate_id} = \@resolved_outcomes;
}

for my $outcome_id (keys %outcome_priority) {
  fail_with("outcome '$outcome_id' is not covered by the latest gate set")
    if !exists $outcome_gate_count{$outcome_id};
}

my $results = eval { decode_json(slurp($results_path)) };
fail_with("invalid JSON in $results_path: $@") if $@;
fail_with("$results_path must be a non-empty JSON array") if ref($results) ne 'ARRAY' || scalar(@$results) < 1;

my %result_by_gate;
for my $result (@$results) {
  fail_with("each result entry must be an object") if ref($result) ne 'HASH';

  my $gate_id = $result->{gate_id} // '';
  $gate_id =~ s/^\s+|\s+$//g;
  fail_with("result has missing gate_id") if $gate_id eq '';
  fail_with("duplicate result entry for gate '$gate_id'") if exists $result_by_gate{$gate_id};

  $result_by_gate{$gate_id} = $result;
}

for my $gate_id (keys %gate_outcome_ids) {
  my $result = $result_by_gate{$gate_id};
  fail_with("missing result for gate '$gate_id' in $results_path") if !defined $result;

  my $status = lc($result->{status} // '');
  fail_with("gate '$gate_id' did not pass (status='$status')") if $status ne 'pass';

  my $exit_code = $result->{exit_code};
  fail_with("gate '$gate_id' missing numeric exit_code") if !defined $exit_code || $exit_code !~ /^-?\d+$/;
  fail_with("gate '$gate_id' exit_code must be 0 (found $exit_code)") if $exit_code != 0;

  my $log_path = $result->{log_path} // '';
  $log_path =~ s/^\s+|\s+$//g;
  fail_with("gate '$gate_id' missing log_path") if $log_path eq '';

  my $resolved_log_path = $log_path =~ m{^/} ? $log_path : "$repo_root/$log_path";
  fail_with("gate '$gate_id' log file missing or empty: $log_path") if !-s $resolved_log_path;
}

for my $outcome_id (keys %outcome_priority) {
  next if $outcome_priority{$outcome_id} ne 'core';

  my $has_passing_gate = 0;
  for my $gate_id (keys %gate_outcome_ids) {
    my $mapped_outcomes = $gate_outcome_ids{$gate_id};
    next if !grep { $_ eq $outcome_id } @$mapped_outcomes;

    my $result = $result_by_gate{$gate_id};
    my $status = lc($result->{status} // '');
    my $exit_code = $result->{exit_code};
    if ($status eq 'pass' && defined $exit_code && $exit_code =~ /^-?\d+$/ && $exit_code == 0) {
      $has_passing_gate = 1;
      last;
    }
  }

  fail_with("core outcome '$outcome_id' has no passing gate") if !$has_passing_gate;
}

my $outcome_total = scalar(keys %outcome_priority);
my $covered_total = scalar(keys %outcome_gate_count);
fail_with("outcome coverage incomplete ($covered_total/$outcome_total)") if $covered_total != $outcome_total;

my $core_total = scalar(grep { $outcome_priority{$_} eq 'core' } keys %outcome_priority);
my $gate_total = scalar(keys %gate_outcome_ids);
print "[verify_outcome_coverage] summary: outcomes=$outcome_total core=$core_total gates=$gate_total\n";
PERL_EOF

echo "== verify_outcome_coverage: PASS =="
