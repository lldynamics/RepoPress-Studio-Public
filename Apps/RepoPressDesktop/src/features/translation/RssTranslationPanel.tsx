import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AiCredentialStatusSnapshot, PlanStructuredTextTranslationRequest, PlanTextTranslationRequest, RepositoryGateway, StructuredTextTranslationPlan, StructuredTextTranslationResult, TextTranslationPlan, TextTranslationProvider, TextTranslationResult } from "../../contracts/repository";
import { useI18n, type UiTranslator } from "../../i18n/i18n";
import { rssTranslationMessages } from "../../i18n/rssTranslationMessages";
import { renderUiMessage, type UiMessage } from "../../i18n/uiMessage";
import type { RssGateway } from "../rss/contracts";
import { DEFAULT_TRANSLATION_CONFIG, TRANSLATION_CONFIG_STORAGE_KEY, defaultsForTranslationProvider, normalizeTranslationConfig, textByteSize, translationNeedsModel, type TranslationConfig } from "./translationConfig";
import { buildTranslationSessionCacheKey, TranslationSessionCache, type RssTranslationScope } from "./translationSessionCache";
import { TRANSLATION_FEED_POLICIES_STORAGE_KEY, TRANSLATION_GLOSSARY_STORAGE_KEY, nextTranslationProvider, normalizeFeedTranslationPolicies, parseTranslationGlossary, stringifyTranslationGlossary, type TranslationFeedPolicy, type TranslationStrategy } from "./translationQuality";
import { buildStructuredHtmlTranslationPlan, decodeStructuredTextTranslationResult, encodeStructuredTextTranslationResult } from "./structuredHtmlTranslation";

type TranslationGateway = Pick<RepositoryGateway, "planTextTranslation" | "executeTextTranslation" | "aiCredentialStatus" | "storeAiCredential" | "deleteAiCredential">
  & Partial<Pick<RepositoryGateway, "planStructuredTextTranslation" | "executeStructuredTextTranslation">>;
type BusyState = "credential" | "plan" | "execute" | null;

const TARGET_LANGUAGES = [
  ["zh", "简体中文"], ["zt", "繁體中文"], ["en", "English"], ["ja", "日本語"], ["ko", "한국어"],
] as const;
const SOURCE_LANGUAGES = [["auto", "自动检测"], ...TARGET_LANGUAGES] as const;
const MAX_TRANSLATION_BYTES = 64 * 1024;
const MAX_STRUCTURED_SOURCE_BYTES = 60 * 1024;

export interface RssTranslationPanelProps {
  articleId: string;
  articleTitle?: string;
  articleHtml?: string;
  feedId?: string;
  feedTitle?: string;
  articleText: string;
  selectionText: string;
  gateway?: TranslationGateway;
  activation?: { id: number; scope: RssTranslationScope };
  sessionCache?: TranslationSessionCache;
  offlineTranslationGateway?: Pick<RssGateway, "getOfflineTranslation" | "saveOfflineTranslation" | "deleteOfflineTranslation">;
  offlineTranslationEnabled?: boolean;
  /**
   * Advances when a sibling workflow writes to the shared session cache. The
   * cache itself is intentionally mutable, so this revision makes that write
   * visible to a mounted panel without changing its request or plan state.
   */
  cacheRevision?: number;
  articleTranslationVisible?: boolean;
  onArticleTranslationChange?: (result: TextTranslationResult | null, requestKey: string) => void;
  onToggleArticleTranslation?: () => void;
  onTranslationResultChange?: (change: RssTranslationResultChange) => void;
}

export interface RssTranslationResultChange {
  scope: RssTranslationScope;
  sourceText: string;
  requestKey: string;
  result: TextTranslationResult | null;
}

export function RssTranslationPanel({ articleId, articleTitle = "", articleHtml = "", feedId, feedTitle, articleText, selectionText, gateway, activation, sessionCache, offlineTranslationGateway, offlineTranslationEnabled = false, cacheRevision = 0, articleTranslationVisible = false, onArticleTranslationChange, onToggleArticleTranslation, onTranslationResultChange }: RssTranslationPanelProps) {
  const { locale, t } = useI18n(rssTranslationMessages);
  const [config, setConfig] = useState<TranslationConfig>(() => {
    try { return normalizeTranslationConfig(JSON.parse(localStorage.getItem(TRANSLATION_CONFIG_STORAGE_KEY) ?? "{}")); }
    catch { return DEFAULT_TRANSLATION_CONFIG; }
  });
  const [feedPolicies, setFeedPolicies] = useState<Record<string, TranslationFeedPolicy>>(() => {
    try { return normalizeFeedTranslationPolicies(JSON.parse(localStorage.getItem(TRANSLATION_FEED_POLICIES_STORAGE_KEY) ?? "{}")); }
    catch { return {}; }
  });
  const [glossaryText, setGlossaryText] = useState(() => {
    try { return stringifyTranslationGlossary(JSON.parse(localStorage.getItem(TRANSLATION_GLOSSARY_STORAGE_KEY) ?? "[]")); }
    catch { return ""; }
  });
  const [token, setToken] = useState("");
  const [credential, setCredential] = useState<AiCredentialStatusSnapshot | null>(null);
  const [plan, setPlan] = useState<TextTranslationPlan | StructuredTextTranslationPlan | null>(null);
  const [planRequestKey, setPlanRequestKey] = useState<string | null>(null);
  const [result, setResult] = useState<TextTranslationResult | null>(null);
  const [resultCacheKey, setResultCacheKey] = useState<string | null>(null);
  const [busy, setBusy] = useState<BusyState>(null);
  const [message, setMessage] = useState<UiMessage | null>(null);
  const [failedProvider, setFailedProvider] = useState<TextTranslationProvider | null>(null);
  const [scope, setScope] = useState<RssTranslationScope>("article");
  const generation = useRef(0);
  const internalSessionCache = useRef(new TranslationSessionCache(32));
  const panelRef = useRef<HTMLElement>(null);
  const scopeControlRef = useRef<HTMLSelectElement>(null);
  const handledActivationId = useRef<number | null>(null);
  const articleTranslationChangeRef = useRef(onArticleTranslationChange);
  const translationResultChangeRef = useRef(onTranslationResultChange);
  const cache = sessionCache ?? internalSessionCache.current;
  const feedPolicy = feedId ? feedPolicies[feedId] : undefined;
  const active = feedPolicy ?? config;
  const parsedGlossary = useMemo(() => parseTranslationGlossary(glossaryText), [glossaryText]);
  const selectedText = selectionText.trim();
  const hasSelection = Boolean(selectedText);
  const structuredArticlePlan = useMemo(() => buildStructuredHtmlTranslationPlan({ title: articleTitle, html: articleHtml, maxTextBytes: MAX_STRUCTURED_SOURCE_BYTES }), [articleHtml, articleTitle]);
  const structuredArticleAvailable = Boolean(gateway?.planStructuredTextTranslation && gateway.executeStructuredTextTranslation && structuredArticlePlan.segments.length);
  const structuredArticleSource = useMemo(() => structuredCacheSource(structuredArticlePlan.segments), [structuredArticlePlan]);
  const text = scope === "selection" ? selectedText : structuredArticleAvailable ? structuredArticleSource : articleText.trim();
  const textBytes = textByteSize(text);
  const modelRequired = translationNeedsModel(active.provider);
  const providerNote = t(providerHelp(active.provider));
  const request = useMemo<PlanTextTranslationRequest>(() => ({ provider: active.provider, endpoint: active.endpoint.trim(), model: active.model.trim(), sourceLanguage: active.sourceLanguage, targetLanguage: active.targetLanguage, glossary: parsedGlossary.entries, text }), [active.provider, active.endpoint, active.model, active.sourceLanguage, active.targetLanguage, parsedGlossary.entries, text]);
  const structuredRequest = useMemo<PlanStructuredTextTranslationRequest>(() => ({ provider: active.provider, endpoint: active.endpoint.trim(), model: active.model.trim(), sourceLanguage: active.sourceLanguage, targetLanguage: active.targetLanguage, glossary: parsedGlossary.entries, segments: structuredArticlePlan.segments }), [active.endpoint, active.model, active.provider, active.sourceLanguage, active.targetLanguage, parsedGlossary.entries, structuredArticlePlan]);
  const reviewedTextBytes = scope === "article" && structuredArticleAvailable ? structuredArticlePlan.sourceTextBytes : textBytes;
  const cacheKey = useMemo(() => buildTranslationSessionCacheKey({ articleId, scope, request }), [articleId, scope, request]);
  // Article display deliberately has its own request and cache key. A live
  // selection must never hide, replace, or accidentally republish it.
  const articleRequest = useMemo<PlanTextTranslationRequest>(() => ({ provider: active.provider, endpoint: active.endpoint.trim(), model: active.model.trim(), sourceLanguage: active.sourceLanguage, targetLanguage: active.targetLanguage, glossary: parsedGlossary.entries, text: structuredArticleAvailable ? structuredArticleSource : articleText.trim() }), [articleId, articleText, active.provider, active.endpoint, active.model, active.sourceLanguage, active.targetLanguage, parsedGlossary.entries, structuredArticleAvailable, structuredArticleSource]);
  const legacyArticleRequest = useMemo<PlanTextTranslationRequest>(() => ({ ...articleRequest, text: articleText.trim() }), [articleRequest, articleText]);
  const articleCacheKey = useMemo(() => buildTranslationSessionCacheKey({ articleId, scope: "article", request: articleRequest }), [articleId, articleRequest]);
  const legacyArticleCacheKey = useMemo(() => buildTranslationSessionCacheKey({ articleId, scope: "article", request: legacyArticleRequest }), [articleId, legacyArticleRequest]);
  const requestKey = useMemo(() => JSON.stringify({ scope, request: scope === "article" && structuredArticleAvailable ? structuredRequest : request }), [request, scope, structuredArticleAvailable, structuredRequest]);
  // Effects clear and restore state after render. Never briefly render a
  // previous article/configuration's result while that transition is pending.
  const resultMatchesCurrentKey = resultCacheKey === cacheKey || (scope === "article" && resultCacheKey === legacyArticleCacheKey);
  const resultForCurrentKey = result && resultMatchesCurrentKey ? result : null;
  const canPlan = Boolean(gateway && !resultForCurrentKey && text && active.endpoint.trim() && (!modelRequired || active.model.trim()) && reviewedTextBytes <= MAX_TRANSLATION_BYTES && (scope !== "article" || !structuredArticleAvailable || structuredArticlePlan.segments.length));
  const currentPlanIsValid = Boolean(plan && planRequestKey === requestKey && !isPlanExpired(plan));
  const fallbackProvider = failedProvider === active.provider ? nextTranslationProvider(active.provider, active.strategy) : null;

  useEffect(() => {
    try { localStorage.setItem(TRANSLATION_CONFIG_STORAGE_KEY, JSON.stringify(config)); } catch { /* saved settings are only a convenience */ }
  }, [config]);

  useEffect(() => {
    try { localStorage.setItem(TRANSLATION_FEED_POLICIES_STORAGE_KEY, JSON.stringify(feedPolicies)); } catch { /* saved settings are only a convenience */ }
  }, [feedPolicies]);

  useEffect(() => {
    try { localStorage.setItem(TRANSLATION_GLOSSARY_STORAGE_KEY, JSON.stringify(parsedGlossary.entries)); } catch { /* saved settings are only a convenience */ }
  }, [parsedGlossary.entries]);

  // Keep the latest callback without making cache publication depend on its
  // identity; parent readers commonly provide an inline state setter.
  useLayoutEffect(() => { articleTranslationChangeRef.current = onArticleTranslationChange; }, [onArticleTranslationChange]);
  useLayoutEffect(() => { translationResultChangeRef.current = onTranslationResultChange; }, [onTranslationResultChange]);

  // Publish or clear the reader copy before the browser paints so changing a
  // provider, target language, article, or body cannot flash a stale result.
  useLayoutEffect(() => {
    const current = cache.get(articleCacheKey);
    const legacy = current || articleCacheKey === legacyArticleCacheKey ? null : cache.get(legacyArticleCacheKey);
    articleTranslationChangeRef.current?.(current ?? legacy, current ? articleCacheKey : legacy ? legacyArticleCacheKey : articleCacheKey);
  }, [cache, articleCacheKey, legacyArticleCacheKey, cacheRevision]);

  // A plan is a snapshot of article, selection, and endpoint settings. Any one
  // of these changing means it is no longer safe to send the old request.
  useLayoutEffect(() => {
    generation.current += 1;
    setPlan(null);
    setPlanRequestKey(null);
    setResult(null);
    setResultCacheKey(null);
    setMessage(null);
    setFailedProvider(null);
    setBusy(null);
  }, [articleId, scope, text, active.provider, active.endpoint, active.model, active.sourceLanguage, active.targetLanguage, active.strategy, parsedGlossary.entries]);

  useEffect(() => {
    const primary = cache.get(cacheKey);
    const legacy = primary || scope !== "article" || cacheKey === legacyArticleCacheKey ? null : cache.get(legacyArticleCacheKey);
    const cached = primary ?? legacy;
    if (!cached) return;
    setResult(cached);
    const restoredKey = primary ? cacheKey : legacyArticleCacheKey;
    setResultCacheKey(restoredKey);
    setMessage(localMessage(legacy ? "已从兼容纯文本缓存恢复译文；可重新翻译以保留标题与正文结构。" : "已从本次运行缓存恢复译文；不会重新发送内容。"));
    translationResultChangeRef.current?.({ scope, sourceText: text, requestKey: restoredKey, result: cached });
  }, [cache, cacheKey, cacheRevision, legacyArticleCacheKey, scope, text]);

  // Persistent records are opt-in and whole-article only. Selection text is
  // deliberately never sent to, read from, or deleted from disk.
  useEffect(() => {
    if (scope !== "article" || !offlineTranslationEnabled || !offlineTranslationGateway || cache.get(cacheKey) || (cacheKey !== legacyArticleCacheKey && cache.get(legacyArticleCacheKey))) return;
    const current = generation.current;
    let cancelled = false;
    void (async () => {
      const primary = await offlineTranslationGateway.getOfflineTranslation({ articleId, request: articleRequest });
      if (primary || articleCacheKey === legacyArticleCacheKey) return { record: primary, restoredKey: articleCacheKey };
      const legacy = await offlineTranslationGateway.getOfflineTranslation({ articleId, request: legacyArticleRequest });
      return { record: legacy, restoredKey: legacyArticleCacheKey };
    })().then(({ record, restoredKey }) => {
      if (cancelled || current !== generation.current || !record) return;
      cache.set(restoredKey, record);
      setResult(record); setResultCacheKey(restoredKey);
      articleTranslationChangeRef.current?.(record, restoredKey);
      translationResultChangeRef.current?.({ scope: "article", sourceText: text, requestKey: restoredKey, result: record });
      setMessage(localMessage(restoredKey === legacyArticleCacheKey && restoredKey !== articleCacheKey ? "已从兼容纯文本离线缓存恢复；可重新翻译以保留标题与正文结构。" : "已从离线译文缓存恢复；不会重新发送内容。"));
    }).catch(() => undefined);
    return () => { cancelled = true; };
  }, [articleCacheKey, articleId, articleRequest, cache, cacheKey, legacyArticleCacheKey, legacyArticleRequest, offlineTranslationEnabled, offlineTranslationGateway, scope, text]);

  useEffect(() => {
    if (!activation || handledActivationId.current === activation.id) return;
    handledActivationId.current = activation.id;
    setScope(activation.scope === "selection" && !hasSelection ? "article" : activation.scope);
    window.requestAnimationFrame(() => {
      panelRef.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
      scopeControlRef.current?.focus();
    });
  }, [activation?.id]);

  useEffect(() => {
    if (scope === "selection" && !hasSelection) setScope("article");
  }, [scope, hasSelection]);

  useEffect(() => {
    setCredential(null);
    setToken("");
  }, [active.provider, active.endpoint, active.model]);

  function updateActive(update: (current: TranslationFeedPolicy) => TranslationFeedPolicy) {
    if (feedId && feedPolicy) {
      setFeedPolicies((current) => ({ ...current, [feedId]: update(current[feedId] ?? feedPolicy) }));
      return;
    }
    setConfig((current) => {
      const next = update(current);
      return { provider: next.provider, endpoint: next.endpoint, model: next.model, sourceLanguage: next.sourceLanguage, targetLanguage: next.targetLanguage, strategy: next.strategy };
    });
  }

  function changeProvider(provider: TextTranslationProvider) {
    const defaults = defaultsForTranslationProvider(provider);
    updateActive((current) => ({ ...current, provider, ...defaults, strategy: "manual" }));
  }

  function changeStrategy(strategy: TranslationStrategy) {
    const preferred = strategy === "local_first" ? "libretranslate_local" : strategy === "ai_first" ? "openai_compatible" : active.provider;
    const defaults = strategy === "manual" ? {} : defaultsForTranslationProvider(preferred);
    updateActive((current) => ({ ...current, ...defaults, provider: preferred, strategy }));
  }

  function toggleFeedPolicy(enabled: boolean) {
    if (!feedId) return;
    setFeedPolicies((current) => {
      if (!enabled) {
        const { [feedId]: _removed, ...rest } = current;
        return rest;
      }
      return { ...current, [feedId]: { ...config } };
    });
  }

  async function inspectCredential() {
    if (!gateway || active.provider !== "openai_compatible" || !request.endpoint || !request.model) return;
    const current = generation.current;
    setBusy("credential"); setMessage(null);
    try {
      const next = await gateway.aiCredentialStatus({ provider: "openai_compatible", endpoint: request.endpoint, model: request.model });
      if (current === generation.current) setCredential(next);
    } catch (error) { if (current === generation.current) setMessage(localError("无法检查托管 AI 凭据：{message}", error)); }
    finally { if (current === generation.current) setBusy(null); }
  }

  async function saveCredential() {
    if (!gateway || active.provider !== "openai_compatible" || !token || !request.endpoint || !request.model) return;
    const current = generation.current;
    const pendingToken = token;
    // Clear React state before the async credential call so a later render never retains it.
    setToken(""); setBusy("credential"); setMessage(null);
    try {
      const next = await gateway.storeAiCredential({ provider: "openai_compatible", endpoint: request.endpoint, model: request.model, token: pendingToken });
      if (current === generation.current) { setCredential(next); setMessage(localMessage(next.sessionOnly ? "凭据只保留到本次应用退出。" : "凭据已保存到系统密钥环。")); }
    } catch (error) { if (current === generation.current) setMessage(localError("无法保存托管 AI 凭据：{message}", error)); }
    finally { if (current === generation.current) setBusy(null); }
  }

  async function deleteCredential() {
    if (!gateway || active.provider !== "openai_compatible" || !credential?.configured || !window.confirm(t("删除此托管 AI 服务的凭据？"))) return;
    const current = generation.current;
    setToken(""); setBusy("credential"); setMessage(null);
    try {
      const next = await gateway.deleteAiCredential({ provider: "openai_compatible", endpoint: request.endpoint, model: request.model });
      if (current === generation.current) { setCredential(next); setMessage(localMessage("托管 AI 凭据已删除。")); }
    } catch (error) { if (current === generation.current) setMessage(localError("无法删除托管 AI 凭据：{message}", error)); }
    finally { if (current === generation.current) setBusy(null); }
  }

  async function createPlan() {
    if (!gateway || !canPlan) return;
    const current = generation.current;
    setBusy("plan"); setPlan(null); setResult(null); setMessage(null);
    try {
      const next = scope === "article" && structuredArticleAvailable
        ? await gateway.planStructuredTextTranslation!(structuredRequest)
        : await gateway.planTextTranslation(request);
      if (current === generation.current) { setPlan(next); setPlanRequestKey(requestKey); setMessage(localMessage("翻译计划已生成；确认前不会发送文章内容。")); }
    } catch (error) { if (current === generation.current) setMessage(localError("无法生成翻译计划：{message}", error)); }
    finally { if (current === generation.current) setBusy(null); }
  }

  async function executePlan() {
    if (!gateway || !plan || !currentPlanIsValid) return;
    const current = generation.current;
    const approvedPlan = plan;
    setPlan(null); setPlanRequestKey(null); setBusy("execute"); setMessage(null);
    try {
      let next: TextTranslationResult;
      if (scope === "article" && structuredArticleAvailable) {
        const structured = await gateway.executeStructuredTextTranslation!({ ...structuredRequest, planId: approvedPlan.planId });
        next = structuredResultAsCachedText(structured);
      } else {
        next = await gateway.executeTextTranslation({ ...request, planId: approvedPlan.planId });
      }
      if (current === generation.current) {
        cache.set(cacheKey, next);
        if (scope === "article" && offlineTranslationEnabled && offlineTranslationGateway) {
          void offlineTranslationGateway.saveOfflineTranslation({ articleId, request, result: next }).catch(() => undefined);
        }
        setResult(next);
        setResultCacheKey(cacheKey);
        if (scope === "article") articleTranslationChangeRef.current?.(next, cacheKey);
        translationResultChangeRef.current?.({ scope, sourceText: text, requestKey: cacheKey, result: next });
        setMessage(localMessage(scope === "article" && offlineTranslationEnabled ? "翻译完成。译文是只读副本，原文未被修改；正在尽力保存离线副本。" : "翻译完成。译文是只读副本，原文未被修改。已保留在本次运行缓存中。"));
      }
    } catch (error) { if (current === generation.current) { setFailedProvider(active.provider); setMessage(localError("翻译请求失败：{message}", error)); } }
    finally { if (current === generation.current) setBusy(null); }
  }

  async function copyResult() {
    if (!resultForCurrentKey) return;
    try { await navigator.clipboard.writeText(displayTranslationText(resultForCurrentKey)); setMessage(localMessage("译文已复制到剪贴板。")); }
    catch { setMessage(localMessage("无法访问剪贴板；请在译文框中手动复制。")); }
  }

  function clearCurrentTranslation() {
    cache.delete(cacheKey);
    if (scope === "article") cache.delete(legacyArticleCacheKey);
    if (scope === "article" && offlineTranslationEnabled && offlineTranslationGateway) {
      void offlineTranslationGateway.deleteOfflineTranslation({ articleId, request: articleRequest }).catch(() => undefined);
      if (articleCacheKey !== legacyArticleCacheKey) void offlineTranslationGateway.deleteOfflineTranslation({ articleId, request: legacyArticleRequest }).catch(() => undefined);
    }
    setPlan(null);
    setPlanRequestKey(null);
    setResult(null);
    setResultCacheKey(null);
    if (scope === "article") articleTranslationChangeRef.current?.(null, cacheKey);
    translationResultChangeRef.current?.({ scope, sourceText: text, requestKey: cacheKey, result: null });
    setMessage(localMessage("已清除此译文；原文未受影响。"));
  }

  function switchToFallback() {
    if (!fallbackProvider) return;
    const defaults = defaultsForTranslationProvider(fallbackProvider);
    updateActive((current) => ({ ...current, provider: fallbackProvider, ...defaults }));
    setFailedProvider(null);
    setMessage({ source: "已切换到{provider}。请重新生成并确认翻译计划；尚未发送任何内容。", labels: { provider: { source: providerLabel(fallbackProvider) } } });
  }

  return <section className="rss-translation" aria-label={t("文章翻译")} ref={panelRef}>
    <header><h3>{t("翻译")}</h3><p>{t("先查看发送计划，再确认执行；译文不会覆盖原文。")}</p></header>
    {!gateway && <p className="rss-translation-message">{t("当前环境未提供翻译服务。")}</p>}
    <label>{t("翻译范围")}<select ref={scopeControlRef} value={scope} onChange={(event) => setScope(event.target.value as RssTranslationScope)} disabled={busy !== null}><option value="article">{t("整篇文章")}</option><option value="selection" disabled={!hasSelection}>{t(hasSelection ? "当前选区" : "当前选区（请先选中文字）")}</option></select></label>
    {feedId && <label className="rss-translation-feed-policy"><input type="checkbox" checked={Boolean(feedPolicy)} onChange={(event) => toggleFeedPolicy(event.target.checked)} disabled={busy !== null} /> {feedTitle ? t("为此 Feed（{title}）记住翻译策略", { title: feedTitle }) : t("为此 Feed 记住翻译策略")}</label>}
    <div className="rss-translation-grid">
      <label>{t("引擎策略")}<select value={active.strategy} onChange={(event) => changeStrategy(event.target.value as TranslationStrategy)} disabled={busy !== null}><option value="manual">{t("手动选择")}</option><option value="local_first">{t("本机优先")}</option><option value="ai_first">{t("AI 优先")}</option></select></label>
      <label>{t("方式")}<select value={active.provider} onChange={(event) => changeProvider(event.target.value as TextTranslationProvider)} disabled={busy !== null}><option value="libretranslate_local">{t("本机 LibreTranslate")}</option><option value="ollama_local">{t("本机 Ollama")}</option><option value="openai_compatible">{t("托管 OpenAI 兼容服务")}</option></select></label>
      <label>{t("来源语言")}<select value={active.sourceLanguage} onChange={(event) => updateActive((current) => ({ ...current, sourceLanguage: event.target.value }))} disabled={busy !== null}>{SOURCE_LANGUAGES.map(([value, label]) => <option key={value} value={value}>{t(label)}</option>)}</select></label>
      <label>{t("目标语言")}<select value={active.targetLanguage} onChange={(event) => updateActive((current) => ({ ...current, targetLanguage: event.target.value }))} disabled={busy !== null}>{TARGET_LANGUAGES.map(([value, label]) => <option key={value} value={value}>{t(label)}</option>)}</select></label>
      <label className="rss-translation-wide">{t("端点")}<input value={active.endpoint} onChange={(event) => updateActive((current) => ({ ...current, endpoint: event.target.value }))} disabled={busy !== null} spellCheck={false} /></label>
      <label>{t("模型")}<input value={active.model} onChange={(event) => updateActive((current) => ({ ...current, model: event.target.value }))} disabled={busy !== null} required={modelRequired} placeholder={t(modelRequired ? "请输入模型名" : "LibreTranslate 不需要模型")} /></label>
    </div>
    <p className="rss-translation-note">{providerNote}</p>
    <p className="rss-translation-note">{scope === "selection"
      ? t("将翻译当前选区（{used} / {maximum} 字节）。本机服务不需要托管 AI 令牌。", { used: formatNumber(reviewedTextBytes, locale), maximum: formatNumber(MAX_TRANSLATION_BYTES, locale) })
      : structuredArticleAvailable
        ? t("将翻译标题与 {count} 个正文文本节点（{used} / {maximum} 字节）。本机服务不需要托管 AI 令牌。", { count: formatNumber(structuredArticlePlan.segments.filter(({ id }) => id !== "title").length, locale), used: formatNumber(reviewedTextBytes, locale), maximum: formatNumber(MAX_TRANSLATION_BYTES, locale) })
        : t("将翻译当前文章纯文本（{used} / {maximum} 字节）。本机服务不需要托管 AI 令牌。", { used: formatNumber(reviewedTextBytes, locale), maximum: formatNumber(MAX_TRANSLATION_BYTES, locale) })}</p>
    {scope === "article" && structuredArticleAvailable && <p className="rss-translation-note">{t("标题层级、列表、引用、代码与安全链接留在本机模板中；服务只接收可见文本片段，返回内容不会作为 HTML 执行。")}</p>}
    {scope === "article" && structuredArticlePlan.wasTruncated && <p className="rss-translation-warning">{t("文章超过结构化翻译上限；超出部分会保留原文，并在译文中明确保持原有结构。")}</p>}
    <section className="rss-translation-glossary" aria-label={t("全局术语表")}><label>{t("全局术语表")}<textarea value={glossaryText} onChange={(event) => setGlossaryText(event.target.value)} disabled={busy !== null} rows={4} placeholder={t("source=target\n或使用 Tab 分隔")} /></label><p className="rss-translation-note">{t("已规范化 {count} 条术语；适用于所有 Feed。", { count: formatNumber(parsedGlossary.entries.length, locale) })}</p>{parsedGlossary.invalidLines.length > 0 && <p className="rss-translation-warning">{t("无效术语行：{lines}（每行使用 source=target 或 Tab 分隔）。", { lines: parsedGlossary.invalidLines.map((line) => formatNumber(line, locale)).join(locale === "en-US" ? ", " : "、") })}</p>}</section>
    {reviewedTextBytes > MAX_TRANSLATION_BYTES && <p className="rss-translation-warning">{t("内容超过 64 KiB 上限；请选中更短的文本后再生成计划。")}</p>}
    {modelRequired && !active.model.trim() && <p className="rss-translation-warning">{t("此 AI 翻译方式必须填写模型名。")}</p>}
    {active.provider === "openai_compatible" && <section className="rss-translation-credential" aria-label={t("托管 AI 凭据")}>
      <p>{t("令牌仅用于当前托管服务；优先保存到系统密钥环，密钥环不可用时只保留到本次应用退出。令牌不会写入本地翻译配置。")}</p>
      <div className="rss-translation-actions"><button type="button" onClick={() => void inspectCredential()} disabled={!gateway || !request.endpoint || !request.model || busy !== null}>{t("检查凭据")}</button>{credential?.configured && <button type="button" onClick={() => void deleteCredential()} disabled={busy !== null}>{t("删除凭据")}</button>}</div>
      {credential && <p className="rss-translation-note">{credential.configured ? t("已配置（{storage}）", { storage: t(credential.sessionOnly ? "仅本次运行" : "系统密钥环") }) : t("尚未配置凭据")}{credential.warning ? ` · ${translateCredentialWarning(credential.warning, t)}` : ""}</p>}
      <label>{t("访问令牌")}<input type="password" autoComplete="new-password" value={token} onChange={(event) => setToken(event.target.value)} disabled={!gateway || busy !== null} /></label>
      <button type="button" onClick={() => void saveCredential()} disabled={!gateway || !token || !request.endpoint || !request.model || busy !== null}>{t("保存凭据")}</button>
    </section>}
    <div className="rss-translation-actions"><button type="button" onClick={() => void createPlan()} disabled={!canPlan || busy !== null}>{t(busy === "plan" ? "生成中…" : "生成翻译计划")}</button></div>
    {message && <p className="rss-translation-message" role="status">{renderUiMessage(message, t)}</p>}
    {fallbackProvider && <div className="rss-translation-actions"><button type="button" onClick={switchToFallback} disabled={busy !== null}>{t("切换到后备方案（{provider}）", { provider: t(providerLabel(fallbackProvider)) })}</button></div>}
    {plan && <section className="rss-translation-plan"><h4>{t("翻译发送计划")}</h4><p>{t("确认后将按此配置发送一次翻译请求；RepoPress 不保存请求正文。")}</p><dl><dt>{t("服务")}</dt><dd>{t(providerLabel(plan.provider))}</dd><dt>{t("端点")}</dt><dd>{plan.endpoint}</dd><dt>{t("模型")}</dt><dd>{plan.model || t("不适用")}</dd><dt>{t("内容")}</dt><dd>{"segmentCount" in plan ? t("{bytes} 字节 · {count} 个文本片段", { bytes: formatNumber(plan.textBytes, locale), count: formatNumber(plan.segmentCount, locale) }) : t("{bytes} 字节", { bytes: formatNumber(plan.textBytes, locale) })}</dd><dt>{t("语言")}</dt><dd>{translateLanguageLabel(plan.sourceLanguage, t)} → {translateLanguageLabel(plan.targetLanguage, t)}</dd><dt>{t("术语表")}</dt><dd>{t("{count} 条", { count: formatNumber(plan.glossaryCount, locale) })}</dd></dl>{plan.warnings.map((warning) => <p className="rss-translation-warning" key={warning}>{translatePlanWarning(warning, t)}</p>)}{!currentPlanIsValid && <p className="rss-translation-warning">{t("文章、选区或配置已变化；此计划已失效。")}</p>}<div className="rss-translation-actions"><button type="button" className="rss-translation-confirm" onClick={() => void executePlan()} disabled={busy !== null || !currentPlanIsValid}>{t(busy === "execute" ? "翻译中…" : "确认并翻译")}</button><button type="button" onClick={() => { setPlan(null); setPlanRequestKey(null); }} disabled={busy !== null}>{t("丢弃计划")}</button></div></section>}
    {resultForCurrentKey && <section className="rss-translation-result"><div><h4>{t(scope === "selection" ? "选区译文（只读）" : decodeStructuredTextTranslationResult(resultForCurrentKey.translatedText) ? "标题与富结构正文译文（只读）" : "整篇纯文本译文（只读）")}</h4><span>{scope === "article" && onToggleArticleTranslation && <button type="button" onClick={onToggleArticleTranslation}>{t(articleTranslationVisible ? "显示原文" : "在阅读区显示译文")}</button>}<button type="button" onClick={() => void copyResult()}>{t("复制译文")}</button><button type="button" onClick={clearCurrentTranslation}>{t("清除此译文")}</button></span></div><p>{resultForCurrentKey.detectedSourceLanguage ? t("检测到源语言：{language}", { language: resultForCurrentKey.detectedSourceLanguage }) : t("源语言由服务自动检测")}</p><textarea readOnly value={displayTranslationText(resultForCurrentKey)} aria-label={t("只读译文")} rows={10} /></section>}
  </section>;
}

function structuredCacheSource(segments: PlanStructuredTextTranslationRequest["segments"]): string {
  return `repopress-rss-structured-source:v1\n${segments.map(({ id, text }) => `${id.length}:${id}${text.length}:${text}`).join("")}`;
}

function structuredResultAsCachedText(result: StructuredTextTranslationResult): TextTranslationResult {
  return {
    translatedText: encodeStructuredTextTranslationResult(result),
    detectedSourceLanguage: result.detectedSourceLanguage,
    provider: result.provider,
    model: result.model,
    targetLanguage: result.targetLanguage,
  };
}

function displayTranslationText(result: TextTranslationResult): string {
  const structured = decodeStructuredTextTranslationResult(result.translatedText);
  return structured ? structured.translations.map(({ translatedText }) => translatedText).join("\n\n") : result.translatedText;
}

function isPlanExpired(plan: TextTranslationPlan): boolean {
  const expiry = Date.parse(plan.expiresAt);
  return !Number.isFinite(expiry) || expiry <= Date.now();
}

function providerHelp(provider: TextTranslationProvider): string {
  switch (provider) {
    case "libretranslate_local": return "需先在本机启动 LibreTranslate / Argos 服务；RepoPress 只允许连接回环地址。";
    case "ollama_local": return "需先在本机启动 Ollama 并安装所填模型；RepoPress 只允许连接回环地址。";
    case "openai_compatible": return "确认执行后，所选文字或文章纯文本将发送到你配置的外部 HTTPS AI 服务。";
  }
}

function providerLabel(provider: TextTranslationProvider): string {
  switch (provider) {
    case "libretranslate_local": return "本机 LibreTranslate";
    case "ollama_local": return "本机 Ollama";
    case "openai_compatible": return "托管 OpenAI 兼容服务";
  }
}

function languageLabel(language: string): string {
  return ({ auto: "自动检测", zh: "简体中文", zt: "繁體中文", en: "English", ja: "日本語", ko: "한국어" } as Record<string, string>)[language] ?? language;
}

function translateLanguageLabel(language: string, t: UiTranslator): string {
  const source = languageLabel(language);
  return source === language ? language : t(source);
}

function planWarningLabel(warning: string): string | null {
  if (warning === "LibreTranslate does not support RepoPress glossary mappings; the glossary will not be applied.") return "LibreTranslate 当前不支持术语表；已保留术语配置，但此次请求不会应用它。";
  if (warning === "After confirmation, text is sent only to the configured loopback LibreTranslate endpoint.") return "确认后，正文只会发送到所配置的本机 LibreTranslate 回环地址。";
  if (warning === "After confirmation, text is sent only to the configured loopback Ollama endpoint.") return "确认后，正文只会发送到所配置的本机 Ollama 回环地址。";
  if (warning === "After confirmation, text is sent to the configured external HTTPS AI service.") return "确认后，正文会发送到所配置的外部 HTTPS AI 服务。";
  return null;
}

function translatePlanWarning(warning: string, t: UiTranslator): string {
  const source = planWarningLabel(warning);
  return source ? t(source) : warning;
}

function credentialWarningLabel(warning: string): string {
  if (warning === "secret_service_unavailable_session_only") return "系统密钥环不可用；关闭应用后凭据会丢失";
  if (warning === "secret_service_failed_session_only_persistent_state_unverified") return "系统密钥环写入失败；本次仅保存在内存，旧持久凭据状态未能确认";
  if (warning === "session_credential_deleted_persistent_state_unverified") return "已删除本次运行的凭据，但无法确认旧的密钥环记录";
  return warning;
}

function translateCredentialWarning(warning: string, t: UiTranslator): string {
  const source = credentialWarningLabel(warning);
  return source === warning ? warning : t(source);
}

function localMessage(source: string, parameters?: UiMessage["parameters"]): UiMessage {
  return { source, parameters };
}

function localError(source: string, error: unknown): UiMessage {
  const literal = error instanceof Error ? error.message : typeof error === "object" && error && "message" in error && typeof error.message === "string" ? error.message : null;
  return literal ? localMessage(source, { message: literal }) : { source, labels: { message: { source: "服务没有返回可用的错误说明。" } } };
}

function formatNumber(value: number, locale: string): string {
  return new Intl.NumberFormat(locale).format(value);
}
