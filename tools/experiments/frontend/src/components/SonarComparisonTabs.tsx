import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { badgeVariantFromTone, deltaTone, formatDelta, formatNumber, getStatusTone, toNumber } from "@/lib/format";
import type { RunRecord, SonarScan } from "@/lib/types";

interface SonarComparisonTabsProps {
  run: RunRecord;
}

const CORE_METRICS = ["bugs", "vulnerabilities", "code_smells", "coverage", "duplicated_lines_density", "ncloc", "sqale_index"];

function extractMetrics(scan?: SonarScan): Record<string, number | null> {
  const out: Record<string, number | null> = {};
  if (!scan?.measures || typeof scan.measures !== "object") {
    return out;
  }

  for (const [key, value] of Object.entries(scan.measures)) {
    out[key] = toNumber(value);
  }
  return out;
}

function deltaBadge(metric: string, value: number | null | undefined) {
  if (value === undefined || value === null) {
    return <Badge variant="outline">—</Badge>;
  }
  const tone = deltaTone(metric, value);
  return <Badge variant={badgeVariantFromTone(tone)}>{formatDelta(value)}</Badge>;
}

function scanDetails(scan: SonarScan | undefined, label: string) {
  return (
    <div className="space-y-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-medium">{label} status:</span>
        <Badge variant={badgeVariantFromTone(getStatusTone(scan?.status))}>{scan?.status || "—"}</Badge>
      </div>

      <dl className="grid gap-2 md:grid-cols-2">
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Project Key</dt>
          <dd className="font-mono text-xs break-all">{scan?.project_key || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Project Name</dt>
          <dd>{scan?.project_name || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Quality Gate</dt>
          <dd>{scan?.quality_gate || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Scan Data Status</dt>
          <dd>{scan?.scan_data_status || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">CE Task Status</dt>
          <dd>{scan?.ce_task_status || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Sonar Task ID</dt>
          <dd className="font-mono text-xs break-all">{scan?.sonar_task_id || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Build Tool</dt>
          <dd>{scan?.build_tool || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Build JDK</dt>
          <dd>{scan?.build_jdk || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Failure Reason</dt>
          <dd>{scan?.failure_reason || "—"}</dd>
        </div>
        <div>
          <dt className="text-xs uppercase text-muted-foreground">Failure Message</dt>
          <dd>{scan?.failure_message || "—"}</dd>
        </div>
      </dl>

      <div>
        <dt className="text-xs uppercase text-muted-foreground">Sonar URL</dt>
        <dd>
          {scan?.sonar_url ? (
            <a className="text-primary underline" href={scan.sonar_url} rel="noreferrer" target="_blank">
              Open dashboard
            </a>
          ) : (
            "—"
          )}
        </dd>
      </div>
    </div>
  );
}

export function SonarComparisonTabs({ run }: SonarComparisonTabsProps) {
  const original = run.stages?.sonar?.original;
  const generated = run.stages?.sonar?.generated;
  const originalMetrics = extractMetrics(original);
  const generatedMetrics = extractMetrics(generated);
  const delta = run.derived?.sonar_delta || {};

  const metrics = new Set<string>([...CORE_METRICS]);
  for (const key of Object.keys(originalMetrics)) {
    metrics.add(key);
  }
  for (const key of Object.keys(generatedMetrics)) {
    metrics.add(key);
  }
  for (const key of Object.keys(delta)) {
    metrics.add(key);
  }

  const orderedMetrics = Array.from(metrics).sort((a, b) => {
    const ai = CORE_METRICS.indexOf(a);
    const bi = CORE_METRICS.indexOf(b);
    if (ai !== -1 || bi !== -1) {
      if (ai === -1) return 1;
      if (bi === -1) return -1;
      return ai - bi;
    }
    return a.localeCompare(b);
  });

  return (
    <Card>
      <CardHeader>
        <CardTitle>Sonar Analysis</CardTitle>
      </CardHeader>
      <CardContent>
        <Tabs defaultValue="comparison">
          <TabsList>
            <TabsTrigger value="comparison">Comparison</TabsTrigger>
            <TabsTrigger value="original">Original</TabsTrigger>
            <TabsTrigger value="generated">Generated</TabsTrigger>
          </TabsList>

          <TabsContent value="comparison">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Metric</TableHead>
                  <TableHead>Original</TableHead>
                  <TableHead>Generated</TableHead>
                  <TableHead>Delta (gen-orig)</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {orderedMetrics.map((metric) => (
                  <TableRow key={metric}>
                    <TableCell className="font-mono text-xs">{metric}</TableCell>
                    <TableCell>{formatNumber(originalMetrics[metric])}</TableCell>
                    <TableCell>{formatNumber(generatedMetrics[metric])}</TableCell>
                    <TableCell>{deltaBadge(metric, (delta[metric] as number | null | undefined) ?? null)}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </TabsContent>

          <TabsContent value="original">{scanDetails(original, "Original")}</TabsContent>
          <TabsContent value="generated">{scanDetails(generated, "Generated")}</TabsContent>
        </Tabs>
      </CardContent>
    </Card>
  );
}
