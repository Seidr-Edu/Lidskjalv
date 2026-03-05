import type { DatasetRegistry, RunIndex, RunRecord } from "@/lib/types";

export const datasetsFixture: DatasetRegistry = {
  datasets: ["sample"],
};

export const runIndexFixture: RunIndex = {
  schema_version: "index.v1",
  dataset_id: "sample",
  runs: [
    {
      run_id: "run-a",
      started_at: "2026-03-02T04:00:00Z",
      finished_at: "2026-03-02T04:10:00Z",
      status: "failed",
      source: "acme/repo-a",
      codegen_status: "passed",
      test_port_status: "failed",
      sonar_delta: {
        bugs: 1,
        vulnerabilities: 0,
        code_smells: 2,
      },
    },
    {
      run_id: "run-b",
      started_at: "2026-03-02T05:00:00Z",
      finished_at: "2026-03-02T05:05:00Z",
      status: "passed",
      source: "acme/repo-b",
      codegen_status: "passed",
      test_port_status: "passed",
      sonar_delta: {
        bugs: -2,
        vulnerabilities: 0,
        code_smells: -5,
      },
    },
  ],
};

function baseRun(runId: string, source: string, status: string): RunRecord {
  const failed = status !== "passed";

  return {
    schema_version: "run.v1",
    run_id: runId,
    started_at: "2026-03-02T04:00:00Z",
    finished_at: "2026-03-02T04:05:00Z",
    status,
    source: {
      display_name: source,
      git: {
        commit: "abc123",
      },
    },
    diagram: {
      sha256: "deadbeef",
      path: null,
    },
    stages: {
      codegen: {
        status: "passed",
        exit_code: 0,
        metrics: {
          gates_total: 5,
        },
      },
      test_port: {
        enabled: true,
        informational: true,
        status: failed ? "failed" : "passed",
        reason: failed ? "tests-failed" : "",
        failure_class: failed ? "behavioral-mismatch" : "",
        adapter_prereqs_ok: true,
        new_repo_unchanged: true,
        behavioral_verdict: failed ? "difference_detected" : "no_difference_detected",
        behavioral_verdict_reason: failed ? "assertion-mismatch-evidence" : "retained-ported-tests-pass",
        write_scope: {
          policy: "tests-only",
          violation_count: failed ? 1 : 0,
          ignored_prefixes: ["./completion/proof/logs/"],
          violations: failed
            ? [
                {
                  kind: "M",
                  path: "./src/main/java/example/ProdFile.java",
                },
              ]
            : [],
          violations_log_path: `${runId}/test-port/workspace/summaries/last-write-scope-failure.txt`,
          diff_path: `${runId}/test-port/workspace/write-guards/disallowed-change.diff`,
          change_set_path: `${runId}/test-port/workspace/write-guards/ported-protected-change-set.tsv`,
        },
        suite_shape: {
          original_snapshot_file_count: 10,
          final_ported_test_file_count: 9,
          retained_original_test_file_count: 9,
          removed_original_test_file_count: 1,
          retention_ratio: 0.9,
        },
        suite_changes: {
          added: 1,
          modified: 2,
          deleted: 0,
          total: 3,
        },
        baseline_original_tests: {
          status: failed ? "fail" : "pass",
          exit_code: failed ? 1 : 0,
          strategy: "maven-unit-first-fallback-full",
          failure_class: failed ? "behavioral-mismatch" : "",
          failure_type: failed ? "behavioral" : "",
          log_path: `${runId}/test-port/logs/baseline-original-tests.log`,
        },
        baseline_generated_tests: {
          status: "pass",
          exit_code: 0,
          strategy: "single-run",
          failure_class: "",
          failure_type: "",
          log_path: `${runId}/test-port/logs/baseline-generated-tests.log`,
        },
        ported_original_tests: {
          status: failed ? "fail" : "pass",
          exit_code: failed ? 1 : 0,
          iterations_used: failed ? 2 : 0,
          adapter_nonzero_runs: failed ? 1 : 0,
          log_path: `${runId}/test-port/logs/adapt-iter-${failed ? 2 : 0}.log`,
        },
        retention_policy: {
          mode: "maximize-retained-original-tests",
          documented_removals_required: true,
          manifest_rel_path: "completion/proof/logs/test-port-removed-tests.tsv",
          undocumented_removed_test_count: 0,
        },
        behavioral_evidence: {
          junit_report_count: failed ? 2 : 1,
          junit_report_files: ["target/surefire-reports/TEST-example.xml"],
          failing_case_count: failed ? 2 : 0,
          failing_case_unique_count: failed ? 2 : 0,
          failing_case_occurrence_count: failed ? 7 : 0,
          grouped_failing_cases: failed
            ? [
                {
                  class: "com.acme.ServiceTest",
                  name: "shouldReturnExpectedValue",
                  kind: "failure",
                  message: "expected:<42> but was:<43>",
                  occurrence_count: 5,
                  sample_report_files: [
                    "target/surefire-reports/TEST-com.acme.ServiceTest.xml",
                    "target/failsafe-reports/TEST-com.acme.ServiceTestIT.xml",
                    "build/test-results/test/TEST-com.acme.ServiceTest.xml",
                  ],
                },
                {
                  class: "com.acme.OtherTest",
                  name: "shouldHandleEdgeCase",
                  kind: "error",
                  message: "java.lang.NullPointerException",
                  occurrence_count: 2,
                  sample_report_files: ["target/surefire-reports/TEST-com.acme.OtherTest.xml"],
                },
              ]
            : [],
        },
        artifacts: {
          tool_run_dir: `${runId}/test-port`,
          tool_json_path: `${runId}/test-port/outputs/test_port.json`,
          tool_summary_path: `${runId}/test-port/outputs/summary.md`,
          tool_log_path: `${runId}/logs/test-port-tool.log`,
          adapter_events_log: `${runId}/test-port/logs/adapter-events.jsonl`,
          adapter_stderr_log: `${runId}/test-port/logs/adapter-stderr.log`,
          adapter_last_message_path: `${runId}/test-port/logs/adapter-last-message.md`,
        },
      },
      sonar: {
        original: {
          status: "failed",
          project_key: `${runId}-orig`,
          project_name: `${runId} original`,
          scan_data_status: "complete",
          measures: {
            bugs: "3",
            vulnerabilities: "0",
            code_smells: "12",
            coverage: "40.0",
          },
          sonar_url: "https://example.com/original",
        },
        generated: {
          status: "failed",
          project_key: `${runId}-gen`,
          project_name: `${runId} generated`,
          scan_data_status: "complete",
          measures: {
            bugs: "1",
            vulnerabilities: "0",
            code_smells: "8",
            coverage: "42.0",
          },
          sonar_url: "https://example.com/generated",
        },
      },
    },
    derived: {
      sonar_delta: {
        bugs: -2,
        vulnerabilities: 0,
        code_smells: -4,
        coverage: 2,
      },
    },
    provenance: {
      source_root: null,
      source_run_file: `${runId}/outputs/experiment.json`,
    },
    extensions: {},
  };
}

export const runAFixture = baseRun("run-a", "acme/repo-a", "failed");
export const runBFixture = baseRun("run-b", "acme/repo-b", "passed");
