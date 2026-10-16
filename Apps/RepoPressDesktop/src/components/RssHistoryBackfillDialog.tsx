import { useEffect, useRef, useState } from "react";
import type { RssFeed, RssGateway, RssHistoryJob } from "../features/rss/contracts";
import { useI18n, type UiTranslator } from "../i18n/i18n";
import { rssMessages } from "../i18n/rssMessages";

export interface RssHistoryBackfillDialogProps {
  feed: RssFeed;
  gateway: RssGateway;
  onClose: () => void;
  onChanged: () => Promise<void> | void;
}

export function RssHistoryBackfillDialog({ feed, gateway, onClose, onChanged }: RssHistoryBackfillDialogProps) {
  const { t } = useI18n(rssMessages);
  const [directoryUrl, setDirectoryUrl] = useState(() => defaultDirectoryUrl(feed));
  const [maxPages, setMaxPages] = useState(10);
  const [maxArticles, setMaxArticles] = useState(100);
  const [fillExisting, setFillExisting] = useState(false);
  const [job, setJob] = useState<RssHistoryJob | null>(null);
  const [confirmed, setConfirmed] = useState(false);
  const [loading, setLoading] = useState(true);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState("");
  const generation = useRef(0);
  const runGeneration = useRef(0);
  const timer = useRef<number | null>(null);
  const timerResolve = useRef<((active: boolean) => void) | null>(null);
  const discoveryTimer = useRef<number | null>(null);
  const discoveryTimerResolve = useRef<((active: boolean) => void) | null>(null);
  const runActive = useRef(false);
  const jobRef = useRef<RssHistoryJob | null>(null);
  const activeDiscovery = useRef<{ id: string; gateway: RssGateway } | null>(null);
  const pauseRequested = useRef<string | null>(null);
  const dialogRef = useRef<HTMLElement | null>(null);
  const closeRef = useRef<() => void>(() => undefined);

  const rememberJob = (next: RssHistoryJob | null) => { jobRef.current = next; setJob(next); };
  const cancelRun = () => {
    runGeneration.current += 1;
    if (timer.current !== null) { window.clearTimeout(timer.current); timer.current = null; }
    timerResolve.current?.(false); timerResolve.current = null;
    runActive.current = false;
    setRunning(false);
  };
  const pauseCurrent = () => {
    const current = jobRef.current;
    if (!current || (!runActive.current && current.status !== "running") || pauseRequested.current === current.id) return;
    pauseRequested.current = current.id;
    void gateway.historyPause(current.id).catch(() => undefined);
  };
  const cancelActiveDiscovery = () => {
    const active = activeDiscovery.current;
    if (discoveryTimer.current !== null) { window.clearTimeout(discoveryTimer.current); discoveryTimer.current = null; }
    discoveryTimerResolve.current?.(false); discoveryTimerResolve.current = null;
    if (active) {
      activeDiscovery.current = null;
      void active.gateway.historyCancelDiscovery(active.id).catch(() => undefined);
    }
  };
  const invalidateDiscovery = () => {
    generation.current += 1; cancelActiveDiscovery(); cancelRun();
    setConfirmed(false); setError(""); setLoading(false);
    if (!runActive.current && jobRef.current?.status !== "running") rememberJob(null);
  };
  const updateLimit = (setValue: (value: number) => void, value: number) => {
    setValue(value); setConfirmed(false); setError("");
  };
  const recoverPersistedDiscovery = async (sequence: number, discovery: { id: string; gateway: RssGateway }) => {
    try {
      const persisted = await discovery.gateway.historyStatus(feed.id);
      if (sequence !== generation.current || activeDiscovery.current?.id !== discovery.id || activeDiscovery.current.gateway !== discovery.gateway) return;
      rememberJob(persisted);
      if (persisted) { setDirectoryUrl(persisted.directoryUrl); setFillExisting(persisted.fillExisting ?? false); }
    } catch { /* Keep the original corrective discovery error. */ }
  };

  useEffect(() => {
    const sequence = ++generation.current;
    setLoading(true); setError(""); setConfirmed(false); rememberJob(null); cancelRun();
    void gateway.historyStatus(feed.id).then((next) => {
      if (sequence !== generation.current) return;
      rememberJob(next);
      if (next) { setDirectoryUrl(next.directoryUrl); setFillExisting(next.fillExisting ?? false); }
    }).catch((caught) => { if (sequence === generation.current) setError(errorMessage(caught, t("历史文章补全失败，请稍后重试。"))); }).finally(() => { if (sequence === generation.current) setLoading(false); });
    return () => {
      generation.current += 1;
      runGeneration.current += 1;
      cancelActiveDiscovery();
      if (timer.current !== null) window.clearTimeout(timer.current);
      timerResolve.current?.(false); timerResolve.current = null;
      pauseCurrent();
    };
  }, [feed.id, gateway]);

  const discover = async () => {
    const normalized = validateDirectoryUrl(directoryUrl, feed, t);
    if (normalized instanceof Error) { setError(normalized.message); return; }
    cancelActiveDiscovery();
    const discovery = { id: globalThis.crypto.randomUUID(), gateway };
    activeDiscovery.current = discovery;
    const sequence = ++generation.current;
    cancelRun(); setLoading(true); setError(""); setConfirmed(false);
    try {
      const next = await gateway.historyDiscover({ feedId: feed.id, directoryUrl: normalized, maxPages: boundedInteger(maxPages, 1, 10), maxArticles: boundedInteger(maxArticles, 1, 500), discoveryId: discovery.id, fillExisting });
      if (sequence === generation.current && activeDiscovery.current?.id === discovery.id && activeDiscovery.current.gateway === discovery.gateway) { pauseRequested.current = null; rememberJob(next); }
    } catch (caught) {
      if (sequence === generation.current && activeDiscovery.current?.id === discovery.id && activeDiscovery.current.gateway === discovery.gateway) {
        setError(errorMessage(caught, t("历史文章补全失败，请稍后重试。")));
        await recoverPersistedDiscovery(sequence, discovery);
      }
    } finally {
      if (activeDiscovery.current?.id === discovery.id && activeDiscovery.current.gateway === discovery.gateway) activeDiscovery.current = null;
      if (sequence === generation.current) setLoading(false);
    }
  };

  const waitForDiscoveryDeadline = (epochSeconds: number, sequence: number, discovery: { id: string; gateway: RssGateway }) => new Promise<boolean>((resolve) => {
    const isActive = () => sequence === generation.current && activeDiscovery.current?.id === discovery.id && activeDiscovery.current.gateway === discovery.gateway;
    const delay = Math.max(0, epochSeconds * 1000 - Date.now());
    if (delay === 0) { resolve(isActive()); return; }
    discoveryTimerResolve.current = resolve;
    discoveryTimer.current = window.setTimeout(() => { discoveryTimer.current = null; discoveryTimerResolve.current = null; resolve(isActive()); }, delay);
  });
  const resumeDiscovery = async () => {
    const current = jobRef.current;
    const pending = current?.candidates.some((candidate) => candidate.status === "pending") ?? false;
    if (!current || loading || running || current.status === "running" || pending || !current.hasMoreDiscovery) return;
    cancelActiveDiscovery();
    const discovery = { id: globalThis.crypto.randomUUID(), gateway };
    activeDiscovery.current = discovery;
    const sequence = ++generation.current;
    cancelRun(); setLoading(true); setError(""); setConfirmed(false);
    try {
      if (!await waitForDiscoveryDeadline(current.nextRequestAt, sequence, discovery)) return;
      const next = await gateway.historyResumeDiscovery({ jobId: current.id, discoveryId: discovery.id, maxPages: boundedInteger(maxPages, 1, 10), maxArticles: boundedInteger(maxArticles, 1, 500) });
      if (sequence === generation.current && activeDiscovery.current?.id === discovery.id && activeDiscovery.current.gateway === discovery.gateway) { pauseRequested.current = null; rememberJob(next); }
    } catch (caught) {
      if (sequence === generation.current && activeDiscovery.current?.id === discovery.id && activeDiscovery.current.gateway === discovery.gateway) {
        setError(errorMessage(caught, t("历史文章补全失败，请稍后重试。")));
        await recoverPersistedDiscovery(sequence, discovery);
      }
    } finally {
      if (activeDiscovery.current?.id === discovery.id && activeDiscovery.current.gateway === discovery.gateway) activeDiscovery.current = null;
      if (sequence === generation.current) setLoading(false);
    }
  };

  const waitUntil = (epochSeconds: number, sequence: number) => new Promise<boolean>((resolve) => {
    const delay = Math.max(0, epochSeconds * 1000 - Date.now());
    if (delay === 0) { resolve(sequence === runGeneration.current); return; }
    timerResolve.current = resolve;
    timer.current = window.setTimeout(() => { timer.current = null; timerResolve.current = null; resolve(sequence === runGeneration.current); }, delay);
  });
  const prepareRetry = async () => {
    const current = jobRef.current;
    const hasPending = current?.candidates.some((candidate) => candidate.status === "pending") ?? false;
    if (!current || current.failedCount < 1 || hasPending || loading || running || current.status === "running") return;
    cancelRun();
    const sequence = ++generation.current;
    setConfirmed(false); setLoading(true); setError("");
    try {
      const next = await gateway.historyPrepareRetry({ jobId: current.id, maxArticles: boundedInteger(maxArticles, 1, 500) });
      if (sequence === generation.current) { pauseRequested.current = null; rememberJob(next); }
    } catch (caught) {
      if (sequence === generation.current) setError(errorMessage(caught, t("无法预览失败重试，请稍后重试。")));
    } finally {
      if (sequence === generation.current) setLoading(false);
    }
  };
  const run = async () => {
    const initial = jobRef.current;
    if (!initial || running || (initial.candidates.some((candidate) => candidate.status === "pending") && !confirmed)) return;
    const sequence = ++runGeneration.current;
    runActive.current = true; setRunning(true); setError(""); pauseRequested.current = null;
    let current = initial;
    try {
      while (sequence === runGeneration.current) {
        if (!await waitUntil(current.nextRequestAt, sequence)) return;
        const previousChanged = current.addedCount + (current.updatedCount ?? 0);
        const next = await gateway.historyStep({ jobId: current.id });
        if (sequence !== runGeneration.current) return;
        current = next; rememberJob(next);
        if (next.addedCount + (next.updatedCount ?? 0) > previousChanged) {
          await onChanged();
          if (sequence !== runGeneration.current) return;
        }
        if (next.status !== "running") return;
      }
    } catch (caught) {
      if (sequence === runGeneration.current) setError(errorMessage(caught, t("历史文章补全失败，请稍后重试。")));
    } finally {
      if (sequence === runGeneration.current) { runActive.current = false; setRunning(false); }
    }
  };
  const pause = async () => {
    const current = jobRef.current;
    const shouldPause = Boolean(current && (runActive.current || current.status === "running"));
    cancelRun(); setLoading(true); setError("");
    if (!current || !shouldPause) { setLoading(false); return; }
    pauseRequested.current = current.id;
    const sequence = generation.current;
    try { const next = await gateway.historyPause(current.id); if (sequence === generation.current) rememberJob(next); }
    catch (caught) { if (sequence === generation.current) setError(errorMessage(caught, t("历史文章补全失败，请稍后重试。"))); }
    finally { if (sequence === generation.current) setLoading(false); }
  };
  const close = () => { cancelActiveDiscovery(); pauseCurrent(); cancelRun(); generation.current += 1; onClose(); };
  closeRef.current = close;
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    dialogRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") { event.preventDefault(); closeRef.current(); } };
    window.addEventListener("keydown", onKeyDown);
    return () => { window.removeEventListener("keydown", onKeyDown); previous?.focus(); };
  }, []);
  const pendingCount = job?.candidates.filter((candidate) => candidate.status === "pending").length ?? 0;
  const canResumeDiscovery = Boolean(job?.hasMoreDiscovery && job.status !== "running" && !running && pendingCount === 0);

  return <div className="rss-modal-backdrop" role="presentation">
    <section ref={dialogRef} tabIndex={-1} className="rss-modal rss-history-backfill" role="dialog" aria-modal="true" aria-label={t("补全历史文章：{title}", { title: feed.title })}>
      <header><div><h2>{t("补全历史文章")}</h2><p>{feed.title}</p></div><button type="button" onClick={close} aria-label={t("关闭")}>×</button></header>
      <p className="rss-help">{t("发现阶段会向同源公开目录逐页发起网络请求，只列出候选地址，不会写入文章。目录地址不得包含查询参数、用户信息或片段。")}</p>
      <p className="rss-help">{t("补全或重试每个候选时，除候选地址外，可能额外请求最多 2 个同源旧地址来核对带或不带斜杠的别名；只访问 robots 允许的公开页面，并遵守 noarchive。")}</p>
      <p className="rss-help">{t("每个订阅只保留一个历史检查点。要从新地址重新发现，请先在“历史补全队列”中确认清除旧检查点。取消或发现失败时，已提交的发现进度仍会保留。")}</p>
      <label>{t("同源目录地址")}<input value={directoryUrl} disabled={running || job?.status === "running"} onChange={(event) => { setDirectoryUrl(event.target.value); invalidateDiscovery(); }} placeholder="https://example.com/archive/" /></label>
      <div className="rss-history-limits"><label>{t("最多目录页")}<input type="number" min="1" max="10" value={maxPages} disabled={loading || running || job?.status === "running"} onChange={(event) => updateLimit(setMaxPages, Number(event.target.value))} /></label><label>{t("最多候选文章")}<input type="number" min="1" max="500" value={maxArticles} disabled={loading || running || job?.status === "running"} onChange={(event) => updateLimit(setMaxArticles, Number(event.target.value))} /></label></div>
      <label className="rss-history-fill-existing"><input type="checkbox" checked={fillExisting} disabled={loading || running || job?.status === "running"} onChange={(event) => { setFillExisting(event.target.checked); invalidateDiscovery(); }} /> {t("同时补齐已有文章缺失或仅含摘要、截断内容的正文（写入本机全文缓存，原文和阅读状态不变）")}</label>
      <p className="rss-help">{t("已就绪的本机全文缓存会优先复用；短但完整的文章不会仅因篇幅短而请求。")}</p>
      <div className="rss-modal-actions"><button type="button" onClick={() => void discover()} disabled={loading || running}>{loading && !job ? t("正在读取状态…") : t("发现候选文章")}</button></div>
      {job && <section className="rss-history-preview" aria-label={t("历史文章候选预览")}>
        <h3>{t(job.retryingFailures ? "失败重试预览（本段 {count} 项）" : "本段候选文章（{count}）", { count: job.candidates.length })}</h3>
        <p className="rss-help">{t("已审查来源：{url}", { url: job.directoryUrl })}</p>
        <p>{t("累计发现 {discoveredCount} · 已添加 {addedCount} · 已补全文 {updatedCount} · 重复 {duplicateCount} · 全量未解决失败 {failedCount} · 本段待处理 {pendingCount}", { discoveredCount: job.discoveredCount ?? job.candidates.length, addedCount: job.addedCount, updatedCount: job.updatedCount ?? 0, duplicateCount: job.duplicateCount, failedCount: job.failedCount, pendingCount })}</p>
        {job.reachedLimit && <p className="rss-help">{t("已达到本次发现上限；可能仍有更早的文章未列出。")}</p>}
        {job.failedCount > 0 && !job.retryingFailures && <p className="rss-help">{t("预览失败重试只会从本机全量未解决失败账本选取本段队列，不会发起网络请求；勾选确认并开始后才会逐项请求。")}</p>}
        {job.message && <p role="status">{historyBackendMessage(job.message, t)}</p>}
        <ul>{job.candidates.map((candidate, index) => <li key={`${candidate.kind ?? "article"}-${candidate.url}-${index}`}><strong>{candidate.title || candidate.url}</strong><span>{candidate.url}</span><small>{t(candidate.kind === "fullText" ? "已有文章全文" : "新文章")} · {t(historyStatusLabel(candidate.status))}{candidate.message ? ` · ${historyBackendMessage(candidate.message, t)}` : ""}</small></li>)}</ul>
        {(job.status === "preview" || job.status === "paused") && pendingCount > 0 && <label className="rss-history-confirm"><input type="checkbox" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} /> {t(job.retryingFailures ? "我确认开始失败重试后会逐项请求本段地址，并把成功解析的文章写入本机 RSS 库。" : "我确认开始后会逐篇请求候选地址，并把成功解析的文章写入本机 RSS 库。")}</label>}
        <div className="rss-modal-actions">
          {(job.status === "preview" || job.status === "paused") && pendingCount > 0 && <button type="button" onClick={() => void run()} disabled={!confirmed || running || loading}>{job.retryingFailures ? t("开始失败重试") : job.status === "paused" ? t("继续补全") : t("开始补全")}</button>}
          {(job.status === "running" || running) && <button type="button" onClick={() => void pause()} disabled={loading}>{t("暂停补全")}</button>}
          {job.failedCount > 0 && job.status !== "running" && !job.retryingFailures && <button type="button" onClick={() => void prepareRetry()} disabled={running || loading || pendingCount > 0}>{t("预览失败重试")}</button>}
          {job.failedCount > 0 && job.status !== "running" && job.retryingFailures && pendingCount === 0 && <button type="button" onClick={() => void prepareRetry()} disabled={running || loading}>{t("预览下一批失败重试")}</button>}
          {canResumeDiscovery && <button type="button" onClick={() => void resumeDiscovery()} disabled={loading}>{t("继续发现历史链接")}</button>}
        </div>
      </section>}
      {error && <p role="alert">{error}</p>}
    </section>
  </div>;
}

function defaultDirectoryUrl(feed: RssFeed) { try { const url = new URL(feed.siteUrl ?? feed.url); url.search = ""; url.hash = ""; url.username = ""; url.password = ""; return url.toString(); } catch { return ""; } }
function validateDirectoryUrl(value: string, feed: RssFeed, t: UiTranslator): string | Error {
  try {
    const url = new URL(value.trim());
    if (!/^https?:$/.test(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash) return new Error(t("目录地址必须是无用户信息、查询参数和片段的 HTTP(S) URL。"));
    const origins = [feed.url, feed.siteUrl].filter((item): item is string => Boolean(item)).flatMap((item) => { try { return [new URL(item).origin]; } catch { return []; } });
    if (!origins.includes(url.origin)) return new Error(t("目录地址必须与订阅地址或站点地址同源。"));
    return url.toString();
  } catch { return new Error(t("请输入有效的同源目录地址。")); }
}
function boundedInteger(value: number, min: number, max: number) { return Math.max(min, Math.min(max, Math.round(Number.isFinite(value) ? value : min))); }
function historyStatusLabel(status: RssHistoryJob["candidates"][number]["status"]) { return ({ pending: "待处理", added: "已添加", duplicate: "重复", updated: "已补全文", failed: "失败" } as const)[status]; }
function historyBackendMessage(message: string, t: UiTranslator) {
  if (message === "Some discovery sources were unavailable or disallowed. Only listed candidates can be imported.") return t("部分发现来源不可用或不允许访问；只能补全已列出的候选文章。");
  if (message === "Source unavailable, unsafe, too short or disallows archival. Retry manually after review.") return t("来源不可用、不安全、内容过短或不允许归档；请审查后手动重试。");
  return message;
}
function errorMessage(value: unknown, fallback: string) {
  const message = value instanceof Error ? value.message : value && typeof value === "object" && "message" in value && typeof value.message === "string" ? value.message : "";
  return message.trim().slice(0, 500) || fallback;
}
