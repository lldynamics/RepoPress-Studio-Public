import { useI18n } from "../i18n/i18n";
import { useEffect, useRef, useState } from "react";
import type { CapabilitySnapshot, DocumentSnapshot, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { EditorSelectionSnapshot } from "../features/ai/selectionReplacement";
import { AIAssistant } from "./AIAssistant";
import { AIChatPanel } from "./AIChatPanel";
import { DocumentAnalysisPanel } from "./DocumentAnalysisPanel";
import { SemanticSearchPanel } from "./SemanticSearchPanel";
import { RepositoryContentHealthPanel } from "./RepositoryContentHealthPanel";
import { useDrawerFocus } from "../features/workspace/drawerFocus";

export type AdvancedToolTab = "ai" | "chat" | "semantic" | "document" | "health";

export interface AdvancedToolsProps {
  open: boolean;
  onClose: () => void;
  repository: RepositorySessionSnapshot | null;
  capabilities: CapabilitySnapshot | null;
  gateway: RepositoryGateway;
  document: DocumentSnapshot | null;
  currentDocumentText: string;
  selection: EditorSelectionSnapshot;
  onApplyAiReplacement: (expectedSelection: EditorSelectionSnapshot, replacementText: string) => boolean;
  onOpenSemanticPath: (path: string) => void;
  onOpenContentHealthIssue: (path: string, range: { from: number; to: number }, expectedDocumentText: string) => void;
  requestedTab?: AdvancedToolTab | null;
  requestedTabKey?: number;
  onActiveTabChange?: (tab: AdvancedToolTab) => void;
}

export function AdvancedTools({ open, onClose, repository, capabilities, gateway, document, currentDocumentText, selection, onApplyAiReplacement, onOpenSemanticPath, onOpenContentHealthIssue, requestedTab = null, requestedTabKey = 0, onActiveTabChange }: AdvancedToolsProps) {
  const { t } = useI18n();
  const [tab, setTab] = useState<AdvancedToolTab>(() => requestedTab ?? "ai");
  const drawer = useRef<HTMLElement>(null);
  const isDemo = capabilities !== null && !capabilities.localEdit;
  useDrawerFocus(open, drawer, onClose);
  useEffect(() => {
    if (!open) return;
    if (requestedTab) setTab(requestedTab);
    onActiveTabChange?.(requestedTab ?? tab);
    // Tab changes from user input report through selectTab; only route requests replay here.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, requestedTab, requestedTabKey, onActiveTabChange]);
  function selectTab(next: AdvancedToolTab) {
    setTab(next);
    onActiveTabChange?.(next);
  }
  const tabOrder: AdvancedToolTab[] = ["ai", "chat", "semantic", "document", "health"];
  function moveTab(event: React.KeyboardEvent<HTMLButtonElement>, current: AdvancedToolTab) {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const currentIndex = tabOrder.indexOf(current);
    const next = event.key === "Home" ? tabOrder[0]
      : event.key === "End" ? tabOrder[tabOrder.length - 1]
      : tabOrder[(currentIndex + (event.key === "ArrowRight" ? 1 : -1) + tabOrder.length) % tabOrder.length];
    selectTab(next);
    queueMicrotask(() => globalThis.document.getElementById(`tool-tab-${next}`)?.focus());
  }
  return <aside ref={drawer} className={open ? "advanced-tools open" : "advanced-tools"} role="dialog" aria-modal="true" aria-labelledby="advanced-tools-title" aria-hidden={!open} inert={!open} tabIndex={-1}>
    <div className="publish-header"><div><h1 id="advanced-tools-title">{t("智能工具")}</h1><p>{t("高级能力均需显式触发；索引和提案不会自动写入文件。")}</p></div><button type="button" className="publish-close" onClick={onClose} aria-label={t("关闭智能工具")}>×</button></div>
    <div className="advanced-tabs" role="tablist" aria-label={t("智能工具类型")}>
      <button type="button" role="tab" id="tool-tab-ai" aria-controls="tool-panel-ai" aria-selected={tab === "ai"} tabIndex={tab === "ai" ? 0 : -1} onKeyDown={(event) => moveTab(event, "ai")} onClick={() => selectTab("ai")}>{t("AI 编辑")}</button>
      <button type="button" role="tab" id="tool-tab-chat" aria-controls="tool-panel-chat" aria-selected={tab === "chat"} tabIndex={tab === "chat" ? 0 : -1} onKeyDown={(event) => moveTab(event, "chat")} onClick={() => selectTab("chat")}>{t("AI 对话")}</button>
      <button type="button" role="tab" id="tool-tab-semantic" aria-controls="tool-panel-semantic" aria-selected={tab === "semantic"} tabIndex={tab === "semantic" ? 0 : -1} onKeyDown={(event) => moveTab(event, "semantic")} onClick={() => selectTab("semantic")}>{t("语义检索")}</button>
      <button type="button" role="tab" id="tool-tab-document" aria-controls="tool-panel-document" aria-selected={tab === "document"} tabIndex={tab === "document" ? 0 : -1} onKeyDown={(event) => moveTab(event, "document")} onClick={() => selectTab("document")}>PDF / OCR</button>
      <button type="button" role="tab" id="tool-tab-health" aria-controls="tool-panel-health" aria-selected={tab === "health"} tabIndex={tab === "health" ? 0 : -1} onKeyDown={(event) => moveTab(event, "health")} onClick={() => selectTab("health")}>{t("内容健康")}</button>
    </div>
    <div className="advanced-content">
      <div id="tool-panel-ai" role="tabpanel" aria-labelledby="tool-tab-ai" hidden={tab !== "ai"}><AIAssistant active={open && tab === "ai"} enabled={capabilities?.aiEditing === true && document?.writable === true} isDemo={isDemo} sessionId={repository?.sessionId ?? null} documentId={document?.documentId ?? null} documentRevision={document?.revision ?? null} selection={selection} gateway={gateway} onApplyReplacement={onApplyAiReplacement} /></div>
      <div id="tool-panel-chat" role="tabpanel" aria-labelledby="tool-tab-chat" hidden={tab !== "chat"}><AIChatPanel active={open && tab === "chat"} enabled={capabilities?.aiEditing === true} isDemo={isDemo} gateway={gateway} /></div>
      <div id="tool-panel-semantic" role="tabpanel" aria-labelledby="tool-tab-semantic" hidden={tab !== "semantic"}><SemanticSearchPanel active={open && tab === "semantic"} enabled={capabilities?.semanticSearch === true} sessionId={repository?.sessionId ?? null} gateway={gateway} onOpenPath={onOpenSemanticPath} /></div>
      <div id="tool-panel-document" role="tabpanel" aria-labelledby="tool-tab-document" hidden={tab !== "document"}><DocumentAnalysisPanel active={open && tab === "document"} enabled={capabilities?.pdfTextExtraction === true} isDemo={isDemo} gateway={gateway} /></div>
      <div id="tool-panel-health" role="tabpanel" aria-labelledby="tool-tab-health" hidden={tab !== "health"}><RepositoryContentHealthPanel active={open && tab === "health"} enabled={capabilities?.contentHealth === true} sessionId={capabilities?.contentHealth === true ? repository?.sessionId ?? null : null} gateway={gateway} currentDocument={document ? { relativePath: document.relativePath, text: currentDocumentText } : null} onOpenIssue={onOpenContentHealthIssue} /></div>
    </div>
  </aside>;
}
