#!/usr/bin/env bash
# tp_verdict.sh - behavioral verdict helpers.

set -euo pipefail

tp_change_set_deleted_count() {
  local path="$1"
  [[ -f "$path" ]] || { echo 0; return 0; }
  awk -F '\t' '$1=="D"{c++} END{print c+0}' "$path"
}

tp_compute_behavioral_verdict() {
  local deleted_count
  deleted_count="$(tp_change_set_deleted_count "$TP_WRITE_SCOPE_CHANGE_SET_PATH")"

  case "$TP_STATUS" in
    failed)
      if [[ "$TP_REASON" == "behavioral-difference-evidence" || "$TP_FAILURE_CLASS" == "behavioral-mismatch" ]]; then
        TP_BEHAVIORAL_VERDICT="difference_detected"
        TP_BEHAVIORAL_VERDICT_REASON="assertion-mismatch-evidence"
      elif [[ "$TP_REASON" == "tests-failed" ]]; then
        TP_BEHAVIORAL_VERDICT="inconclusive"
        TP_BEHAVIORAL_VERDICT_REASON="${TP_FAILURE_CLASS:-ported-tests-failed}"
      elif [[ "$TP_REASON" == "write-scope-violation" ]]; then
        TP_BEHAVIORAL_VERDICT="invalid"
        TP_BEHAVIORAL_VERDICT_REASON="write-scope-violation"
      else
        TP_BEHAVIORAL_VERDICT="inconclusive"
        TP_BEHAVIORAL_VERDICT_REASON="${TP_REASON:-stage-failed}"
      fi
      ;;
    passed)
      if [[ "$deleted_count" -gt 0 ]]; then
        TP_BEHAVIORAL_VERDICT="inconclusive"
        TP_BEHAVIORAL_VERDICT_REASON="suite-reduced-during-adaptation"
      else
        TP_BEHAVIORAL_VERDICT="no_difference_detected"
        TP_BEHAVIORAL_VERDICT_REASON="retained-ported-tests-pass"
      fi
      ;;
    skipped)
      TP_BEHAVIORAL_VERDICT="skipped"
      TP_BEHAVIORAL_VERDICT_REASON="${TP_REASON:-stage-skipped}"
      ;;
    *)
      TP_BEHAVIORAL_VERDICT="inconclusive"
      TP_BEHAVIORAL_VERDICT_REASON="${TP_REASON:-unknown}"
      ;;
  esac
}
