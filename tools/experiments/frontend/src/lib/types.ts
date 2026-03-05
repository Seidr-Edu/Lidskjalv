export interface DatasetRegistry {
  datasets: string[];
}

export type SonarMetricKey =
  | "bugs"
  | "vulnerabilities"
  | "code_smells"
  | "coverage"
  | "duplicated_lines_density"
  | "reliability_rating"
  | "security_rating"
  | "sqale_rating"
  | "ncloc"
  | "sqale_index";

export type SonarDelta = Record<string, number | null | undefined> & Partial<Record<SonarMetricKey, number | null>>;

export interface RunIndexEntry {
  run_id: string;
  started_at?: string | null;
  finished_at?: string | null;
  status?: string | null;
  source?: string | null;
  diagram_sha256?: string | null;
  codegen_status?: string | null;
  test_port_status?: string | null;
  sonar_delta?: SonarDelta;
  [key: string]: unknown;
}

export interface RunIndex {
  schema_version: "index.v1";
  dataset_id: string;
  runs: RunIndexEntry[];
  [key: string]: unknown;
}

export interface SourceRepo {
  raw?: string;
  type?: string;
  normalized_ref?: string;
  subdir?: string;
  key?: string;
  display_name?: string;
  git?: {
    commit?: string;
    remote?: string;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface DiagramInfo {
  sha256?: string | null;
  path?: string | null;
  [key: string]: unknown;
}

export interface CodegenStage {
  status?: string | null;
  exit_code?: number | null;
  metrics?: Record<string, unknown>;
  [key: string]: unknown;
}

export interface TestPortFailureCase {
  class?: string | null;
  name?: string | null;
  kind?: string | null;
  message?: string | null;
  report_file?: string | null;
  [key: string]: unknown;
}

export interface TestPortGroupedFailureCase {
  class?: string | null;
  name?: string | null;
  kind?: string | null;
  message?: string | null;
  occurrence_count?: number;
  sample_report_files?: string[];
  [key: string]: unknown;
}

export interface TestPortWriteScopeViolation {
  kind?: string | null;
  path?: string | null;
  [key: string]: unknown;
}

export interface TestPortWriteScope {
  policy?: string | null;
  violation_count?: number;
  violations?: TestPortWriteScopeViolation[];
  ignored_prefixes?: string[];
  violations_log_path?: string | null;
  diff_path?: string | null;
  change_set_path?: string | null;
  [key: string]: unknown;
}

export interface TestPortExecutionSummary {
  tests_discovered?: number | null;
  tests_executed?: number | null;
  tests_failed?: number | null;
  tests_errors?: number | null;
  tests_skipped?: number | null;
  junit_reports_found?: number | null;
  [key: string]: unknown;
}

export interface TestPortFailureDiagnostics {
  phase?: string | null;
  subclass?: string | null;
  first_failure_line?: string | null;
  log_excerpt_path?: string | null;
  [key: string]: unknown;
}

export interface TestPortRunnerPreflight {
  detected_runner?: string | null;
  supported?: boolean | null;
  missing_capabilities?: string[];
  module_root?: string | null;
  frameworks_detected?: string[];
  [key: string]: unknown;
}

export interface TestPortTestOutcome {
  status?: string | null;
  exit_code?: number | null;
  strategy?: string | null;
  failure_class?: string | null;
  failure_class_legacy?: string | null;
  failure_type?: string | null;
  failure_diagnostics?: TestPortFailureDiagnostics;
  execution_summary?: TestPortExecutionSummary;
  iterations_used?: number;
  adapter_nonzero_runs?: number;
  log_path?: string | null;
  [key: string]: unknown;
}

export interface TestPortBehavioralEvidence {
  junit_report_count?: number;
  junit_report_files?: string[];
  failing_case_count?: number;
  failing_case_unique_count?: number;
  failing_case_occurrence_count?: number;
  failing_cases?: TestPortFailureCase[];
  grouped_failing_cases?: TestPortGroupedFailureCase[];
  truncated?: boolean;
  grouped_truncated?: boolean;
  [key: string]: unknown;
}

export interface TestPortRetentionPolicy {
  mode?: string | null;
  documented_removals_required?: boolean;
  manifest_rel_path?: string | null;
  undocumented_removed_test_count?: number;
  [key: string]: unknown;
}

export interface TestPortAdapter {
  events_log?: string | null;
  stderr_log?: string | null;
  last_message_path?: string | null;
  [key: string]: unknown;
}

export interface TestPortArtifacts {
  tool_run_dir?: string | null;
  tool_json_path?: string | null;
  tool_summary_path?: string | null;
  tool_log_path?: string | null;
  run_dir?: string | null;
  logs_dir?: string | null;
  workspace_dir?: string | null;
  outputs_dir?: string | null;
  summary_md?: string | null;
  adapter_events_log?: string | null;
  adapter_stderr_log?: string | null;
  adapter_last_message_path?: string | null;
  [key: string]: unknown;
}

export interface TestPortStage {
  enabled?: boolean;
  informational?: boolean;
  status?: string | null;
  reason?: string | null;
  status_detail?: string | null;
  failure_class?: string | null;
  failure_class_legacy?: string | null;
  adapter_prereqs_ok?: boolean;
  new_repo_unchanged?: boolean;
  behavioral_verdict?: string | null;
  behavioral_verdict_reason?: string | null;
  runner_preflight?: TestPortRunnerPreflight;
  failure_diagnostics?: TestPortFailureDiagnostics;
  write_scope?: TestPortWriteScope;
  suite_shape?: {
    original_snapshot_file_count?: number;
    final_ported_test_file_count?: number;
    retained_original_test_file_count?: number;
    removed_original_test_file_count?: number;
    retention_ratio?: number | null;
    retained_modified_count?: number;
    retained_unchanged_count?: number;
    assertion_line_change_count?: number;
    [key: string]: unknown;
  };
  suite_changes?: {
    added?: number;
    modified?: number;
    deleted?: number;
    total?: number;
    [key: string]: unknown;
  };
  baseline_original_tests?: TestPortTestOutcome;
  baseline_generated_tests?: TestPortTestOutcome;
  ported_original_tests?: TestPortTestOutcome;
  retention_policy?: TestPortRetentionPolicy;
  behavioral_evidence?: TestPortBehavioralEvidence;
  removed_original_tests?: Array<Record<string, unknown>>;
  adapter?: TestPortAdapter;
  artifacts?: TestPortArtifacts;
  [key: string]: unknown;
}

export interface SonarScan {
  mode?: string;
  reused?: boolean;
  project_key?: string;
  project_name?: string;
  status?: string | null;
  sonar_url?: string;
  quality_gate?: string;
  sonar_task_id?: string;
  ce_task_status?: string;
  scan_data_status?: string;
  state_log_dir?: string | null;
  build_tool?: string;
  build_jdk?: string;
  failure_reason?: string;
  failure_message?: string;
  measures?: Record<string, string | number | null | undefined>;
  [key: string]: unknown;
}

export interface SonarStage {
  original?: SonarScan;
  generated?: SonarScan;
  [key: string]: unknown;
}

export interface RunStages {
  codegen?: CodegenStage;
  test_port?: TestPortStage;
  sonar?: SonarStage;
  [key: string]: unknown;
}

export interface RunRecord {
  schema_version: "run.v1";
  run_id: string;
  started_at?: string | null;
  finished_at?: string | null;
  status?: string | null;
  source?: SourceRepo;
  diagram?: DiagramInfo;
  stages: RunStages;
  derived: {
    sonar_delta?: SonarDelta;
    [key: string]: unknown;
  };
  provenance: {
    source_root?: string | null;
    source_run_file?: string | null;
    [key: string]: unknown;
  };
  extensions: Record<string, unknown>;
  [key: string]: unknown;
}
