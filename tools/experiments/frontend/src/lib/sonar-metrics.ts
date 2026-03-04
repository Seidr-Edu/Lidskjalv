import { formatDelta, formatNumber, toNumber } from "@/lib/format";

export const SONAR_CORE_METRICS = [
  "bugs",
  "vulnerabilities",
  "code_smells",
  "coverage",
  "duplicated_lines_density",
  "reliability_rating",
  "security_rating",
  "sqale_rating",
  "ncloc",
  "sqale_index",
] as const;

const METRIC_LABELS: Record<string, string> = {
  bugs: "Bugs",
  vulnerabilities: "Vulnerabilities",
  code_smells: "Code Smells",
  coverage: "Coverage",
  duplicated_lines_density: "Duplication Density",
  ncloc: "Lines of Code",
  sqale_index: "Technical Debt",
  reliability_rating: "Reliability",
  security_rating: "Security",
  sqale_rating: "Maintainability",
};

const PERCENT_METRICS = new Set<string>(["coverage", "duplicated_lines_density"]);
const RATING_METRICS = new Set<string>(["reliability_rating", "security_rating", "sqale_rating"]);

export type SonarRating = "A" | "B" | "C" | "D" | "E";
export type RatingDeltaTrend = "improved" | "regressed" | "similar";

function formatDecimal(value: number): string {
  if (Number.isInteger(value)) {
    return String(value);
  }

  return value.toFixed(2).replace(/\.00$/, "").replace(/(\.\d)0$/, "$1");
}

export function metricLabel(metric: string): string {
  return METRIC_LABELS[metric] ?? metric.replace(/_/g, " ");
}

export function isRatingMetric(metric: string): boolean {
  return RATING_METRICS.has(metric);
}

export function toRating(value: unknown): SonarRating | null {
  const numeric = toNumber(value);
  if (numeric === null) {
    return null;
  }

  const rounded = Math.round(numeric);
  if (rounded < 1 || rounded > 5) {
    return null;
  }

  return (["A", "B", "C", "D", "E"] as const)[rounded - 1] ?? null;
}

export function ratingClassName(rating: SonarRating | null): string {
  switch (rating) {
    case "A":
      return "border-emerald-300 bg-emerald-100 text-emerald-800";
    case "B":
      return "border-lime-300 bg-lime-100 text-lime-800";
    case "C":
      return "border-amber-300 bg-amber-100 text-amber-900";
    case "D":
      return "border-orange-300 bg-orange-100 text-orange-900";
    case "E":
      return "border-red-300 bg-red-100 text-red-800";
    default:
      return "";
  }
}

export function ratingDeltaInfo(delta: number | null): { trend: RatingDeltaTrend; steps: number } | null {
  if (delta === null) {
    return null;
  }

  const roundedDelta = Math.round(delta);
  if (roundedDelta === 0) {
    return { trend: "similar", steps: 0 };
  }

  if (roundedDelta < 0) {
    return { trend: "improved", steps: Math.abs(roundedDelta) };
  }

  return { trend: "regressed", steps: roundedDelta };
}

export function ratingDeltaClassName(delta: number | null): string {
  const info = ratingDeltaInfo(delta);
  if (!info) {
    return "";
  }

  if (info.trend === "similar") {
    return "border-slate-300 bg-slate-100 text-slate-800";
  }

  if (info.trend === "improved") {
    return info.steps >= 2
      ? "border-emerald-400 bg-emerald-200 text-emerald-900"
      : "border-emerald-300 bg-emerald-100 text-emerald-800";
  }

  return info.steps >= 2 ? "border-red-400 bg-red-200 text-red-900" : "border-orange-300 bg-orange-100 text-orange-900";
}

export function formatRatingDelta(delta: number | null, originalValue: unknown, generatedValue: unknown): string {
  const info = ratingDeltaInfo(delta);
  if (!info) {
    return "—";
  }

  const fromRating = toRating(originalValue);
  const toRatingValue = toRating(generatedValue);
  const transition = fromRating && toRatingValue ? ` (${fromRating}->${toRatingValue})` : "";

  if (info.trend === "similar") {
    return `Similar${transition}`;
  }

  const verb = info.trend === "improved" ? "Improved" : "Regressed";
  const unit = info.steps === 1 ? "grade" : "grades";
  return `${verb} ${info.steps} ${unit}${transition}`;
}

export function formatMetricValue(metric: string, value: unknown): string {
  if (isRatingMetric(metric)) {
    return toRating(value) ?? "—";
  }

  const numeric = toNumber(value);
  if (numeric === null) {
    return formatNumber(value);
  }

  if (PERCENT_METRICS.has(metric)) {
    return `${formatDecimal(numeric)}%`;
  }

  if (metric === "sqale_index") {
    return `${formatDecimal(numeric)} min`;
  }

  return formatDecimal(numeric);
}

export function formatMetricDelta(metric: string, value: number | null): string {
  if (value === null) {
    return "—";
  }

  if (PERCENT_METRICS.has(metric)) {
    const sign = value > 0 ? "+" : "";
    return `${sign}${formatDecimal(value)}%`;
  }

  if (metric === "sqale_index") {
    const sign = value > 0 ? "+" : "";
    return `${sign}${formatDecimal(value)} min`;
  }

  return formatDelta(value);
}
