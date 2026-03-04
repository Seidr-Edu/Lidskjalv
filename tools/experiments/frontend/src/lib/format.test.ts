import { describe, expect, it } from "vitest";

import { deltaTone, formatDelta, formatDuration, getStatusTone } from "@/lib/format";

describe("format helpers", () => {
  it("maps status tone correctly", () => {
    expect(getStatusTone("passed")).toBe("success");
    expect(getStatusTone("failed")).toBe("danger");
    expect(getStatusTone("completed_with_warnings")).toBe("warning");
    expect(getStatusTone("unknown")).toBe("neutral");
  });

  it("formats durations and deltas", () => {
    expect(formatDuration("2026-03-02T04:00:00Z", "2026-03-02T04:05:30Z")).toBe("5m 30s");
    expect(formatDelta(0)).toBe("0");
    expect(formatDelta(-2.3)).toBe("-2.30");
    expect(formatDelta(2)).toBe("+2");
  });

  it("computes delta tone with metric direction", () => {
    expect(deltaTone("bugs", -1)).toBe("success");
    expect(deltaTone("bugs", 1)).toBe("danger");
    expect(deltaTone("coverage", 4)).toBe("success");
    expect(deltaTone("coverage", -4)).toBe("danger");
    expect(deltaTone("custom_metric", 1)).toBe("neutral");
  });
});
