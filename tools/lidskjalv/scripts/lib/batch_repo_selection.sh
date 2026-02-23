#!/usr/bin/env bash
# batch_repo_selection.sh - Repository input collection and dry-run planning
# Handles loading repos from file or single-repo flag and formatting dry-run output

batch_collect_repos() {
  BATCH_REPOS_TO_PROCESS=()

  if [[ -n "$SINGLE_REPO" ]]; then
    local parsed_source
    parsed_source="$(parse_repo_source "$SINGLE_REPO" 2>/dev/null || true)"
    if [[ -z "$parsed_source" ]]; then
      log_error "Invalid --repo value: $SINGLE_REPO"
      log_error "Use URL, url:<...>, or path:<...>"
      exit 1
    fi
    local source_type source_ref
    IFS='|' read -r source_type source_ref <<< "$parsed_source"
    BATCH_REPOS_TO_PROCESS+=("${source_type}|${source_ref}||||")
    return
  fi

  if [[ ! -f "$REPOS_FILE" ]]; then
    log_error "Repos file not found: $REPOS_FILE"
    exit 1
  fi

  while IFS= read -r line; do
    BATCH_REPOS_TO_PROCESS+=("$line")
  done < <(parse_repos_file "$REPOS_FILE")
}

batch_print_dry_run_plan() {
  log_info "DRY RUN - Would process:"
  local entry source_type source_ref jdk subdir key_override name_override
  local normalized_ref key display_name status

  for entry in "${BATCH_REPOS_TO_PROCESS[@]}"; do
    IFS='|' read -r source_type source_ref jdk subdir key_override name_override <<< "$entry"
    normalized_ref="$(normalize_source_ref "$source_type" "$source_ref" "$REPOS_ROOT")"
    key="$(derive_source_key "$source_type" "$normalized_ref" "$key_override")"
    display_name="$(derive_source_display_name "$source_type" "$normalized_ref" "$name_override")"
    status="$(state_get_status "$key")"

    if ! $FORCE_RERUN && [[ "$status" == "success" ]]; then
      echo "  [SKIP] ${display_name} (${source_type}:${source_ref}) (already successful)"
    else
      echo "  [PROCESS] ${display_name} (${source_type}:${source_ref})${jdk:+ (jdk=$jdk)}${subdir:+ (subdir=$subdir)}${key_override:+ (key=$key_override)}"
    fi
  done
}
