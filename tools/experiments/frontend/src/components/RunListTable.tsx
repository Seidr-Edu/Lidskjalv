import type { KeyboardEvent } from "react";

import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { badgeVariantFromTone, deltaTone, formatDateTime, getStatusTone } from "@/lib/format";
import { formatMetricDelta, metricLabel } from "@/lib/sonar-metrics";
import type { RunIndexEntry } from "@/lib/types";

import { StatusBadge } from "./StatusBadge";

interface RunListTableProps {
  runs: RunIndexEntry[];
  selectedRunId?: string;
  onSelectRun: (runId: string) => void;
}

const SUMMARY_METRICS = ["bugs", "vulnerabilities", "code_smells"];

function handleRowKeyboard(event: KeyboardEvent<HTMLTableRowElement>, runId: string, onSelectRun: (runId: string) => void) {
  if (event.key === "Enter" || event.key === " ") {
    event.preventDefault();
    onSelectRun(runId);
  }
}

function deltaBadge(metric: string, value: number | null | undefined) {
  if (value === undefined || value === null) {
    return (
      <Badge key={metric} variant="outline">
        {metricLabel(metric)}: —
      </Badge>
    );
  }

  const tone = deltaTone(metric, value);
  const variant = tone === "success" ? "success" : tone === "danger" ? "destructive" : "outline";

  return (
    <Badge key={metric} variant={variant}>
      {metricLabel(metric)}: {formatMetricDelta(metric, value)}
    </Badge>
  );
}

export function RunListTable({ runs, selectedRunId, onSelectRun }: RunListTableProps) {
  return (
    <Table>
      <TableHeader>
        <TableRow>
          <TableHead>Run ID</TableHead>
          <TableHead>Source</TableHead>
          <TableHead>Started</TableHead>
          <TableHead>Status</TableHead>
          <TableHead>Codegen</TableHead>
          <TableHead>Test-port</TableHead>
          <TableHead>Sonar Δ</TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {runs.length === 0 ? (
          <TableRow>
            <TableCell className="text-muted-foreground" colSpan={7}>
              No runs match the current filters.
            </TableCell>
          </TableRow>
        ) : (
          runs.map((run) => (
            <TableRow
              key={run.run_id}
              aria-selected={run.run_id === selectedRunId}
              className="cursor-pointer"
              data-state={run.run_id === selectedRunId ? "selected" : undefined}
              onClick={() => onSelectRun(run.run_id)}
              onKeyDown={(event) => handleRowKeyboard(event, run.run_id, onSelectRun)}
              role="button"
              tabIndex={0}
            >
              <TableCell className="font-mono text-xs">{run.run_id}</TableCell>
              <TableCell>{run.source || "—"}</TableCell>
              <TableCell>{formatDateTime(run.started_at)}</TableCell>
              <TableCell>
                <StatusBadge status={run.status} />
              </TableCell>
              <TableCell>
                <Badge variant={badgeVariantFromTone(getStatusTone(run.codegen_status))}>{run.codegen_status || "—"}</Badge>
              </TableCell>
              <TableCell>
                <Badge variant={badgeVariantFromTone(getStatusTone(run.test_port_status))}>{run.test_port_status || "—"}</Badge>
              </TableCell>
              <TableCell>
                <div className="flex flex-wrap gap-1">
                  {SUMMARY_METRICS.map((metric) => deltaBadge(metric, run.sonar_delta?.[metric] as number | null | undefined))}
                </div>
              </TableCell>
            </TableRow>
          ))
        )}
      </TableBody>
    </Table>
  );
}
