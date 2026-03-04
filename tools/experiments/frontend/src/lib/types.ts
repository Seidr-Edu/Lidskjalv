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

export interface TestPortStage {
  status?: string | null;
  reason?: string | null;
  failure_class?: string | null;
  behavioral_verdict?: string | null;
  behavioral_verdict_reason?: string | null;
  suite_shape?: {
    original_snapshot_file_count?: number;
    final_ported_test_file_count?: number;
    retention_ratio?: number | null;
    [key: string]: unknown;
  };
  suite_changes?: {
    added?: number;
    modified?: number;
    deleted?: number;
    total?: number;
    [key: string]: unknown;
  };
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
