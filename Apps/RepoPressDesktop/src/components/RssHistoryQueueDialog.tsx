import { useEffect, useRef, useState } from "react";
import type { RssFeed, RssGateway, RssHistoryCheckpointSummary } from "../features/rss/contracts";
import { useI18n } from "../i18n/i18n";
import { rssMessages } from "../i18n/rssMessages";

export interface RssHistoryQueueDialogProps {
  gateway: RssGateway;
  feeds: RssFeed[];
  onClose: () => void;
  onOpen: (feedId: string) => void;
}

export function RssHistoryQueueDialog({ gateway, feeds, onClose, onOpen }: RssHistoryQueueDialogProps) {
  const { t } = useI18n(rssMessages);
  const [summaries, setSummaries] = useState<RssHistoryCheckpointSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [clearingId, setClearingId] = useState<string | null>(null);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const generation = useRef(0);
  const dialogRef = useRef<HTMLElement | null>(null);
  const closeRef = useRef<() => void>(() => undefined);

  useEffect(() => {
    const sequence = ++generation.current;
    setSummaries([]); setLoading(true); setClearingId(null); setMessage(""); setError("");
    void gateway.historyList().then((items) => {
      if (sequence === generation.current) setSummaries(items.slice(0, 20));
    }).catch((caught) => {
      if (sequence === generation.current) setError(errorMessage(caught, t("无法读取历史补全队列，请稍后重试。")));
    }).finally(() => { if (sequence === generation.current) setLoading(false); });
    return () => { generation.current += 1; };
  }, [gateway]);

  const close = () => { generation.current += 1; setLoading(false); setClearingId(null); onClose(); };
  closeRef.current = close;
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    dialogRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") { event.preventDefault(); closeRef.current(); } };
    window.addEventListener("keydown", onKeyDown);
    return () => { window.removeEventListener("keydown", onKeyDown); previous?.focus(); };
  }, []);

  const clear = async (summary: RssHistoryCheckpointSummary) => {
    if (summary.status === "running" || clearingId) return;
    if (!window.confirm(t("清除“{url}”的历史补全检查点、候选项和失败记录？清除后不能从原位置继续发现；已保存文章、全文缓存和阅读状态会保留。", { url: summary.directoryUrl }))) return;
    const sequence = ++generation.current;
    setClearingId(summary.id); setMessage(""); setError("");
    try {
      await gateway.historyClear(summary.id);
      if (sequence !== generation.current) return;
      try {
        const items = await gateway.historyList();
        if (sequence !== generation.current) return;
        setSummaries(items.slice(0, 20));
        setMessage(t("历史补全检查点已清除；文章、缓存和阅读状态未更改。"));
      } catch (caught) {
        if (sequence === generation.current) setError(errorMessage(caught, t("检查点已清除，但无法刷新队列；请关闭后重新打开。")));
      }
    } catch (caught) {
      if (sequence === generation.current) setError(errorMessage(caught, t("无法清除历史补全检查点，请按提示处理后重试。")));
    } finally {
      if (sequence === generation.current) setClearingId(null);
    }
  };

  const feedTitle = (summary: RssHistoryCheckpointSummary) => feeds.find((feed) => feed.id === summary.feedId)?.title ?? t("订阅已不存在");
  return <div className="rss-modal-backdrop" role="presentation">
    <section ref={dialogRef} tabIndex={-1} className="rss-modal rss-history-queue" role="dialog" aria-modal="true" aria-label={t("历史补全队列")}>
      <header><div><h2>{t("历史补全队列")}</h2><p>{t("查看本机保存的历史发现检查点；打开队列不会发起网络请求。")}</p></div><button type="button" onClick={close} aria-label={t("关闭")}>×</button></header>
      <p className="rss-help">{t("清除只会移除发现游标、候选项和失败记录；文章、全文缓存和阅读状态都会保留。")}</p>
      {loading && !summaries.length ? <p role="status">{t("正在读取状态…")}</p> : summaries.length ? <ul className="rss-history-queue-list">{summaries.map((summary) => {
        const stale = summary.stale || !feeds.some((feed) => feed.id === summary.feedId);
        return <li key={summary.id} className={stale ? "stale" : undefined}>
          <div><strong>{feedTitle(summary)}</strong>{stale && <span className="rss-history-stale">{t("失效检查点")}</span>}<span>{summary.directoryUrl}</span><small>{summary.retryingFailures ? t("失败重试批次") : t(historyJobStatusLabel(summary.status))} · {t("累计发现 {discoveredCount} · 本段候选 {candidateCount} · 本段待处理 {pendingCount} · 已添加 {addedCount} · 已补全文 {updatedCount} · 重复 {duplicateCount} · 全量未解决失败 {failedCount}", { discoveredCount: summary.discoveredCount, candidateCount: summary.candidateCount, pendingCount: summary.pendingCount, addedCount: summary.addedCount, updatedCount: summary.updatedCount, duplicateCount: summary.duplicateCount, failedCount: summary.failedCount })}</small>{summary.hasMoreDiscovery && <small>{t("当前段处理完后仍可手动继续发现更早的链接")}</small>}</div>
          <div className="rss-history-queue-actions"><button type="button" onClick={() => onOpen(summary.feedId)} disabled={stale || clearingId !== null}>{t("打开检查点")}</button><button type="button" onClick={() => void clear(summary)} disabled={summary.status === "running" || clearingId !== null}>{clearingId === summary.id ? t("正在清除…") : t("清除检查点")}</button></div>
        </li>;
      })}</ul> : <p>{t("没有保存的历史补全检查点。")}</p>}
      {message && <p role="status">{message}</p>}
      {error && <p role="alert">{error}</p>}
    </section>
  </div>;
}

function historyJobStatusLabel(status: RssHistoryCheckpointSummary["status"]) { return ({ preview: "等待确认", paused: "已暂停", running: "正在补全", complete: "本批次已完成" } as const)[status]; }
function errorMessage(value: unknown, fallback: string) {
  const message = value instanceof Error ? value.message : value && typeof value === "object" && "message" in value && typeof value.message === "string" ? value.message : "";
  return message.trim().slice(0, 500) || fallback;
}
