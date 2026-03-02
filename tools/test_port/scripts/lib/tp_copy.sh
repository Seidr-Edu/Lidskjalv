#!/usr/bin/env bash
# tp_copy.sh - workspace copy/snapshot helpers.

set -euo pipefail

tp_prepare_workspace_copies() {
  mkdir -p "$TP_WORKSPACE_DIR" "$TP_LOG_DIR" "$TP_SUMMARY_DIR" "$TP_GUARDS_DIR" "$TP_OUTPUT_DIR"

  tp_copy_dir "$TP_ORIGINAL_EFFECTIVE_PATH" "$TP_ORIGINAL_BASELINE_REPO"
  tp_copy_dir "$TP_GENERATED_REPO" "$TP_GENERATED_BASELINE_REPO"
  tp_copy_dir "$TP_GENERATED_REPO" "$TP_PORTED_REPO"

  TP_GENERATED_REPO_BEFORE_HASH="$(tp_tree_fingerprint "$TP_GENERATED_REPO")"
  printf '%s\n' "$TP_GENERATED_REPO_BEFORE_HASH" > "$TP_GENERATED_BEFORE_HASH_PATH"
}

tp_snapshot_original_tests() {
  mkdir -p "$TP_ORIGINAL_TESTS_SNAPSHOT"
  if ! rsync -a --prune-empty-dirs \
    --include='*/' \
    --include='src/test/***' \
    --include='src/*Test*/***' \
    --include='test/***' \
    --include='tests/***' \
    --exclude='*' \
    "$TP_ORIGINAL_EFFECTIVE_PATH/" "$TP_ORIGINAL_TESTS_SNAPSHOT/" >/dev/null 2>&1; then
    return 1
  fi
  find "$TP_ORIGINAL_TESTS_SNAPSHOT" -type f -print -quit | grep -q .
}

tp_seed_ported_repo_with_original_tests() {
  find "$TP_PORTED_REPO" -type d \
    \( -path '*/src/test' -o -path '*/test' -o -path '*/tests' -o -path '*/src/*Test*' \) \
    -prune -exec rm -rf {} + 2>/dev/null || true

  rsync -a "$TP_ORIGINAL_TESTS_SNAPSHOT/" "$TP_PORTED_REPO/" >/dev/null 2>&1
}
