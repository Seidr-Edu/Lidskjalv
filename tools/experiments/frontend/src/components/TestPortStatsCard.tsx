import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { TestPortGroupedFailureCase, TestPortStage, TestPortTestOutcome } from "@/lib/types";

import { StatusBadge } from "./StatusBadge";

interface TestPortStatsCardProps {
  testPort?: TestPortStage;
}

function valueOrDash(value?: string | number | null) {
  if (value === null || value === undefined || value === "") {
    return "—";
  }
  return String(value);
}

function boolOrDash(value?: boolean | null) {
  if (value === null || value === undefined) {
    return "—";
  }
  return value ? "true" : "false";
}

function ratioOrDash(value?: number | null) {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return "—";
  }
  return Number(value).toFixed(3);
}

function normalizeGroupedFailures(testPort?: TestPortStage): TestPortGroupedFailureCase[] {
  const grouped = testPort?.behavioral_evidence?.grouped_failing_cases;
  if (Array.isArray(grouped) && grouped.length > 0) {
    return grouped;
  }

  const fallback = testPort?.behavioral_evidence?.failing_cases;
  if (!Array.isArray(fallback)) {
    return [];
  }

  return fallback.map((item) => ({
    class: typeof item?.class === "string" ? item.class : "",
    name: typeof item?.name === "string" ? item.name : "",
    kind: typeof item?.kind === "string" ? item.kind : "",
    message: typeof item?.message === "string" ? item.message : "",
    occurrence_count: 1,
    sample_report_files: typeof item?.report_file === "string" && item.report_file.length > 0 ? [item.report_file] : [],
  }));
}

function testOutcomeRow(title: string, value?: TestPortTestOutcome) {
  return (
    <div className="space-y-1 rounded-md border p-2">
      <div className="text-xs uppercase text-muted-foreground">{title}</div>
      <div className="flex flex-wrap items-center gap-2 text-sm">
        <StatusBadge status={value?.status} />
        <span>exit {valueOrDash(value?.exit_code)}</span>
      </div>
      <div className="space-y-1 text-xs text-muted-foreground">
        <div>Strategy: {valueOrDash(value?.strategy)}</div>
        <div>Failure class: {valueOrDash(value?.failure_class)}</div>
        <div>Failure type: {valueOrDash(value?.failure_type)}</div>
        <div>Log: {valueOrDash(value?.log_path)}</div>
      </div>
    </div>
  );
}

export function TestPortStatsCard({ testPort }: TestPortStatsCardProps) {
  const groupedFailures = normalizeGroupedFailures(testPort);
  const uniqueFailCount = testPort?.behavioral_evidence?.failing_case_unique_count ?? testPort?.behavioral_evidence?.failing_case_count;
  const occurrenceFailCount = testPort?.behavioral_evidence?.failing_case_occurrence_count ?? uniqueFailCount;
  const ignoredPrefixes = Array.isArray(testPort?.write_scope?.ignored_prefixes) ? (testPort?.write_scope?.ignored_prefixes ?? []) : [];
  const writeScopeViolations = Array.isArray(testPort?.write_scope?.violations) ? (testPort?.write_scope?.violations ?? []) : [];
  const artifacts = testPort?.artifacts;
  const artifactRows = [
    ["tool_run_dir", artifacts?.tool_run_dir],
    ["tool_json_path", artifacts?.tool_json_path],
    ["tool_summary_path", artifacts?.tool_summary_path],
    ["tool_log_path", artifacts?.tool_log_path],
    ["adapter_events_log", artifacts?.adapter_events_log],
    ["adapter_stderr_log", artifacts?.adapter_stderr_log],
    ["adapter_last_message_path", artifacts?.adapter_last_message_path],
  ].filter(([, value]) => typeof value === "string" && value.length > 0) as Array<[string, string]>;

  return (
    <Card>
      <CardHeader>
        <CardTitle>Test-port</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-4">
          <div className="space-y-1">
            <div className="text-xs uppercase text-muted-foreground">Stage status</div>
            <StatusBadge status={testPort?.status} />
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Behavioral verdict</div>
            <div>{valueOrDash(testPort?.behavioral_verdict)}</div>
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Verdict reason</div>
            <div>{valueOrDash(testPort?.behavioral_verdict_reason)}</div>
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Failure class</div>
            <div>{valueOrDash(testPort?.failure_class)}</div>
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Reason</div>
            <div>{valueOrDash(testPort?.reason)}</div>
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Adapter prereqs ok</div>
            <div>{boolOrDash(testPort?.adapter_prereqs_ok)}</div>
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Generated repo unchanged</div>
            <div>{boolOrDash(testPort?.new_repo_unchanged)}</div>
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Iterations / adapter non-zero</div>
            <div>
              {valueOrDash(testPort?.ported_original_tests?.iterations_used)} / {valueOrDash(testPort?.ported_original_tests?.adapter_nonzero_runs)}
            </div>
          </div>
        </div>

        <div className="grid gap-3 md:grid-cols-2">
          <div className="rounded-md border p-3">
            <h4 className="mb-2 text-sm font-medium">Suite Shape</h4>
            <div className="space-y-1 text-sm">
              <div>Original snapshot files: {valueOrDash(testPort?.suite_shape?.original_snapshot_file_count)}</div>
              <div>Final ported test files: {valueOrDash(testPort?.suite_shape?.final_ported_test_file_count)}</div>
              <div>Retained original test files: {valueOrDash(testPort?.suite_shape?.retained_original_test_file_count)}</div>
              <div>Removed original test files: {valueOrDash(testPort?.suite_shape?.removed_original_test_file_count)}</div>
              <div>Retention ratio: {ratioOrDash(testPort?.suite_shape?.retention_ratio)}</div>
            </div>
          </div>

          <div className="rounded-md border p-3">
            <h4 className="mb-2 text-sm font-medium">Suite Changes</h4>
            <div className="space-y-1 text-sm">
              <div>Added: {valueOrDash(testPort?.suite_changes?.added)}</div>
              <div>Modified: {valueOrDash(testPort?.suite_changes?.modified)}</div>
              <div>Deleted: {valueOrDash(testPort?.suite_changes?.deleted)}</div>
              <div>Total: {valueOrDash(testPort?.suite_changes?.total)}</div>
            </div>
          </div>
        </div>

        <div className="grid gap-3 lg:grid-cols-3">
          <div className="space-y-2 rounded-md border p-3">
            <h4 className="text-sm font-medium">Baseline + Ported Tests</h4>
            {testOutcomeRow("Baseline original", testPort?.baseline_original_tests)}
            {testOutcomeRow("Baseline generated", testPort?.baseline_generated_tests)}
            {testOutcomeRow("Ported original", testPort?.ported_original_tests)}
          </div>

          <div className="space-y-2 rounded-md border p-3">
            <h4 className="text-sm font-medium">Write Scope</h4>
            <div className="space-y-1 text-sm">
              <div>Policy: {valueOrDash(testPort?.write_scope?.policy)}</div>
              <div>Violation count: {valueOrDash(testPort?.write_scope?.violation_count)}</div>
              <div>
                Ignored prefixes:{" "}
                {ignoredPrefixes.length > 0 ? ignoredPrefixes.join(", ") : "—"}
              </div>
              <div>Violations log: {valueOrDash(testPort?.write_scope?.violations_log_path)}</div>
              <div>Disallowed diff: {valueOrDash(testPort?.write_scope?.diff_path)}</div>
            </div>
            {writeScopeViolations.length > 0 && (
              <div className="max-h-40 space-y-1 overflow-auto rounded-md border p-2 text-xs">
                {writeScopeViolations.map((entry, index) => (
                  <div key={`${entry.kind ?? ""}:${entry.path ?? ""}:${index}`}>
                    [{valueOrDash(entry.kind)}] {valueOrDash(entry.path)}
                  </div>
                ))}
              </div>
            )}
          </div>

          <div className="space-y-2 rounded-md border p-3">
            <h4 className="text-sm font-medium">Retention Policy</h4>
            <div className="space-y-1 text-sm">
              <div>Mode: {valueOrDash(testPort?.retention_policy?.mode)}</div>
              <div>Documented removals required: {boolOrDash(testPort?.retention_policy?.documented_removals_required)}</div>
              <div>Undocumented removed tests: {valueOrDash(testPort?.retention_policy?.undocumented_removed_test_count)}</div>
              <div>Manifest path: {valueOrDash(testPort?.retention_policy?.manifest_rel_path)}</div>
            </div>
          </div>
        </div>

        <div className="space-y-2 rounded-md border p-3">
          <h4 className="text-sm font-medium">Behavioral Evidence</h4>
          <div className="grid gap-2 text-sm sm:grid-cols-3">
            <div>JUnit reports: {valueOrDash(testPort?.behavioral_evidence?.junit_report_count)}</div>
            <div>Unique failing signatures: {valueOrDash(uniqueFailCount)}</div>
            <div>Total failing occurrences: {valueOrDash(occurrenceFailCount)}</div>
          </div>
          {groupedFailures.length > 0 ? (
            <div className="max-h-72 space-y-2 overflow-auto rounded-md border p-2 text-xs">
              {groupedFailures.map((entry, index) => (
                <div className="rounded border p-2" key={`${entry.class ?? ""}:${entry.name ?? ""}:${entry.kind ?? ""}:${entry.message ?? ""}:${index}`}>
                  <div className="font-medium">
                    {valueOrDash(entry.class)}#{valueOrDash(entry.name)} [{valueOrDash(entry.kind)}]
                  </div>
                  <div>Occurrences: {valueOrDash(entry.occurrence_count)}</div>
                  <div>Message: {valueOrDash(entry.message)}</div>
                  <div>
                    Sample report files:{" "}
                    {Array.isArray(entry.sample_report_files) && entry.sample_report_files.length > 0
                      ? entry.sample_report_files.join(", ")
                      : "—"}
                  </div>
                </div>
              ))}
            </div>
          ) : (
            <div className="text-sm text-muted-foreground">No failing case details.</div>
          )}
        </div>

        <div className="space-y-2 rounded-md border p-3">
          <h4 className="text-sm font-medium">Artifacts</h4>
          {artifactRows.length === 0 ? (
            <div className="text-sm text-muted-foreground">No artifact references.</div>
          ) : (
            <div className="space-y-1 text-xs">
              {artifactRows.map(([label, value]) => (
                <div key={label}>
                  <span className="font-medium">{label}:</span> {value}
                </div>
              ))}
            </div>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
