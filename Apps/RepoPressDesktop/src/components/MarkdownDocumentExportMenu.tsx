import { useState } from "react";
import { useI18n } from "../i18n/i18n";
import { editingMenuMessages } from "../i18n/editingMenuMessages";
import {
  createMarkdownDocumentExportPlan,
  type MarkdownDocumentExportFormat,
  type MarkdownDocumentExportPlan,
} from "../features/export/markdownDocumentExport";
import "./MarkdownDocumentExportMenu.css";

export type MarkdownDocumentExportSaveResult = void | { status: "saved" | "cancelled" };

export interface MarkdownDocumentExportMenuProps {
  markdown: string;
  fileName?: string | null;
  title?: string | null;
  disabled?: boolean;
  /**
   * Owns the desktop save dialog and UTF-8 write. It is deliberately injected:
   * this component cannot obtain filesystem authority or fall back to a browser download.
   */
  onSave?: (plan: MarkdownDocumentExportPlan) => Promise<MarkdownDocumentExportSaveResult> | MarkdownDocumentExportSaveResult;
  onSuccess?: (plan: MarkdownDocumentExportPlan) => void;
  onError?: (error: unknown, plan: MarkdownDocumentExportPlan) => void;
}

export function MarkdownDocumentExportMenu({
  markdown,
  fileName,
  title,
  disabled = false,
  onSave,
  onSuccess,
  onError,
}: MarkdownDocumentExportMenuProps) {
  const { t } = useI18n(editingMenuMessages);
  const [busyFormat, setBusyFormat] = useState<MarkdownDocumentExportFormat | null>(null);
  const unavailable = disabled || !onSave;

  async function save(format: MarkdownDocumentExportFormat) {
    if (unavailable || busyFormat) return;
    const plan = createMarkdownDocumentExportPlan({ markdown, fileName, title }, format);
    setBusyFormat(format);
    try {
      const result = await onSave(plan);
      // Cancelling a platform dialog is intentionally silent and does not
      // change editor state or emit a misleading success message.
      if (result?.status !== "cancelled") onSuccess?.(plan);
    } catch (error) {
      onError?.(error, plan);
    } finally {
      setBusyFormat(null);
    }
  }

  return <div className="markdown-document-export-menu" role="group" aria-label={t("导出文稿")}>
    <button type="button" onClick={() => void save("markdown")} disabled={unavailable || Boolean(busyFormat)} title={onSave ? t("导出当前缓冲区为 Markdown") : t("当前平台尚未接入保存能力")} aria-label={t(busyFormat === "markdown" ? "正在导出 Markdown…" : "导出 Markdown…")}>
      {t(busyFormat === "markdown" ? "正在导出 Markdown…" : "导出 Markdown…")}
    </button>
    <button type="button" onClick={() => void save("html")} disabled={unavailable || Boolean(busyFormat)} title={onSave ? t("导出当前缓冲区为 HTML") : t("当前平台尚未接入保存能力")} aria-label={t(busyFormat === "html" ? "正在导出 HTML…" : "导出 HTML…")}>
      {t(busyFormat === "html" ? "正在导出 HTML…" : "导出 HTML…")}
    </button>
  </div>;
}
