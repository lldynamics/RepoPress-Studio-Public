import { open } from "@tauri-apps/plugin-dialog";
import { useEffect, useRef, useState } from "react";
import type {
  DocumentCapabilities,
  PdfOcrExtraction,
  PdfOcrLanguage,
  PdfSelection,
  PdfTextExtraction,
  KnowledgeImportResult,
} from "../contracts/repository";
import { useI18n } from "../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";

const PREVIEW_CHARACTER_LIMIT = 8_000;

export interface DocumentAnalysisGateway {
  documentCapabilities(): Promise<DocumentCapabilities>;
  selectPdf(path: string): Promise<PdfSelection>;
  extractPdfText(token: string): Promise<PdfTextExtraction>;
  extractPdfOcr(token: string, language: PdfOcrLanguage): Promise<PdfOcrExtraction>;
  importKnowledgeText(request: { sourceKind: "pdf"; title: string; sourceName: string; sourceUrl: string | null; text: string; allowsLocalSemanticIndex: boolean }): Promise<KnowledgeImportResult>;
}

export interface DocumentAnalysisPanelProps {
  enabled: boolean;
  isDemo: boolean;
  gateway: DocumentAnalysisGateway;
  active: boolean;
}

/**
 * A deliberately two-step PDF flow. Selecting a file only creates a short
 * lived authorization token; extracting its text requires a separate click
 * and sends that token, never a path or capability object, to the backend.
 */
export function DocumentAnalysisPanel({
  enabled,
  isDemo,
  gateway,
  active,
}: DocumentAnalysisPanelProps) {
  const [capabilities, setCapabilities] = useState<DocumentCapabilities | null>(null);
  const [selection, setSelection] = useState<PdfSelection | null>(null);
  const [result, setResult] = useState<(PdfTextExtraction & { mode: "text" }) | (PdfOcrExtraction & { mode: "ocr" }) | null>(null);
  const [ocrLanguage, setOcrLanguage] = useState<PdfOcrLanguage>("eng");
  const [busy, setBusy] = useState<"select" | "extract" | "ocr" | "import" | null>(null);
  const [message, setMessage] = useState<UiMessage | null>(null);
  const [copied, setCopied] = useState(false);
  const [importMessage, setImportMessage] = useState<UiMessage | null>(null);
  const { t, locale } = useI18n();
  const [sourceName, setSourceName] = useState("");
  const [allowKnowledgeSemanticIndex, setAllowKnowledgeSemanticIndex] = useState(false);
  const requestId = useRef(0);

  useEffect(() => {
    if (active) return;
    requestId.current += 1;
    setSelection(null);
    setResult(null);
    setMessage(null);
    setCopied(false);
    setImportMessage(null);
    setSourceName("");
    setAllowKnowledgeSemanticIndex(false);
    setBusy(null);
  }, [active]);

  useEffect(() => {
    if (!isDemo) return;
    requestId.current += 1;
    setCapabilities(null);
    setSelection(null);
    setResult(null);
    setBusy(null);
    setMessage(null);
    setCopied(false);
    setImportMessage(null);
    setSourceName("");
    setAllowKnowledgeSemanticIndex(false);
  }, [isDemo]);

  async function choosePdf() {
    if (!enabled || isDemo || busy) return;
    const currentRequest = ++requestId.current;
    setBusy("select");
    setMessage(null);
    setResult(null);
    setSelection(null);
    setCopied(false);
    setImportMessage(null);
    try {
      // Capability probing is intentional and click-triggered. The dialog is
      // also only opened after this explicit user action.
      const nextCapabilities = await gateway.documentCapabilities();
      if (currentRequest !== requestId.current) return;
      setCapabilities(nextCapabilities);
      const ocrReady = nextCapabilities.ocr.enabled && nextCapabilities.ocr.ready;
      if (!nextCapabilities.pdfTextReady && !ocrReady) {
        setMessage({ source: "PDF 文字层和本地 OCR 依赖均未就绪；未打开文件选择器，也未读取任何 PDF。" });
        return;
      }

      const path = await open({
        multiple: false,
        directory: false,
        filters: [{ name: "PDF", extensions: ["pdf"] }],
      });
      if (currentRequest !== requestId.current || typeof path !== "string") return;
      const nextSelection = await gateway.selectPdf(path);
      if (currentRequest !== requestId.current) return;
      setSelection(nextSelection);
      setSourceName(nextSelection.fileName);
      setMessage({ source: "PDF 已验证。请选择一种方式并再次明确确认；授权仅能消费一次。" });
    } catch (error) {
      if (currentRequest === requestId.current) setMessage(localError("无法选择 PDF：{error}", error));
    } finally {
      if (currentRequest === requestId.current) setBusy(null);
    }
  }

  async function extractText() {
    if (!enabled || isDemo || busy || !selection) return;
    const approvedSelection = selection;
    const currentRequest = ++requestId.current;
    // The UI token is invalidated before the async operation begins. The
    // backend also consumes it first, so retries require a new selection.
    setSelection(null);
    setBusy("extract");
    setMessage(null);
    setCopied(false);
    try {
      const nextResult = await gateway.extractPdfText(approvedSelection.token);
      if (currentRequest !== requestId.current) return;
      setResult({ ...nextResult, mode: "text" });
      setMessage({ source: "已完成 PDF 文字层提取。" });
    } catch (error) {
      if (currentRequest === requestId.current) setMessage(localError("无法提取文字层：{error}", error));
    } finally {
      if (currentRequest === requestId.current) setBusy(null);
    }
  }

  async function extractOcr() {
    if (!enabled || isDemo || busy || !selection || !capabilities?.ocr.enabled || !capabilities.ocr.ready) return;
    const approvedSelection = selection;
    const currentRequest = ++requestId.current;
    setSelection(null);
    setBusy("ocr");
    setMessage(null);
    setCopied(false);
    try {
      const nextResult = await gateway.extractPdfOcr(approvedSelection.token, ocrLanguage);
      if (currentRequest !== requestId.current) return;
      setResult({ ...nextResult, mode: "ocr" });
      setMessage({ source: "已完成本地 OCR。" });
    } catch (error) {
      if (currentRequest === requestId.current) setMessage(localError("无法执行本地 OCR：{error}", error));
    } finally {
      if (currentRequest === requestId.current) setBusy(null);
    }
  }

  async function copyResult() {
    if (!result) return;
    try {
      await navigator.clipboard.writeText(result.text);
      setCopied(true);
    } catch (error) {
      setMessage(localError("无法复制完整文本：{error}", error));
    }
  }
  async function importResult() {
    if (!result || !sourceName || busy) return;
    const currentRequest = requestId.current;
    setBusy("import");
    setImportMessage(null);
    try {
      const imported = await gateway.importKnowledgeText({ sourceKind: "pdf", title: sourceName.replace(/\.pdf$/i, ""), sourceName, sourceUrl: null, text: result.text, allowsLocalSemanticIndex: allowKnowledgeSemanticIndex });
      if (currentRequest === requestId.current) setImportMessage({ source: imported.deduplicated ? "资料已存在，未重复保存。" : "已导入本地资料库。" });
    } catch (error) {
      if (currentRequest === requestId.current) setImportMessage(localError("导入资料库失败：{error}", error));
    } finally {
      if (currentRequest === requestId.current) setBusy(null);
    }
  }

  const ready = capabilities?.pdfTextReady === true;
  const ocrReady = capabilities?.ocr.enabled === true && capabilities.ocr.ready === true;
  const preview = result ? previewText(result.text, t) : null;
  return (
    <section className="advanced-document-analysis" aria-label={t("PDF 文档分析")} hidden={!active}>
      <div className="panel-heading">
        <span>{t("PDF 文档分析")}</span>
        <span className="readonly-badge">{t("可选")}</span>
      </div>
      <p className="tool-muted">{t("选择 PDF 后，可提取已有文字层，或在本机执行最多 12 页 OCR。两种方式只能确认一种。")}</p>
      {isDemo && <p className="tool-warning">{t("浏览器演示不会打开系统文件选择器、读取 PDF 或调用文档工具。")}</p>}
      {!isDemo && !enabled && <p className="tool-warning">{t("当前桌面环境未启用可选文档分析。")}</p>}
      {capabilities && <CapabilityStatus capabilities={capabilities} />}
      {message && <p className="tool-state" role="status">{renderUiMessage(message, t)}</p>}

      <div className="tool-actions">
        <button type="button" onClick={() => void choosePdf()} disabled={!enabled || isDemo || busy !== null}>
          {busy === "select" ? t("正在检查并选择…") : t("检查能力并选择 PDF")}
        </button>
        <button
          type="button"
          className="danger-action"
          onClick={() => void extractText()}
          disabled={!enabled || isDemo || busy !== null || !selection || !ready}
        >
          {busy === "extract" ? t("正在提取…") : t("提取已有文字层")}
        </button>
        <label className="tool-inline-label" htmlFor="ocr-language">{t("OCR 语言")}</label>
        <select id="ocr-language" value={ocrLanguage} onChange={(event) => setOcrLanguage(event.target.value as PdfOcrLanguage)} disabled={!ocrReady || busy !== null || !selection}>
          <option value="eng">{t("英语")}</option><option value="chi_sim">{t("简体中文")}</option><option value="eng+chi_sim">{t("中英混合")}</option>
        </select>
        <button type="button" className="danger-action" onClick={() => void extractOcr()} disabled={!enabled || isDemo || busy !== null || !selection || !ocrReady}>
          {busy === "ocr" ? t("正在本地 OCR…") : t("本地 OCR（最多 12 页）")}
        </button>
      </div>

      {selection && <SelectionCard selection={selection} />}
      {result && (
        <section className="tool-result" aria-label={t("PDF 文本分析结果")}>
          <h3>{t(result.mode === "ocr" ? "本地 OCR 结果" : "文字层结果")}</h3>
          <p className="tool-muted">{result.mode === "ocr" ? t("来源：{source} · 语言：{language} · 识别 {count} 页", { source: t("本地 OCR"), language: languageLabel(result.language, t), count: result.pageCount }) : t("来源：{source} · 无需 OCR", { source: t("PDF 已有文字层") })}</p>
          <p className="tool-muted">{t("界面最多显示 {count} 个字符；复制按钮仍会复制完整结果。", { count: PREVIEW_CHARACTER_LIMIT.toLocaleString(locale) })}</p>
          <pre className="tool-text-preview">{preview || t("（未识别到文本）")}</pre>
          <div className="tool-actions">
            <button type="button" onClick={() => void copyResult()}>{copied ? t("已复制完整文本") : t("复制完整文本")}</button>
            <label className="knowledge-check" htmlFor="pdf-knowledge-semantic"><input id="pdf-knowledge-semantic" type="checkbox" checked={allowKnowledgeSemanticIndex} onChange={(event) => setAllowKnowledgeSemanticIndex(event.target.checked)} disabled={busy !== null} />{t("允许导入后参与本机语义索引")}</label>
            <button type="button" onClick={() => void importResult()} disabled={busy !== null || !result.text.trim()}>{busy === "import" ? t("正在导入…") : t("导入资料库")}</button>
          </div>
          {importMessage && <p className="tool-state" role="status">{renderUiMessage(importMessage, t)}</p>}
          {result.warnings.map((warning) => <p className="tool-warning" key={warning}>{warningLabel(warning, t)}</p>)}
        </section>
      )}
    </section>
  );
}

function SelectionCard({ selection }: { selection: PdfSelection }) {
  const { t, locale } = useI18n();
  const expiresAt = new Date(selection.expiresAtEpochSeconds * 1_000);
  const displayExpiry = Number.isNaN(expiresAt.getTime()) ? t("约 5 分钟后") : expiresAt.toLocaleTimeString(locale);
  return <section className="tool-selection" aria-label={t("待提取 PDF")}>
    <h3>{t("已验证，等待确认")}</h3>
    <p>{selection.fileName} · {formatBytes(selection.byteSize, locale)}</p>
    <p className="tool-muted">{t("此授权仅一次有效，将在 {time}（最多 5 分钟）过期。点击任一确认按钮才会处理文件。", { time: displayExpiry })}</p>
    {selection.warnings.map((warning) => <p className="tool-warning" key={warning}>{warningLabel(warning, t)}</p>)}
  </section>;
}

function CapabilityStatus({ capabilities }: { capabilities: DocumentCapabilities }) {
  const { t } = useI18n();
  const ready = (value: boolean) => value ? t("已就绪") : t("不可用");
  const found = (value: boolean) => value ? t("已找到") : t("不可用");
  return <section className="tool-capabilities" aria-label={t("PDF 工具状态")}>
    <p className={capabilities.pdfTextReady ? "tool-ready" : "tool-warning"}>
      {t("PDF 文字层：{status}", { status: ready(capabilities.pdfTextReady) })}
    </p>
    <p className="tool-muted">{t("隔离环境：{sandbox} · pdftotext：{pdftotext}", { sandbox: capabilities.sandbox.available ? t("已验证") : t("不可用"), pdftotext: found(capabilities.pdftotext.available) })}</p>
    <p className={capabilities.ocr.enabled && capabilities.ocr.ready ? "tool-ready" : "tool-muted"}>{t("OCR：{status}", { status: capabilities.ocr.enabled && capabilities.ocr.ready ? t("已就绪，可在本机执行") : t("不可用") })}</p>
    <p className="tool-muted">{t("pdfinfo：{status}", { status: found(capabilities.ocr.pdfInfo.available) })}</p>
    {capabilities.warnings.map((warning) => <p className="tool-warning" key={warning}>{warningLabel(warning, t)}</p>)}
  </section>;
}

function previewText(value: string, t: (source: string) => string): string {
  return value.length <= PREVIEW_CHARACTER_LIMIT ? value : `${value.slice(0, PREVIEW_CHARACTER_LIMIT)}\n\n…${t("预览已截断；完整文本仍可复制")}`;
}

function formatBytes(value: number, locale: string): string {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toLocaleString(locale, { maximumFractionDigits: 1 })} KiB`;
  return `${(value / (1024 * 1024)).toLocaleString(locale, { maximumFractionDigits: 1 })} MiB`;
}

function languageLabel(value: PdfOcrLanguage, t: (source: string) => string): string {
  return t(({ eng: "英语", chi_sim: "简体中文", "eng+chi_sim": "中英混合" }[value]));
}

function warningLabel(value: string, t: (source: string) => string): string {
  const source = {
    ocr_readiness_only: "OCR 当前不可用。",
    ocr_requires_explicit_local_confirmation: "OCR 只在本机运行，并且需要再次明确确认。",
    ocr_page_empty: "至少一页没有识别到文字。",
    ocr_text_sanitized: "为安全显示，OCR 文本中的控制字符已清理。",
    pdf_text_extraction_unavailable: "PDF 文字层提取依赖未就绪。",
    ocr_dependencies_unavailable: "OCR 的可选依赖不完整。",
    pdf_text_layer_empty: "该 PDF 没有可提取的文字层。",
    pdf_text_sanitized: "提取文本中的控制字符已清理。",
    pdf_text_truncated: "提取文本超过安全上限，结果已截断。",
  }[value];
  return source ? t(source) : value;
}

function messageFrom(error: unknown): string | UiMessage {
  if (!(error instanceof Error) && (typeof error !== "object" || error === null || !("message" in error) || typeof error.message !== "string") && typeof error !== "string") return { source: "未知错误" };
  const raw = (error instanceof Error ? error.message : typeof error === "object" ? error.message : error) as string;
  // Native errors may contain local paths; keep the UI reviewable without exposing them.
  return raw.replace(/(?:[A-Za-z]:[\\/]|\/)[^\s，。；：:]+/g, "[本地文件]");
}

function localError(source: string, error: unknown): UiMessage {
  const detail = messageFrom(error);
  return typeof detail === "string" ? { source, parameters: { error: detail } } : { source, parameters: { error: "" }, labels: { error: detail } };
}
