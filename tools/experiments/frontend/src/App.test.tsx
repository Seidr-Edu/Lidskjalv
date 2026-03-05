import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";

import App from "@/App";
import { datasetsFixture, runAFixture, runBFixture, runIndexFixture } from "@/test/fixtures/sample-data";

function installFetchRoutes(routes: Record<string, { status?: number; body: unknown }>) {
  const fetchMock = vi.fn(async (url: string) => {
    const route = routes[url];
    if (!route) {
      return new Response("Not Found", { status: 404 });
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
  window.history.replaceState({}, "", "/");
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("App", () => {
  it("loads runs, filters list, and switches selected run", async () => {
    installFetchRoutes({
      "/frontend-data/datasets.json": { body: datasetsFixture },
      "/frontend-data/sample/runs/index.json": { body: runIndexFixture },
      "/frontend-data/sample/runs/run-a.json": { body: runAFixture },
      "/frontend-data/sample/runs/run-b.json": { body: runBFixture },
    });

    render(<App />);

    await screen.findByText("Runs (2)");
    await screen.findByText("Behavioral Evidence");
    expect(screen.getByText("Unique failing signatures: 2")).toBeInTheDocument();
    expect(screen.getByText("Total failing occurrences: 7")).toBeInTheDocument();
    expect(screen.getByText(/tool_json_path:/)).toBeInTheDocument();
    expect(screen.getByText("Occurrences: 5")).toBeInTheDocument();

    const runList = screen.getByTestId("run-list");
    await within(runList).findByText("run-a");

    const user = userEvent.setup();
    await user.type(screen.getByRole("textbox", { name: "Search runs" }), "repo-b");

    expect(within(runList).queryByText("run-a")).not.toBeInTheDocument();
    expect(within(runList).getByText("run-b")).toBeInTheDocument();

    await user.clear(screen.getByRole("textbox", { name: "Search runs" }));

    const runBCell = within(runList).getByText("run-b");
    const row = runBCell.closest("tr");
    expect(row).not.toBeNull();

    if (row) {
      await user.click(row);
    }

    await waitFor(() => {
      expect(window.location.search).toContain("run=run-b");
    });

    await screen.findByText("No failing case details.");
  });

  it("shows empty state when no datasets exist", async () => {
    installFetchRoutes({
      "/frontend-data/datasets.json": { body: { datasets: [] } },
    });

    render(<App />);

    await screen.findByText("No datasets");
  });

  it("shows error state when datasets fetch fails", async () => {
    installFetchRoutes({
      "/frontend-data/datasets.json": { status: 500, body: { message: "nope" } },
    });

    render(<App />);

    await screen.findByText("Datasets failed to load");
  });
});
