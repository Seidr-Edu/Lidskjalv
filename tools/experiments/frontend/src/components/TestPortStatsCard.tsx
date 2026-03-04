import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import type { TestPortStage } from "@/lib/types";

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

export function TestPortStatsCard({ testPort }: TestPortStatsCardProps) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Test-port</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4 text-sm">
          <div className="space-y-1">
            <div className="text-xs uppercase text-muted-foreground">Stage status</div>
            <StatusBadge status={testPort?.status} />
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Behavioral verdict</div>
            <div>{valueOrDash(testPort?.behavioral_verdict)}</div>
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Failure class</div>
            <div>{valueOrDash(testPort?.failure_class)}</div>
          </div>
          <div>
            <div className="text-xs uppercase text-muted-foreground">Reason</div>
            <div>{valueOrDash(testPort?.reason)}</div>
          </div>
        </div>

        <div className="grid gap-3 md:grid-cols-2">
          <div className="rounded-md border p-3">
            <h4 className="mb-2 text-sm font-medium">Suite Shape</h4>
            <div className="space-y-1 text-sm">
              <div>Original snapshot files: {valueOrDash(testPort?.suite_shape?.original_snapshot_file_count)}</div>
              <div>Final ported test files: {valueOrDash(testPort?.suite_shape?.final_ported_test_file_count)}</div>
              <div>Retention ratio: {valueOrDash(testPort?.suite_shape?.retention_ratio)}</div>
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
      </CardContent>
    </Card>
  );
}
