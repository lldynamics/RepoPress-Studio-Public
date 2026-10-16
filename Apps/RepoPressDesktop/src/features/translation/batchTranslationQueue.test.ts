import { describe, expect, it } from "vitest";
import type { PlanTextTranslationRequest } from "../../contracts/repository";
import { DEFAULT_TRANSLATION_CONFIG } from "./translationConfig";
import {
  batchTranslationCounts,
  clampBatchTranslationConcurrency,
  clampBatchTranslationLimit,
  isHostedBatch,
  patchBatchItem,
  resolveBatchTranslationConfig,
  summarizeBatchDestinations,
  type BatchTranslationItem,
} from "./batchTranslationQueue";

const request = (provider: PlanTextTranslationRequest["provider"], endpoint = "http://local", model = ""): PlanTextTranslationRequest => ({ provider, endpoint, model, sourceLanguage: "en", targetLanguage: "zh", text: "hello" });
const item = (articleId: string, status: BatchTranslationItem["status"], provider: PlanTextTranslationRequest["provider"] = "libretranslate_local"): BatchTranslationItem => ({ articleId, feedId: "feed", title: articleId, request: request(provider), cacheKey: articleId, plan: null, status, error: null });

describe("batch translation queue model", () => {
  it("clamps limits and concurrency", () => {
    expect(clampBatchTranslationLimit(1)).toBe(1);
    expect(clampBatchTranslationLimit(20)).toBe(20);
    expect(clampBatchTranslationLimit(0)).toBe(10);
    expect(clampBatchTranslationLimit(21)).toBe(10);
    expect(clampBatchTranslationLimit(Number.NaN)).toBe(10);
    expect(clampBatchTranslationConcurrency(1)).toBe(1);
    expect(clampBatchTranslationConcurrency(3)).toBe(3);
    expect(clampBatchTranslationConcurrency(4)).toBe(2);
  });

  it("uses an isolated feed policy over global settings", () => {
    const global = { ...DEFAULT_TRANSLATION_CONFIG };
    const policy = { ...global, provider: "openai_compatible" as const, endpoint: "https://example.test", model: "model" };
    const policies = { feed: policy };
    const resolved = resolveBatchTranslationConfig("feed", global, policies);
    expect(resolved).toEqual(policy);
    expect(resolved).not.toBe(policy);
    expect(resolveBatchTranslationConfig("other", global, policies)).toEqual(global);
  });

  it("counts states and pending planning work", () => {
    const counts = batchTranslationCounts([item("a", "planning"), item("b", "planned"), item("c", "running"), item("d", "cached"), item("e", "succeeded"), item("f", "failed")]);
    expect(counts).toEqual({ total: 6, planned: 1, running: 1, succeeded: 1, cached: 1, failed: 1, pending: 1 });
  });

  it("summarizes only actionable destinations in stable order", () => {
    const items = [item("a", "succeeded", "openai_compatible"), item("b", "failed", "openai_compatible"), item("c", "planned", "libretranslate_local"), item("d", "cached", "ollama_local")];
    items[0].request.endpoint = "https://z";
    items[1].request.endpoint = "https://z";
    expect(summarizeBatchDestinations(items)).toEqual([
      { provider: "libretranslate_local", endpoint: "http://local", model: "", count: 1 },
      { provider: "openai_compatible", endpoint: "https://z", model: "", count: 2 },
    ]);
    expect(isHostedBatch(items)).toBe(true);
  });

  it("patches immutably and preserves unrelated items", () => {
    const original = [item("a", "planned"), item("b", "running")];
    const patched = patchBatchItem(original, "a", { status: "succeeded", error: null });
    expect(patched).not.toBe(original);
    expect(patched[0]).not.toBe(original[0]);
    expect(patched[1]).toBe(original[1]);
    expect(original[0].status).toBe("planned");
  });
});
