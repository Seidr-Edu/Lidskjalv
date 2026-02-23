#!/usr/bin/env bash
# runner_gates.sh - Gate execution and failure summarization
# Runs fixed and model acceptance gates, summarizes failures, and manages outcome locking

andvari_run_fixed_gate() {
  local label="$1"
  local run_time
  run_time="$(andvari_timestamp_utc)"

  echo "=== ${label} @ ${run_time} ===" >> "$GATE_LOG"

  set +e
  (
    cd "$NEW_REPO_DIR"
    ./gate_recon.sh
  ) > "$LAST_FIXED_GATE_OUTPUT" 2>&1
  local gate_status=$?
  set -e

  cat "$LAST_FIXED_GATE_OUTPUT" | tee -a "$GATE_LOG"
  echo >> "$GATE_LOG"

  return "$gate_status"
}

andvari_run_model_acceptance() {
  local label="$1"
  local run_time
  run_time="$(andvari_timestamp_utc)"

  echo "=== ${label}/hard @ ${run_time} ===" >> "$GATE_LOG"
  set +e
  (
    cd "$NEW_REPO_DIR"
    ./gate_hard.sh
  ) > "$LAST_HARD_GATE_OUTPUT" 2>&1
  local hard_status=$?
  set -e

  cat "$LAST_HARD_GATE_OUTPUT" | tee -a "$GATE_LOG"
  echo >> "$GATE_LOG"

  if [[ "$hard_status" -ne 0 ]]; then
    return 1
  fi

  echo "=== ${label}/model @ ${run_time} ===" >> "$GATE_LOG"
  set +e
  (
    cd "$NEW_REPO_DIR"
    ./scripts/verify_outcome_coverage.sh \
      --max-gate-revisions "$MAX_GATE_REVISIONS" \
      --model-gate-timeout-sec "$MODEL_GATE_TIMEOUT_SEC"
  ) > "$LAST_MODEL_VERIFY_OUTPUT" 2>&1
  local model_status=$?
  set -e

  cat "$LAST_MODEL_VERIFY_OUTPUT" | tee -a "$GATE_LOG"
  echo >> "$GATE_LOG"

  return "$model_status"
}

andvari_summarize_last_gate_failure() {
  tail -n 200 "$LAST_FIXED_GATE_OUTPUT" > "$GATE_SUMMARY_FILE"
}

andvari_summarize_model_gate_failure() {
  {
    echo "----- HARD GATE FAILURE (last ~200 lines) -----"
    tail -n 200 "$LAST_HARD_GATE_OUTPUT" || true
    echo "----- MODEL VERIFICATION FAILURE (last ~200 lines) -----"
    tail -n 200 "$LAST_MODEL_VERIFY_OUTPUT" || true
  } > "$GATE_SUMMARY_FILE"
}

andvari_lock_initial_outcomes() {
  local completion_dir="${NEW_REPO_DIR}/completion"
  local outcomes_file="${completion_dir}/outcomes.initial.json"
  local gates_file="${completion_dir}/gates.v1.json"
  local gate_runner_file="${completion_dir}/run_all_gates.sh"
  local locked_dir="${completion_dir}/locked"

  [[ -f "$outcomes_file" ]] || andvari_fail "Declaration phase did not create completion/outcomes.initial.json"
  [[ -f "$gates_file" ]] || andvari_fail "Declaration phase did not create completion/gates.v1.json"
  [[ -f "$gate_runner_file" ]] || andvari_fail "Declaration phase did not create completion/run_all_gates.sh"

  chmod +x "$gate_runner_file"
  mkdir -p "$locked_dir"
  cp "$outcomes_file" "${locked_dir}/outcomes.initial.json"
  cp "$gates_file" "${locked_dir}/gates.v1.json"
  printf '%s\n' "$(andvari_compute_sha256 "$outcomes_file")" > "${locked_dir}/outcomes.initial.sha256"
}

andvari_latest_gate_version() {
  local completion_dir="${NEW_REPO_DIR}/completion"
  local latest=0
  local file
  local base
  local version

  if [[ ! -d "$completion_dir" ]]; then
    echo "none"
    return
  fi

  shopt -s nullglob
  for file in "$completion_dir"/gates.v*.json; do
    base="$(basename "$file")"
    if [[ "$base" =~ ^gates\.v([0-9]+)\.json$ ]]; then
      version=$((10#${BASH_REMATCH[1]}))
      if (( version > latest )); then
        latest="$version"
      fi
    fi
  done
  shopt -u nullglob

  if (( latest == 0 )); then
    echo "none"
  else
    echo "v${latest}"
  fi
}
