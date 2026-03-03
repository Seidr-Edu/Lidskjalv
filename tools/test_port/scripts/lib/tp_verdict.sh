#!/usr/bin/env bash
# tp_verdict.sh - behavioral verdict helpers.

set -euo pipefail

tp_compute_behavioral_verdict() {
  local failing_case_count
  local removed_original_count
  failing_case_count="${TP_EVIDENCE_JUNIT_FAILING_CASE_COUNT:-0}"
  removed_original_count="${TP_EVIDENCE_REMOVED_ORIGINAL_TEST_FILE_COUNT:-0}"

  case "$TP_STATUS" in
    failed)
      if [[ "$TP_REASON" == "write-scope-violation" ]]; then
        TP_BEHAVIORAL_VERDICT="invalid"
        TP_BEHAVIORAL_VERDICT_REASON="write-scope-violation"
      elif [[ "$TP_REASON" == "insufficient-test-evidence" ]]; then
        TP_BEHAVIORAL_VERDICT="invalid"
        TP_BEHAVIORAL_VERDICT_REASON="${TP_FAILURE_CLASS:-insufficient-test-evidence}"
      elif [[ "$failing_case_count" -gt 0 || "$TP_REASON" == "behavioral-difference-evidence" || "$TP_FAILURE_CLASS" == "behavioral-mismatch" ]]; then
        TP_BEHAVIORAL_VERDICT="difference_detected"
        TP_BEHAVIORAL_VERDICT_REASON="assertion-mismatch-evidence"
      elif [[ "$TP_REASON" == "tests-failed" ]]; then
        TP_BEHAVIORAL_VERDICT="inconclusive"
        TP_BEHAVIORAL_VERDICT_REASON="${TP_FAILURE_CLASS:-ported-tests-failed}"
      else
        TP_BEHAVIORAL_VERDICT="inconclusive"
        TP_BEHAVIORAL_VERDICT_REASON="${TP_REASON:-stage-failed}"
      fi
      ;;
    passed)
      if [[ "$removed_original_count" -gt 0 ]]; then
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
