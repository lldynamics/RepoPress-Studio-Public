import { useCallback, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { OperationLogSnapshot } from "../contracts/activity";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import { filterOperationLog, formatOperationDate, formatOperationDuration, operationKindLabel, repositoryDisplayName, type OperationCategory, type OperationOutcomeFilter, type OperationRepositoryFilter } from "../features/activity/operationLog";
import "./OperationLogCenter.css";

export interface OperationLogCenterProps { open: boolean; onClose: () => void; gateway: RepositoryGateway; repository: RepositorySessionSnapshot | null; enabled: boolean; }
const emptySnapshot: OperationLogSnapshot = { entries: [], latestSequence: 0, persistent: false, warning: null, currentRepositoryKey: null };
const categoryOptions: Array<[OperationCategory | "all", string]> = [["all", "全部类别"], ["writing", "写作"], ["draft", "草稿"], ["image", "图片"], ["publish", "发布"], ["knowledge", "资料"]];
function errorText(reason: unknown) {
  return reason instanceof Error && reason.message ? reason.message : "操作日志读取失败。";
}

export function OperationLogCenter({ open, onClose, gateway, repository, enabled }: OperationLogCenterProps) {
  const root = useRef<HTMLDivElement>(null);
  const clearButton = useRef<HTMLButtonElement>(null);
  const refreshButton = useRef<HTMLButtonElement>(null);
  const closeButton = useRef<HTMLButtonElement>(null);
  const confirmCancelButton = useRef<HTMLButtonElement>(null);
  const generation = useRef(0);
  const titleId = useId();
  const sessionId = repository?.sessionId ?? undefined;
  const [snapshot, setSnapshot] = useState<OperationLogSnapshot>(emptySnapshot);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");
  const [category, setCategory] = useState<OperationCategory | "all">("all");
  const [outcome, setOutcome] = useState<OperationOutcomeFilter>("all");
  const [repoFilter, setRepoFilter] = useState<OperationRepositoryFilter>("all");
  const [query, setQuery] = useState("");
  const [selectedSequence, setSelectedSequence] = useState<number | null>(null);
  const [confirming, setConfirming] = useState(false);
  const [focusTarget, setFocusTarget] = useState<"confirm" | "after-clear" | null>(null);
  const close = useCallback(() => {
    generation.current += 1;
    onClose();
  }, [onClose]);
  useDrawerFocus(open, root, close);
  useLayoutEffect(() => {
    generation.current += 1;
    setSnapshot(emptySnapshot);
    setSelectedSequence(null);
    setConfirming(false);
    setError("");
    setStatus("");
    setLoading(false);
    setBusy(false);
    setFocusTarget(null);
    return () => { generation.current += 1; };
  }, [gateway, open, sessionId, enabled]);
  useLayoutEffect(() => {
    if (!open || !focusTarget) return;
    const current = generation.current;
    const target = focusTarget;
    setFocusTarget(null);
    queueMicrotask(() => {
      if (current !== generation.current) return;
      if (target === "confirm") confirmCancelButton.current?.focus();
      else {
        const next = [clearButton.current, refreshButton.current, closeButton.current]
          .find((button) => button?.isConnected && !button.disabled);
        next?.focus();
      }
    });
  }, [enabled, focusTarget, open, snapshot.entries.length]);
  const load = useCallback(async (force = false) => {
    if (!open || !enabled || (!force && (loading || busy))) return;
    const current = ++generation.current;
    setLoading(true);
    setError("");
    try {
      const next = await gateway.getOperationLog(sessionId);
      if (current === generation.current) {
        setSnapshot(next);
        setSelectedSequence(null);
      }
    } catch (reason) {
      if (current === generation.current) setError(errorText(reason));
    } finally {
      if (current === generation.current) setLoading(false);
    }
  }, [busy, enabled, gateway, loading, open, sessionId]);
  useLayoutEffect(() => { if (open && enabled) void load(true); }, [open, enabled, gateway, sessionId]); // eslint-disable-line react-hooks/exhaustive-deps
  const currentRepositoryKey = snapshot.currentRepositoryKey;
  const visible = useMemo(() => filterOperationLog(snapshot.entries, { category, outcome, repository: repoFilter, query }, currentRepositoryKey), [category, currentRepositoryKey, outcome, query, repoFilter, snapshot.entries]);
  const selected = visible.find((entry) => entry.sequence === selectedSequence) ?? null;
  const cutoff = useRef(0);
  function beginClear() {
    cutoff.current = snapshot.latestSequence;
    setConfirming(true);
    setFocusTarget("confirm");
    setError("");
  }
  async function clear() {
    if (busy || !enabled) return;
    const current = ++generation.current;
    setBusy(true);
    setError("");
    try {
      const next = await gateway.clearOperationLog(cutoff.current, sessionId);
      if (current === generation.current) {
        setSnapshot(next);
        setSelectedSequence(null);
        setConfirming(false);
        setFocusTarget("after-clear");
        setStatus("已清空已加载的日志记录。");
      }
    } catch (reason) {
      if (current === generation.current) setError(errorText(reason));
    } finally {
      if (current === generation.current) setBusy(false);
    }
  }
  if (!open) return null;
  return <div className="operation-log-scrim" ref={root}><section className="operation-log" role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1}>
    <header><div><h2 id={titleId}>操作日志</h2><p>记录最近最多 500 条安全摘要；成功表示命令完成，不代表上线保证。</p></div><button ref={closeButton} type="button" onClick={close} aria-label="关闭操作日志">×</button></header>
    <main><div className="operation-log-actions"><button ref={refreshButton} type="button" onClick={() => void load()} disabled={loading || busy || !enabled}>刷新</button><button ref={clearButton} type="button" onClick={beginClear} disabled={confirming || busy || loading || !enabled || snapshot.entries.length === 0}>清空已加载记录</button></div>
    {!enabled && <p className="operation-log-empty">操作日志当前不可用，未读取任何数据。</p>}
    {snapshot.warning && <p className="operation-log-warning">{snapshot.warning}</p>} {!snapshot.persistent && enabled && <p className="operation-log-warning">当前使用内存日志，应用关闭后记录可能丢失。</p>}
    <div className="operation-log-filters"><label>搜索动作<input value={query} onChange={(e) => { setQuery(e.target.value); setSelectedSequence(null); }} placeholder="例如：保存" /></label><label>类别<select value={category} onChange={(e) => { setCategory(e.target.value as typeof category); setSelectedSequence(null); }}>{categoryOptions.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label><label>结果<select value={outcome} onChange={(e) => { setOutcome(e.target.value as OperationOutcomeFilter); setSelectedSequence(null); }}><option value="all">全部结果</option><option value="succeeded">成功</option><option value="failed">失败</option></select></label><label>范围<select value={repoFilter} onChange={(e) => { setRepoFilter(e.target.value as OperationRepositoryFilter); setSelectedSequence(null); }}><option value="all">全部日志</option><option value="current">当前仓库</option><option value="unlinked">未关联仓库</option></select></label></div>
    <div className="operation-log-status" aria-live="polite">{loading ? "正在读取…" : error || status}</div><div className="operation-log-grid"><div className="operation-log-list" aria-label="日志记录">{visible.map((entry) => <button type="button" key={entry.sequence} className={selectedSequence === entry.sequence ? "selected" : ""} onClick={() => setSelectedSequence(entry.sequence)}><strong>{operationKindLabel(entry.kind)} · #{entry.sequence}</strong><span>{formatOperationDate(entry.occurredAtEpochMs)} · {entry.outcome === "succeeded" ? "成功" : "失败"}</span></button>)}{!visible.length && <p className="operation-log-empty">没有匹配的日志记录。</p>}</div><div className="operation-log-detail">{selected ? <><h3>{operationKindLabel(selected.kind)}</h3><dl><div><dt>时间</dt><dd>{formatOperationDate(selected.occurredAtEpochMs)}</dd></div><div><dt>耗时</dt><dd>{formatOperationDuration(selected.durationMs)}</dd></div><div><dt>结果</dt><dd>{selected.outcome === "succeeded" ? "成功" : "失败"}</dd></div><div><dt>范围</dt><dd>{repositoryDisplayName(selected.repositoryKey, currentRepositoryKey)}</dd></div><div><dt>摘要</dt><dd>已隐藏文稿、路径、用户名称和原始异常。</dd></div></dl></> : <p>选择一条记录查看详情。</p>}</div></div><p className="operation-log-boundary">日志仅保留操作类型、结果、时间、耗时和仓库关联信息。失败时可能已经产生部分副作用。</p>
    {confirming && <div className="operation-log-confirm" role="alertdialog" aria-label="确认清空日志"><p>清空打开确认前已加载记录（截至序号 #{cutoff.current}），业务数据不会删除；序号之后产生记录保留</p><button type="button" onClick={() => void clear()} disabled={busy}>确认清空</button><button ref={confirmCancelButton} type="button" onClick={() => { setConfirming(false); setFocusTarget("after-clear"); }} disabled={busy}>取消</button></div>}
    </main></section></div>;
}
export default OperationLogCenter;
