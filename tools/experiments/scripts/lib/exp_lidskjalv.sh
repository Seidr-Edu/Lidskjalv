#!/usr/bin/env bash
# exp_lidskjalv.sh - run scan-one for original and generated repositories.

set -euo pipefail

_exp_scan_set_var() {
  local prefix="$1"
  local field="$2"
  local value="$3"
  printf -v "${prefix}_${field}" '%s' "$value"
}

_exp_sonar_get_task_status() {
  local task_id="$1"
  [[ -n "${SONAR_HOST_URL:-}" && -n "${SONAR_TOKEN:-}" ]] || { echo "UNKNOWN"; return 0; }

  local response
  response="$(curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/ce/task?id=${task_id}" 2>/dev/null || true)"
  if [[ -z "$response" ]]; then
    echo "UNKNOWN"
    return 0
  fi

  echo "$response" | jq -r '.task.status // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN"
}

_exp_wait_for_sonar_task() {
  local task_id="$1"
  local timeout_sec="$2"
  local poll_sec="$3"

  local elapsed=0
  local status="UNKNOWN"
  while true; do
    status="$(_exp_sonar_get_task_status "$task_id")"
    case "$status" in
      SUCCESS|FAILED|CANCELED)
        echo "$status"
        return 0
        ;;
    esac

    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      echo "TIMEOUT"
      return 1
    fi

    sleep "$poll_sec"
    elapsed=$((elapsed + poll_sec))
  done
}

_exp_fetch_sonar_quality_gate() {
  local project_key="$1"
  local qg_json qg_status

  qg_json="$(curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/qualitygates/project_status?projectKey=${project_key}" 2>/dev/null || echo "{}")"
  qg_status="$(echo "$qg_json" | jq -r '.projectStatus.status // empty' 2>/dev/null || true)"
  echo "$qg_status"
}

_exp_fetch_sonar_measures_json() {
  local project_key="$1"
  local metric_keys
  metric_keys="${EXP_SONAR_METRIC_KEYS:-bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density,reliability_rating,security_rating,sqale_rating,ncloc,sqale_index}"
  curl -sf -u "${SONAR_TOKEN}:" \
    "${SONAR_HOST_URL}/api/measures/component?component=${project_key}&metricKeys=${metric_keys}" \
    2>/dev/null \
    | jq -c 'reduce (.component.measures // [])[] as $m ({}; .[$m.metric]=$m.value)' 2>/dev/null || echo "{}"
}

_exp_collect_scan_metadata() {
  local prefix="$1"
  local project_key="$2"
  local scan_status="$3"

  _exp_scan_set_var "$prefix" "SONAR_URL" ""
  _exp_scan_set_var "$prefix" "QUALITY_GATE" ""
  _exp_scan_set_var "$prefix" "MEASURES_JSON" "{}"
  _exp_scan_set_var "$prefix" "STATE_LOG_DIR" "${LOG_DIR}/${project_key}"
  _exp_scan_set_var "$prefix" "SONAR_TASK_ID" ""
  _exp_scan_set_var "$prefix" "CE_TASK_STATUS" ""
  _exp_scan_set_var "$prefix" "DATA_STATUS" "unavailable"

  if [[ -n "${SONAR_HOST_URL:-}" ]]; then
    _exp_scan_set_var "$prefix" "SONAR_URL" "${SONAR_HOST_URL}/dashboard?id=${project_key}"
  fi

  local task_id=""
  if declare -f state_get >/dev/null 2>&1; then
    task_id="$(state_get "$project_key" "sonar_task_id" 2>/dev/null || true)"
  fi
  _exp_scan_set_var "$prefix" "SONAR_TASK_ID" "$task_id"

  if $SKIP_SONAR; then
    _exp_scan_set_var "$prefix" "DATA_STATUS" "skipped"
    return 0
  fi

  if [[ "$scan_status" != "success" ]]; then
    _exp_scan_set_var "$prefix" "DATA_STATUS" "unavailable"
    return 0
  fi

  [[ -n "${SONAR_HOST_URL:-}" && -n "${SONAR_TOKEN:-}" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local ce_status=""
  if [[ -n "$task_id" ]]; then
    if [[ "${SONAR_WAIT:-on}" == "on" ]]; then
      ce_status="$(_exp_wait_for_sonar_task "$task_id" "${SONAR_WAIT_TIMEOUT_SEC:-300}" "${SONAR_WAIT_POLL_SEC:-5}" || true)"
    else
      ce_status="$(_exp_sonar_get_task_status "$task_id")"
    fi
  fi
  _exp_scan_set_var "$prefix" "CE_TASK_STATUS" "$ce_status"

  local qg_status measures_json
  qg_status="$(_exp_fetch_sonar_quality_gate "$project_key")"
  _exp_scan_set_var "$prefix" "QUALITY_GATE" "$qg_status"

  measures_json="$(_exp_fetch_sonar_measures_json "$project_key")"
  _exp_scan_set_var "$prefix" "MEASURES_JSON" "$measures_json"

  local data_status="unavailable"
  if [[ "$measures_json" != "{}" ]]; then
    data_status="complete"
  else
    case "$ce_status" in
      PENDING|IN_PROGRESS|TIMEOUT) data_status="pending" ;;
      FAILED|CANCELED) data_status="failed" ;;
      *) data_status="unavailable" ;;
    esac
  fi

  _exp_scan_set_var "$prefix" "DATA_STATUS" "$data_status"

  if [[ "$data_status" == "pending" ]]; then
    exp_warn "Sonar metrics not ready yet for ${project_key} (task=${task_id:-<none>} status=${ce_status:-UNKNOWN})"
  fi
}

exp_scan_original() {
  ORIGINAL_SCAN_MODE="$SCAN_ORIGINAL_MODE"
  ORIGINAL_SCAN_STATUS="skipped"
  ORIGINAL_SCAN_REUSED=false
  _exp_collect_scan_metadata "ORIGINAL_SCAN" "$ORIGINAL_SCAN_KEY" "$ORIGINAL_SCAN_STATUS"

  if [[ "$SCAN_ORIGINAL_MODE" == "skip" ]]; then
    return 0
  fi

  local should_scan=true
  if [[ "$SCAN_ORIGINAL_MODE" == "auto" ]] && state_is_success "$ORIGINAL_SCAN_KEY"; then
    should_scan=false
    ORIGINAL_SCAN_REUSED=true
    ORIGINAL_SCAN_STATUS="success"
    _exp_collect_scan_metadata "ORIGINAL_SCAN" "$ORIGINAL_SCAN_KEY" "$ORIGINAL_SCAN_STATUS"
  fi

  if [[ "$should_scan" == true ]]; then
    local scan_path="${EXP_WORKSPACE_SCAN_DIR}/original-source-copy"
    exp_copy_dir "$ORIGINAL_REPO_PATH" "$scan_path"

    local cmd=("${REPO_ROOT}/scripts/scan-one.sh" --path "$scan_path" --project-key "$ORIGINAL_SCAN_KEY" --project-name "$ORIGINAL_SCAN_DISPLAY_NAME")
    [[ -n "$SOURCE_SUBDIR" ]] && cmd+=(--subdir "$SOURCE_SUBDIR")
    $SKIP_SONAR && cmd+=(--skip-sonar)

    set +e
    "${cmd[@]}" >"${EXP_LOG_DIR}/original-scan.log" 2>&1
    local rc=$?
    set -e
    ORIGINAL_SCAN_STATUS=$([[ $rc -eq 0 ]] && echo success || echo failed)
    _exp_collect_scan_metadata "ORIGINAL_SCAN" "$ORIGINAL_SCAN_KEY" "$ORIGINAL_SCAN_STATUS"
  fi
}

exp_scan_generated() {
  GENERATED_SCAN_STATUS="skipped"
  _exp_collect_scan_metadata "GENERATED_SCAN" "$GENERATED_SONAR_KEY" "$GENERATED_SCAN_STATUS"
  [[ -d "$ANDVARI_NEW_REPO" ]] || return 0

  local gen_scan_copy="${EXP_WORKSPACE_SCAN_DIR}/generated-source-copy"
  exp_copy_dir "$ANDVARI_NEW_REPO" "$gen_scan_copy"

  local cmd=("${REPO_ROOT}/scripts/scan-one.sh" --path "$gen_scan_copy" --project-key "$GENERATED_SONAR_KEY" --project-name "$GENERATED_DISPLAY_NAME")
  $SKIP_SONAR && cmd+=(--skip-sonar)

  set +e
  "${cmd[@]}" >"${EXP_LOG_DIR}/generated-scan.log" 2>&1
  local rc=$?
  set -e
  GENERATED_SCAN_STATUS=$([[ $rc -eq 0 ]] && echo success || echo failed)
  _exp_collect_scan_metadata "GENERATED_SCAN" "$GENERATED_SONAR_KEY" "$GENERATED_SCAN_STATUS"
}
