import type { ReactNode } from "react";
import type { WritingStats } from "../features/writing/markdownWriting";
import type { MarkdownDiagnosticsSession } from "../features/writing/useMarkdownDiagnostics";
import { markdownDiagnosticStatusMessage } from "../features/writing/markdownDiagnosticStatus";
import { useI18n } from "../i18n/i18n";
import "./WorkspaceStatusBar.css";

export interface WorkspaceStatusBarDocument {
  relativePath: string;
  writable: boolean;
  encoding: string;
  lineEnding: string;
}

export type WorkspaceStatus = "clean" | "dirty" | "saving" | "saved" | "conflict" | "failed";

export interface WorkspaceStatusBarProps {
  document?: WorkspaceStatusBarDocument;
  state: WorkspaceStatus;
  stats?: WritingStats;
  diagnostics?: { errors: number; warnings: number };
  diagnosticStatus?: MarkdownDiagnosticsSession["status"];
  diagnosticTruncated?: boolean;
  onOpenDiagnostics?: () => void;
  disabled?: boolean;
  children?: ReactNode;
}

const statusLabels: Record<WorkspaceStatus, string> = {
  clean: "已保存", dirty: "有未保存修改", saving: "正在保存…", saved: "刚刚保存", conflict: "保存冲突", failed: "保存失败",
};

function formatEncoding(value: string): string {
  return value.toLocaleLowerCase() === "utf-8" ? "UTF-8" : value;
}

function formatLineEnding(value: string): string {
  switch (value.toLocaleLowerCase()) {
    case "lf": return "LF";
    case "crlf": return "CRLF";
    case "mixed": return "混合换行";
    case "none": return "无换行";
    default: return value;
  }
}

export function WorkspaceStatusBar({ document, state, stats, diagnostics, diagnosticStatus, diagnosticTruncated = false, onOpenDiagnostics, disabled = false, children }: WorkspaceStatusBarProps) {
  const { t } = useI18n();
  const statusText = document ? (!document.writable && (state === "clean" || state === "saved") ? t("只读") : t(statusLabels[state])) : t("未打开文档");
  const diagnosticsDisabled = disabled || !onOpenDiagnostics || (!diagnostics && !diagnosticStatus);
  const diagnosticCountsReady = diagnostics && (!diagnosticStatus || diagnosticStatus === "ready");
  const diagnosticLabel = diagnosticCountsReady ? t("本地诊断：{errors} 个错误，{warnings} 个警告", { errors: diagnostics.errors, warnings: diagnostics.warnings })
    : t(markdownDiagnosticStatusMessage(diagnosticStatus ?? "idle"));
  return <footer className="workspace-status-bar" aria-label={t("工作区状态栏")}>
    <div className="workspace-status-bar__primary">
      <span className={`workspace-status-bar__state workspace-status-bar__state--${state}`} role="status" aria-live="polite">{statusText}</span>
      {document && <><span className="workspace-status-bar__path" title={document.relativePath}>{document.relativePath}</span><span className="workspace-status-bar__access">{document.writable ? t("可写") : t("只读")}</span></>}
    </div>
    {children && <div className="workspace-status-bar__cursor">{children}</div>}
    {document && stats && <div className="workspace-status-bar__stats" aria-label={t("文稿统计")}>
      <span>{t("{count} 字词", { count: stats.words })}</span><span>{t("{count} 字符", { count: stats.characters })}</span><span>{t("预计阅读 {minutes} 分钟", { minutes: stats.readingMinutes })}</span>
    </div>}
    {document && <div className="workspace-status-bar__format" aria-label={t("文稿格式")}><span>{formatEncoding(document.encoding)}</span><span>{t(formatLineEnding(document.lineEnding))}</span></div>}
    {document && (diagnostics || diagnosticStatus) && <button type="button" className="workspace-status-bar__diagnostics" onClick={onOpenDiagnostics} disabled={diagnosticsDisabled} aria-label={`${diagnosticLabel}${diagnosticCountsReady && diagnosticTruncated ? ` · ${t("检查结果已截断")}` : ""}`}>
      {diagnosticCountsReady ? <><span>{t("{count} 错误", { count: diagnostics.errors })}</span><span>{t("{count} 警告", { count: diagnostics.warnings })}</span>{diagnosticTruncated && <span>{t("检查结果已截断")}</span>}</> : <span>{diagnosticLabel}</span>}
    </button>}
  </footer>;
}
