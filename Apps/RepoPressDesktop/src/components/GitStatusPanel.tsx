import { useEffect, useRef, useState } from "react";
import type { GitDiffSnapshot, GitStatusSnapshot } from "../contracts/repository";
import { useI18n } from "../i18n/i18n";
import type { UiMessage } from "../i18n/uiMessage";

export function GitStatusPanel({ status, sessionId, getDiff }: { status: GitStatusSnapshot; sessionId: string; getDiff: (sessionId: string, relativePath: string) => Promise<GitDiffSnapshot> }) {
  const { t } = useI18n();
  const [selectedPath, setSelectedPath] = useState<string | null>(null);
  const [diff, setDiff] = useState<GitDiffSnapshot | null>(null);
  const [error, setError] = useState<string | UiMessage | null>(null);
  const [loading, setLoading] = useState(false);
  const requestNumber = useRef(0);
  useEffect(() => { setSelectedPath(null); setDiff(null); setError(null); setLoading(false); requestNumber.current += 1; }, [sessionId, status]);
  async function openDiff(relativePath: string) {
    const requestId = ++requestNumber.current; setSelectedPath(relativePath); setLoading(true); setError(null); setDiff(null);
    try { const next = await getDiff(sessionId, relativePath); if (requestId === requestNumber.current) setDiff(next); }
    catch (caught) { if (requestId === requestNumber.current) setError(messageFrom(caught)); }
    finally { if (requestId === requestNumber.current) setLoading(false); }
  }
  return <section className="git-status" aria-label={t("Git 状态（只读）")}>
    <div className="panel-heading"><span>{t("Git 状态")}</span><span className="readonly-badge">{t("只读")}</span></div>
    <p>{status.branch ?? t("无可用分支")}</p><p>{status.available ? (status.changedFiles.length ? t("{count} 项本地改动", { count: status.changedFiles.length }) : t("工作区干净")) : t("当前目录不是 Git 仓库")}</p>
    {status.warnings.map((warning) => <p className="git-warning" key={warning}>{gitWarning(warning, t)}</p>)}
    {status.available && status.changedFiles.length > 0 && <div className="changed-files" aria-label={t("已改变文件")}>{status.changedFiles.map((file) => <button key={`${file.status}:${file.relativePath}`} type="button" className={selectedPath === file.relativePath ? "changed-file active" : "changed-file"} onClick={() => void openDiff(file.relativePath)}><span>{file.status}</span>{file.relativePath}</button>)}</div>}
    {loading && <p className="search-state" role="status">{t("正在读取 diff…")}</p>}
    {error && <p className="search-state error" role="alert">{t("无法读取 diff：{message}", { message: typeof error === "string" ? error : t(error.source, error.parameters) })}</p>}
    {diff && <DiffView diff={diff} />}
  </section>;
}

function DiffView({ diff }: { diff: GitDiffSnapshot }) {
  const { t } = useI18n();
  return <div className="diff-view" aria-label={t("{path} 的 Git diff", { path: diff.relativePath })}>
    {diff.warnings.map((warning) => <p className="git-warning" key={warning}>{gitWarning(warning, t)}</p>)}
    {diff.binary && <p className="search-state">{t("二进制文件无法显示文本 diff。")}</p>}
    {diff.truncated && <p className="search-state">{t("diff 已截断，显示内容不完整。")}</p>}
    {!diff.binary && !diff.stagedPatch && !diff.workingTreePatch && <p className="search-state">{t("该文件没有可显示的文本改动。")}</p>}
    {diff.stagedPatch && <><h3>{t("暂存区")}</h3><pre>{diff.stagedPatch}</pre></>}
    {diff.workingTreePatch && <><h3>{t("工作树")}</h3><pre>{diff.workingTreePatch}</pre></>}
  </div>;
}
function gitWarning(value: string, t: (source: string) => string): string {
  const source = {
    not_git_repository: "当前目录不是 Git 仓库。",
    untracked_file_has_no_git_patch: "未跟踪文件还没有可显示的 Git patch。",
    untracked_symlink_not_previewed: "未跟踪的符号链接不会被读取或预览。",
    diff_output_truncated: "diff 超出安全输出上限，已截断。",
  }[value];
  return source ? t(source) : value;
}
function messageFrom(error: unknown): string | UiMessage {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null && "message" in error && typeof error.message === "string") return error.message;
  if (typeof error === "string") return error;
  return { source: "未知错误" };
}
