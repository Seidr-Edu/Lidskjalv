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
        status: status === "passed" ? "passed" : "failed",
        reason: "tests-failed",
        failure_class: status === "passed" ? "" : "behavioral-mismatch",
        behavioral_verdict: status === "passed" ? "no_difference_detected" : "difference_detected",
        suite_shape: {
          original_snapshot_file_count: 10,
          final_ported_test_file_count: 9,
          retention_ratio: 0.9,
        },
        suite_changes: {
          added: 1,
          modified: 2,
          deleted: 0,
          total: 3,
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
