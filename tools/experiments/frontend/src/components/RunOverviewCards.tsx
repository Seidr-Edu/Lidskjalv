import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { formatDateTime, formatDuration } from "@/lib/format";
import type { RunRecord } from "@/lib/types";

import { StatusBadge } from "./StatusBadge";

interface RunOverviewCardsProps {
  run: RunRecord;
}

export function RunOverviewCards({ run }: RunOverviewCardsProps) {
  return (
    <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
      <Card>
        <CardHeader>
          <CardTitle>Run Status</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2">
          <StatusBadge status={run.status} />
          <p className="text-xs text-muted-foreground font-mono break-all">{run.run_id}</p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Duration</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm">
          <div>{formatDuration(run.started_at, run.finished_at)}</div>
          <div className="text-xs text-muted-foreground">Started: {formatDateTime(run.started_at)}</div>
          <div className="text-xs text-muted-foreground">Finished: {formatDateTime(run.finished_at)}</div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Source</CardTitle>
        </CardHeader>
        <CardContent className="space-y-1 text-sm">
          <div>{run.source?.display_name || "—"}</div>
          <div className="text-xs text-muted-foreground font-mono break-all">{run.source?.git?.commit || "—"}</div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Diagram SHA</CardTitle>
        </CardHeader>
        <CardContent className="text-xs font-mono break-all text-muted-foreground">{run.diagram?.sha256 || "—"}</CardContent>
      </Card>
    </div>
  );
}
