import { useEffect, useMemo, useRef, useState } from "react";
import type { GatewayError, SitePreviewReadiness, SitePreviewSnapshot } from "../contracts/repository";
import type {
  SitePreviewDocumentBinding,
  SitePreviewPageSnapshot,
  SitePreviewPlan,
  SitePreviewPlanRequest,
} from "../contracts/sitePreview";
import { useI18n } from "../i18n/i18n";
import { sitePreviewMessages } from "../i18n/sitePreviewMessages";

const LOOPBACK_URL = /^http:\/\/127\.0\.0\.1:(\d{1,5})(\/[^?#]*)?$/;
const CONTROL_OR_BACKSLASH = /[\\\u0000-\u001F\u007F]/;
const ENCODED_CONTROL_OR_BACKSLASH = /%(?:0[0-9a-f]|1[0-9a-f]|5c|7f)/i;

export function safePreviewUrl(value: string | null): string | null {
  if (!value || CONTROL_OR_BACKSLASH.test(value) || ENCODED_CONTROL_OR_BACKSLASH.test(value)) {
    return null;
  }
  const match = LOOPBACK_URL.exec(value);
  if (!match) return null;
  const port = Number(match[1]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  try {
    const url = new URL(value);
    if (
      url.protocol !== "http:" || url.hostname !== "127.0.0.1" || !url.port
      || Number(url.port) !== port || url.username || url.password || url.search || url.hash
    ) return null;
    return url.toString();
  } catch {
    return null;
  }
}

export function siteArticlePreviewUrl(
  previewRoot: string | null,
  articlePath: string | null | undefined,
): string | null {
  const safeRoot = safePreviewUrl(previewRoot);
  const safePath = safeSiteArticlePath(articlePath);
  if (!safeRoot || !safePath) return null;
  try {
    const root = new URL(safeRoot);
    const target = new URL(safePath, `${root.protocol}//${root.host}/`);
    if (
      target.protocol !== root.protocol || target.hostname !== root.hostname
      || target.port !== root.port || target.username || target.password
    ) return null;
    target.search = "";
    target.hash = "";
    return target.toString();
  } catch {
    return null;
  }
}

function safeSiteArticlePath(articlePath: string | null | undefined): string | null {
  if (!articlePath || CONTROL_OR_BACKSLASH.test(articlePath)) return null;
  const path = articlePath.split(/[?#]/, 1)[0];
  if (!path) return null;
  let decoded = path;
  for (let attempt = 0; attempt < 32; attempt += 1) {
    if (
      CONTROL_OR_BACKSLASH.test(decoded)
      || /^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(decoded)
      || /(^|\/)\.{1,2}(?=\/|$)/.test(decoded)
    ) return null;
    try {
      const next = decodeURIComponent(decoded);
      if (next === decoded) break;
      decoded = next;
    } catch {
      return null;
    }
  }
  try {
    if (decodeURIComponent(decoded) !== decoded) return null;
  } catch {
    return null;
  }
  if (
    CONTROL_OR_BACKSLASH.test(decoded)
    || /^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(decoded)
    || /(^|\/)\.{1,2}(?=\/|$)/.test(decoded)
  ) return null;
  return path.startsWith("/") ? path : `/${path}`;
}

type Target = "article" | "home";
type PreviewOwner = { sessionId: string; previewId: string };
type AsyncStamp = { sessionId: string; contextKey: string; lifecycle: number };
type VerifiedPage = { snapshot: SitePreviewPageSnapshot; expected: AsyncStamp };

export interface SitePreviewProps {
  sessionId: string | undefined;
  markdownHtml: string;
  articlePath?: string | null;
  inspect: (sessionId: string) => Promise<SitePreviewReadiness>;
  contextKey: string;
  document: SitePreviewDocumentBinding | null;
  unsaved?: boolean;
  plan: (sessionId: string, request: SitePreviewPlanRequest) => Promise<SitePreviewPlan>;
  start: (sessionId: string, planId: string, confirmed: boolean) => Promise<SitePreviewSnapshot>;
  check: (sessionId: string, previewId: string, target: Target) => Promise<SitePreviewPageSnapshot>;
  stop: (sessionId: string, previewId: string) => Promise<SitePreviewSnapshot>;
  isContextCurrent?: (expectedKey: string) => boolean;
}

export function SitePreview({
  sessionId, markdownHtml, articlePath, inspect, contextKey, document, unsaved = false,
  plan, start, check, stop, isContextCurrent = () => true,
}: SitePreviewProps) {
  const { t } = useI18n(sitePreviewMessages);
  const initialTarget: Target = safeSiteArticlePath(articlePath) ? "article" : "home";
  const [mode, setMode] = useState<"markdown" | "site">("markdown");
  const [readiness, setReadiness] = useState<SitePreviewReadiness | null>(null);
  const [snapshot, setSnapshot] = useState<SitePreviewSnapshot | null>(null);
  const [verifiedPage, setVerifiedPage] = useState<VerifiedPage | null>(null);
  const [siteTarget, setSiteTarget] = useState<Target>(initialTarget);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);

  const mountedRef = useRef(false);
  const sessionRef = useRef(sessionId);
  const contextKeyRef = useRef(contextKey);
  const isContextCurrentRef = useRef(isContextCurrent);
  const inspectRef = useRef(inspect);
  const stopRef = useRef(stop);
  const lifecycleRef = useRef(0);
  const inspectGenerationRef = useRef(0);
  const inspectRequestRef = useRef<{
    sessionId: string;
    promise: Promise<SitePreviewReadiness>;
  } | null>(null);
  const operationGenerationRef = useRef(0);
  const busyOwnerRef = useRef<number | null>(null);
  const probeGenerationRef = useRef(0);
  const targetRef = useRef<Target>(initialTarget);
  const ownerRef = useRef<PreviewOwner | null>(null);
  const previousContextRef = useRef<string | undefined>(undefined);
  const previousArticleRef = useRef<string | null | undefined>(undefined);

  sessionRef.current = sessionId;
  contextKeyRef.current = contextKey;
  isContextCurrentRef.current = isContextCurrent;
  inspectRef.current = inspect;
  stopRef.current = stop;

  function stamp(): AsyncStamp | null {
    return sessionId ? { sessionId, contextKey, lifecycle: lifecycleRef.current } : null;
  }

  function stampIsCurrent(expected: AsyncStamp): boolean {
    return mountedRef.current
      && sessionRef.current === expected.sessionId
      && contextKeyRef.current === expected.contextKey
      && lifecycleRef.current === expected.lifecycle
      && isContextCurrentRef.current(expected.contextKey);
  }

  function invalidateOperations() {
    operationGenerationRef.current += 1;
    busyOwnerRef.current = null;
    probeGenerationRef.current += 1;
    setBusy(false);
  }

  function stopOwner(owner: PreviewOwner | null) {
    if (!owner) return;
    void stopRef.current(owner.sessionId, owner.previewId).catch(() => undefined);
  }

  function releaseCurrentOwner() {
    const owner = ownerRef.current;
    ownerRef.current = null;
    stopOwner(owner);
  }

  useEffect(() => {
    mountedRef.current = true;
    const generation = ++inspectGenerationRef.current;
    lifecycleRef.current += 1;
    invalidateOperations();
    releaseCurrentOwner();
    setReadiness(null);
    setSnapshot(null);
    setVerifiedPage(null);
    setError(null);
    setMode("markdown");
    const nextTarget: Target = safeSiteArticlePath(articlePath) ? "article" : "home";
    targetRef.current = nextTarget;
    setSiteTarget(nextTarget);

    if (sessionId) {
      let request = inspectRequestRef.current;
      if (!request || request.sessionId !== sessionId) {
        request = { sessionId, promise: inspectRef.current(sessionId) };
        inspectRequestRef.current = request;
      }
      void request.promise.then((value) => {
        if (
          mountedRef.current && generation === inspectGenerationRef.current
          && sessionRef.current === sessionId
        ) setReadiness(value);
      }).catch((caught: unknown) => {
        if (
          mountedRef.current && generation === inspectGenerationRef.current
          && sessionRef.current === sessionId
        ) setError(caught);
      });
    }

    return () => {
      mountedRef.current = false;
      inspectGenerationRef.current += 1;
      lifecycleRef.current += 1;
      invalidateOperations();
      releaseCurrentOwner();
    };
    // articlePath is reset by its own effect. Keeping it out preserves one inspect per session.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId]);

  useEffect(() => {
    const changed = previousContextRef.current !== undefined
      && previousContextRef.current !== contextKey;
    previousContextRef.current = contextKey;
    if (!changed) return;
    lifecycleRef.current += 1;
    invalidateOperations();
    releaseCurrentOwner();
    setSnapshot(null);
    setVerifiedPage(null);
    setError(null);
  }, [contextKey]);

  useEffect(() => {
    const changed = previousArticleRef.current !== undefined
      && previousArticleRef.current !== articlePath;
    previousArticleRef.current = articlePath;
    if (!changed) return;
    lifecycleRef.current += 1;
    invalidateOperations();
    releaseCurrentOwner();
    setSnapshot(null);
    setVerifiedPage(null);
    setError(null);
    const nextTarget: Target = safeSiteArticlePath(articlePath) ? "article" : "home";
    targetRef.current = nextTarget;
    setSiteTarget(nextTarget);
  }, [articlePath]);

  const previewRoot = useMemo(() => safePreviewUrl(snapshot?.url ?? null), [snapshot?.url]);
  const articleUrl = useMemo(
    () => siteArticlePreviewUrl(previewRoot, articlePath),
    [articlePath, previewRoot],
  );
  const requestedUrl = siteTarget === "article" ? articleUrl : previewRoot;
  const showingArticle = siteTarget === "article" && Boolean(articleUrl);
  const snapshotId = snapshot?.previewId ?? null;
  const page = verifiedPage?.snapshot ?? null;
  const pageIsReady = Boolean(
    snapshot?.running && snapshotId && page && page.ready && page.previewId === snapshotId
    && requestedUrl && page.requestedUrl === requestedUrl && safePreviewUrl(page.url) === page.url
    && sameOrigin(page.url, previewRoot)
    && verifiedPage?.expected.sessionId === sessionId
    && verifiedPage?.expected.contextKey === contextKey
    && verifiedPage?.expected.lifecycle === lifecycleRef.current
    && isContextCurrentRef.current(contextKey),
  );

  function beginOperation(): number | null {
    if (busyOwnerRef.current !== null) return null;
    const token = ++operationGenerationRef.current;
    busyOwnerRef.current = token;
    setBusy(true);
    setError(null);
    return token;
  }

  function finishOperation(token: number) {
    if (busyOwnerRef.current !== token) return;
    busyOwnerRef.current = null;
    setBusy(false);
  }

  async function runProbe(expected: AsyncStamp, owner: PreviewOwner, target: Target) {
    const token = ++probeGenerationRef.current;
    targetRef.current = target;
    setSiteTarget(target);
    setVerifiedPage(null);
    setError(null);
    try {
      const checked = await check(owner.sessionId, owner.previewId, target);
      if (
        token === probeGenerationRef.current && targetRef.current === target
        && ownerRef.current?.sessionId === owner.sessionId
        && ownerRef.current.previewId === owner.previewId && stampIsCurrent(expected)
      ) setVerifiedPage({ snapshot: checked, expected });
    } catch (caught) {
      if (
        token === probeGenerationRef.current
        && ownerRef.current?.sessionId === owner.sessionId
        && ownerRef.current.previewId === owner.previewId && stampIsCurrent(expected)
      ) setError(caught);
    }
  }

  async function prepareAndStart() {
    if (
      !sessionId || !readiness?.supported || !readiness.runtimeAvailable || snapshot?.running
    ) return;
    const operationToken = beginOperation();
    const expected = stamp();
    if (operationToken === null || !expected) return;
    const activeSession = expected.sessionId;
    try {
      const planned = await plan(activeSession, { document, articlePath: articlePath ?? null });
      if (!stampIsCurrent(expected)) return;
      if (planned.expiresAtEpochMs <= Date.now()) {
        setError("preview_plan_expired");
        return;
      }
      const confirmed = window.confirm(t(
        "将运行本机 {runtime} 以预览此仓库。仅在你信任该仓库时继续。",
        { runtime: planned.executable || readiness.executable || planned.siteKind },
      ));
      if (!confirmed || !stampIsCurrent(expected)) return;
      if (planned.expiresAtEpochMs <= Date.now()) {
        setError("preview_plan_expired");
        return;
      }

      const next = await start(activeSession, planned.planId, true);
      const nextId = next.previewId;
      if (!nextId || !next.running || !stampIsCurrent(expected)) {
        if (nextId) stopOwner({ sessionId: activeSession, previewId: nextId });
        return;
      }

      const owner = { sessionId: activeSession, previewId: nextId };
      ownerRef.current = owner;
      setSnapshot(next);
      const nextRoot = safePreviewUrl(next.url);
      const nextTarget: Target = siteArticlePreviewUrl(nextRoot, articlePath) ? "article" : "home";
      await runProbe(expected, owner, nextTarget);
    } catch (caught) {
      if (stampIsCurrent(expected) && busyOwnerRef.current === operationToken) setError(caught);
    } finally {
      finishOperation(operationToken);
    }
  }

  async function probe(target: Target) {
    const owner = ownerRef.current;
    const expected = stamp();
    if (!owner || !expected || owner.sessionId !== expected.sessionId) return;
    await runProbe(expected, owner, target);
  }

  async function stopPreview() {
    const owner = ownerRef.current;
    const expected = stamp();
    if (!owner || !expected || owner.sessionId !== expected.sessionId) return;
    const operationToken = beginOperation();
    if (operationToken === null) return;
    ++probeGenerationRef.current;
    setVerifiedPage(null);
    try {
      const next = await stop(owner.sessionId, owner.previewId);
      if (
        stampIsCurrent(expected) && ownerRef.current?.sessionId === owner.sessionId
        && ownerRef.current.previewId === owner.previewId
      ) {
        ownerRef.current = null;
        setSnapshot(next);
      }
    } catch (caught) {
      if (stampIsCurrent(expected) && busyOwnerRef.current === operationToken) setError(caught);
    } finally {
      finishOperation(operationToken);
    }
  }

  return (
    <section className="preview-panel" aria-label={t("预览")}>
      <div className="panel-heading">
        <span>{t("预览")}</span>
        <div className="preview-modes" role="group" aria-label={t("预览模式")}>
          <button type="button" aria-pressed={mode === "markdown"} onClick={() => setMode("markdown")}>Markdown</button>
          <button type="button" aria-pressed={mode === "site"} onClick={() => setMode("site")}>{t("真实站点")}</button>
        </div>
      </div>
      {mode === "markdown" ? (
        <article className="markdown-preview" dangerouslySetInnerHTML={{ __html: markdownHtml }} />
      ) : (
        <div className="site-preview">
          {!sessionId && <p className="search-state">{t("选择仓库后可检查真实站点预览。")}</p>}
          {unsaved && <p className="git-warning">{t("真实预览使用已保存文件；未保存的编辑不会包含在内。")}</p>}
          {error !== null && (
            <p className="search-state error" role="alert">
              {t("预览错误：{error}", { error: reasonMessage(error, t) })}
            </p>
          )}
          {sessionId && !readiness && error === null && (
            <p className="search-state" role="status">{t("正在检查站点运行时…")}</p>
          )}
          {readiness && (
            <>
              <p>{readiness.siteKind} {readiness.version ? `(${readiness.version})` : ""}</p>
              {readiness.warning && <p className="git-warning">{reasonMessage(readiness.warning, t)}</p>}
              {!readiness.supported || !readiness.runtimeAvailable ? (
                <p className="search-state">{reasonMessage(readiness.reason ?? "preview_site_kind_unsupported", t)}</p>
              ) : (
                <div className="preview-actions">
                  <button
                    type="button"
                    onClick={() => void prepareAndStart()}
                    disabled={busy || Boolean(snapshot?.running)}
                  >
                    {busy ? t("处理中…") : t("启动 {runtime}", { runtime: readiness.executable ?? t("站点") })}
                  </button>
                  <button
                    type="button"
                    onClick={() => void stopPreview()}
                    disabled={busy || ownerRef.current === null}
                  >
                    {t("停止")}
                  </button>
                </div>
              )}
            </>
          )}
          {snapshot?.running && !pageIsReady && error === null && (
            <p className="search-state" role="status">
              {page ? reasonMessage(page.reason, t) : t("进程已运行，正在核验页面…")}
            </p>
          )}
          {snapshot?.running && (
            <div className="preview-modes" role="group" aria-label={t("真实站点页面")}>
              {articleUrl && (
                <button type="button" aria-pressed={showingArticle} onClick={() => void probe("article")}>
                  {t("当前文章")}
                </button>
              )}
              <button type="button" aria-pressed={!showingArticle} onClick={() => void probe("home")}>
                {t("站点首页")}
              </button>
              <button type="button" onClick={() => void probe(siteTarget)} disabled={busy}>
                {t("重新验证页面")}
              </button>
            </div>
          )}
          {pageIsReady && page && (
            <>
              <p className="search-state" role="status">{t("页面已就绪")}</p>
              <iframe
                className="site-preview-frame"
                title={showingArticle ? t("本机站点预览：当前文章") : t("本机站点预览：站点首页")}
                src={page.url}
                sandbox="allow-forms allow-scripts"
                referrerPolicy="no-referrer"
              />
            </>
          )}
        </div>
      )}
    </section>
  );
}

function sameOrigin(value: string, root: string | null): boolean {
  if (!root) return false;
  try {
    return new URL(value).origin === new URL(root).origin;
  } catch {
    return false;
  }
}

const REASON_SOURCES: Record<string, string> = {
  preview_unknown_error: "未知预览错误。",
  ready: "页面已就绪。",
  http_error: "页面核验失败。",
  timeout: "页面核验超时。",
  invalid_response: "页面返回了无效响应。",
  redirect_rejected: "页面重定向不安全，已拒绝嵌入。",
  process_exited: "预览进程在页面就绪前退出。",
  preview_context_changed: "预览上下文已变化，请重新验证。",
  preview_plan_expired: "预览计划已过期，请重新生成。",
  preview_article_unavailable: "当前文章没有可用的站点预览地址。",
  preview_site_kind_unsupported: "真实站点预览目前仅支持 Zola 和 Hugo；不会执行 Astro、Jekyll 或 npm 脚本。",
  runtime_not_found_in_trusted_locations: "未在受信任的系统或用户工具目录中找到对应运行时。",
  repository_root_not_safe: "仓库根目录未通过真实预览安全检查。",
  preview_page_not_ready: "页面尚未就绪。",
  preview_page_not_found: "未找到预览页面。",
  preview_page_probe_failed: "无法核验预览页面。",
  preview_process_exited: "预览进程在页面就绪前退出。",
  preview_timeout: "页面核验超时。",
  preview_page_unsafe_url: "站点返回了不安全的预览地址，已拒绝嵌入。",
  "A real preview processes content from this trusted repository.":
    "真实预览会处理本地仓库内容，请只对可信仓库启动。",
};

function reasonMessage(value: unknown, t: ReturnType<typeof useI18n>["t"]): string {
  let raw = "preview_unknown_error";
  if (isGatewayError(value)) {
    raw = Object.prototype.hasOwnProperty.call(REASON_SOURCES, value.code)
      ? value.code
      : "preview_unknown_error";
  } else if (typeof value === "string") {
    raw = value;
  } else if (value instanceof Error) {
    raw = value.message;
  }
  return t(REASON_SOURCES[raw] ?? raw);
}

function isGatewayError(value: unknown): value is GatewayError {
  return typeof value === "object" && value !== null
    && "code" in value && typeof value.code === "string";
}
