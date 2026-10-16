import { useEffect, useMemo, useRef, useState } from "react";
import type { PlanTextTranslationRequest, RepositoryGateway } from "../../contracts/repository";
import { useI18n } from "../../i18n/i18n";
import { rssTranslationMessages } from "../../i18n/rssTranslationMessages";
import { renderUiMessage, type UiMessage } from "../../i18n/uiMessage";
import type { RssFeed, RssGateway, RssScope } from "../rss/contracts";
import { rssArticlePlainText } from "../rss/rssReader";
import { DEFAULT_TRANSLATION_CONFIG, TRANSLATION_CONFIG_STORAGE_KEY, normalizeTranslationConfig } from "./translationConfig";
import { buildTranslationSessionCacheKey, TranslationSessionCache } from "./translationSessionCache";
import { normalizeFeedTranslationPolicies, normalizeTranslationGlossary, TRANSLATION_FEED_POLICIES_STORAGE_KEY, TRANSLATION_GLOSSARY_STORAGE_KEY } from "./translationQuality";
import { MAX_BATCH_TRANSLATION_ITEMS, batchTranslationCounts, clampBatchTranslationConcurrency, clampBatchTranslationLimit, isHostedBatch, patchBatchItem, resolveBatchTranslationConfig, summarizeBatchDestinations, type BatchTranslationItem, type BatchTranslationItemStatus, type BatchTranslationPhase } from "./batchTranslationQueue";

type TranslationGateway = Pick<RepositoryGateway, "planTextTranslation" | "executeTextTranslation">;

const LIMITS = [5, 10, 20] as const;
const CONCURRENCIES = [1, 2, 3] as const;

export interface RssBatchTranslationDialogProps {
  open: boolean;
  onOpen?: () => void;
  onClose: () => void;
  feeds: RssFeed[];
  rssGateway: Pick<RssGateway, "listArticles" | "getArticle">;
  translationGateway?: TranslationGateway;
  sessionCache: TranslationSessionCache;
  onCacheChange?: () => void;
  offlineTranslationGateway?: Pick<RssGateway, "getOfflineTranslation" | "saveOfflineTranslation">;
  offlineTranslationEnabled?: boolean;
  refreshEnqueue?: { id: number; feedId?: string };
}

/**
 * A deliberately session-only pretranslation queue. The component remains
 * mounted by its parent: hiding it only minimizes the view and never destroys
 * the planned request snapshots or work already in flight.
 */
export function RssBatchTranslationDialog({ open, onOpen, onClose, feeds, rssGateway, translationGateway, sessionCache, onCacheChange, offlineTranslationGateway, offlineTranslationEnabled = false, refreshEnqueue }: RssBatchTranslationDialogProps) {
  const { locale, t } = useI18n(rssTranslationMessages);
  const [scope, setScope] = useState<"all" | string>("all");
  const [limit, setLimit] = useState<(typeof LIMITS)[number]>(10);
  const [concurrency, setConcurrency] = useState<(typeof CONCURRENCIES)[number]>(2);
  const [items, setItems] = useState<BatchTranslationItem[]>([]);
  const [phase, setPhase] = useState<BatchTranslationPhase>("idle");
  const [message, setMessage] = useState<UiMessage | null>(null);
  const [localItemErrors, setLocalItemErrors] = useState<Record<string, UiMessage>>({});
  const [minimized, setMinimized] = useState(false);
  const generation = useRef(0);
  const itemsRef = useRef(items);
  const pauseRequested = useRef(false);
  const handledRefresh = useRef<number | null>(null);

  useEffect(() => { itemsRef.current = items; }, [items]);
  useEffect(() => { if (open) setMinimized(false); }, [open]);
  useEffect(() => () => { generation.current += 1; }, []);

  const counts = useMemo(() => batchTranslationCounts(items), [items]);
  const destinations = useMemo(() => summarizeBatchDestinations(items), [items]);
  const isVisible = open && !minimized;
  const sendingItems = items.filter((item) => item.status === "planned" || item.status === "running");
  const hasHostedDestination = isHostedBatch(sendingItems) && sendingItems.some((item) => isExternalHttpsEndpoint(item.request.endpoint));
  // Never mint another batch of plans while an existing plan is awaiting
  // confirmation or paused. Plans reserve server-side capacity until expiry.
  const canPrepare = Boolean(translationGateway) && (phase === "idle" || phase === "complete");

  function patchItem(articleId: string, patch: Partial<Omit<BatchTranslationItem, "articleId">>) {
    setItems((current) => patchBatchItem(current, articleId, patch));
  }

  function minimize() {
    setMinimized(true);
    onClose();
  }

  function restore() {
    setMinimized(false);
    onOpen?.();
  }

  async function prepare(onlyFailed = false, localOnly = false, refreshFeedId?: string) {
    if (!translationGateway) return;
    const currentGeneration = ++generation.current;
    pauseRequested.current = false;
    setPhase("preparing");
    setMessage(null);
    if (onlyFailed) setLocalItemErrors((current) => Object.fromEntries(Object.entries(current).filter(([articleId]) => !itemsRef.current.some((item) => item.articleId === articleId && item.status === "failed"))));
    else setLocalItemErrors({});

    let config = DEFAULT_TRANSLATION_CONFIG;
    let policies: ReturnType<typeof normalizeFeedTranslationPolicies> = {};
    let glossary: ReturnType<typeof normalizeTranslationGlossary> = [];
    try { config = normalizeTranslationConfig(JSON.parse(localStorage.getItem(TRANSLATION_CONFIG_STORAGE_KEY) ?? "{}")); } catch { /* default config is safe */ }
    try { policies = normalizeFeedTranslationPolicies(JSON.parse(localStorage.getItem(TRANSLATION_FEED_POLICIES_STORAGE_KEY) ?? "{}")); } catch { /* no policy is safe */ }
    try { glossary = normalizeTranslationGlossary(JSON.parse(localStorage.getItem(TRANSLATION_GLOSSARY_STORAGE_KEY) ?? "[]")); } catch { /* no glossary is safe */ }

    let candidates: Array<{ id: string; feedId: string; title: string }>;
    if (onlyFailed) {
      candidates = itemsRef.current.filter((item) => item.status === "failed").map(({ articleId: id, feedId, title }) => ({ id, feedId, title }));
      setItems((current) => current.map((item) => item.status === "failed" ? { ...item, status: "planning", plan: null, error: null } : item));
    } else {
      setItems([]);
      const requestScope: RssScope = refreshFeedId ? { feed: refreshFeedId } : scope === "all" ? "all" : { feed: scope };
      try {
        const page = await rssGateway.listArticles({ scope: requestScope, searchText: "", unreadOnly: true, author: null, tag: null, sort: "newest", offset: 0, limit });
        if (generation.current !== currentGeneration) return;
        candidates = page.articles.slice(0, MAX_BATCH_TRANSLATION_ITEMS).map(({ id, feedId, title }) => ({ id, feedId, title }));
      } catch (error) {
        if (generation.current === currentGeneration) { setPhase("idle"); setMessage(localError("无法读取未读文章：{message}", error)); }
        return;
      }
    }

    if (!candidates.length) {
      if (generation.current === currentGeneration) { setPhase("idle"); setMessage(localMessage(onlyFailed ? "没有失败项可重新生成计划。" : "没有符合条件的未读文章。")); }
      return;
    }

    const prepared: BatchTranslationItem[] = [];
    for (const candidate of candidates) {
      if (generation.current !== currentGeneration) return;
      const active = resolveBatchTranslationConfig(candidate.feedId, config, policies);
      const failedRequest: PlanTextTranslationRequest = {
        provider: active.provider,
        endpoint: active.endpoint,
        model: active.model,
        sourceLanguage: active.sourceLanguage,
        targetLanguage: active.targetLanguage,
        glossary,
        text: "",
      };
      try {
        const article = await rssGateway.getArticle(candidate.id);
        if (generation.current !== currentGeneration) return;
        if (!article) throw new LocalBatchError("文章已不可用");
        const text = rssArticlePlainText(article).trim();
        if (!text) throw new LocalBatchError("文章没有可翻译的正文");
        const request: PlanTextTranslationRequest = { ...failedRequest, text };
        if (localOnly && request.provider === "openai_compatible") continue;
        const cacheKey = buildTranslationSessionCacheKey({ articleId: article.id, scope: "article", request });
        if (sessionCache.get(cacheKey)) {
          prepared.push({ articleId: article.id, feedId: candidate.feedId, title: candidate.title, request, cacheKey, status: "cached", plan: null, error: null });
          continue;
        }
        if (offlineTranslationEnabled && offlineTranslationGateway) {
          const offline = await offlineTranslationGateway.getOfflineTranslation({ articleId: article.id, request });
          if (generation.current !== currentGeneration) return;
          if (offline) {
            sessionCache.set(cacheKey, offline);
            prepared.push({ articleId: article.id, feedId: candidate.feedId, title: candidate.title, request, cacheKey, status: "cached", plan: null, error: null });
            continue;
          }
        }
        const plan = await translationGateway.planTextTranslation(request);
        if (generation.current !== currentGeneration) return;
        prepared.push({ articleId: article.id, feedId: candidate.feedId, title: candidate.title, request, cacheKey, status: "planned", plan, error: null });
      } catch (error) {
        if (generation.current !== currentGeneration) return;
        const rawError = literalError(error);
        if (error instanceof LocalBatchError || !rawError) {
          const presentation = error instanceof LocalBatchError ? localMessage(error.source) : localMessage("服务没有返回可用的错误说明。");
          setLocalItemErrors((current) => ({ ...current, [candidate.id]: presentation }));
        }
        prepared.push({ articleId: candidate.id, feedId: candidate.feedId, title: candidate.title, request: failedRequest, cacheKey: "", status: "failed", plan: null, error: error instanceof LocalBatchError || !rawError ? null : rawError });
      }
      if (generation.current !== currentGeneration) return;
      if (onlyFailed) setItems((previous) => previous.map((item) => prepared.find((next) => next.articleId === item.articleId) ?? item));
      else setItems([...prepared]);
    }
    if (generation.current !== currentGeneration) return;
    setItems(onlyFailed ? (previous) => previous.map((item) => prepared.find((next) => next.articleId === item.articleId) ?? item) : prepared);
    const hasPlannedItems = prepared.some((item) => item.status === "planned");
    setPhase(hasPlannedItems ? "awaiting_confirmation" : "complete");
    setMessage(localMessage(hasPlannedItems
      ? localOnly ? "刷新后已生成仅本机服务的预翻译计划；仍需明确确认才会发送正文。" : "计划已生成；确认前不会发送文章内容。缓存命中的文章不会重新请求。"
      : prepared.some((item) => item.status === "cached")
        ? "所有文章均已在本次运行缓存中；没有新的翻译请求。"
        : "没有可确认的翻译计划；请查看失败项并重新生成计划。"
    ));
  }

  async function executeOne(item: BatchTranslationItem, currentGeneration: number) {
    if (!translationGateway || !item.plan) return;
    setLocalItemErrors((current) => {
      if (!Object.prototype.hasOwnProperty.call(current, item.articleId)) return current;
      const { [item.articleId]: _removed, ...rest } = current;
      return rest;
    });
    patchItem(item.articleId, { status: "running", error: null });
    try {
      const result = await translationGateway.executeTextTranslation({ ...item.request, planId: item.plan.planId });
      if (generation.current !== currentGeneration) return;
      sessionCache.set(item.cacheKey, result);
      if (offlineTranslationEnabled && offlineTranslationGateway) void offlineTranslationGateway.saveOfflineTranslation({ articleId: item.articleId, request: item.request, result }).catch(() => undefined);
      onCacheChange?.();
      patchItem(item.articleId, { status: "succeeded" });
    } catch (error) {
      if (generation.current !== currentGeneration) return;
      const rawError = literalError(error);
      if (!rawError) setLocalItemErrors((current) => ({ ...current, [item.articleId]: localMessage("服务没有返回可用的错误说明。") }));
      patchItem(item.articleId, { status: "failed", error: rawError });
    }
  }

  async function confirmAndStart() {
    if (!translationGateway || (phase !== "awaiting_confirmation" && phase !== "paused")) return;
    const currentGeneration = generation.current;
    pauseRequested.current = false;
    setPhase("running");
    const claimed = new Set<string>();
    const worker = async () => {
      while (generation.current === currentGeneration && !pauseRequested.current) {
        const next = itemsRef.current.find((item) => item.status === "planned" && !claimed.has(item.articleId));
        if (!next) return;
        claimed.add(next.articleId);
        await executeOne(next, currentGeneration);
      }
    };
    await Promise.all(Array.from({ length: clampBatchTranslationConcurrency(concurrency) }, worker));
    if (generation.current !== currentGeneration) return;
    setPhase(pauseRequested.current ? "paused" : "complete");
    if (!pauseRequested.current) setMessage(localMessage(offlineTranslationEnabled
      ? "批量翻译已完成。译文正在按偏好保存到离线译文库，原文未被修改。"
      : "批量翻译已完成。译文仅保留在本次运行缓存中，原文未被修改。"
    ));
  }

  function pause() {
    if (phase !== "running") return;
    pauseRequested.current = true;
    setPhase("pausing");
    setMessage(localMessage("暂停请求已记录；正在翻译的文章完成后将暂停。"));
  }

  function resume() {
    if (phase !== "paused") return;
    void confirmAndStart();
  }

  function clearRecord() {
    generation.current += 1;
    pauseRequested.current = false;
    setItems([]);
    setLocalItemErrors({});
    setMessage(null);
    setPhase("idle");
  }

  useEffect(() => {
    if (!refreshEnqueue || handledRefresh.current === refreshEnqueue.id || phase !== "idle") return;
    handledRefresh.current = refreshEnqueue.id;
    void prepare(false, true, refreshEnqueue.feedId);
  }, [refreshEnqueue?.id, phase]);

  const dialog = <section className="rss-modal rss-batch-translation" role="dialog" aria-modal="true" aria-label={t("批量预翻译")}>
    <header><div><h2>{t("批量预翻译")}</h2><p>{t("仅处理未读文章。先生成计划，确认后才会发送正文；译文不会在此展示或写回原文。")}</p></div><button type="button" aria-label={t("最小化批量预翻译")} onClick={minimize}>—</button></header>
    {!translationGateway && <p className="rss-translation-message">{t("当前环境未提供翻译服务。")}</p>}
    <div className="rss-batch-translation-controls">
      <label>{t("范围")}<select value={scope} onChange={(event) => setScope(event.target.value)} disabled={!canPrepare}><option value="all">{t("全部 Feed")}</option>{feeds.map((feed) => <option key={feed.id} value={feed.id}>{feed.title}</option>)}</select></label>
      <label>{t("未读文章")}<input value={t("仅未读")} readOnly aria-label={t("文章状态：仅未读")} /></label>
      <label>{t("数量")}<select value={limit} onChange={(event) => setLimit(clampBatchTranslationLimit(Number(event.target.value)) as (typeof LIMITS)[number])} disabled={!canPrepare}>{LIMITS.map((value) => <option key={value} value={value}>{t("{count} 篇", { count: formatNumber(value, locale) })}</option>)}</select></label>
      <label>{t("并发")}<select value={concurrency} onChange={(event) => setConcurrency(clampBatchTranslationConcurrency(Number(event.target.value)) as (typeof CONCURRENCIES)[number])} disabled={phase === "running"}>{CONCURRENCIES.map((value) => <option key={value} value={value}>{formatNumber(value, locale)}</option>)}</select></label>
    </div>
    {hasHostedDestination && <p className="rss-batch-translation-hosted-warning">{t("注意：此计划包含外部 HTTPS 托管 AI 服务。确认后，所列文章正文会发送到对应服务。")}</p>}
    {message && <p className="rss-translation-message" role="status">{renderUiMessage(message, t)}</p>}
    {destinations.length > 0 && <section className="rss-batch-translation-destinations" aria-label={t("翻译目的地")}><h3>{t("发送目的地")}</h3><ul>{destinations.map((destination) => <li key={`${destination.provider}|${destination.endpoint}|${destination.model}`}>{t(destination.model ? "{provider} · {endpoint} · {model}：{count} 篇" : "{provider} · {endpoint}：{count} 篇", { provider: t(providerLabel(destination.provider)), endpoint: destination.endpoint, model: destination.model, count: formatNumber(destination.count, locale) })}</li>)}</ul></section>}
    {items.length > 0 && <section className="rss-batch-translation-items" aria-label={t("文章计划")}><h3>{t("任务（{count} 篇）", { count: formatNumber(items.length, locale) })}</h3><ul>{items.map((item) => { const localItemError = localItemErrors[item.articleId]; const error = localItemError ? renderUiMessage(localItemError, t) : item.error; const status = t(statusLabel(item.status)); return <li key={item.articleId}><span>{item.title || t("未命名文章")}</span><small>{error ? t("{status}：{message}", { status, message: error }) : status}</small>{item.plan?.warnings.map((warning) => <em key={warning}>{t("计划提醒：{warning}", { warning })}</em>)}</li>; })}</ul></section>}
    <footer className="rss-modal-actions rss-batch-translation-actions">
      <span aria-live="polite">{t("已缓存 {cached} · 已计划 {planned} · 进行中 {running} · 完成 {succeeded} · 失败 {failed}", { cached: formatNumber(counts.cached, locale), planned: formatNumber(counts.planned, locale), running: formatNumber(counts.running, locale), succeeded: formatNumber(counts.succeeded, locale), failed: formatNumber(counts.failed, locale) })}</span>
      <button type="button" onClick={() => void prepare(false)} disabled={!canPrepare}>{t("准备计划")}</button>
      {phase === "awaiting_confirmation" && <button type="button" className="rss-translation-confirm" onClick={() => void confirmAndStart()} disabled={!items.some((item) => item.status === "planned")}>{t("确认并开始")}</button>}
      {phase === "running" && <button type="button" onClick={pause}>{t("暂停")}</button>}
      {phase === "paused" && <button type="button" onClick={resume}>{t("恢复{suffix}", { suffix: "" })}</button>}
      {items.some((item) => item.status === "failed") && ["awaiting_confirmation", "paused", "complete"].includes(phase) && <button type="button" onClick={() => void prepare(true)}>{t("为失败项重新生成计划")}</button>}
      {phase === "complete" && <button type="button" onClick={clearRecord}>{t("清空记录")}</button>}
    </footer>
  </section>;

  return <>{isVisible && <div className="rss-modal-backdrop rss-batch-translation-backdrop">{dialog}</div>}{!isVisible && phase !== "idle" && <button className="rss-batch-translation-minimized" type="button" onClick={restore}>{t("批量预翻译：{phase}（{count}）", { phase: t(phaseLabel(phase)), count: formatNumber(items.length, locale) })}</button>}</>;
}

class LocalBatchError extends Error {
  constructor(readonly source: string) { super(source); }
}
function literalError(error: unknown): string | null {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error && "message" in error && typeof error.message === "string") return error.message;
  return null;
}
function localMessage(source: string, parameters?: UiMessage["parameters"]): UiMessage {
  return { source, parameters };
}
function localError(source: string, error: unknown): UiMessage {
  const literal = literalError(error);
  return literal ? localMessage(source, { message: literal }) : { source, labels: { message: { source: "服务没有返回可用的错误说明。" } } };
}
function isExternalHttpsEndpoint(endpoint: string): boolean {
  try {
    const url = new URL(endpoint);
    return url.protocol === "https:" && !["localhost", "::1"].includes(url.hostname) && !/^127(?:\.\d{1,3}){3}$/.test(url.hostname);
  } catch { return false; }
}
function providerLabel(provider: PlanTextTranslationRequest["provider"]): string { return provider === "libretranslate_local" ? "本机 LibreTranslate" : provider === "ollama_local" ? "本机 Ollama" : "托管 OpenAI 兼容服务"; }
function statusLabel(status: BatchTranslationItemStatus): string { return ({ planning: "准备中", cached: "已缓存", planned: "已计划", running: "翻译中", succeeded: "已完成", failed: "失败" })[status]; }
function phaseLabel(phase: BatchTranslationPhase): string { return ({ idle: "空闲", preparing: "准备中", awaiting_confirmation: "等待确认", running: "运行中", pausing: "暂停中", paused: "已暂停", complete: "已完成" })[phase]; }
function formatNumber(value: number, locale: string): string { return new Intl.NumberFormat(locale).format(value); }
