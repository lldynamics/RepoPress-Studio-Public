import type {
  PlanTextTranslationRequest,
  TextTranslationPlan,
  TextTranslationProvider,
} from "../../contracts/repository";
import type { TranslationConfig } from "./translationConfig";
import type { TranslationFeedPolicy } from "./translationQuality";

export const MAX_BATCH_TRANSLATION_ITEMS = 20;
const DEFAULT_BATCH_TRANSLATION_LIMIT = 10;
const DEFAULT_BATCH_TRANSLATION_CONCURRENCY = 2;

export type BatchTranslationItemStatus =
  | "planning"
  | "planned"
  | "running"
  | "cached"
  | "succeeded"
  | "failed";

export type BatchTranslationPhase =
  | "idle"
  | "preparing"
  | "awaiting_confirmation"
  | "running"
  | "pausing"
  | "paused"
  | "complete";

export interface BatchTranslationItem {
  articleId: string;
  feedId: string;
  title: string;
  request: PlanTextTranslationRequest;
  cacheKey: string;
  plan: TextTranslationPlan | null;
  status: BatchTranslationItemStatus;
  error: string | null;
}

export interface BatchTranslationCounts {
  total: number;
  planned: number;
  running: number;
  succeeded: number;
  cached: number;
  failed: number;
  pending: number;
}

export interface BatchTranslationDestinationSummary {
  provider: TextTranslationProvider;
  endpoint: string;
  model: string;
  count: number;
}

/** Coerce an item limit to the bounded queue limit, using the product default for invalid input. */
export function clampBatchTranslationLimit(value: number): number {
  return Number.isInteger(value) && value >= 1 && value <= MAX_BATCH_TRANSLATION_ITEMS
    ? value
    : DEFAULT_BATCH_TRANSLATION_LIMIT;
}

/** Coerce worker concurrency to the small bounded range supported by the queue. */
export function clampBatchTranslationConcurrency(value: number): number {
  return Number.isInteger(value) && value >= 1 && value <= 3
    ? value
    : DEFAULT_BATCH_TRANSLATION_CONCURRENCY;
}

/** Resolve a feed's settings without exposing either input object to mutation. */
export function resolveBatchTranslationConfig(
  feedId: string,
  globalConfig: TranslationConfig,
  feedPolicies: Readonly<Record<string, TranslationFeedPolicy>>,
): TranslationConfig {
  const selected = feedPolicies[feedId] ?? globalConfig;
  return { ...selected };
}

export function batchTranslationCounts(items: readonly BatchTranslationItem[]): BatchTranslationCounts {
  const counts: BatchTranslationCounts = {
    total: items.length,
    planned: 0,
    running: 0,
    succeeded: 0,
    cached: 0,
    failed: 0,
    pending: 0,
  };
  for (const item of items) {
    switch (item.status) {
      case "planned": counts.planned += 1; break;
      case "running": counts.running += 1; break;
      case "succeeded": counts.succeeded += 1; break;
      case "cached": counts.cached += 1; break;
      case "failed": counts.failed += 1; break;
      case "planning": counts.pending += 1; break;
    }
  }
  return counts;
}

/** Group active/terminal destinations in deterministic provider-endpoint-model order. */
export function summarizeBatchDestinations(
  items: readonly BatchTranslationItem[],
): BatchTranslationDestinationSummary[] {
  const grouped = new Map<string, BatchTranslationDestinationSummary>();
  for (const item of items) {
    if (!["planned", "running", "succeeded", "failed"].includes(item.status)) continue;
    const { provider, endpoint, model } = item.request;
    const key = JSON.stringify([provider, endpoint, model]);
    const existing = grouped.get(key);
    if (existing) existing.count += 1;
    else grouped.set(key, { provider, endpoint, model, count: 1 });
  }
  return [...grouped.values()].sort((a, b) =>
    a.provider.localeCompare(b.provider) || a.endpoint.localeCompare(b.endpoint) || a.model.localeCompare(b.model),
  );
}

export function patchBatchItem(
  items: readonly BatchTranslationItem[],
  articleId: string,
  patch: Partial<Omit<BatchTranslationItem, "articleId">>,
): BatchTranslationItem[] {
  return items.map((item) => item.articleId === articleId ? { ...item, ...patch } : item);
}

export function isHostedBatch(items: readonly BatchTranslationItem[]): boolean {
  return items.some((item) => item.request.provider === "openai_compatible");
}
