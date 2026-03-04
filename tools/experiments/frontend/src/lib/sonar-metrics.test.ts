import { describe, expect, it } from "vitest";

import {
  formatMetricDelta,
  formatMetricValue,
  formatRatingDelta,
  metricLabel,
  ratingDeltaClassName,
  ratingDeltaInfo,
  toRating,
} from "@/lib/sonar-metrics";

describe("sonar metric presentation", () => {
  it("maps internal metric keys to display labels", () => {
    expect(metricLabel("ncloc")).toBe("Lines of Code");
    expect(metricLabel("sqale_index")).toBe("Technical Debt");
    expect(metricLabel("sqale_rating")).toBe("Maintainability");
  });

  it("formats ratings as A-E", () => {
    expect(toRating("1.0")).toBe("A");
    expect(toRating(3)).toBe("C");
    expect(toRating("5.0")).toBe("E");
    expect(formatMetricValue("sqale_rating", "2.0")).toBe("B");
  });

  it("formats percentage metrics with percent suffix", () => {
    expect(formatMetricValue("coverage", "0.5")).toBe("0.5%");
    expect(formatMetricValue("duplicated_lines_density", 1)).toBe("1%");
    expect(formatMetricDelta("coverage", 0.25)).toBe("+0.25%");
    expect(formatMetricDelta("duplicated_lines_density", -1.2)).toBe("-1.2%");
  });

  it("formats technical debt values in minutes", () => {
    expect(formatMetricValue("sqale_index", "380")).toBe("380 min");
    expect(formatMetricDelta("sqale_index", -15)).toBe("-15 min");
  });

  it("describes rating delta as improvement/regression/similar", () => {
    expect(ratingDeltaInfo(-1)).toEqual({ trend: "improved", steps: 1 });
    expect(ratingDeltaInfo(2)).toEqual({ trend: "regressed", steps: 2 });
    expect(ratingDeltaInfo(0)).toEqual({ trend: "similar", steps: 0 });

    expect(formatRatingDelta(-1, "2.0", "1.0")).toBe("Improved 1 grade (B->A)");
    expect(formatRatingDelta(2, "1.0", "3.0")).toBe("Regressed 2 grades (A->C)");
    expect(formatRatingDelta(0, "1.0", "1.0")).toBe("Similar (A->A)");
  });

  it("uses stronger colors for larger rating shifts", () => {
    expect(ratingDeltaClassName(-1)).toContain("emerald-100");
    expect(ratingDeltaClassName(-2)).toContain("emerald-200");
    expect(ratingDeltaClassName(1)).toContain("orange-100");
    expect(ratingDeltaClassName(2)).toContain("red-200");
    expect(ratingDeltaClassName(0)).toContain("slate-100");
  });
});
