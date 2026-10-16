import { useEffect, useRef, useState } from "react";
import type { SemanticIndexStatus, SemanticSearchSnapshot } from "../contracts/repository";
import { useI18n } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";

/** The narrow P3 gateway surface keeps the panel independently testable. */
export interface SemanticSearchGateway {
  semanticIndexStatus(sessionId: string): Promise<SemanticIndexStatus>;
  rebuildSemanticIndex(sessionId: string): Promise<SemanticIndexStatus>;
  semanticSearch(sessionId: string, query: string, limit?: number): Promise<SemanticSearchSnapshot>;
}

type AsyncState = "idle" | "loading" | "error";

export interface SemanticSearchPanelProps {
  /** A repository session supplied by the parent; omitted in the browser demo. */
  sessionId: string | null;
  /** Desktop-only capability gate. False means display-only mode. */
  enabled: boolean;
  /** The parent-owned gateway; the panel never opens a network connection itself. */
  gateway: SemanticSearchGateway;
  /** Open a result in the parent editor. */
  onOpenPath: (path: string) => void;
  /** Avoid loading even read-only index status while this panel is hidden. */
  active: boolean;
}

export function SemanticSearchPanel({
  sessionId,
  enabled,
  gateway,
  onOpenPath,
  active,
}: SemanticSearchPanelProps) {
  const [index, setIndex] = useState<SemanticIndexStatus | null>(null);
  const [results, setResults] = useState<SemanticSearchSnapshot | null>(null);
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<AsyncState>("idle");
  const [message, setMessage] = useState<UiMessage | null>(null);
  const { t } = useI18n();
  const generation = useRef(0);
  const canUse = Boolean(active && enabled && sessionId);
  const indexReady = Boolean(index?.ready && index.indexedChunks > 0);

  useEffect(() => {
    const current = ++generation.current;
    setIndex(null);
    setResults(null);
    setQuery("");
    setMessage(null);
    if (!canUse || !sessionId) {
      setStatus("idle");
      return;
    }
    setStatus("loading");
    void gateway.semanticIndexStatus(sessionId)
      .then((snapshot) => {
        if (current !== generation.current) return;
        setIndex(snapshot);
        setStatus("idle");
      })
      .catch((error: unknown) => {
        if (current !== generation.current) return;
        // No prior in-memory index is an expected cold-session state.  It is
        // intentionally not built until the user presses the explicit button.
        if (errorCode(error) === "semantic_index_not_ready") {
          setStatus("idle");
          return;
        }
        setStatus("error");
        setMessage(localError("无法读取离线索引状态：{error}", error));
      });
  }, [canUse, gateway, sessionId]);

  async function rebuildIndex() {
    if (!canUse || !sessionId) return;
    const current = generation.current;
    setStatus("loading");
    setMessage(null);
    setResults(null);
    try {
      const snapshot = await gateway.rebuildSemanticIndex(sessionId);
      if (current !== generation.current) return;
      setIndex(snapshot);
      setStatus("idle");
      setMessage({ source: "离线索引已建立；文档内容仅保留在当前应用会话内。" });
    } catch (error) {
      if (current !== generation.current) return;
      setStatus("error");
      setMessage(localError("无法建立离线索引：{error}", error));
    }
  }

  async function search() {
    const normalizedQuery = query.trim();
    if (!canUse || !sessionId || !indexReady || !normalizedQuery) return;
    const current = generation.current;
    setStatus("loading");
    setMessage(null);
    try {
      const snapshot = await gateway.semanticSearch(sessionId, normalizedQuery, 20);
      if (current !== generation.current) return;
      setResults(snapshot);
      setStatus("idle");
    } catch (error) {
      if (current !== generation.current) return;
      setStatus("error");
      setMessage(localError("无法完成离线检索：{error}", error));
    }
  }

  if (!active) return null;

  const readOnlyExplanation = !enabled
    ? t("浏览器演示模式不读取本地仓库，也不会建立或查询离线索引。")
    : !sessionId
      ? t("选择本地仓库后才能建立仅会话内的离线索引。")
      : null;

  return <section className="advanced-panel semantic-search-panel" aria-label={t("离线语义检索")}>
    <div className="advanced-heading">
      <div><strong>{t("离线语义检索")}</strong><p>{t("索引仅存在于当前应用会话；不会下载模型、写入索引或自动搜索。")}</p></div>
      <span className="tool-badge">{t("本地")}</span>
    </div>
    {readOnlyExplanation ? <p className="tool-muted">{readOnlyExplanation}</p> : <>
      <div className="tool-actions">
        <button type="button" onClick={() => void rebuildIndex()} disabled={status === "loading"}>
          {index ? t("更新离线索引") : t("建立离线索引")}
        </button>
      </div>
      {status === "loading" && <p className="tool-muted" role="status">{t("正在处理本地索引…")}</p>}
      {message && <p className={status === "error" ? "tool-error" : "tool-muted"} role={status === "error" ? "alert" : "status"}>{renderUiMessage(message, t)}</p>}
      {index ? <IndexSummary index={index} /> : <p className="tool-muted">{t("尚未建立本会话离线索引。建立后才可搜索。")}</p>}
      <form className="tool-search" onSubmit={(event) => { event.preventDefault(); void search(); }}>
        <label htmlFor="semantic-search-query">{t("查询")}</label>
        <input id="semantic-search-query" value={query} onChange={(event) => setQuery(event.target.value)} disabled={!indexReady || status === "loading"} maxLength={300} placeholder={t("例如：车辆维护、发布流程")} />
        <button type="submit" disabled={!indexReady || !query.trim() || status === "loading"}>{t("搜索")}</button>
      </form>
      {!indexReady && index && <p className="tool-muted">{t("当前索引没有可搜索的 Markdown chunk。")}</p>}
      {results && <Results snapshot={results} onOpenPath={onOpenPath} />}
    </>}
  </section>;
}

function IndexSummary({ index }: { index: SemanticIndexStatus }) {
  const { t, locale } = useI18n();
  return <dl className="tool-details">
    <dt>{t("状态")}</dt><dd>{index.summary} · {index.sessionOnly ? t("仅本次会话") : t("持久化")}</dd>
    <dt>{t("模型")}</dt><dd>{index.modelId} · {t("编码 v{version}", { version: index.encodingVersion })}</dd>
    <dt>{t("范围")}</dt><dd>{t("{files} 个文件 · {chunks} 个 chunk · {bytes}", { files: index.indexedFiles, chunks: index.indexedChunks, bytes: byteLabel(index.indexedBytes, locale) })}</dd>
    <dt>{t("本次复用")}</dt><dd>{t("{count} 个未变 chunk", { count: index.reusedChunks })}</dd>
  </dl>;
}

function Results({ snapshot, onOpenPath }: { snapshot: SemanticSearchSnapshot; onOpenPath: (path: string) => void }) {
  const { t } = useI18n();
  return <div className="tool-results" aria-live="polite">
    <p className="tool-muted">{snapshot.results.length ? t("找到 {count} 个结果{limited}。", { count: snapshot.results.length, limited: snapshot.truncated ? t("（结果已限制）") : "" }) : t("没有匹配的离线结果{limited}。", { limited: snapshot.truncated ? t("（结果已限制）") : "" })}</p>
    {snapshot.results.map((result) => <button type="button" className="tool-result" key={result.chunkId} onClick={() => onOpenPath(result.path)}>
      <span><code>{result.path}:{result.line}</code>{result.endLine !== result.line ? `–${result.endLine}` : ""}</span>
      {result.heading && <strong>{result.heading}</strong>}
      <span>{result.snippet}</span>
      <small>{t("得分 {score} · {reason}", { score: result.score.toFixed(3), reason: result.reason })}</small>
    </button>)}
  </div>;
}

function byteLabel(value: number, locale: string): string {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toLocaleString(locale, { maximumFractionDigits: 1 })} KiB`;
  return `${(value / (1024 * 1024)).toLocaleString(locale, { maximumFractionDigits: 1 })} MiB`;
}

function errorCode(error: unknown): string | null {
  return typeof error === "object" && error !== null && "code" in error && typeof error.code === "string" ? error.code : null;
}

function messageFrom(error: unknown): string | UiMessage {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null && "message" in error && typeof error.message === "string") return error.message;
  if (typeof error === "string") return error;
  return { source: "未知错误" };
}

function localError(source: string, error: unknown): UiMessage {
  const detail = messageFrom(error);
  return typeof detail === "string" ? { source, parameters: { error: detail } } : { source, parameters: { error: "" }, labels: { error: detail } };
}
