import { afterEach, describe, expect, it, vi } from "vitest";

import { clearRunRecordCache, DataClientError, loadDatasets, loadRunIndex, loadRunRecord } from "@/lib/data-client";

function mockFetchWithRoutes(routes: Record<string, { status?: number; body: unknown }>) {
  const fetchMock = vi.fn(async (url: string) => {
    const route = routes[url];
    if (!route) {
      return new Response("not found", { status: 404 });
    }

    return new Response(JSON.stringify(route.body), {
      status: route.status ?? 200,
      headers: { "content-type": "application/json" },
    });
  });

  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

afterEach(() => {
  clearRunRecordCache();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("data-client", () => {
  it("loads datasets and filters invalid entries", async () => {
    mockFetchWithRoutes({
      "/frontend-data/datasets.json": {
        body: { datasets: ["sample", 12, "", "prod"] },
      },
    });

    const datasets = await loadDatasets();
    expect(datasets.datasets).toEqual(["sample", "prod"]);
  });

  it("throws for unsupported index schema", async () => {
    mockFetchWithRoutes({
      "/frontend-data/sample/runs/index.json": {
        body: { schema_version: "index.v0", dataset_id: "sample", runs: [] },
      },
    });

    await expect(loadRunIndex("sample")).rejects.toBeInstanceOf(DataClientError);
  });

  it("caches run records by dataset and run id", async () => {
    const fetchMock = mockFetchWithRoutes({
      "/frontend-data/sample/runs/run-1.json": {
        body: {
          schema_version: "run.v1",
          run_id: "run-1",
          stages: {},
          derived: {},
          provenance: {},
          extensions: {},
        },
      },
    });

    const first = await loadRunRecord("sample", "run-1");
    const second = await loadRunRecord("sample", "run-1");

    expect(first.run_id).toBe("run-1");
    expect(second.run_id).toBe("run-1");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
