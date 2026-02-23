#!/usr/bin/env bash
set -euo pipefail

timestamp_utc_adapter() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

append_adapter_event() {
  local events_log="$1"
  local phase="$2"
  local iteration="$3"
  local run_time
  run_time="$(timestamp_utc_adapter)"

  printf '{"type":"andvari.adapter","adapter":"codex","phase":"%s","iteration":"%s","time":"%s"}\n' \
    "$phase" "$iteration" "$run_time" >> "$events_log"
}

# _codex_prompts_dir - returns the absolute path to the prompts directory.
_codex_prompts_dir() {
  echo "${ROOT_DIR}/prompts"
}

# _codex_render_template TEMPLATE_NAME [VAR=VALUE ...]
# Reads the named template from the prompts directory and substitutes
# any VAR=VALUE pairs supplied as extra arguments using sed.
# Prints the rendered content to stdout; returns 1 if the file is missing.
_codex_render_template() {
  local template_name="$1"
  shift
  local prompts_dir
  prompts_dir="$(_codex_prompts_dir)"
  local template_path="${prompts_dir}/${template_name}"

  [[ -f "$template_path" ]] || {
    echo "Prompt template not found: ${template_path}" >&2
    return 1
  }

  local content
  content="$(cat "$template_path")"

  # Callers only pass pre-validated integer values; substitution is safe.
  local pair key val
  for pair in "$@"; do
    key="${pair%%=*}"
    val="${pair#*=}"
    content="${content//\$\{${key}\}/${val}}"
  done

  # Use printf '%s' to avoid adding an extra newline beyond what the template provides.
  printf '%s' "$content"
}

codex_check_prereqs() {
  if ! command -v codex >/dev/null 2>&1; then
    echo "codex CLI not found. Install Codex CLI and ensure 'codex' is on PATH." >&2
    return 1
  fi

  local codex_home="${CODEX_HOME:-${HOME}/.codex}"
  local session_dir="${codex_home}/sessions"
  if [[ -e "$codex_home" && ! -w "$codex_home" ]]; then
    cat >&2 <<PREREQ_EOF
codex CLI home is not writable: ${codex_home}
Fix ownership/permissions, for example:
  sudo chown -R \$(whoami) "${codex_home}"
PREREQ_EOF
    return 1
  fi
  if [[ -e "$session_dir" && ! -w "$session_dir" ]]; then
    cat >&2 <<PREREQ_EOF
codex CLI session directory is not writable: ${session_dir}
Fix ownership/permissions, for example:
  sudo chown -R \$(whoami) "${codex_home}"
PREREQ_EOF
    return 1
  fi

  if ! codex login status >/dev/null 2>&1; then
    cat >&2 <<'PREREQ_EOF'
codex CLI is not authenticated.
Run one of:
  codex login
  printenv OPENAI_API_KEY | codex login --with-api-key
PREREQ_EOF
    return 1
  fi

  local prompts_dir
  prompts_dir="$(_codex_prompts_dir)"
  local required_templates=(
    "initial_reconstruction.md"
    "fix_iteration.md"
    "gate_declaration.md"
    "implementation_iteration.md"
  )
  local tpl
  for tpl in "${required_templates[@]}"; do
    [[ -f "${prompts_dir}/${tpl}" ]] || {
      echo "Required prompt template not found: ${prompts_dir}/${tpl}" >&2
      return 1
    }
  done
}

run_codex_prompt() {
  local new_repo_dir="$1"
  local input_diagram_path="$2"
  local prompt_file="$3"
  local events_log="$4"
  local stderr_log="$5"
  local output_last_message="$6"

  local input_dir
  input_dir="$(cd "$(dirname "$input_diagram_path")" && pwd)"

  set +e
  (
    cd "$new_repo_dir"
    codex exec \
      --skip-git-repo-check \
      --full-auto \
      --add-dir "$input_dir" \
      --json \
      --output-last-message "$output_last_message" \
      - < "$prompt_file"
  ) >> "$events_log" 2>> "$stderr_log"
  local status=$?
  set -e

  return "$status"
}

codex_run_initial_reconstruction() {
  local new_repo_dir="$1"
  local input_diagram_path="$2"
  local events_log="$3"
  local stderr_log="$4"
  local output_last_message="$5"

  local prompt_file
  prompt_file="$(mktemp)"

  _codex_render_template "initial_reconstruction.md" > "$prompt_file"

  append_adapter_event "$events_log" "initial" "0"
  local status
  set +e
  run_codex_prompt \
    "$new_repo_dir" \
    "$input_diagram_path" \
    "$prompt_file" \
    "$events_log" \
    "$stderr_log" \
    "$output_last_message"
  status=$?
  set -e

  rm -f "$prompt_file"
  return "$status"
}

codex_run_fix_iteration() {
  local new_repo_dir="$1"
  local input_diagram_path="$2"
  local gate_summary_file="$3"
  local events_log="$4"
  local stderr_log="$5"
  local output_last_message="$6"
  local iteration="$7"

  local prompt_file
  prompt_file="$(mktemp)"

  {
    _codex_render_template "fix_iteration.md"
    echo "----- BEGIN GATE SUMMARY -----"
    cat "$gate_summary_file"
    echo "----- END GATE SUMMARY -----"
  } > "$prompt_file"

  append_adapter_event "$events_log" "repair-fixed" "$iteration"
  local status
  set +e
  run_codex_prompt \
    "$new_repo_dir" \
    "$input_diagram_path" \
    "$prompt_file" \
    "$events_log" \
    "$stderr_log" \
    "$output_last_message"
  status=$?
  set -e

  rm -f "$prompt_file"
  return "$status"
}

codex_run_gate_declaration() {
  local new_repo_dir="$1"
  local input_diagram_path="$2"
  local events_log="$3"
  local stderr_log="$4"
  local output_last_message="$5"
  local max_gate_revisions="$6"

  local max_gate_version=$((max_gate_revisions + 1))
  local prompt_file
  prompt_file="$(mktemp)"

  _codex_render_template "gate_declaration.md" \
    "MAX_GATE_VERSION=${max_gate_version}" \
    > "$prompt_file"

  append_adapter_event "$events_log" "declare" "0"
  local status
  set +e
  run_codex_prompt \
    "$new_repo_dir" \
    "$input_diagram_path" \
    "$prompt_file" \
    "$events_log" \
    "$stderr_log" \
    "$output_last_message"
  status=$?
  set -e

  rm -f "$prompt_file"
  return "$status"
}

codex_run_implementation_iteration() {
  local new_repo_dir="$1"
  local input_diagram_path="$2"
  local gate_summary_file="$3"
  local events_log="$4"
  local stderr_log="$5"
  local output_last_message="$6"
  local iteration="$7"
  local max_gate_revisions="$8"
  local model_gate_timeout_sec="$9"

  local max_gate_version=$((max_gate_revisions + 1))
  local prompt_file
  prompt_file="$(mktemp)"

  {
    _codex_render_template "implementation_iteration.md" \
      "MAX_GATE_VERSION=${max_gate_version}" \
      "MAX_GATE_REVISIONS=${max_gate_revisions}" \
      "MODEL_GATE_TIMEOUT_SEC=${model_gate_timeout_sec}"
    echo "----- BEGIN GATE SUMMARY -----"
    cat "$gate_summary_file"
    echo "----- END GATE SUMMARY -----"
  } > "$prompt_file"

  append_adapter_event "$events_log" "implement" "$iteration"
  local status
  set +e
  run_codex_prompt \
    "$new_repo_dir" \
    "$input_diagram_path" \
    "$prompt_file" \
    "$events_log" \
    "$stderr_log" \
    "$output_last_message"
  status=$?
  set -e

  rm -f "$prompt_file"
  return "$status"
}
