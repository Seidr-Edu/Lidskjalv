import { useEffect, useMemo, useState } from "react";

import { CodegenStatsCard } from "@/components/CodegenStatsCard";
import { DatasetSelect } from "@/components/DatasetSelect";
import { EmptyState } from "@/components/EmptyState";
import { ErrorState } from "@/components/ErrorState";
import { RunListTable } from "@/components/RunListTable";
import { RunOverviewCards } from "@/components/RunOverviewCards";
import { SonarComparisonTabs } from "@/components/SonarComparisonTabs";
import { TestPortStatsCard } from "@/components/TestPortStatsCard";
import { Accordion, AccordionContent, AccordionItem, AccordionTrigger } from "@/components/ui/accordion";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { DataClientError, loadDatasets, loadRunIndex, loadRunRecord } from "@/lib/data-client";
import type { RunIndex, RunRecord } from "@/lib/types";

const STATUS_FILTER_ALL = "all";
const DEFAULT_STATUSES = ["passed", "failed", "completed", "completed_with_warnings", "skipped"];

function formatError(error: unknown): string {
  if (error instanceof DataClientError) {
    return error.message;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return "Unknown error";
}

export default function App() {
  const params = new URLSearchParams(window.location.search);
  const initialDataset = params.get("dataset") ?? "";
  const initialRun = params.get("run") ?? "";

  const [datasets, setDatasets] = useState<string[]>([]);
  const [datasetsLoading, setDatasetsLoading] = useState(true);
  const [datasetsError, setDatasetsError] = useState<string | null>(null);

  const [selectedDataset, setSelectedDataset] = useState<string>(initialDataset);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<string>(STATUS_FILTER_ALL);

  const [runIndex, setRunIndex] = useState<RunIndex | null>(null);
  const [runIndexLoading, setRunIndexLoading] = useState(false);
  const [runIndexError, setRunIndexError] = useState<string | null>(null);

  const [selectedRunId, setSelectedRunId] = useState(initialRun);
  const [runRecord, setRunRecord] = useState<RunRecord | null>(null);
  const [runLoading, setRunLoading] = useState(false);
  const [runError, setRunError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function bootstrapDatasets() {
      setDatasetsLoading(true);
      setDatasetsError(null);

      try {
        const registry = await loadDatasets();
        if (cancelled) {
          return;
        }

        const list = registry.datasets;
        setDatasets(list);
        if (!selectedDataset || !list.includes(selectedDataset)) {
          setSelectedDataset(list[0] || "");
        }
      } catch (error) {
        if (!cancelled) {
          setDatasetsError(formatError(error));
        }
      } finally {
        if (!cancelled) {
          setDatasetsLoading(false);
        }
      }
    }

    bootstrapDatasets();

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!selectedDataset) {
      setRunIndex(null);
      return;
    }

    let cancelled = false;

    async function loadIndex() {
      setRunIndexLoading(true);
      setRunIndexError(null);

      try {
        const index = await loadRunIndex(selectedDataset);
        if (cancelled) {
          return;
        }

        setRunIndex(index);

        const runIds = new Set(index.runs.map((run) => run.run_id));
        if (selectedRunId && runIds.has(selectedRunId)) {
          return;
        }

        if (initialRun && runIds.has(initialRun)) {
          setSelectedRunId(initialRun);
          return;
        }

        setSelectedRunId(index.runs[0]?.run_id || "");
      } catch (error) {
        if (!cancelled) {
          setRunIndex(null);
          setRunIndexError(formatError(error));
        }
      } finally {
        if (!cancelled) {
          setRunIndexLoading(false);
        }
      }
    }

    loadIndex();

    return () => {
      cancelled = true;
    };
  }, [selectedDataset]);

  useEffect(() => {
    if (!selectedDataset || !selectedRunId) {
      setRunRecord(null);
      setRunError(null);
      return;
    }

    let cancelled = false;

    async function loadRecord() {
      setRunLoading(true);
      setRunError(null);

      try {
        const record = await loadRunRecord(selectedDataset, selectedRunId);
        if (!cancelled) {
          setRunRecord(record);
        }
      } catch (error) {
        if (!cancelled) {
          setRunRecord(null);
          setRunError(formatError(error));
        }
      } finally {
        if (!cancelled) {
          setRunLoading(false);
        }
      }
    }

    loadRecord();

    return () => {
      cancelled = true;
    };
  }, [selectedDataset, selectedRunId]);

  useEffect(() => {
    const query = new URLSearchParams(window.location.search);

    if (selectedDataset) {
      query.set("dataset", selectedDataset);
    } else {
      query.delete("dataset");
    }

    if (selectedRunId) {
      query.set("run", selectedRunId);
    } else {
      query.delete("run");
    }

    const queryText = query.toString();
    const nextUrl = queryText ? `${window.location.pathname}?${queryText}` : window.location.pathname;
    window.history.replaceState({}, "", nextUrl);
  }, [selectedDataset, selectedRunId]);

  const filteredRuns = useMemo(() => {
    const runs = runIndex?.runs || [];
    const searchLower = search.trim().toLowerCase();

    return runs.filter((run) => {
      if (statusFilter !== STATUS_FILTER_ALL) {
        if ((run.status || "") !== statusFilter) {
          return false;
        }
      }

      if (!searchLower) {
        return true;
      }

      const target = `${run.run_id} ${run.source || ""}`.toLowerCase();
      return target.includes(searchLower);
    });
  }, [runIndex, search, statusFilter]);

  const statusOptions = useMemo(() => {
    const observed = new Set<string>(DEFAULT_STATUSES);
    for (const run of runIndex?.runs || []) {
      if (typeof run.status === "string" && run.status.length > 0) {
        observed.add(run.status);
      }
    }
    return [STATUS_FILTER_ALL, ...Array.from(observed.values()).sort((a, b) => a.localeCompare(b))];
  }, [runIndex]);

  return (
    <div className="min-h-screen p-4 md:p-6">
      <div className="mx-auto flex w-full max-w-[1600px] flex-col gap-4">
        <header className="rounded-lg border bg-card p-4 shadow-sm">
          <div className="mb-3">
            <h1 className="text-xl font-semibold">Experiment Run Inspector</h1>
            <p className="text-sm text-muted-foreground">Inspect codegen, test-port, and sonar data for exported experiment runs.</p>
          </div>

          <div className="grid gap-3 md:grid-cols-3">
            <DatasetSelect
              datasets={datasets}
              disabled={datasetsLoading || datasets.length === 0}
              onChange={setSelectedDataset}
              value={selectedDataset}
            />

            <Input
              aria-label="Search runs"
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Search by run id or source"
              value={search}
            />

            <Select onValueChange={setStatusFilter} value={statusFilter}>
              <SelectTrigger aria-label="Status filter">
                <SelectValue placeholder="Filter by status" />
              </SelectTrigger>
              <SelectContent>
                {statusOptions.map((status) => (
                  <SelectItem key={status} value={status}>
                    {status === STATUS_FILTER_ALL ? "all statuses" : status}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        </header>

        {datasetsError && <ErrorState title="Datasets failed to load" message={datasetsError} />}

        {!datasetsLoading && datasets.length === 0 && (
          <EmptyState
            description="No datasets found. Export data first using tools/experiments/scripts/export-frontend-data.sh"
            title="No datasets"
          />
        )}

        {datasets.length > 0 && (
          <div className="grid gap-4 xl:grid-cols-12">
            <Card className="xl:col-span-5">
              <CardHeader className="pb-2">
                <CardTitle className="text-base">Runs ({filteredRuns.length})</CardTitle>
              </CardHeader>
              <CardContent>
                {runIndexLoading ? (
                  <p className="text-sm text-muted-foreground">Loading run index…</p>
                ) : runIndexError ? (
                  <ErrorState title="Run index failed to load" message={runIndexError} />
                ) : (
                  <div className="max-h-[72vh] overflow-auto" data-testid="run-list">
                    <RunListTable onSelectRun={setSelectedRunId} runs={filteredRuns} selectedRunId={selectedRunId} />
                  </div>
                )}
              </CardContent>
            </Card>

            <div className="space-y-4 xl:col-span-7">
              {runLoading && <p className="text-sm text-muted-foreground">Loading run details…</p>}

              {!runLoading && runError && <ErrorState title="Run details failed to load" message={runError} />}

              {!runLoading && !runError && !runRecord && (
                <EmptyState
                  description="Pick a run from the table to inspect stage details."
                  title="No run selected"
                />
              )}

              {!runLoading && !runError && runRecord && (
                <>
                  <RunOverviewCards run={runRecord} />
                  <CodegenStatsCard codegen={runRecord.stages?.codegen} />
                  <TestPortStatsCard testPort={runRecord.stages?.test_port} />
                  <SonarComparisonTabs run={runRecord} />

                  <Card>
                    <CardHeader>
                      <CardTitle>Debug</CardTitle>
                    </CardHeader>
                    <CardContent>
                      <Accordion collapsible type="single">
                        <AccordionItem value="raw-json">
                          <AccordionTrigger>Raw run JSON</AccordionTrigger>
                          <AccordionContent>
                            <pre className="max-h-[260px] overflow-auto rounded-md bg-muted p-3 text-xs">
                              {JSON.stringify(runRecord, null, 2)}
                            </pre>
                          </AccordionContent>
                        </AccordionItem>
                      </Accordion>
                    </CardContent>
                  </Card>
                </>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
