import type { DatasetRegistry, RunIndex, RunIndexEntry, RunRecord } from "@/lib/types";

const DATA_BASE = import.meta.env.VITE_DATA_BASE || "/frontend-data";

const runCache = new Map<string, RunRecord>();

export class DataClientError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "DataClientError";
  }
}

function ensureObject(value: unknown, context: string): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  throw new DataClientError(`Invalid JSON object for ${context}`);
}

async function fetchJson(path: string): Promise<unknown> {
  const res = await fetch(`${DATA_BASE}${path}`);
  if (!res.ok) {
    throw new DataClientError(`Request failed (${res.status}) for ${path}`);
  }

  try {
    return await res.json();
  } catch {
    throw new DataClientError(`Invalid JSON response for ${path}`);
  }
}

function normalizeRunIndexEntry(input: unknown): RunIndexEntry | null {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    return null;
  }

  const obj = input as Record<string, unknown>;
  if (typeof obj.run_id !== "string" || obj.run_id.length === 0) {
    return null;
  }

  return obj as unknown as RunIndexEntry;
}

export async function loadDatasets(): Promise<DatasetRegistry> {
  const raw = ensureObject(await fetchJson("/datasets.json"), "datasets.json");

  const datasetsRaw = raw.datasets;
  const datasets = Array.isArray(datasetsRaw)
    ? datasetsRaw.filter((item): item is string => typeof item === "string" && item.length > 0)
    : [];

  return { datasets };
}

export async function loadRunIndex(datasetId: string): Promise<RunIndex> {
  const raw = ensureObject(await fetchJson(`/${datasetId}/runs/index.json`), `${datasetId}/runs/index.json`);
  const schemaVersion = raw.schema_version;
  if (schemaVersion !== "index.v1") {
    throw new DataClientError(`Unsupported index schema version: ${String(schemaVersion)}`);
  }

  const runsRaw = Array.isArray(raw.runs) ? raw.runs : [];
  const runs = runsRaw.map(normalizeRunIndexEntry).filter((entry): entry is RunIndexEntry => entry !== null);

  return {
    ...(raw as unknown as Omit<RunIndex, "runs" | "schema_version" | "dataset_id">),
    schema_version: "index.v1",
    dataset_id: typeof raw.dataset_id === "string" ? raw.dataset_id : datasetId,
    runs,
  };
}

function validateRunRecord(rawValue: unknown, datasetId: string, runId: string): RunRecord {
  const raw = ensureObject(rawValue, `${datasetId}/runs/${runId}.json`);

  if (raw.schema_version !== "run.v1") {
    throw new DataClientError(`Unsupported run schema version: ${String(raw.schema_version)}`);
  }
  if (typeof raw.run_id !== "string" || raw.run_id.length === 0) {
    throw new DataClientError("Invalid run record: missing run_id");
  }
  if (!raw.stages || typeof raw.stages !== "object" || Array.isArray(raw.stages)) {
    throw new DataClientError("Invalid run record: stages must be an object");
  }
  if (!raw.derived || typeof raw.derived !== "object" || Array.isArray(raw.derived)) {
    throw new DataClientError("Invalid run record: derived must be an object");
  }
  if (!raw.provenance || typeof raw.provenance !== "object" || Array.isArray(raw.provenance)) {
    throw new DataClientError("Invalid run record: provenance must be an object");
  }
  if (!raw.extensions || typeof raw.extensions !== "object" || Array.isArray(raw.extensions)) {
    throw new DataClientError("Invalid run record: extensions must be an object");
  }

  return raw as unknown as RunRecord;
}

export async function loadRunRecord(datasetId: string, runId: string): Promise<RunRecord> {
  const cacheKey = `${datasetId}:${runId}`;
  const cached = runCache.get(cacheKey);
  if (cached) {
    return cached;
  }

  const raw = await fetchJson(`/${datasetId}/runs/${runId}.json`);
  const parsed = validateRunRecord(raw, datasetId, runId);
  runCache.set(cacheKey, parsed);
  return parsed;
}

export function clearRunRecordCache() {
  runCache.clear();
}
