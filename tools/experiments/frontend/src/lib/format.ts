import type { SonarMetricKey } from "@/lib/types";

const LOWER_IS_BETTER: SonarMetricKey[] = [
  "bugs",
  "vulnerabilities",
  "code_smells",
  "duplicated_lines_density",
  "sqale_index",
  "ncloc",
];

const HIGHER_IS_BETTER: SonarMetricKey[] = ["coverage"];

export type StatusTone = "success" | "danger" | "warning" | "neutral";

export function formatDateTime(value?: string | null): string {
  if (!value) {
    return "—";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return date.toLocaleString();
}

export function durationSeconds(startedAt?: string | null, finishedAt?: string | null): number | null {
  if (!startedAt || !finishedAt) {
    return null;
  }

  const start = new Date(startedAt).getTime();
  const end = new Date(finishedAt).getTime();
  if (Number.isNaN(start) || Number.isNaN(end) || end < start) {
    return null;
  }

  return Math.floor((end - start) / 1000);
}

export function formatDuration(startedAt?: string | null, finishedAt?: string | null): string {
  const seconds = durationSeconds(startedAt, finishedAt);
  if (seconds === null) {
    return "—";
  }

  const mins = Math.floor(seconds / 60);
  const rem = seconds % 60;
  if (mins === 0) {
    return `${rem}s`;
  }
  return `${mins}m ${rem}s`;
}

export function getStatusTone(status?: string | null): StatusTone {
  const normalized = (status || "").toLowerCase();

  if (["passed", "pass", "completed"].includes(normalized)) {
    return "success";
  }

  if (["failed", "fail", "invalid", "error"].includes(normalized)) {
    return "danger";
  }

  if (["skipped", "inconclusive", "completed_with_warnings", "warning", "partial", "unavailable", "pending"].includes(normalized)) {
    return "warning";
  }

  return "neutral";
}

export function toNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  const num = typeof value === "number" ? value : Number(value);
  if (Number.isNaN(num)) {
    return null;
  }
  return num;
}

export function formatNumber(value: unknown): string {
  const numeric = toNumber(value);
  if (numeric === null) {
    return "—";
  }
  if (Number.isInteger(numeric)) {
    return String(numeric);
  }
  return numeric.toFixed(2);
}

export function metricDirection(metric: string): "higher" | "lower" | "neutral" {
  if (LOWER_IS_BETTER.includes(metric as SonarMetricKey)) {
    return "lower";
  }

  if (HIGHER_IS_BETTER.includes(metric as SonarMetricKey)) {
    return "higher";
  }

  return "neutral";
}

export function deltaTone(metric: string, delta: number | null): StatusTone {
  if (delta === null) {
    return "neutral";
  }

  const direction = metricDirection(metric);
  if (direction === "neutral" || delta === 0) {
    return "neutral";
  }

  if (direction === "lower") {
    return delta < 0 ? "success" : "danger";
  }

  return delta > 0 ? "success" : "danger";
}

export function formatDelta(value: number | null): string {
  if (value === null) {
    return "—";
  }

  const sign = value > 0 ? "+" : "";
  if (Number.isInteger(value)) {
    return `${sign}${value}`;
  }
  return `${sign}${value.toFixed(2)}`;
}

export function badgeVariantFromTone(tone: StatusTone): "default" | "success" | "destructive" | "warning" | "outline" {
  if (tone === "success") {
    return "success";
  }
  if (tone === "danger") {
    return "destructive";
  }
  if (tone === "warning") {
    return "warning";
  }
  return "outline";
}
