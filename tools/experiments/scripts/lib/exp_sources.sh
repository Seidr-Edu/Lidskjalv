#!/usr/bin/env bash
# exp_sources.sh - source materialization and metadata capture.

set -euo pipefail

exp_materialize_original_repo() {
  if [[ "$SOURCE_TYPE" == "path" ]]; then
    ORIGINAL_REPO_PATH="$SOURCE_REF"
    [[ -d "$ORIGINAL_REPO_PATH" ]] || exp_fail "source path not found: $ORIGINAL_REPO_PATH"
  else
    ORIGINAL_REPO_PATH="${LIDSKJALV_DATA_DIR}/work/${ORIGINAL_SOURCE_KEY}"
    if [[ ! -d "$ORIGINAL_REPO_PATH/.git" ]]; then
      exp_log "Cloning original url source into ${ORIGINAL_REPO_PATH}"
      rm -rf "$ORIGINAL_REPO_PATH"
      git clone "$SOURCE_REF" "$ORIGINAL_REPO_PATH" >/dev/null 2>&1 || exp_fail "failed to clone source repo"
    fi
  fi

  ORIGINAL_EFFECTIVE_PATH="$ORIGINAL_REPO_PATH"
  if [[ -n "$SOURCE_SUBDIR" ]]; then
    ORIGINAL_EFFECTIVE_PATH="${ORIGINAL_REPO_PATH}/${SOURCE_SUBDIR}"
    [[ -d "$ORIGINAL_EFFECTIVE_PATH" ]] || exp_fail "--source-subdir not found: $SOURCE_SUBDIR"
  fi

  ORIGINAL_GIT_COMMIT=""
  ORIGINAL_GIT_BRANCH=""
  ORIGINAL_GIT_REMOTE=""
  if [[ -d "$ORIGINAL_REPO_PATH/.git" ]]; then
    ORIGINAL_GIT_COMMIT="$(git -C "$ORIGINAL_REPO_PATH" rev-parse HEAD 2>/dev/null || true)"
    ORIGINAL_GIT_BRANCH="$(git -C "$ORIGINAL_REPO_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    ORIGINAL_GIT_REMOTE="$(git -C "$ORIGINAL_REPO_PATH" remote get-url origin 2>/dev/null || true)"
  fi
}
