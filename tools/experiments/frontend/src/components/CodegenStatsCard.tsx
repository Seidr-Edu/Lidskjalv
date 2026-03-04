import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { formatNumber } from "@/lib/format";
import type { CodegenStage } from "@/lib/types";

import { StatusBadge } from "./StatusBadge";

interface CodegenStatsCardProps {
  codegen?: CodegenStage;
}

function formatMetricValue(value: unknown): string {
  const asNumber = formatNumber(value);
  if (asNumber !== "—") {
    return asNumber;
  }
  if (typeof value === "string" && value.length > 0) {
    return value;
  }
  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }
  return "—";
}

export function CodegenStatsCard({ codegen }: CodegenStatsCardProps) {
  const metrics = codegen?.metrics && typeof codegen.metrics === "object" ? Object.entries(codegen.metrics) : [];
  metrics.sort(([a], [b]) => a.localeCompare(b));

  return (
    <Card>
      <CardHeader>
        <CardTitle>Code Generation</CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="flex flex-wrap items-center gap-2 text-sm">
          <span>Status:</span>
          <StatusBadge status={codegen?.status} />
          <span className="text-muted-foreground">Exit code:</span>
          <span className="font-mono">{codegen?.exit_code ?? "—"}</span>
        </div>

        <div>
          <h4 className="mb-2 text-sm font-medium">Metrics</h4>
          {metrics.length === 0 ? (
            <p className="text-sm text-muted-foreground">No codegen metrics present for this run.</p>
          ) : (
            <div className="grid gap-2 sm:grid-cols-2 xl:grid-cols-3">
              {metrics.map(([key, value]) => (
                <div key={key} className="rounded-md border bg-muted/30 p-2">
                  <div className="text-xs uppercase tracking-wide text-muted-foreground">{key}</div>
                  <div className="font-mono text-sm">{formatMetricValue(value)}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
