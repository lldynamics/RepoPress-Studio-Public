import type { DraftVersionReason } from "../../contracts/repository";

export interface DraftDiffLine {
  kind: "context" | "added" | "removed";
  text: string;
  currentLine: number | null;
  historicalLine: number | null;
}

export interface DraftVersionComparison {
  addedCount: number;
  removedCount: number;
  unchangedCount: number;
  truncated: boolean;
  lines: DraftDiffLine[];
}

const REASON_LABELS: Record<DraftVersionReason, string> = {
  beforeSave: "保存前",
  beforeRestore: "恢复前",
  deleted: "删除前",
};

export function draftVersionReasonLabel(reason: string): string {
  return Object.prototype.hasOwnProperty.call(REASON_LABELS, reason)
    ? REASON_LABELS[reason as DraftVersionReason]
    : "未知版本";
}

export function formatDraftHistoryTime(epochSeconds: number): string {
  if (!Number.isFinite(epochSeconds)) return "时间未知";
  return new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short" }).format(new Date(epochSeconds * 1000));
}

export function formatDraftHistorySize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "大小未知";
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KiB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

const MAX_LINES = 400;
const MAX_BYTES = 128 * 1024;

function splitLines(text: string): string[] {
  return text.length ? text.replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n") : [];
}

export function compareDraftVersion(current: string, historical: string): DraftVersionComparison {
  const currentLines = splitLines(current);
  const historicalLines = splitLines(historical);
  const bytes = (value: string) => new TextEncoder().encode(value).byteLength;
  if (currentLines.length > MAX_LINES || historicalLines.length > MAX_LINES || bytes(current) > MAX_BYTES || bytes(historical) > MAX_BYTES) {
    return { addedCount: current === historical ? 0 : currentLines.length, removedCount: current === historical ? 0 : historicalLines.length, unchangedCount: current === historical ? currentLines.length : 0, truncated: true, lines: [] };
  }

  const dp: number[][] = Array.from({ length: historicalLines.length + 1 }, () => new Array<number>(currentLines.length + 1).fill(0));
  for (let h = historicalLines.length - 1; h >= 0; h -= 1) {
    for (let c = currentLines.length - 1; c >= 0; c -= 1) {
      dp[h][c] = historicalLines[h] === currentLines[c] ? dp[h + 1][c + 1] + 1 : Math.max(dp[h + 1][c], dp[h][c + 1]);
    }
  }
  const lines: DraftDiffLine[] = [];
  let h = 0; let c = 0; let addedCount = 0; let removedCount = 0; let unchangedCount = 0;
  while (h < historicalLines.length || c < currentLines.length) {
    if (h < historicalLines.length && c < currentLines.length && historicalLines[h] === currentLines[c]) {
      lines.push({ kind: "context", text: currentLines[c], currentLine: c + 1, historicalLine: h + 1 }); unchangedCount += 1; h += 1; c += 1;
    } else if (c < currentLines.length && (h >= historicalLines.length || dp[h][c + 1] >= dp[h + 1][c])) {
      lines.push({ kind: "added", text: currentLines[c], currentLine: c + 1, historicalLine: null }); addedCount += 1; c += 1;
    } else {
      lines.push({ kind: "removed", text: historicalLines[h], currentLine: null, historicalLine: h + 1 }); removedCount += 1; h += 1;
    }
  }
  return { addedCount, removedCount, unchangedCount, truncated: false, lines };
}
