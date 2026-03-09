#!/usr/bin/env bash
# runner_flows.sh - Fixed and model mode orchestration flows
# Implements fixed-gate and model-gate execution flows with repair iteration loops

andvari_execute_fixed_flow() {
  echo "[andvari] starting fixed-gate reconstruction..."

  if ! adapter_run_initial_reconstruction \
    "$ADAPTER" \
    "$NEW_REPO_DIR" \
    "${INPUT_DIR}/diagram.puml" \
    "$EVENTS_LOG" \
    "$ADAPTER_STDERR_LOG" \
    "${OUTPUTS_DIR}/adapter_last_message_initial.txt"; then
    ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
    echo "[andvari] warning: initial adapter run returned non-zero status"
  fi

  if andvari_run_fixed_gate "gate-initial"; then
    STATUS="passed"
    return
  fi

  local iter
  for ((iter = 1; iter <= MAX_ITER; iter++)); do
    REPAIR_ITERATIONS_USED="$iter"
    andvari_summarize_last_gate_failure
    echo "[andvari] fixed gate failed, running repair iteration ${iter}/${MAX_ITER}..."

    if ! adapter_run_fix_iteration \
      "$ADAPTER" \
      "$NEW_REPO_DIR" \
      "${INPUT_DIR}/diagram.puml" \
      "$GATE_SUMMARY_FILE" \
      "$EVENTS_LOG" \
      "$ADAPTER_STDERR_LOG" \
      "${OUTPUTS_DIR}/adapter_last_message_iter_${iter}.txt" \
      "$iter"; then
      ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
      echo "[andvari] warning: adapter repair iteration ${iter} returned non-zero status"
    fi

    if andvari_run_fixed_gate "gate-retry-${iter}"; then
      STATUS="passed"
      break
    fi
  done
}

andvari_execute_model_flow() {
  echo "[andvari] starting model-gate declaration phase..."
  if ! adapter_run_gate_declaration \
    "$ADAPTER" \
    "$NEW_REPO_DIR" \
    "${INPUT_DIR}/diagram.puml" \
    "$EVENTS_LOG" \
    "$ADAPTER_STDERR_LOG" \
    "${OUTPUTS_DIR}/adapter_last_message_declaration.txt" \
    "$MAX_GATE_REVISIONS"; then
    ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
    echo "[andvari] warning: declaration phase returned non-zero status"
  fi

  andvari_lock_initial_outcomes

  echo "Initial implementation run. No prior gate failure summary." > "$GATE_SUMMARY_FILE"
  echo "[andvari] starting model-gate implementation phase..."
  if ! adapter_run_implementation_iteration \
    "$ADAPTER" \
    "$NEW_REPO_DIR" \
    "${INPUT_DIR}/diagram.puml" \
    "$GATE_SUMMARY_FILE" \
    "$EVENTS_LOG" \
    "$ADAPTER_STDERR_LOG" \
    "${OUTPUTS_DIR}/adapter_last_message_initial_implementation.txt" \
    "0" \
    "$MAX_GATE_REVISIONS" \
    "$MODEL_GATE_TIMEOUT_SEC"; then
    ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
    echo "[andvari] warning: initial implementation phase returned non-zero status"
  fi

  if andvari_run_model_acceptance "gate-initial"; then
    STATUS="passed"
    return
  fi

  local iter
  for ((iter = 1; iter <= MAX_ITER; iter++)); do
    REPAIR_ITERATIONS_USED="$iter"
    andvari_summarize_model_gate_failure
    echo "[andvari] model gate failed, running repair iteration ${iter}/${MAX_ITER}..."

    if ! adapter_run_implementation_iteration \
      "$ADAPTER" \
      "$NEW_REPO_DIR" \
      "${INPUT_DIR}/diagram.puml" \
      "$GATE_SUMMARY_FILE" \
      "$EVENTS_LOG" \
      "$ADAPTER_STDERR_LOG" \
      "${OUTPUTS_DIR}/adapter_last_message_iter_${iter}.txt" \
      "$iter" \
      "$MAX_GATE_REVISIONS" \
      "$MODEL_GATE_TIMEOUT_SEC"; then
      ADAPTER_FAILURES=$((ADAPTER_FAILURES + 1))
      echo "[andvari] warning: adapter repair iteration ${iter} returned non-zero status"
    fi

    if andvari_run_model_acceptance "gate-retry-${iter}"; then
      STATUS="passed"
      break
    fi
  done
}
