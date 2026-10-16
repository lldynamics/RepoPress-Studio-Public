import { flushSync } from "react-dom";
import { exitActivity } from "./platform/exitActivity";
import { editorExitGateway, listenForEditorClose } from "./platform/editorExitGateway";
import { EditorExitController, type EditorExitState } from "./features/workspace/editorExit";
import { EditorExitDialog } from "./components/EditorExitDialog";
import type { SiteProfile, SiteProfileSnapshot } from "./contracts/sites";
import type { MetadataBatchPlan, MetadataBatchRequest, MetadataBatchResult } from "./contracts/metadataBatch";
import { SiteProfileSwitcher } from "./components/SiteProfileSwitcher";
import { SiteWorkspace } from "./components/SiteWorkspace";
import type { ArticleStateContext, ArticleStateLocation } from "./contracts/articleState";
import type { ArticleStateChangePlan } from "./contracts/articleStateChange";
import { prepareRepositorySwitch, type RepositoryTarget } from "./features/workspace/repositorySwitch";
import { Component, lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState, type ClipboardEvent as ReactClipboardEvent, type FormEvent as ReactFormEvent, type ReactNode } from "react";
import type { ReactCodeMirrorRef } from "@uiw/react-codemirror";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { type DocumentSnapshot, type GeneralDraftTransferResult, type GitStatusSnapshot, type MarkdownFileEntry, type MarkdownSearchResult, type RepositorySessionSnapshot, type WorkspacePreferences, type WorkspaceStateSnapshot, type WritingImageImportResult } from "./contracts/repository";
import { createRepositoryGateway } from "./platform/repositoryGateway";
import { renderMarkdownPreview } from "./preview/renderMarkdownPreview";
import { resolveEditorLocation, type EditorLocation } from "./features/workspace/editorNavigation";
import { FileNavigator } from "./components/FileNavigator";
import { WorkspaceNavigation, type WorkspaceSection } from "./components/WorkspaceNavigation";
import { WorkspaceActionMenu } from "./components/WorkspaceActionMenu";
import { ResizableWorkspace } from "./components/ResizableWorkspace";
import { WorkspaceInspector } from "./components/WorkspaceInspector";
import { WorkspaceStatusBar } from "./components/WorkspaceStatusBar";
import { I18nProvider, useI18n, useUiLanguage } from "./i18n/i18n";
import { renderUiMessage, type UiMessage } from "./i18n/uiMessage";
import { GitStatusPanel } from "./components/GitStatusPanel";
const SitePreview = lazy(() => import("./components/SitePreview").then((module) => ({ default: module.SitePreview })));
import { WorkspaceCommandPalette, type WorkspaceCommand } from "./components/WorkspaceCommandPalette";
import { DraftLifecycleDialog, type DraftLifecycleMode } from "./components/DraftLifecycleDialog";
import { FrontMatterPanel } from "./components/FrontMatterPanel";
import { MetadataInspector } from "./components/MetadataInspector";
import { MarkdownOutlinePanel } from "./components/MarkdownOutlinePanel";
import { MarkdownWritingToolbar } from "./components/MarkdownWritingToolbar";
import type { AdvancedToolTab } from "./components/AdvancedTools";
import { MarkdownAdvancedEditingMenu } from "./components/MarkdownAdvancedEditingMenu";
import { MarkdownTableEditingMenu } from "./components/MarkdownTableEditingMenu";
import { ChineseTypographyButton } from "./components/ChineseTypographyButton";
import { MarkdownSlashMenu } from "./components/MarkdownSlashMenu";
import { MarkdownSnippetLibrary, readStoredMarkdownSnippets } from "./components/MarkdownSnippetLibrary";
import { MarkdownInternalLinkPicker } from "./components/MarkdownInternalLinkPicker";
import { MarkdownCursorWorkflowControls } from "./components/MarkdownCursorWorkflowControls";
import { MarkdownDocumentExportMenu } from "./components/MarkdownDocumentExportMenu";
import { MarkdownSSGComponentStrip } from "./components/MarkdownSSGComponentStrip";
import { replaceUnchangedSelection, type EditorSelectionSnapshot } from "./features/ai/selectionReplacement";
import { createRssGateway } from "./features/rss/rssGateway";
import { insertRssReferenceAt, isRssEditorContextCurrent, rssInspirationDraft, rssReferenceMarkdown, safeExternalHttpUrl } from "./features/rss/rssReader";
import { insertMarkdownImages } from "./features/writing/imageInsertion";
import type { RepositoryImage } from "./contracts/images";
import type { ImageReferenceRepairEdit } from "./contracts/imageReferences";
import type { SaveConflictReviewSnapshot } from "./features/workspace/saveConflictReview";
import { insertRepositoryImage, repositoryImageMarkdownPath } from "./features/images/repositoryImages";
import { applyMarkdownFormat, getWritingStats, planMarkdownListContinuation, type MarkdownFormat, type TextRange } from "./features/writing/markdownWriting";
import { useMarkdownDiagnostics } from "./features/writing/useMarkdownDiagnostics";
import { planMarkdownSmartPaste } from "./features/writing/markdownSmartPaste";
import { planMarkdownAutomaticPairing } from "./features/writing/markdownAutomaticPairing";
import { isImeCompositionBeforeInput, isImeCompositionKeyboardEvent } from "./features/writing/imeComposition";
import { planMarkdownTableEdit } from "./features/writing/markdownTableEditing";
import { applyMarkdownIndent, applySlashCommand, findSlashQuery, getSlashCommands, type SlashCommand } from "./features/writing/markdownPowerTools";
import { BUILT_IN_MARKDOWN_SNIPPETS, insertMarkdownSnippet, type MarkdownSnippet } from "./features/writing/markdownSnippets";
import { getMarkdownSSGComponentOccurrences } from "./features/writing/markdownSSGComponents";
import { destinationForMarkdownFile, findInternalLinkQuery } from "./features/writing/markdownInternalLinks";
import { parseFrontMatter, type FrontMatterField } from "./features/frontmatter/frontMatter";
import { DEFAULT_WORKSPACE_PREFERENCES, normalizeWorkspacePreferences, normalizeWorkspaceState, RecoveryDraftScheduler, recoveryDraftPreview, recoveryMatch } from "./features/workspace/workspaceRecovery";
import { LatestPreferenceSelection } from "./features/workspace/latestPreferenceSelection";
import { createMarkdownDocumentExportSaver } from "./platform/markdownDocumentExportGateway";
import "./App.css";

const MarkdownEditorSurface = lazy(() => import("./components/MarkdownEditorSurface"));
const MarkdownWritingInspector = lazy(() => import("./components/DeferredMarkdownWritingInspector"));
const PublishCenter = lazy(() => import("./components/PublishCenter").then(({ PublishCenter: Surface }) => ({ default: Surface })));
const MetadataBatchCenter = lazy(() => import("./components/MetadataBatchCenter").then(({ MetadataBatchCenter: Surface }) => ({ default: Surface })));
const SaveConflictReview = lazy(() => import("./components/SaveConflictReview").then(({ SaveConflictReview: Surface }) => ({ default: Surface })));
const AdvancedTools = lazy(() => import("./components/AdvancedTools").then(({ AdvancedTools: Surface }) => ({ default: Surface })));
const SettingsCenter = lazy(() => import("./components/SettingsCenter").then(({ SettingsCenter: Surface }) => ({ default: Surface })));
const KnowledgeLibrary = lazy(() => import("./components/KnowledgeLibrary").then(({ KnowledgeLibrary: Surface }) => ({ default: Surface })));
const RssReader = lazy(() => import("./components/RssReader").then(({ RssReader: Surface }) => ({ default: Surface })));
const DraftHistoryCenter = lazy(() => import("./components/DraftHistoryCenter"));
const GeneralDraftCenter = lazy(() => import("./components/GeneralDraftCenter"));
const ImageWorkbench = lazy(() => import("./components/ImageWorkbench"));
const SiteProfileCenter = lazy(() => import("./components/SiteProfileCenter"));
const ArticleStatePanel = lazy(() => import("./components/ArticleStatePanel"));
const OperationLogCenter = lazy(() => import("./components/OperationLogCenter"));

class DeferredSurfaceErrorBoundary extends Component<{ label: string; children: ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  render() {
    if (this.state.error) {
      return <DeferredSurfaceFailure label={this.props.label} />;
    }
    return this.props.children;
  }
}

function DeferredSurfaceFailure({ label }: { label: string }) {
  const { t } = useI18n();
  return <section role="alert" aria-live="assertive"><p>{t("{label}未能加载。主工作区仍可继续使用。", { label })}</p><button type="button" onClick={() => window.location.reload()}>{t("重新加载应用")}</button></section>;
}

function DeferredSurface({ label, children }: { label: string; children: ReactNode }) {
  const { t } = useI18n();
  return <DeferredSurfaceErrorBoundary label={label}><Suspense fallback={<p role="status" aria-live="polite">{t("正在加载{label}…", { label })}</p>}>{children}</Suspense></DeferredSurfaceErrorBoundary>;
}

type EditorState = "clean" | "dirty" | "saving" | "saved" | "conflict" | "failed";
// Keep persisted/command route identifiers stable while presenting Reading and Sites.
type WorkspaceMode = "writing" | "rss" | "sync";
const gateway = createRepositoryGateway();
const rssGateway = createRssGateway();
const saveMarkdownDocumentExport = createMarkdownDocumentExportSaver();
const searchMarkdownFiles = (sessionId: string, query: string, limit?: number) => gateway.searchMarkdownFiles(sessionId, query, limit);
const getGitFileDiff = (sessionId: string, relativePath: string) => gateway.gitFileDiff(sessionId, relativePath);
const inspectSitePreview = (sessionId: string) => gateway.inspectSitePreview(sessionId);
const planSitePreview: typeof gateway.planSitePreview = (sessionId, request) => gateway.planSitePreview(sessionId, request);
const startSitePreview: typeof gateway.startSitePreview = (sessionId, planId, confirmed) => gateway.startSitePreview(sessionId, planId, confirmed);
const checkSitePreviewPage: typeof gateway.checkSitePreviewPage = (sessionId, previewId, target) => gateway.checkSitePreviewPage(sessionId, previewId, target);
const stopSitePreview: typeof gateway.stopSitePreview = (sessionId, previewId) => gateway.stopSitePreview(sessionId, previewId);

function editorStateLabel(state: EditorState): string {
  return { clean: "已保存", dirty: "有未保存修改", saving: "正在保存…", saved: "刚刚保存", conflict: "保存冲突", failed: "保存失败" }[state];
}

function hasUnsavedWork(state: EditorState): boolean {
  return state === "dirty" || state === "saving" || state === "conflict" || state === "failed";
}

function canSaveDocument(state: EditorState): boolean {
  return state === "dirty" || state === "failed";
}

function localDateStamp(date = new Date()): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function draftTemplate(relativePath: string): string {
  const filename = relativePath.split("/").pop()?.replace(/\.(md|markdown)$/i, "") || "new-article";
  const slug = filename.toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "") || "new-article";
  const title = filename === "new-article" ? "新文章" : filename.replace(/[-_]+/g, " ");
  return [
    "---",
    `title: ${JSON.stringify(title)}`,
    `date: ${JSON.stringify(localDateStamp())}`,
    `slug: ${JSON.stringify(slug)}`,
    'description: ""',
    "tags: []",
    "categories: []",
    "draft: true",
    "---",
    "",
    `# ${title}`,
    "",
  ].join("\n");
}

function App() {
  const [capabilities, setCapabilities] = useState<Awaited<ReturnType<typeof gateway.getCapabilities>> | null>(null);
  const [repository, setRepository] = useState<RepositorySessionSnapshot | null>(null);
  const [files, setFiles] = useState<MarkdownFileEntry[]>([]);
  const [document, setDocument] = useState<DocumentSnapshot | null>(null);
  const [editorValue, setEditorValue] = useState("");
  const [editorState, setEditorState] = useState<EditorState>("clean");
  const [gitStatus, setGitStatus] = useState<GitStatusSnapshot | null>(null);
  const [notice, setNotice] = useState<string | UiMessage>("正在检查桌面能力…");
  const [workspaceState, setWorkspaceState] = useState<WorkspaceStateSnapshot>(() => normalizeWorkspaceState(null));
  const workspaceStateRef = useRef(workspaceState);
  const preferenceSaveQueue = useRef<Promise<void>>(Promise.resolve());
  const [optimisticWritingToolDensity, setOptimisticWritingToolDensity] = useState<WorkspacePreferences["writingToolDensity"] | null>(null);
  const writingToolDensitySelection = useRef(new LatestPreferenceSelection<WorkspacePreferences["writingToolDensity"]>());
  const [prefersDark, setPrefersDark] = useState(() => window.matchMedia("(prefers-color-scheme: dark)").matches);
  const [publishCenterOpen, setPublishCenterOpen] = useState(false);
  const [metadataBatchOpen, setMetadataBatchOpen] = useState(false);
  const [metadataBatchLoaded, setMetadataBatchLoaded] = useState(false);
  const [metadataBatchBusy, setMetadataBatchBusy] = useState(false);
  const metadataBatchInFlight = useRef(false);
  const metadataBatchOpenRef = useRef(false);
  const [conflictOpen, setConflictOpen] = useState(false);
  const [conflictLoaded, setConflictLoaded] = useState(false);
  const [conflictBusy, setConflictBusy] = useState(false);
  const [conflictError, setConflictError] = useState("");
  const [conflictReview, setConflictReview] = useState<SaveConflictReviewSnapshot | null>(null);
  const conflictOpenRef = useRef(false);
  const conflictInFlight = useRef(false);
  const conflictGeneration = useRef(0);
  const conflictReviewRef = useRef<SaveConflictReviewSnapshot | null>(null);
  conflictOpenRef.current = conflictOpen;
  conflictReviewRef.current = conflictReview;
  const deferredKnowledgeOpen = useRef<string | null>(null);
  metadataBatchOpenRef.current = metadataBatchOpen;
  const metadataBatchPlan = useRef<{ plan: MetadataBatchPlan; repositoryGeneration: number } | null>(null);
  const [advancedToolsOpen, setAdvancedToolsOpen] = useState(false);
  const [advancedToolsRequestedTab, setAdvancedToolsRequestedTab] = useState<AdvancedToolTab | null>(null);
  const [advancedToolsRequestedTabKey, setAdvancedToolsRequestedTabKey] = useState(0);
  const [advancedToolsActiveTab, setAdvancedToolsActiveTab] = useState<AdvancedToolTab>("ai");
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [knowledgeLibraryOpen, setKnowledgeLibraryOpen] = useState(false);
  const [publishCenterLoaded, setPublishCenterLoaded] = useState(false);
  const [advancedToolsLoaded, setAdvancedToolsLoaded] = useState(false);
  const [settingsLoaded, setSettingsLoaded] = useState(false);
  const [knowledgeLibraryLoaded, setKnowledgeLibraryLoaded] = useState(false);
  const [draftHistoryCenterOpen, setDraftHistoryCenterOpen] = useState(false);
  const [draftHistoryCenterLoaded, setDraftHistoryCenterLoaded] = useState(false);
  const [generalDraftCenterOpen, setGeneralDraftCenterOpen] = useState(false);
  const [generalDraftCenterLoaded, setGeneralDraftCenterLoaded] = useState(false);
  const [imageWorkbenchOpen, setImageWorkbenchOpen] = useState(false);
  const [imageWorkbenchLoaded, setImageWorkbenchLoaded] = useState(false);
  const [siteProfiles, setSiteProfiles] = useState<SiteProfileSnapshot | null>(null);
  const [siteProfileCenterOpen, setSiteProfileCenterOpen] = useState(false);
  const [siteProfileCenterLoaded, setSiteProfileCenterLoaded] = useState(false);
  const [repositorySwitchBusy, setRepositorySwitchBusy] = useState(false);
  const siteSelectionInFlight = useRef(false);
  const [operationLogOpen, setOperationLogOpen] = useState(false);
  const [operationLogLoaded, setOperationLogLoaded] = useState(false);
  const imageWorkbenchOpenRef = useRef(false);
  const imageWorkbenchGeneration = useRef(0);
  const imageReuseInFlight = useRef(false);
  imageWorkbenchOpenRef.current = imageWorkbenchOpen;
  const [knowledgeTargetItemId, setKnowledgeTargetItemId] = useState<string | null>(null);
  const [knowledgeTargetRequestKey, setKnowledgeTargetRequestKey] = useState(0);
  const [commandPaletteOpen, setCommandPaletteOpen] = useState(false);
  const [workspaceMode, setWorkspaceMode] = useState<WorkspaceMode>("writing");
  const [sidebarVisible, setSidebarVisible] = useState(true);
  const [previewVisible, setPreviewVisible] = useState(true);
  const [focusMode, setFocusMode] = useState(false);
  const [writingInspectorOpen, setWritingInspectorOpen] = useState(true);
  const [inspectorTab, setInspectorTab] = useState<"writing" | "metadata" | "state">("metadata");
  const [writingInspectorLoaded, setWritingInspectorLoaded] = useState(false);
  const [articleStateLoaded, setArticleStateLoaded] = useState(false);
  const [inspectorRevealRequestKey, setInspectorRevealRequestKey] = useState(0);
  const [findFocusRequest, setFindFocusRequest] = useState<{ key: number; documentKey: string } | null>(null);
  const findFocusSequence = useRef(0);
  const handleFindFocusHandled = useCallback((key: number) => {
    setFindFocusRequest((current) => current?.key === key ? null : current);
  }, []);
  const [outlinePinned, setOutlinePinned] = useState(false);
  const [fieldFocusRequest, setFieldFocusRequest] = useState<{
    documentKey: string; field: FrontMatterField; requestKey: number; expectedText: string;
  } | null>(null);
  const fieldFocusSequence = useRef(0);
  const editorDocumentKey = JSON.stringify([repository?.sessionId, document?.documentId, document?.revision]);
  const editorDocumentKeyRef = useRef(editorDocumentKey);
  editorDocumentKeyRef.current = editorDocumentKey;
  const [snippetLibraryOpen, setSnippetLibraryOpen] = useState(false);
  const [internalLinkPickerOpen, setInternalLinkPickerOpen] = useState(false);
  const [customSnippets, setCustomSnippets] = useState<MarkdownSnippet[]>([]);
  const [draftDialogMode, setDraftDialogMode] = useState<DraftLifecycleMode | null>(null);
  const [rssInspirationDraftText, setRssInspirationDraftText] = useState<string | null>(null);
  const [draftDialogBusy, setDraftDialogBusy] = useState(false);
  const [draftDialogError, setDraftDialogError] = useState<string | null>(null);
  const [imageImportBusy, setImageImportBusy] = useState(false);
  const [slashMenuDismissed, setSlashMenuDismissed] = useState(false);
  const [goToLineRequestKey, setGoToLineRequestKey] = useState(0);
  const [editorSelection, setEditorSelection] = useState<EditorSelectionSnapshot>({ from: 0, to: 0, text: "" });
  const editorRef = useRef<ReactCodeMirrorRef>(null);
  const pendingEditorFocus = useRef(false);
  const imageImportInFlight = useRef(false);
  const editorNavigationGeneration = useRef(0);
  const pendingEditorLocation = useRef<{
    generation: number; repositoryGeneration: number; documentGeneration: number;
    repositoryId: string; documentId: string; text: string; range: TextRange; notice: string | UiMessage;
  } | null>(null);
  const repositoryOpenGeneration = useRef(0);
  const documentOpenGeneration = useRef(0);
  const articleStateWritable = Boolean(document?.writable && capabilities?.localEdit);
  const articleStateContext = useMemo<ArticleStateContext | null>(() => repository && document ? {
    kind: "repository", repository: { sessionId: repository.sessionId, siteKind: repository.siteKind, contentRoot: repository.contentRoot },
    documentId: document.documentId, relativePath: document.relativePath, writable: articleStateWritable,
  } : null, [repository?.sessionId, repository?.siteKind, repository?.contentRoot, document?.documentId, document?.relativePath, articleStateWritable]);
  const articleStateEditGeneration = useRef(0);
  const sitePreviewEditGeneration = useRef(0);
  const consumedArticleStatePlans = useRef(new WeakSet<ArticleStateChangePlan>());
  const articleStateApplyInFlight = useRef(false);
  const articleStateMounted = useRef(true);
  useEffect(() => {
    articleStateMounted.current = true;
    return () => { articleStateMounted.current = false; articleStateEditGeneration.current += 1; };
  }, []);
  const saveGeneration = useRef(0);
  const saveInFlight = useRef(false);
  const activeEditorContext = useRef({ repositoryId: null as string | null, documentId: null as string | null });
  const activeEditorText = useRef(editorValue);
  workspaceStateRef.current = workspaceState;
  activeEditorContext.current = { repositoryId: repository?.sessionId ?? null, documentId: document?.documentId ?? null };
  activeEditorText.current = editorValue;
  const recoveryScheduler = useRef(new RecoveryDraftScheduler<WorkspaceStateSnapshot>(1000));
  const startupRestoreStarted = useRef(false);
  const previewHtml = useMemo(() => renderMarkdownPreview(editorValue), [editorValue]);
  const ssgComponentOccurrences = useMemo(() => getMarkdownSSGComponentOccurrences(editorValue), [editorValue]);
  const slashQuery = useMemo(() => editorSelection.from === editorSelection.to ? findSlashQuery(editorValue, editorSelection.to) : null, [editorValue, editorSelection.from, editorSelection.to]);
  const slashCommands = useMemo(() => {
    const query = (slashQuery?.query ?? "").normalize("NFKC").toLocaleLowerCase();
    const snippetCommands = [...BUILT_IN_MARKDOWN_SNIPPETS.filter((snippet) => snippet.id !== "footnote"), ...customSnippets]
      .filter((snippet) => !query || `${snippet.label} ${snippet.description ?? ""} ${snippet.shortcut}`.normalize("NFKC").toLocaleLowerCase().includes(query))
      .map<SlashCommand>((snippet) => ({ id: `snippet:${snippet.id}`, label: snippet.label, description: snippet.description ?? `插入 /${snippet.shortcut}`, keywords: [snippet.shortcut], template: "" }));
    return [...getSlashCommands(query), ...snippetCommands];
  }, [customSnippets, slashQuery?.query]);
  const slashMenuOpen = Boolean(slashQuery && document?.writable && capabilities?.localEdit && !slashMenuDismissed);
  const snippetContext = useMemo(() => {
    const metadata = parseFrontMatter(editorValue)?.values;
    const filename = document?.relativePath.split("/").pop()?.replace(/\.(?:md|markdown|mdx)$/i, "") ?? "";
    const fallbackTitle = filename.replace(/[-_]+/g, " ").trim() || "未命名文章";
    const fallbackSlug = filename.toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-|-$/g, "");
    return { title: metadata?.title.trim() || fallbackTitle, slug: metadata?.slug.trim() || fallbackSlug };
  }, [document?.relativePath, editorValue]);
  const articlePreviewPath = useMemo(() => {
    if (!document || !repository) return null;
    const file = files.find((item) => item.relativePath === document.relativePath) ?? {
      relativePath: document.relativePath,
      displayName: document.relativePath.split("/").pop() ?? document.relativePath,
      directory: document.relativePath.split("/").slice(0, -1).join("/"),
      byteSize: document.byteSize,
    };
    return destinationForMarkdownFile(file, repository, parseFrontMatter(editorValue)?.values.permalink);
  }, [document, editorValue, files, repository]);
  const knownArticleTitles = useMemo(() => files.flatMap((file) => [file.displayName, file.relativePath]), [files]);
  const writingStats = useMemo(() => getWritingStats(editorValue), [editorValue]);
  const writingDiagnosticSession = useMarkdownDiagnostics(editorValue, editorDocumentKey, knownArticleTitles, Boolean(document));
  const diagnosticSummary = useMemo(() => writingDiagnosticSession.status === "ready" ? ({ errors: writingDiagnosticSession.diagnostics.filter((item) => item.severity === "error").length,
    warnings: writingDiagnosticSession.diagnostics.filter((item) => item.severity === "warning").length }) : undefined, [writingDiagnosticSession]);
  const currentLineEnding = useMemo(() => {
    const crlf = editorValue.includes("\r\n");
    const lf = /(?<!\r)\n/.test(editorValue);
    return crlf && lf ? "mixed" : crlf ? "crlf" : lf ? "lf" : "none";
  }, [editorValue]);
  const preferences = workspaceState.preferences ?? DEFAULT_WORKSPACE_PREFERENCES;
  const { locale, t } = useUiLanguage(preferences.uiLanguage);
  const writingToolDensity = optimisticWritingToolDensity ?? preferences.writingToolDensity;
  const darkMode = preferences.theme === "dark" || (preferences.theme === "system" && prefersDark);

  useEffect(() => {
    if (!inspectorRevealRequestKey) return;
    const slot = window.document.querySelector<HTMLElement>(".workspace-inspector-slot");
    if (slot && !slot.hidden) slot.scrollIntoView?.({ block: "nearest", inline: "nearest" });
  }, [inspectorRevealRequestKey]);

  const [exitState, setExitState] = useState<EditorExitState>({ open: false, busy: false, snapshot: null, error: "", exportPath: null });
  const exitContext = useRef({ repository, document, editorState, recoveryEnabled: preferences.recoveryEnabled, workspaceWarning: Boolean(workspaceState.warning), canStart: false });
  exitContext.current = { repository, document, editorState, recoveryEnabled: preferences.recoveryEnabled, workspaceWarning: Boolean(workspaceState.warning),
    canStart: workspaceMode === "writing" && !repositorySwitchBusy && !draftDialogBusy
      && !publishCenterOpen && !metadataBatchOpen && !conflictOpen && !advancedToolsOpen && !settingsOpen
      && !knowledgeLibraryOpen && !draftHistoryCenterOpen && !generalDraftCenterOpen && !imageWorkbenchOpen
      && !siteProfileCenterOpen && !operationLogOpen && !commandPaletteOpen && !draftDialogMode
      && !snippetLibraryOpen && !internalLinkPickerOpen,
  };
  const articleStateActive = workspaceMode === "writing" && inspectorTab === "state" && writingInspectorOpen && !focusMode;
  const articleStateCanChange = articleStateActive && exitContext.current.canStart && articleStateWritable
    && !imageImportBusy && !metadataBatchBusy && !saveInFlight.current && editorState !== "saving" && editorState !== "conflict";
  const articleStateBaseKey = JSON.stringify([editorDocumentKey, document?.relativePath, document?.baselineSha256,
    repository?.siteKind, repository?.contentRoot, articleStateWritable, repositoryOpenGeneration.current, documentOpenGeneration.current, saveGeneration.current]);
  const articleStateBinding = useRef({ key: articleStateBaseKey, text: editorValue, available: articleStateCanChange });
  if (articleStateBinding.current.key !== articleStateBaseKey || articleStateBinding.current.text !== editorValue
    || articleStateBinding.current.available !== articleStateCanChange) {
    articleStateEditGeneration.current += 1;
    articleStateBinding.current = { key: articleStateBaseKey, text: editorValue, available: articleStateCanChange };
  }
  const articleStateContextKey = JSON.stringify([articleStateBaseKey, articleStateEditGeneration.current]);
  const articleStateContextKeyRef = useRef(articleStateContextKey);
  articleStateContextKeyRef.current = articleStateContextKey;
  const liveArticleState = useRef({ context: articleStateContext, key: articleStateContextKey, canChange: articleStateCanChange,
    generation: articleStateEditGeneration.current, repositoryGeneration: repositoryOpenGeneration.current,
    documentGeneration: documentOpenGeneration.current, saveGeneration: saveGeneration.current });
  liveArticleState.current = { context: articleStateContext, key: articleStateContextKey, canChange: articleStateCanChange,
    generation: articleStateEditGeneration.current, repositoryGeneration: repositoryOpenGeneration.current,
    documentGeneration: documentOpenGeneration.current, saveGeneration: saveGeneration.current };
  const sitePreviewContextKey = JSON.stringify([editorDocumentKey, document?.baselineSha256, repository?.siteKind,
    repository?.contentRoot, editorValue, editorState, repositoryOpenGeneration.current, documentOpenGeneration.current,
    saveGeneration.current, sitePreviewEditGeneration.current]);
  const liveSitePreview = useRef({ key: sitePreviewContextKey, text: editorValue, editGeneration: sitePreviewEditGeneration.current,
    repositoryGeneration: repositoryOpenGeneration.current, documentGeneration: documentOpenGeneration.current, saveGeneration: saveGeneration.current });
  liveSitePreview.current = { key: sitePreviewContextKey, text: editorValue, editGeneration: sitePreviewEditGeneration.current,
    repositoryGeneration: repositoryOpenGeneration.current, documentGeneration: documentOpenGeneration.current, saveGeneration: saveGeneration.current };
  const isSitePreviewContextCurrent = (key: string) => !exitActivity.frozen && !saveInFlight.current
    && key === liveSitePreview.current.key && liveSitePreview.current.text === activeEditorText.current
    && liveSitePreview.current.editGeneration === sitePreviewEditGeneration.current
    && liveSitePreview.current.repositoryGeneration === repositoryOpenGeneration.current
    && liveSitePreview.current.documentGeneration === documentOpenGeneration.current
    && liveSitePreview.current.saveGeneration === saveGeneration.current;
  const exitController = useRef<EditorExitController | null>(null);
  if (!exitController.current) exitController.current = new EditorExitController({
    gate: exitActivity, gateway: editorExitGateway,
    readSnapshot: () => {
      const current = exitContext.current;
      const text = activeEditorText.current;
      return {
        draft: current.repository && current.document?.writable ? { sessionId: current.repository.sessionId, documentId: current.document.documentId, text, expectedSha256: current.document.baselineSha256 } : null,
        dirty: hasUnsavedWork(current.editorState) || Boolean(current.document && text !== current.document.text),
        recoveryEnabled: current.recoveryEnabled,
        workspaceWarning: current.workspaceWarning,
      };
    },
    canStart: () => exitContext.current.canStart && !saveInFlight.current && !imageImportInFlight.current
      && !imageReuseInFlight.current && !metadataBatchInFlight.current && !conflictInFlight.current
      && !siteSelectionInFlight.current && !editorRef.current?.view?.composing
      && !window.document.querySelector("dialog[open]"),
    suspendRecovery: () => {
      recoveryScheduler.current.cancel();
      repositoryOpenGeneration.current += 1; documentOpenGeneration.current += 1;
      editorNavigationGeneration.current += 1; imageWorkbenchGeneration.current += 1;
    },
    onState: setExitState,
    onBlocked: setNotice,
  });
  useEffect(() => {
    if (!isTauriRuntime()) return;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void listenForEditorClose(() => {
      // Apply queued async editor results before deciding which buffer to protect.
      flushSync(() => {});
      exitController.current?.request();
    }).then((cleanup) => { if (disposed) cleanup(); else unlisten = cleanup; })
      .catch(() => setNotice("关闭窗口保护未能连接。请先保存文章，再重新启动应用。"));
    return () => { disposed = true; unlisten?.(); exitController.current?.dispose(); };
  }, []);

  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const update = () => setPrefersDark(media.matches);
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  useEffect(() => {
    let cancelled = false;
    void Promise.all([gateway.getCapabilities(), gateway.getWorkspaceState()]).then(async ([capabilitySnapshot, rawWorkspaceState]) => {
      if (cancelled) return;
      const nextWorkspaceState = normalizeWorkspaceState(rawWorkspaceState);
      setCapabilities(capabilitySnapshot); setWorkspaceState(nextWorkspaceState);
      if (nextWorkspaceState.warning) setNotice(nextWorkspaceState.warning);
      else setNotice(capabilitySnapshot.localEdit ? "请选择一个仓库开始编辑。" : "浏览器演示模式：仅展示只读样例。");
      if (!startupRestoreStarted.current && capabilitySnapshot.localEdit && nextWorkspaceState.preferences.restoreLastWorkspace && nextWorkspaceState.lastRepositoryPath) {
        startupRestoreStarted.current = true;
        await openRepositoryPath(nextWorkspaceState.lastRepositoryPath, nextWorkspaceState.lastDocumentPath, true);
      }
    }).catch(() => { if (!cancelled) setNotice("无法读取桌面能力或工作区状态。请重新启动应用。"); });
    return () => { cancelled = true; };
  // The initial restore must run once; it intentionally uses the startup snapshot.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!capabilities?.siteProfiles) return;
    let cancelled = false;
    void gateway.getSiteProfiles().then((snapshot) => {
      if (!cancelled) acceptSiteProfiles(snapshot);
    }).catch(() => { if (!cancelled) setNotice("无法读取已保存站点，可在站点管理中重试。"); });
    return () => { cancelled = true; };
  }, [capabilities?.siteProfiles]);

  function acceptSiteProfiles(snapshot: SiteProfileSnapshot) {
    setSiteProfiles((current) => !current || snapshot.revision >= current.revision ? snapshot : current);
  }

  async function selectSiteProfile(profile: SiteProfile): Promise<boolean> {
    if (!capabilities?.siteProfiles || siteSelectionInFlight.current) return false;
    if (profile.rootPath === repository?.rootPath) return true;
    if (hasUnsavedWork(editorState) && !window.confirm(t("当前文档有未保存修改。仍要切换站点吗？"))) return false;
    siteSelectionInFlight.current = true;
    try { return await openRepositoryTarget({ kind: "profile", profileId: profile.profileId }); }
    finally { siteSelectionInFlight.current = false; }
  }

  useEffect(() => () => recoveryScheduler.current.cancel(), []);

  useEffect(() => {
    if (!capabilities?.knowledgeLibrary) return;
    let cancelled = false;
    let checking = false;
    const checkForBrowserOpenRequest = async () => {
      if (exitActivity.frozen || checking || cancelled || metadataBatchOpenRef.current || conflictOpenRef.current) return;
      checking = true;
      try {
        const itemId = deferredKnowledgeOpen.current ?? await gateway.takeKnowledgeOpenRequest();
        if (exitActivity.frozen || metadataBatchOpenRef.current || conflictOpenRef.current) { deferredKnowledgeOpen.current = itemId; return; }
        deferredKnowledgeOpen.current = null;
        if (!cancelled && itemId) {
          setPublishCenterOpen(false);
          setAdvancedToolsOpen(false);
          setSettingsOpen(false);
          setDraftHistoryCenterOpen(false);
          setGeneralDraftCenterOpen(false);
          closeImageWorkbench();
          setOperationLogOpen(false);
          setSiteProfileCenterOpen(false);
          setCommandPaletteOpen(false);
          setSnippetLibraryOpen(false);
          setInternalLinkPickerOpen(false);
          setKnowledgeTargetItemId(itemId);
          setKnowledgeTargetRequestKey((current) => current + 1);
          setKnowledgeLibraryLoaded(true);
          setKnowledgeLibraryOpen(true);
          setNotice("已根据浏览器扩展请求打开对应资料。");
        }
      } catch {
        // The loopback bridge remains optional. A transient local failure is retried quietly.
      } finally {
        checking = false;
      }
    };
    void checkForBrowserOpenRequest();
    const timer = window.setInterval(() => void checkForBrowserOpenRequest(), 750);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [capabilities?.knowledgeLibrary]);

  useEffect(() => { setSlashMenuDismissed(false); }, [slashQuery?.from, slashQuery?.to, slashQuery?.query]);

  useEffect(() => {
    const handleShortcut = (event: KeyboardEvent) => {
      if (metadataBatchOpenRef.current || conflictOpenRef.current) return;
      if (exitActivity.frozen || isImeCompositionKeyboardEvent(event)) return;
      if (!(event.ctrlKey || event.metaKey) || event.altKey) return;
      if (publishCenterOpen || advancedToolsOpen || settingsOpen || knowledgeLibraryOpen || draftHistoryCenterOpen || generalDraftCenterOpen || imageWorkbenchOpen || operationLogOpen || siteProfileCenterOpen || commandPaletteOpen || draftDialogMode || snippetLibraryOpen || internalLinkPickerOpen) return;
      const target = event.target as HTMLElement | null;
      if (target?.closest('[role="dialog"]')) return;
      if (event.key.toLowerCase() === "s") { event.preventDefault(); void saveDocument(); }
      if (event.key.toLowerCase() === "o") { event.preventDefault(); void chooseRepository(); }
      if (event.key.toLowerCase() === "k") { event.preventDefault(); setCommandPaletteOpen(true); }
      if (event.key.toLowerCase() === "l" && document) { event.preventDefault(); setWorkspaceMode("writing"); setGoToLineRequestKey((current) => current + 1); }
      if (event.key.toLowerCase() === "p" && event.shiftKey) { event.preventDefault(); openWorkspaceDrawer("publish"); }
      if (event.key.toLowerCase() === "e" && event.shiftKey) { event.preventDefault(); focusEditor(); }
      if (event.key.toLowerCase() === "f" && event.shiftKey) { event.preventDefault(); focusFileSearch(); }
      if (event.key.toLowerCase() === "n" && !event.shiftKey) { event.preventDefault(); openDraftDialog("create"); }
      if (event.key.toLowerCase() === "f" && !event.shiftKey && document) {
        event.preventDefault(); setWorkspaceMode("writing"); setFocusMode(false); setInspectorTab("writing"); setWritingInspectorOpen(true); setWritingInspectorLoaded(true);
        setInspectorRevealRequestKey((current) => current + 1);
        setFindFocusRequest({ key: ++findFocusSequence.current, documentKey: editorDocumentKey });
      }
      if (event.key.toLowerCase() === "b" && !event.shiftKey && target?.closest(".cm-editor")) { event.preventDefault(); applyWritingFormat("bold"); }
      if (event.key.toLowerCase() === "i" && !event.shiftKey && target?.closest(".cm-editor")) { event.preventDefault(); applyWritingFormat("italic"); }
    };
    window.addEventListener("keydown", handleShortcut);
    return () => window.removeEventListener("keydown", handleShortcut);
  });

  useEffect(() => {
    setSnippetLibraryOpen(false);
    setInternalLinkPickerOpen(false);
  }, [repository?.sessionId, document?.documentId]);

  useEffect(() => { setFieldFocusRequest(null); }, [editorDocumentKey, editorValue]);

  useEffect(() => {
    setFindFocusRequest((current) => current && (current.documentKey !== editorDocumentKey
      || workspaceMode !== "writing" || inspectorTab !== "writing" || !writingInspectorOpen || focusMode) ? null : current);
  }, [editorDocumentKey, workspaceMode, inspectorTab, writingInspectorOpen, focusMode]);

  useEffect(() => {
    if (conflictReviewRef.current && (conflictReviewRef.current.documentKey !== editorDocumentKey
      || conflictReviewRef.current.localText !== editorValue)) {
      conflictGeneration.current += 1;
      conflictReviewRef.current = null; setConflictReview(null);
      setConflictError("文稿或编辑内容已变化，请重新读取冲突版本。");
    }
  }, [editorDocumentKey, editorValue]);

  useEffect(() => { setDraftHistoryCenterOpen(false); }, [repository?.sessionId]);

  useEffect(() => {
    setCustomSnippets(repository ? readStoredMarkdownSnippets(repository.rootPath) : []);
  }, [repository?.rootPath]);

  useEffect(() => {
    if (exitState.open || !repository || !document || !canSaveDocument(editorState) || !document.writable || !capabilities?.localEdit || !preferences.recoveryEnabled) {
      recoveryScheduler.current.cancel();
      return;
    }
    const request = { sessionId: repository.sessionId, documentId: document.documentId, text: editorValue, expectedSha256: document.baselineSha256 };
    recoveryScheduler.current.schedule(
      () => gateway.saveRecoveryDraft(request),
      (snapshot) => setWorkspaceState(normalizeWorkspaceState(snapshot)),
      () => { /* Recovery is best-effort; saving the actual document remains available. */ },
    );
    return () => recoveryScheduler.current.cancel();
  }, [repository, document, editorState, capabilities?.localEdit, preferences.recoveryEnabled, editorValue, exitState.open]);

  async function chooseRepository() {
    if (imageImportInFlight.current) { setNotice("图片仍在导入，请稍候。"); return; }
    if (hasUnsavedWork(editorState) && !window.confirm(t("当前文档有未保存修改。仍要切换仓库吗？"))) return;
    try {
      const selectedPath = isTauriRuntime()
        ? await exitActivity.run(() => openDialog({ directory: true, multiple: false, title: "选择 RepoPress 仓库" }))
        : "/演示/RepoPress";
      if (typeof selectedPath !== "string") return;
      await openRepositoryPath(selectedPath);
    } catch (error) { setNotice(`无法打开仓库：${messageFrom(error)}`); }
  }

  async function openRepositoryPath(path: string, documentPath: string | null = null, restoring = false): Promise<boolean> {
    return openRepositoryTarget({ kind: "path", path }, documentPath, restoring);
  }

  async function openRepositoryTarget(target: RepositoryTarget, documentPath: string | null = null, restoring = false): Promise<boolean> {
    if (exitActivity.frozen) return false;
    if (imageImportInFlight.current) { setNotice("图片仍在导入，请稍候。"); return false; }
    if (saveInFlight.current) { setNotice("当前文章仍在保存，请等待完成后再切换仓库。"); return false; }
    const editorContextAtStart = { ...activeEditorContext.current };
    const editorTextAtStart = activeEditorText.current;
    const requestGeneration = ++repositoryOpenGeneration.current;
    setRepositorySwitchBusy(true);
    documentOpenGeneration.current += 1;
    recoveryScheduler.current.cancel();
    try {
      const isCurrent = () =>
        !exitActivity.frozen && requestGeneration === repositoryOpenGeneration.current
        && !saveInFlight.current && !imageImportInFlight.current
        && activeEditorContext.current.repositoryId === editorContextAtStart.repositoryId
        && activeEditorContext.current.documentId === editorContextAtStart.documentId
        && activeEditorText.current === editorTextAtStart;
      const prepared = await prepareRepositorySwitch(gateway, target, documentPath, isCurrent);
      if (!prepared || !isCurrent()) {
        if (requestGeneration === repositoryOpenGeneration.current) setNotice("切换期间当前文章发生了变化或正在写入；已保留当前内容，没有切换仓库。");
        return false;
      }
      const { repository: selected, files: selectedFiles, document: restoredDocument, restoreFailed } = prepared;
      const restoredText = restoredDocument?.text ?? "";
      saveGeneration.current += 1;
      activeEditorContext.current = { repositoryId: selected.sessionId, documentId: restoredDocument?.documentId ?? null };
      activeEditorText.current = restoredText;
      closeImageWorkbench();
      setSiteProfileCenterOpen(false); setOperationLogOpen(false); setGeneralDraftCenterOpen(false); setDraftHistoryCenterOpen(false);
      setRepository(selected); setFiles(selectedFiles);
      setDocument(restoredDocument); setEditorValue(restoredText); setEditorState("clean"); setGitStatus(null); setPublishCenterOpen(false); setAdvancedToolsOpen(false); setDraftDialogMode(null); setSnippetLibraryOpen(false); setInternalLinkPickerOpen(false); setEditorSelection({ from: 0, to: 0, text: "" });
      if (restoredDocument) setNotice({ source: "已恢复上次工作区：{name} / {path}", parameters: { name: selected.displayName, path: documentPath! } });
      else if (restoreFailed) setNotice({ source: "已恢复仓库：{name}；上次文档无法打开。", parameters: { name: selected.displayName } });
      else setNotice({ source: restoring ? "已恢复上次仓库：{name}" : "已打开：{name}", parameters: { name: selected.displayName } });
      return true;
    } catch (error) {
      if (requestGeneration !== repositoryOpenGeneration.current) return false;
      setNotice(restoring ? `无法恢复上次工作区：${messageFrom(error)}` : `无法打开仓库：${messageFrom(error)}`);
      return false;
    } finally {
      if (requestGeneration === repositoryOpenGeneration.current) setRepositorySwitchBusy(false);
    }
  }

  async function selectDocument(file: MarkdownFileEntry, navigationGeneration?: number): Promise<boolean> {
    if (navigationGeneration !== undefined && navigationGeneration !== editorNavigationGeneration.current) return false;
    if (!repository) return false;
    if (imageImportInFlight.current) { setNotice("图片仍在导入，请稍候。"); return false; }
    if (saveInFlight.current) { setNotice("当前文章仍在保存，请等待完成后再切换文章。"); return false; }
    if (exitActivity.frozen) return false;
    if (navigationGeneration === undefined && hasUnsavedWork(editorState) && !window.confirm(t("当前文档有未保存修改。仍要切换吗？"))) return false;
    if (navigationGeneration === undefined) {
      editorNavigationGeneration.current += 1;
      pendingEditorLocation.current = null;
    }
    const editorContextAtStart = { ...activeEditorContext.current };
    const editorTextAtStart = activeEditorText.current;
    const requestGeneration = ++documentOpenGeneration.current;
    const repositoryGeneration = repositoryOpenGeneration.current;
    const repositoryId = repository.sessionId;
    recoveryScheduler.current.cancel();
    try {
      const nextDocument = await gateway.openDocument(repositoryId, file.relativePath);
      if (requestGeneration !== documentOpenGeneration.current || repositoryGeneration !== repositoryOpenGeneration.current) return false;
      if (activeEditorContext.current.repositoryId !== editorContextAtStart.repositoryId
        || activeEditorContext.current.documentId !== editorContextAtStart.documentId
        || activeEditorText.current !== editorTextAtStart) {
        setNotice("打开文章期间当前内容发生了变化；已保留新输入，没有切换文章。");
        return false;
      }
      saveGeneration.current += 1;
      activeEditorContext.current = { repositoryId, documentId: nextDocument.documentId };
      activeEditorText.current = nextDocument.text;
      setWorkspaceMode("writing");
      setDocument(nextDocument); setEditorValue(nextDocument.text); setEditorState("clean"); setSnippetLibraryOpen(false); setInternalLinkPickerOpen(false); setEditorSelection({ from: 0, to: 0, text: "" });
      setNotice({ source: nextDocument.writable ? "正在编辑：{name}" : nextDocument.readOnlyReason ? "以只读方式打开：{name}（{reason}）" : "以只读方式打开：{name}（当前格式不可安全保存）", parameters: { name: file.displayName, reason: nextDocument.readOnlyReason ?? "" } });
      return true;
    } catch (error) {
      if (requestGeneration === documentOpenGeneration.current && repositoryGeneration === repositoryOpenGeneration.current) setNotice(`无法打开文档：${messageFrom(error)}`);
      return false;
    }
  }

  function updateDocument(value: string) { if (exitActivity.frozen || imageImportInFlight.current || metadataBatchInFlight.current || conflictOpenRef.current) return; if (value !== activeEditorText.current) { articleStateEditGeneration.current += 1; sitePreviewEditGeneration.current += 1; } activeEditorText.current = value; setEditorValue(value); if (document) setEditorState("dirty"); }

  function applyEditorChange(value: string, selection: TextRange, statusMessage?: string | UiMessage, allowDuringImageImport = false, focusAfterChange = true) {
    if (exitActivity.frozen) return;
    if (conflictOpenRef.current) return;
    if (metadataBatchInFlight.current) { setNotice("批量维护仍在执行，请稍候。"); return; }
    if (imageImportInFlight.current && !allowDuringImageImport) { setNotice("图片仍在导入，请稍候。"); return; }
    if (!document || (value !== editorValue && (!document.writable || !capabilities?.localEdit))) return;
    if (value !== activeEditorText.current) { articleStateEditGeneration.current += 1; sitePreviewEditGeneration.current += 1; }
    if (value !== editorValue) activeEditorText.current = value;
    const safeSelection = {
      from: Math.max(0, Math.min(value.length, selection.from)),
      to: Math.max(0, Math.min(value.length, selection.to)),
    };
    const view = editorRef.current?.view;
    if (view) {
      const currentValue = view.state.doc.toString();
      if (currentValue === value) {
        view.dispatch({ selection: { anchor: safeSelection.from, head: safeSelection.to }, scrollIntoView: focusAfterChange });
      } else {
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: value }, selection: { anchor: safeSelection.from, head: safeSelection.to }, scrollIntoView: focusAfterChange });
      }
      if (allowDuringImageImport && currentValue !== value) {
        setEditorValue(value);
        setEditorSelection({ ...safeSelection, text: value.slice(safeSelection.from, safeSelection.to) });
      }
      if (focusAfterChange) view.focus();
    } else {
      setEditorValue(value);
      setEditorSelection({ ...safeSelection, text: value.slice(safeSelection.from, safeSelection.to) });
    }
    if (value !== editorValue) setEditorState("dirty");
    if (statusMessage) setNotice(statusMessage);
  }

  function applyWritingFormat(format: MarkdownFormat) {
    if (!document?.writable || !capabilities?.localEdit || imageImportBusy) return;
    const result = applyMarkdownFormat(editorValue, editorSelection, format);
    applyEditorChange(result.text, result.selection);
  }

  function handleEditorPaste(event: ReactClipboardEvent) {
    if (!document?.writable || !capabilities?.localEdit || imageImportBusy || imageImportInFlight.current) return;
    const plan = planMarkdownSmartPaste(editorValue, editorSelection, {
      plainText: event.clipboardData.getData("text/plain"),
      html: event.clipboardData.getData("text/html") || null,
    });
    if (!plan) return;
    event.preventDefault();
    event.stopPropagation();
    const cleanup = plan.removedTrackingParameterCount ? `，并移除 ${plan.removedTrackingParameterCount} 个跟踪参数` : "";
    const status = plan.kind === "link" ? `已将所选文字转换为链接${cleanup}` : `已将富文本转换为 Markdown${cleanup}`;
    applyEditorChange(plan.text, plan.selection, status);
  }

  function applyAutomaticPairing(typedText: string): boolean {
    if (!preferences.automaticPairingEnabled || !document?.writable || !capabilities?.localEdit || imageImportBusy || imageImportInFlight.current) return false;
    const result = planMarkdownAutomaticPairing(editorValue, editorSelection, typedText);
    if (!result) return false;
    applyEditorChange(result.text, result.selection);
    return true;
  }

  function handleEditorBeforeInput(event: ReactFormEvent<HTMLDivElement>) {
    const input = event.nativeEvent as InputEvent;
    if (isImeCompositionBeforeInput(input) || input.inputType !== "insertText" || !input.data || !applyAutomaticPairing(input.data)) return;
    event.preventDefault();
    event.stopPropagation();
  }

  function applySlashSelection(command: SlashCommand) {
    if (!slashQuery || !document?.writable || !capabilities?.localEdit || imageImportBusy) return;
    const expectedText = editorValue.slice(slashQuery.from, slashQuery.to);
    if (command.id.startsWith("snippet:")) {
      const snippetId = command.id.slice("snippet:".length);
      const snippet = [...BUILT_IN_MARKDOWN_SNIPPETS, ...customSnippets].find((item) => item.id === snippetId);
      if (!snippet || editorValue.slice(slashQuery.from, slashQuery.to) !== expectedText) { setSlashMenuDismissed(true); setNotice("斜杠命令位置已变化，请重新输入。"); return; }
      const withoutTrigger = editorValue.slice(0, slashQuery.from) + editorValue.slice(slashQuery.to);
      const result = insertMarkdownSnippet(withoutTrigger, { from: slashQuery.from, to: slashQuery.from }, snippet, snippetContext);
      setSlashMenuDismissed(true);
      applyEditorChange(result.text, result.selection, `已插入“${snippet.label}”`);
      return;
    }
    const result = applySlashCommand(editorValue, editorSelection.to, command.id, expectedText);
    if (!result) { setSlashMenuDismissed(true); setNotice("斜杠命令位置已变化，请重新输入。"); return; }
    setSlashMenuDismissed(true);
    applyEditorChange(result.text, result.selection);
  }

  function closeSlashMenu() {
    setSlashMenuDismissed(true);
    window.requestAnimationFrame(() => editorRef.current?.view?.focus());
  }

  async function chooseWritingImages() {
    if (!repository || !document?.writable || !capabilities?.localEdit || imageImportInFlight.current) {
      setNotice("请先打开一篇可编辑的本地文章。");
      return;
    }
    const activeRepository = repository;
    const activeDocument = document;
    const source = editorValue;
    const selection = editorSelection;
    imageImportInFlight.current = true; setImageImportBusy(true);
    try {
      const selected = await openDialog({
        multiple: true,
        directory: false,
        title: "选择要插入的图片",
        filters: [{ name: "图片", extensions: ["png", "jpg", "jpeg", "gif", "webp"] }],
      });
      const paths = typeof selected === "string" ? [selected] : Array.isArray(selected) ? selected : [];
      if (!paths.length) return;
      const imported: WritingImageImportResult[] = []; const failures: string[] = [];
      for (const path of paths) {
        try { imported.push(await gateway.importWritingImage(activeRepository.sessionId, path, activeDocument.documentId)); }
        catch (error) { failures.push(messageFrom(error)); }
      }
      if (!imported.length) { setNotice(`没有图片可插入：${failures[0] ?? "导入失败"}`); return; }
      if (activeEditorContext.current.repositoryId !== activeRepository.sessionId || activeEditorContext.current.documentId !== activeDocument.documentId || activeEditorText.current !== source) {
        setNotice("文章上下文已变化，未把导入结果插入正文。请重新打开原文章后检查图片资源。");
        return;
      }
      const result = insertMarkdownImages(source, selection, imported.map((image) => ({ markdownPath: image.markdownPath, fallbackAlt: image.fileName.replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ") })));
      applyEditorChange(result.text, result.selection, undefined, true);
      setWorkspaceMode("writing");
      setFocusMode(false);
      setWritingInspectorOpen(true);
      const partial = failures.length ? `；另有 ${failures.length} 张未导入：${failures[0]}` : "";
      setNotice(`已插入 ${imported.length} 张图片。当前已选中第一张的 Alt 文本，可直接修改${partial}`);
    } catch (error) { setNotice(`无法选择或导入图片：${messageFrom(error)}`); }
    finally { imageImportInFlight.current = false; setImageImportBusy(false); }
  }

  async function saveRssArticleToKnowledge(input: Parameters<NonNullable<React.ComponentProps<typeof RssReader>["onSaveToKnowledge"]>>[0]) {
    if (!capabilities?.knowledgeLibrary) throw new Error("当前版本的本地资料库不可用。");
    const text = input.text.trim();
    if (!text) throw new Error("这篇 RSS 文章没有可保存的正文。");
    const sourceUrl = safeExternalHttpUrl(input.article.link);
    const result = await gateway.importKnowledgeText({
      sourceKind: sourceUrl ? "web" : "text",
      title: input.article.title.trim() || "RSS 文章",
      sourceName: input.feed?.title.trim() || input.article.author?.trim() || "RSS",
      sourceUrl,
      text,
      allowsLocalSemanticIndex: false,
    });
    setNotice(result.summary || "RSS 文章已保存到本地资料库。");
  }

  async function insertRssReference(input: Parameters<NonNullable<React.ComponentProps<typeof RssReader>["onInsertReference"]>>[0]) {
    if (imageImportInFlight.current) throw new Error("图片仍在导入，请稍候再插入 RSS 摘录。");
    if (!repository || !document?.writable || !capabilities?.localEdit) throw new Error("请先打开一篇可编辑的本地 Markdown 稿件。");
    const text = input.text.trim();
    if (!text) throw new Error("这篇 RSS 文章没有可插入的摘录。");
    const activeRepository = repository;
    const activeDocument = document;
    const source = editorValue;
    const selection = editorSelection;
    await saveRssArticleToKnowledge(input);
    if (!isRssEditorContextCurrent(
      { repositoryId: activeRepository.sessionId, documentId: activeDocument.documentId, editorText: source },
      { repositoryId: activeEditorContext.current.repositoryId, documentId: activeEditorContext.current.documentId, editorText: activeEditorText.current },
    )) {
      setNotice("RSS 文章已保存到资料库；当前稿件在等待期间发生变化，未插入来源链接。");
      return;
    }
    const reference = rssReferenceMarkdown(input.article, text, input.feed?.title);
    const result = insertRssReferenceAt(source, selection.to, reference);
    applyEditorChange(result.text, { from: result.cursor, to: result.cursor }, "RSS 文章已保存到资料库，并插入安全来源链接。");
    setWorkspaceMode("writing");
  }

  async function createRssInspirationDraft(input: Parameters<NonNullable<React.ComponentProps<typeof RssReader>["onCreateInspirationDraft"]>>[0]) {
    if (!repository || !capabilities?.localEdit) throw new Error("请先选择一个可编辑的本地仓库。");
    const text = input.text.trim();
    if (!text) throw new Error("这篇 RSS 文章没有可用于灵感草稿的正文。");
    await saveRssArticleToKnowledge(input);
    openDraftDialog("create", rssInspirationDraft(input.article, text, input.feed?.title));
  }

  function openDraftDialog(mode: DraftLifecycleMode, initialText?: string) {
    if (imageImportInFlight.current) { setNotice("图片仍在导入，请稍候。"); return; }
    if (!repository || !capabilities?.localEdit) {
      setNotice("请先选择一个可编辑的本地仓库。");
      return;
    }
    if (mode !== "create" && !document) {
      setNotice("请先打开要管理的 Markdown 文章。");
      return;
    }
    if (mode !== "create" && hasUnsavedWork(editorState)) {
      setNotice("重命名或删除前请先保存当前修改，避免丢失写作内容。");
      return;
    }
    if (mode === "create" && hasUnsavedWork(editorState) && !window.confirm(t("当前文章有未保存修改。仍要新建并切换文章吗？"))) return;
    setDraftDialogError(null);
    setRssInspirationDraftText(mode === "create" ? initialText ?? null : null);
    setDraftDialogMode(mode);
  }

  async function submitDraftLifecycle(relativePath?: string) {
    if (!draftDialogMode || !repository) return;
    if (imageImportInFlight.current) { setDraftDialogError("图片仍在导入，请稍候。"); return; }
    if (saveInFlight.current) { setDraftDialogError("当前文章仍在保存，请等待完成后再管理文章。"); return; }
    setDraftDialogBusy(true);
    setDraftDialogError(null);
    documentOpenGeneration.current += 1;
    try {
      if (draftDialogMode === "create" && relativePath) {
        const created = await gateway.createMarkdownDocument(repository.sessionId, relativePath, rssInspirationDraftText ?? draftTemplate(relativePath));
        saveGeneration.current += 1;
        activeEditorContext.current = { repositoryId: repository.sessionId, documentId: created.documentId }; activeEditorText.current = created.text;
        setWorkspaceMode("writing");
        setDocument(created); setEditorValue(created.text); setEditorState("clean"); setEditorSelection({ from: 0, to: 0, text: "" });
        setFiles(await gateway.listMarkdownFiles(repository.sessionId));
        setNotice(`已创建并打开：${created.relativePath}`);
        setRssInspirationDraftText(null);
      } else if (draftDialogMode === "rename" && relativePath && document) {
        const renamed = await gateway.renameMarkdownDocument(repository.sessionId, document.documentId, relativePath, document.baselineSha256);
        saveGeneration.current += 1;
        activeEditorContext.current = { repositoryId: repository.sessionId, documentId: renamed.documentId }; activeEditorText.current = renamed.text;
        setDocument(renamed); setEditorValue(renamed.text); setEditorState("clean"); setEditorSelection({ from: 0, to: 0, text: "" });
        setFiles(await gateway.listMarkdownFiles(repository.sessionId));
        setNotice(`已重命名为：${renamed.relativePath}`);
      } else if (draftDialogMode === "delete" && document) {
        const deleted = await gateway.deleteMarkdownDocument(repository.sessionId, document.documentId, document.baselineSha256);
        saveGeneration.current += 1;
        activeEditorContext.current = { repositoryId: repository.sessionId, documentId: null }; activeEditorText.current = "";
        setDocument(null); setEditorValue(""); setEditorState("clean"); setEditorSelection({ from: 0, to: 0, text: "" });
        setFiles(await gateway.listMarkdownFiles(repository.sessionId));
        setNotice(`已移入回收站：${deleted.relativePath}`);
      }
      setDraftDialogMode(null);
    } catch (error) {
      const gatewayError = error as { code?: string };
      setDraftDialogError(gatewayError.code === "save_conflict" ? "文件已在磁盘上发生变化。请重新打开后再试，原文件没有被覆盖。" : messageFrom(error));
    } finally { setDraftDialogBusy(false); }
  }

  const handleAdvancedToolTabChange = useCallback((tab: AdvancedToolTab) => {
    setAdvancedToolsActiveTab(tab);
    if (tab === "health") setWorkspaceMode("sync");
  }, []);

  function openWorkspaceDrawer(drawer: "publish" | "tools" | "settings" | "knowledge" | "activity" | "sites" | "metadataBatch", toolTab: AdvancedToolTab | null = null) {
    if (exitActivity.frozen || metadataBatchInFlight.current) return;
    if (drawer === "publish" || drawer === "sites" || (drawer === "tools" && toolTab === "health")) setWorkspaceMode("sync");
    if (drawer === "metadataBatch") setMetadataBatchLoaded(true);
    setMetadataBatchOpen(drawer === "metadataBatch");
    closeImageWorkbench();
    if (drawer === "publish") setPublishCenterLoaded(true);
    if (drawer === "tools") {
      setAdvancedToolsLoaded(true);
      const nextTab = toolTab ?? "ai";
      setAdvancedToolsRequestedTab(nextTab);
      setAdvancedToolsActiveTab(nextTab);
      setAdvancedToolsRequestedTabKey((current) => current + 1);
    }
    if (drawer === "settings") setSettingsLoaded(true);
    if (drawer === "knowledge") setKnowledgeLibraryLoaded(true);
    if (drawer === "activity") setOperationLogLoaded(true);
    if (drawer === "sites") setSiteProfileCenterLoaded(true);
    setSiteProfileCenterOpen(drawer === "sites");
    setOperationLogOpen(drawer === "activity");
    setPublishCenterOpen(drawer === "publish");
    setAdvancedToolsOpen(drawer === "tools");
    setSettingsOpen(drawer === "settings");
    setKnowledgeLibraryOpen(drawer === "knowledge");
    if (drawer === "knowledge") setKnowledgeTargetItemId(null);
    setCommandPaletteOpen(false);
    setSnippetLibraryOpen(false);
    setInternalLinkPickerOpen(false);
    setDraftHistoryCenterOpen(false);
    setGeneralDraftCenterOpen(false);
  }

  function selectWorkspaceSection(section: WorkspaceSection) {
    if (exitActivity.frozen || metadataBatchInFlight.current || imageImportInFlight.current || repositorySwitchBusy || draftDialogBusy || conflictBusy) return;
    if (section === "library") { openWorkspaceDrawer("knowledge"); return; }
    if (section === "images") { openImageWorkbench(); return; }
    closeImageWorkbench();
    setMetadataBatchOpen(false); setOperationLogOpen(false); setSiteProfileCenterOpen(false);
    setPublishCenterOpen(false); setAdvancedToolsOpen(false); setSettingsOpen(false); setKnowledgeLibraryOpen(false);
    setDraftHistoryCenterOpen(false); setGeneralDraftCenterOpen(false); setCommandPaletteOpen(false);
    setSnippetLibraryOpen(false); setInternalLinkPickerOpen(false);
    setWorkspaceMode(section);
  }

  function openDraftHistoryCenter() {
    if (metadataBatchInFlight.current) return;
    setMetadataBatchOpen(false);
    setOperationLogOpen(false);
    setSiteProfileCenterOpen(false);
    if (!repository || !capabilities?.localEdit) {
      setNotice("请先打开一个可编辑的本地仓库。");
      return;
    }
    setWorkspaceMode("writing");
    closeImageWorkbench();
    setPublishCenterOpen(false);
    setAdvancedToolsOpen(false);
    setSettingsOpen(false);
    setKnowledgeLibraryOpen(false);
    setCommandPaletteOpen(false);
    setDraftDialogMode(null);
    setSnippetLibraryOpen(false);
    setInternalLinkPickerOpen(false);
    setGeneralDraftCenterOpen(false);
    setDraftHistoryCenterLoaded(true);
    setDraftHistoryCenterOpen(true);
  }

  function openGeneralDraftCenter() {
    if (metadataBatchInFlight.current) return;
    setMetadataBatchOpen(false);
    setOperationLogOpen(false);
    setSiteProfileCenterOpen(false);
    if (!capabilities?.localEdit) {
      setNotice("通用草稿库仅在桌面应用中可用。");
      return;
    }
    setWorkspaceMode("writing");
    closeImageWorkbench();
    setPublishCenterOpen(false);
    setAdvancedToolsOpen(false);
    setSettingsOpen(false);
    setKnowledgeLibraryOpen(false);
    setDraftHistoryCenterOpen(false);
    setCommandPaletteOpen(false);
    setDraftDialogMode(null);
    setSnippetLibraryOpen(false);
    setInternalLinkPickerOpen(false);
    setGeneralDraftCenterLoaded(true);
    setGeneralDraftCenterOpen(true);
  }

  function closeImageWorkbench() {
    imageWorkbenchGeneration.current += 1;
    imageWorkbenchOpenRef.current = false;
    setImageWorkbenchOpen(false);
  }

  function openImageWorkbench() {
    if (exitActivity.frozen || metadataBatchInFlight.current) return;
    setMetadataBatchOpen(false);
    setOperationLogOpen(false);
    setSiteProfileCenterOpen(false);
    imageWorkbenchGeneration.current += 1;
    setPublishCenterOpen(false);
    setAdvancedToolsOpen(false);
    setSettingsOpen(false);
    setKnowledgeLibraryOpen(false);
    setDraftHistoryCenterOpen(false);
    setGeneralDraftCenterOpen(false);
    setCommandPaletteOpen(false);
    setDraftDialogMode(null);
    setSnippetLibraryOpen(false);
    setInternalLinkPickerOpen(false);
    setImageWorkbenchLoaded(true);
    setImageWorkbenchOpen(true);
  }

  async function planMetadataBatch(request: MetadataBatchRequest): Promise<MetadataBatchPlan> {
    if (!repository || request.sessionId !== repository.sessionId || !capabilities?.metadataBatch || metadataBatchInFlight.current) throw new Error("当前仓库无法生成批量计划。");
    if (document && (hasUnsavedWork(editorState) || activeEditorText.current !== document.text) && request.paths.includes(document.relativePath)) throw new Error("请先保存当前文章，再重新预览。");
    const generation = repositoryOpenGeneration.current;
    const plan = await gateway.planMetadataBatch(request);
    if (generation !== repositoryOpenGeneration.current || activeEditorContext.current.repositoryId !== request.sessionId) throw new Error("仓库已切换，请重新预览。");
    metadataBatchPlan.current = { plan, repositoryGeneration: generation };
    return plan;
  }

  async function executeMetadataBatch(sessionId: string, planId: string): Promise<MetadataBatchResult> {
    const pending = metadataBatchPlan.current;
    if (!repository || repository.sessionId !== sessionId || !pending || pending.plan.planId !== planId
      || pending.repositoryGeneration !== repositoryOpenGeneration.current || repositorySwitchBusy
      || saveInFlight.current || imageImportInFlight.current || metadataBatchInFlight.current) throw new Error("当前状态无法执行，请重新预览。");
    const affectsCurrent = Boolean(document && pending.plan.previews.some((p) => p.relativePath === document.relativePath && p.status === "change"));
    if (affectsCurrent && document && (hasUnsavedWork(editorState) || activeEditorText.current !== document.text)) throw new Error("当前文章有未保存修改，请先保存并重新预览。");
    metadataBatchPlan.current = null;
    metadataBatchInFlight.current = true; saveInFlight.current = true; setMetadataBatchBusy(true);
    documentOpenGeneration.current += 1; editorNavigationGeneration.current += 1; pendingEditorLocation.current = null;
    const context = { ...activeEditorContext.current }; const text = activeEditorText.current;
    const currentPath = affectsCurrent ? document?.relativePath : undefined;
    if (affectsCurrent) recoveryScheduler.current.cancel();
    try {
      const result = await gateway.executeMetadataBatch(sessionId, planId);
      setNotice(result.summary);
      return result;
    } finally {
      // Re-read even after an uncertain response. Never replay a pre-batch editor snapshot.
      if (currentPath && activeEditorContext.current.repositoryId === context.repositoryId
        && activeEditorContext.current.documentId === context.documentId && activeEditorText.current === text) {
        try {
          const refreshed = await gateway.openDocument(sessionId, currentPath);
          if (activeEditorContext.current.repositoryId === context.repositoryId && activeEditorContext.current.documentId === context.documentId && activeEditorText.current === text) {
            activeEditorContext.current = { repositoryId: sessionId, documentId: refreshed.documentId };
            activeEditorText.current = refreshed.text;
            setDocument(refreshed); setEditorValue(refreshed.text); setEditorState("clean");
            setEditorSelection({ from: 0, to: 0, text: "" });
          }
        } catch { setNotice("批量操作后无法刷新当前文章；请重新打开文章核对磁盘与历史版本。"); }
      }
      metadataBatchInFlight.current = false; saveInFlight.current = false; setMetadataBatchBusy(false);
    }
  }

  async function reuseRepositoryImage(image: RepositoryImage, altText: string): Promise<boolean> {
    if (!repository || !document?.writable || !capabilities?.imageWorkbench || !capabilities.localEdit || imageImportInFlight.current || imageReuseInFlight.current) return false;
    const targetRepository = repository;
    const targetDocument = document;
    const source = editorValue;
    const selection = editorSelection;
    const generation = imageWorkbenchGeneration.current;
    imageReuseInFlight.current = true;
    try {
      const verified = await gateway.readRepositoryImage(targetRepository.sessionId, image.relativePath, image.sha256);
      if (verified.relativePath !== image.relativePath || verified.sha256 !== image.sha256 || verified.mimeType !== image.mimeType) throw new Error("图片已变化，请重新扫描后插入。");
      if (generation !== imageWorkbenchGeneration.current || !imageWorkbenchOpenRef.current || activeEditorContext.current.repositoryId !== targetRepository.sessionId || activeEditorContext.current.documentId !== targetDocument.documentId || activeEditorText.current !== source || imageImportInFlight.current) {
        throw new Error("文章上下文已变化，请重新选择插入位置。");
      }
      const path = repositoryImageMarkdownPath(image.relativePath, targetRepository, targetDocument.relativePath);
      const insertion = insertRepositoryImage(source, selection, path, altText);
      closeImageWorkbench();
      setWorkspaceMode("writing");
      applyEditorChange(insertion.text, insertion.selection, "已复用仓库图片。修改仅在编辑缓冲区中，请检查 Alt 文本后保存。");
      window.requestAnimationFrame(() => editorRef.current?.view?.focus());
      return true;
    } finally { imageReuseInFlight.current = false; }
  }

  async function applyGeneralDraftTransfer(result: GeneralDraftTransferResult) {
    if (exitActivity.frozen) return;
    const activeRepository = repository;
    if (!activeRepository) {
      setNotice(result.summary);
      return;
    }
    const clearCurrentDocument = () => {
      recoveryScheduler.current.cancel();
      saveGeneration.current += 1;
      activeEditorContext.current = { repositoryId: activeRepository.sessionId, documentId: null };
      activeEditorText.current = "";
      setDocument(null);
      setEditorValue("");
      setEditorState("clean");
      setEditorSelection({ from: 0, to: 0, text: "" });
    };
    const transferRemovedCurrent = result.operation === "moveCurrentToGeneral"
      && Boolean(document && result.affectedRelativePaths.includes(document.relativePath));
    if (transferRemovedCurrent) clearCurrentDocument();
    try {
      const nextFiles = await gateway.listMarkdownFiles(activeRepository.sessionId);
      setFiles(nextFiles);
      if (!transferRemovedCurrent && document && !nextFiles.some((item) => item.relativePath === document.relativePath)) clearCurrentDocument();
      setNotice(result.summary);
    } catch {
      setNotice(`${result.summary}；文件列表暂时无法刷新，可重新打开仓库后查看。`);
    }
  }

  async function applyDraftHistoryRestore(snapshot: DocumentSnapshot, source: "version" | "recycle") {
    if (exitActivity.frozen) return;
    if (!repository) return;
    recoveryScheduler.current.cancel();
    saveGeneration.current += 1;
    activeEditorContext.current = { repositoryId: repository.sessionId, documentId: snapshot.documentId };
    activeEditorText.current = snapshot.text;
    setWorkspaceMode("writing");
    setDocument(snapshot);
    setEditorValue(snapshot.text);
    setEditorState("clean");
    setEditorSelection({ from: 0, to: 0, text: "" });
    const restoredNotice = source === "version" ? `已恢复历史版本：${snapshot.relativePath}` : `已从回收站恢复：${snapshot.relativePath}`;
    try {
      setFiles(await gateway.listMarkdownFiles(repository.sessionId));
      setNotice(restoredNotice);
    } catch {
      setNotice(`${restoredNotice}；文件列表暂时无法刷新，可重新打开仓库后查看。`);
    }
  }

  function openSnippetLibrary() {
    if (!document?.writable || !capabilities?.localEdit || imageImportInFlight.current) {
      setNotice("请先打开一篇可编辑的本地文章。");
      return;
    }
    setWorkspaceMode("writing"); setCommandPaletteOpen(false); setInternalLinkPickerOpen(false); setSnippetLibraryOpen(true);
  }

  function openInternalLinkPicker() {
    if (!repository || !document?.writable || !capabilities?.localEdit || imageImportInFlight.current) {
      setNotice("请先打开一篇可编辑的本地文章。");
      return;
    }
    setWorkspaceMode("writing"); setCommandPaletteOpen(false); setSnippetLibraryOpen(false); setInternalLinkPickerOpen(true);
  }

  function focusEditor() {
    editorNavigationGeneration.current += 1;
    pendingEditorLocation.current = null;
    setWorkspaceMode("writing");
    pendingEditorFocus.current = true;
    window.requestAnimationFrame(() => {
      if (!pendingEditorFocus.current || !editorRef.current?.view) return;
      pendingEditorFocus.current = false;
      editorRef.current.view.focus();
    });
  }

  function fulfillPendingEditorFocus() {
    fulfillPendingEditorLocation();
    if (!pendingEditorFocus.current || !editorRef.current?.view) return;
    pendingEditorFocus.current = false;
    editorRef.current.view.focus();
  }
  function focusFileSearch() { setWorkspaceMode("writing"); setFocusMode(false); setSidebarVisible(true); window.requestAnimationFrame(() => window.document.querySelector<HTMLInputElement>("#markdown-search")?.focus()); }

  function toggleWritingInspector(tab: "writing" | "metadata") {
    if (!document || exitActivity.frozen || metadataBatchInFlight.current || conflictOpenRef.current) return;
    setWorkspaceMode("writing"); setFocusMode(false);
    if (tab === "writing") setWritingInspectorLoaded(true);
    setWritingInspectorOpen((open) => !(open && inspectorTab === tab));
    setInspectorTab(tab);
    if (!writingInspectorOpen || inspectorTab !== tab || focusMode) setInspectorRevealRequestKey((current) => current + 1);
  }

  function showWritingInspector(tab: "writing" | "metadata" | "state") {
    if (!document || exitActivity.frozen || metadataBatchInFlight.current || conflictOpenRef.current) return;
    if (tab === "writing") setWritingInspectorLoaded(true);
    if (tab === "state") setArticleStateLoaded(true);
    setWorkspaceMode("writing"); setFocusMode(false); setInspectorTab(tab); setWritingInspectorOpen(true);
    setInspectorRevealRequestKey((current) => current + 1);
  }

  function locateMetadataField(field: FrontMatterField, expectedText: string) {
    if (!repository || !document) return;
    if (imageImportInFlight.current || saveInFlight.current) {
      setNotice("文章仍在保存或导入图片，请稍候再定位。"); return;
    }
    if (activeEditorContext.current.repositoryId !== repository.sessionId
      || activeEditorContext.current.documentId !== document.documentId
      || activeEditorText.current !== expectedText) {
      setNotice("属性检查已过期，请重新检查后再定位。"); return;
    }
    editorNavigationGeneration.current += 1;
    documentOpenGeneration.current += 1;
    pendingEditorLocation.current = null; pendingEditorFocus.current = false;
    setWorkspaceMode("writing"); setFocusMode(false); setInspectorTab("metadata"); setWritingInspectorOpen(true);
    setPublishCenterOpen(false); setAdvancedToolsOpen(false); setCommandPaletteOpen(false);
    setFieldFocusRequest({ documentKey: editorDocumentKey, field, requestKey: ++fieldFocusSequence.current, expectedText });
  }

  function locateArticleStateIssue(location: ArticleStateLocation, expectedText: string, expectedContextKey: string) {
    if (!repository || !document || exitActivity.frozen || metadataBatchInFlight.current || conflictOpenRef.current
      || imageImportInFlight.current || saveInFlight.current || repositorySwitchBusy) return;
    if (articleStateContextKeyRef.current !== expectedContextKey
      || activeEditorContext.current.repositoryId !== repository.sessionId
      || activeEditorContext.current.documentId !== document.documentId || activeEditorText.current !== expectedText) {
      setNotice("文章状态检查已过期，请重新查看后再定位。");
      return;
    }
    if (location.kind === "field") locateMetadataField(location.field, expectedText);
    else if (location.kind === "range") void navigateToDocument(document.relativePath,
      { kind: "range", range: { from: location.from, to: location.to }, expectedText }, "文章状态");
    else if (location.kind === "site") selectWorkspaceSection("sync");
    else openWorkspaceDrawer("publish");
  }

  async function applyArticleStateChange(plan: ArticleStateChangePlan): Promise<boolean> {
    if (!plan || typeof plan !== "object" || consumedArticleStatePlans.current.has(plan)) return false;
    consumedArticleStatePlans.current.add(plan);
    if (articleStateApplyInFlight.current) return false;
    articleStateApplyInFlight.current = true;
    const isCurrent = () => articleStateMounted.current && !exitActivity.frozen && liveArticleState.current.canChange
      && exitContext.current.canStart && !saveInFlight.current && !imageImportInFlight.current && !imageReuseInFlight.current
      && !metadataBatchInFlight.current && !conflictInFlight.current && !siteSelectionInFlight.current && !conflictOpenRef.current
      && !editorRef.current?.view?.composing
      && liveArticleState.current.repositoryGeneration === repositoryOpenGeneration.current
      && liveArticleState.current.documentGeneration === documentOpenGeneration.current
      && liveArticleState.current.saveGeneration === saveGeneration.current
      && liveArticleState.current.generation === articleStateEditGeneration.current
      && liveArticleState.current.key === plan.contextKey && activeEditorText.current === plan.expectedText
      && liveArticleState.current.context?.kind === "repository"
      && activeEditorContext.current.repositoryId === liveArticleState.current.context.repository.sessionId
      && activeEditorContext.current.documentId === liveArticleState.current.context.documentId;
    try {
      if (!isCurrent()) return false;
      const [{ planArticleStateChange }, { applyArticleStateChangeToEditor }] = await Promise.all([
        import("./features/writing/articleStateChange"), import("./components/MarkdownEditorSurface"),
      ]);
      if (!isCurrent()) return false;
      const live = liveArticleState.current;
      const rebuilt = planArticleStateChange({ text: activeEditorText.current, context: live.context!,
        contextKey: live.key, nowEpochMs: Date.now() }, plan.target);
      if (!rebuilt.ok || rebuilt.plan.nextText !== plan.nextText || rebuilt.plan.beforeField !== plan.beforeField
        || rebuilt.plan.afterField !== plan.afterField || JSON.stringify(rebuilt.plan.edit) !== JSON.stringify(plan.edit)) return false;
      const view = editorRef.current?.view;
      if (!view || !isCurrent() || !applyArticleStateChangeToEditor(view, rebuilt.plan)) return false;
      if (activeEditorText.current !== rebuilt.plan.nextText) { articleStateEditGeneration.current += 1; sitePreviewEditGeneration.current += 1; }
      activeEditorText.current = rebuilt.plan.nextText;
      setEditorValue(rebuilt.plan.nextText); setEditorState("dirty");
      setEditorSelection({ ...rebuilt.plan.selection, text: rebuilt.plan.nextText.slice(rebuilt.plan.selection.from, rebuilt.plan.selection.to) });
      setNotice("文章状态已应用到编辑器，尚未保存。");
      return true;
    } catch {
      return false;
    } finally { articleStateApplyInFlight.current = false; }
  }

  function toggleFocusMode() {
    setWorkspaceMode("writing");
    setFocusMode((current) => !current);
    window.requestAnimationFrame(() => window.document.querySelector<HTMLElement>(".cm-content")?.focus());
  }

  function applyAiReplacement(expectedSelection: EditorSelectionSnapshot, replacementText: string): boolean {
    if (exitActivity.frozen) return false;
    if (imageImportInFlight.current) { setNotice("图片仍在导入，请稍候再应用 AI 建议。"); return false; }
    if (editorSelection.from !== expectedSelection.from || editorSelection.to !== expectedSelection.to || editorSelection.text !== expectedSelection.text) return false;
    const replacement = replaceUnchangedSelection(editorValue, expectedSelection, expectedSelection.text, replacementText);
    if (!replacement || !document?.writable || !capabilities?.localEdit) return false;
    activeEditorText.current = replacement.text; setEditorValue(replacement.text);
    setEditorSelection(replacement.selection);
    setEditorState("dirty");
    setNotice("AI 提案已应用到编辑缓冲区；点击“保存”后才会写入磁盘。");
    return true;
  }

  async function openSemanticPath(relativePath: string) {
    const known = files.find((file) => file.relativePath === relativePath);
    const segments = relativePath.split("/");
    const file = known ?? {
      relativePath,
      displayName: segments[segments.length - 1] || relativePath,
      directory: segments.slice(0, -1).join("/"),
      byteSize: 0,
    };
    await selectDocument(file);
  }

  // Keep the request until the lazy editor has mounted and received this document.
  // A late editor callback may only select; it must never replace newer text.
  function fulfillPendingEditorLocation() {
    window.requestAnimationFrame(() => {
      const pending = pendingEditorLocation.current;
      if (!pending) return;
      if (pending.generation !== editorNavigationGeneration.current
        || pending.repositoryGeneration !== repositoryOpenGeneration.current
        || pending.documentGeneration !== documentOpenGeneration.current
        || activeEditorContext.current.repositoryId !== pending.repositoryId
        || activeEditorContext.current.documentId !== pending.documentId
        || activeEditorText.current !== pending.text) {
        pendingEditorLocation.current = null;
        return;
      }
      const view = editorRef.current?.view;
      if (!view || view.state.doc.toString() !== pending.text) return;
      pendingEditorLocation.current = null;
      view.dispatch({ selection: { anchor: pending.range.from, head: pending.range.to }, scrollIntoView: true });
      view.focus();
      setEditorSelection({ ...pending.range, text: pending.text.slice(pending.range.from, pending.range.to) });
      setNotice(pending.notice);
    });
  }

  useEffect(() => { fulfillPendingEditorLocation(); }, [document?.documentId, editorValue, workspaceMode]);

  async function navigateToDocument(relativePath: string, location: EditorLocation | null, source: "搜索结果" | "内容健康报告" | "文章大纲" | "写作面板" | "发布中心审阅" | "文章状态") {
    if (!repository) return;
    if (imageImportInFlight.current || saveInFlight.current) {
      setNotice("文章仍在保存或导入图片，请稍候再定位。");
      return;
    }
    const sameDocument = document?.relativePath === relativePath
      && activeEditorContext.current.documentId === document.documentId;
    // Declining a new navigation must not cancel an already accepted load.
    if (!sameDocument && hasUnsavedWork(editorState) && !window.confirm(t("当前文档有未保存修改。仍要切换吗？"))) return;
    const requestGeneration = ++editorNavigationGeneration.current;
    documentOpenGeneration.current += 1;
    pendingEditorLocation.current = null;
    pendingEditorFocus.current = false;
    const repositoryId = repository.sessionId;
    const repositoryGeneration = repositoryOpenGeneration.current;
    if (!sameDocument) {
      const known = files.find((file) => file.relativePath === relativePath);
      const segments = relativePath.split("/");
      const opened = await selectDocument(known ?? {
        relativePath, displayName: segments[segments.length - 1] || relativePath,
        directory: segments.slice(0, -1).join("/"), byteSize: 0,
      }, requestGeneration);
      if (!opened) return;
    }
    if (requestGeneration !== editorNavigationGeneration.current
      || repositoryGeneration !== repositoryOpenGeneration.current
      || activeEditorContext.current.repositoryId !== repositoryId) return;
    const text = activeEditorText.current;
    const range = location ? resolveEditorLocation(text, location) : { from: 0, to: 0 };
    if (!range) {
      setNotice({ source: "{origin}的位置已变化或无法核验，请重新检查后再定位。", labels: { origin: { source } } });
      return;
    }
    const documentId = activeEditorContext.current.documentId;
    if (!documentId) return;
    setWorkspaceMode("writing"); setFocusMode(false);
    setAdvancedToolsOpen(false); setPublishCenterOpen(false); setCommandPaletteOpen(false);
    setSnippetLibraryOpen(false); setInternalLinkPickerOpen(false);
    pendingEditorLocation.current = {
      generation: requestGeneration, repositoryGeneration, documentGeneration: documentOpenGeneration.current,
      repositoryId, documentId, text, range, notice: { source: "已从{origin}定位：{path}", parameters: { path: relativePath }, labels: { origin: { source } } },
    };
    fulfillPendingEditorLocation();
  }

  function openSearchResult(match: MarkdownSearchResult, query: string) {
    void navigateToDocument(match.relativePath, match.matchKind === "content" ? {
      kind: "search", lineNumber: match.lineNumber ?? 0, snippet: match.snippet, query,
    } : null, "搜索结果");
  }

  function openContentHealthIssue(relativePath: string, range: TextRange, expectedDocumentText: string) {
    return navigateToDocument(relativePath, { kind: "range", range, expectedText: expectedDocumentText }, "内容健康报告");
  }

  async function saveDocument() {
    if (exitActivity.frozen) return;
    if (conflictOpenRef.current) return;
    if (!repository || !document || !canSaveDocument(editorState)) return;
    if (saveInFlight.current) { setNotice("保存仍在进行；新输入会保留，请在完成后再次保存。"); return; }
    const savingRepository = repository;
    const savingDocument = document;
    const savingText = editorValue;
    const requestGeneration = ++saveGeneration.current;
    saveInFlight.current = true;
    recoveryScheduler.current.cancel();
    setEditorState("saving");
    try {
      const result = await gateway.saveDocument({ sessionId: savingRepository.sessionId, documentId: savingDocument.documentId, text: savingText, expectedSha256: savingDocument.baselineSha256 });
      if (exitActivity.frozen || requestGeneration !== saveGeneration.current) return;
      if (activeEditorContext.current.repositoryId !== savingRepository.sessionId || activeEditorContext.current.documentId !== savingDocument.documentId) {
        setNotice("先前打开的文章已完成保存；当前文章未被改动。");
        return;
      }
      setDocument(result);
      if (activeEditorText.current === savingText) {
        activeEditorText.current = result.text; setEditorValue(result.text); setEditorState("saved"); setNotice("已安全保存到本地仓库。");
      } else {
        setEditorState("dirty"); setNotice("已保存点击时的版本；保存期间的新输入仍在编辑缓冲区，请再次保存。");
      }
      try { setWorkspaceState(normalizeWorkspaceState(await gateway.getWorkspaceState())); } catch { /* The disk save succeeded; workspace state can refresh on next launch. */ }
    } catch (error) {
      if (exitActivity.frozen || requestGeneration !== saveGeneration.current) return;
      if (activeEditorContext.current.repositoryId !== savingRepository.sessionId || activeEditorContext.current.documentId !== savingDocument.documentId) return;
      const gatewayError = error as { code?: string; message?: string };
      if (gatewayError.code === "save_conflict") { setEditorState("conflict"); setNotice("文件已被外部修改；请审阅保存冲突。编辑缓冲区和磁盘文件均已保留。"); }
      else { setEditorState("failed"); setNotice(`保存失败：${messageFrom(error)}`); }
    } finally { saveInFlight.current = false; }
  }

  function conflictTextWithinBudget(text: string) {
    return text.length <= 256 * 1024 && new TextEncoder().encode(text).length <= 256 * 1024;
  }

  function closeConflictReview() {
    if (conflictInFlight.current) return;
    conflictGeneration.current += 1;
    conflictOpenRef.current = false; setConflictOpen(false);
    conflictReviewRef.current = null; setConflictReview(null); setConflictError("");
  }

  async function loadConflictReview() {
    if (!repository || !document || !document.writable || !capabilities?.localEdit
      || saveInFlight.current || imageImportInFlight.current || metadataBatchInFlight.current || conflictInFlight.current) return;
    const sessionId = repository.sessionId;
    const key = editorDocumentKey;
    const localText = activeEditorText.current;
    const baselineText = document.text;
    const path = document.relativePath;
    const generation = ++conflictGeneration.current;
    conflictOpenRef.current = true; setConflictOpen(true); setConflictLoaded(true);
    setConflictReview(null); conflictReviewRef.current = null; setConflictError("");
    setPublishCenterOpen(false); setAdvancedToolsOpen(false); setSettingsOpen(false);
    setKnowledgeLibraryOpen(false); setDraftHistoryCenterOpen(false); setGeneralDraftCenterOpen(false);
    closeImageWorkbench(); setOperationLogOpen(false); setSiteProfileCenterOpen(false);
    setMetadataBatchOpen(false); setCommandPaletteOpen(false); setSnippetLibraryOpen(false); setInternalLinkPickerOpen(false);
    documentOpenGeneration.current += 1; editorNavigationGeneration.current += 1; pendingEditorLocation.current = null;
    conflictInFlight.current = true; saveInFlight.current = true; setConflictBusy(true);
    const stillCurrent = () => generation === conflictGeneration.current && conflictOpenRef.current
      && editorDocumentKeyRef.current === key && activeEditorContext.current.repositoryId === sessionId
      && activeEditorText.current === localText;
    try {
      if (!conflictTextWithinBudget(baselineText) || !conflictTextWithinBudget(localText)) throw new Error("版本超过 256 KiB，无法完整展示冲突；原稿保持不变。");
      const disk = await gateway.openDocument(sessionId, path);
      if (!stillCurrent()) return;
      if (disk.relativePath !== path || !disk.writable || !conflictTextWithinBudget(disk.text)) throw new Error("磁盘版本不可安全编辑或超过 256 KiB；原稿保持不变。");
      const snapshot = { documentKey: key, relativePath: path, baselineText, localText, diskText: disk.text, diskSha256: disk.baselineSha256 };
      conflictReviewRef.current = snapshot; setConflictReview(snapshot);
    } catch (error) {
      if (stillCurrent()) setConflictError(`无法读取冲突版本：${messageFrom(error)}`);
    } finally { conflictInFlight.current = false; saveInFlight.current = false; setConflictBusy(false); }
  }

  async function applyConflictReview(mergedText: string) {
    const review = conflictReviewRef.current;
    if (!repository || !document || !review || !conflictOpenRef.current || conflictInFlight.current
      || saveInFlight.current || imageImportInFlight.current || metadataBatchInFlight.current
      || !document.writable || !capabilities?.localEdit) throw new Error("当前状态无法应用，请重新读取冲突版本。");
    const generation = conflictGeneration.current;
    const sessionId = repository.sessionId;
    const stillCurrent = () => generation === conflictGeneration.current && conflictOpenRef.current
      && conflictReviewRef.current === review && editorDocumentKeyRef.current === review.documentKey
      && activeEditorContext.current.repositoryId === sessionId && activeEditorText.current === review.localText;
    if (!stillCurrent() || !conflictTextWithinBudget(mergedText)) throw new Error("原稿已变化或合并文本超过 256 KiB，请重新审阅。");
    conflictInFlight.current = true; saveInFlight.current = true; setConflictBusy(true); setConflictError("");
    recoveryScheduler.current.cancel();
    let backupCreated = false;
    try {
      const verifyDisk = async () => {
        const disk = await gateway.openDocument(sessionId, review.relativePath);
        if (!stillCurrent()) throw new Error("文稿上下文已变化，未载入合并稿。");
        if (!disk.writable || disk.relativePath !== review.relativePath || disk.baselineSha256 !== review.diskSha256 || disk.text !== review.diskText)
          throw new Error("磁盘版本再次变化，请重新读取并审阅。");
        return disk;
      };
      await verifyDisk();
      const backup = await gateway.saveGeneralDraft({ draftId: null, text: review.localText, expectedRevision: null, expectedSha256: null });
      backupCreated = true;
      if (!stillCurrent()) throw new Error("文稿上下文已变化，未载入合并稿。");
      const stored = await gateway.getGeneralDraft(backup.draftId);
      if (!stillCurrent() || stored.draftId !== backup.draftId || stored.text !== review.localText)
        throw new Error("无法核对原稿备份，未载入合并稿。");
      const disk = await verifyDisk();
      saveGeneration.current += 1; documentOpenGeneration.current += 1; editorNavigationGeneration.current += 1;
      pendingEditorFocus.current = false;
      pendingEditorLocation.current = {
        generation: editorNavigationGeneration.current, repositoryGeneration: repositoryOpenGeneration.current,
        documentGeneration: documentOpenGeneration.current, repositoryId: sessionId, documentId: disk.documentId,
        text: mergedText, range: { from: 0, to: 0 }, notice: "原稿已备份到通用草稿，合并结果已载入编辑缓冲区；尚未写回仓库。",
      };
      activeEditorContext.current = { repositoryId: sessionId, documentId: disk.documentId };
      activeEditorText.current = mergedText;
      conflictReviewRef.current = null; setConflictReview(null);
      conflictOpenRef.current = false; setConflictOpen(false);
      setDocument(disk); setEditorValue(mergedText); setEditorSelection({ from: 0, to: 0, text: "" });
      setEditorState(mergedText === disk.text ? "clean" : "dirty");
      setNotice("原稿已备份到通用草稿，合并结果已载入编辑缓冲区；尚未写回仓库。");
    } catch (error) {
      throw new Error(`${messageFrom(error)}${backupCreated ? " 原稿副本已保留在通用草稿中。" : " 原稿仍保留在编辑缓冲区。"}`);
    } finally { conflictInFlight.current = false; saveInFlight.current = false; setConflictBusy(false); }
  }

  function applyImageReferenceRepair(edit: ImageReferenceRepairEdit): boolean {
    if (exitActivity.frozen) return false;
    if (!repository || !document?.writable || !capabilities?.localEdit || !imageWorkbenchOpenRef.current
      || saveInFlight.current || imageImportInFlight.current || metadataBatchInFlight.current || conflictOpenRef.current
      || edit.documentKey !== editorDocumentKeyRef.current || edit.relativePath !== document.relativePath
      || activeEditorContext.current.repositoryId !== repository.sessionId || activeEditorContext.current.documentId !== document.documentId
      || activeEditorText.current !== edit.expectedText) return false;
    applyEditorChange(edit.nextText, edit.selection, "已替换当前文章中的单个图片引用；尚未保存。");
    return true;
  }

  async function refreshGitStatus() {
    if (!repository || !capabilities?.gitStatus) return;
    const sessionId = repository.sessionId;
    const repositoryGeneration = repositoryOpenGeneration.current;
    const isCurrent = () => !exitActivity.frozen && repositoryGeneration === repositoryOpenGeneration.current
      && activeEditorContext.current.repositoryId === sessionId;
    try {
      const nextStatus = await gateway.gitStatus(sessionId);
      if (!isCurrent()) return;
      setGitStatus(nextStatus);
      setNotice(nextStatus.available ? "Git 状态已刷新（仅查看）。" : "所选目录不是 Git 仓库；仍可继续本地编辑。");
    } catch (error) {
      if (!isCurrent()) return;
      const gatewayError = error as { code?: string };
      if (gatewayError.code === "git_unavailable") {
        setGitStatus(null);
        setNotice("Git 当前不可用；仍可继续本地编辑。安装或恢复 Git 后重新启动应用。");
      } else setNotice(`无法刷新 Git 状态：${messageFrom(error)}`);
    }
  }

  function updateWorkspacePreferences(update: (current: WorkspacePreferences) => WorkspacePreferences): Promise<void> {
    const operation = preferenceSaveQueue.current.then(async () => {
      const current = workspaceStateRef.current.preferences ?? DEFAULT_WORKSPACE_PREFERENCES;
      const next = normalizeWorkspacePreferences(update(current));
      const snapshot = normalizeWorkspaceState(await gateway.updateWorkspacePreferences(next));
      workspaceStateRef.current = snapshot;
      setWorkspaceState(snapshot);
    });
    preferenceSaveQueue.current = operation.catch(() => undefined);
    return operation;
  }

  function saveWorkspacePreferences(nextPreferences: WorkspacePreferences): Promise<void> {
    return updateWorkspacePreferences(() => nextPreferences);
  }

  function changeWritingToolDensity(density: WorkspacePreferences["writingToolDensity"]) {
    const persistedDensity = workspaceStateRef.current.preferences?.writingToolDensity ?? preferences.writingToolDensity;
    const generation = writingToolDensitySelection.current.request(density, persistedDensity);
    if (generation === null) return;
    setOptimisticWritingToolDensity(density);
    void updateWorkspacePreferences((current) => ({ ...current, writingToolDensity: density }))
      .then(() => {
        if (!writingToolDensitySelection.current.settle(generation)) return;
        setOptimisticWritingToolDensity(null);
      })
      .catch((error) => {
        if (!writingToolDensitySelection.current.settle(generation)) return;
        setOptimisticWritingToolDensity(null);
        setNotice(`无法保存写作工具密度：${messageFrom(error)}`);
      });
  }

  async function changeWritingToolbarItems(itemIds: WorkspacePreferences["writingToolbarItemIds"]) {
    const unchanged = itemIds.length === preferences.writingToolbarItemIds.length
      && itemIds.every((itemId, index) => itemId === preferences.writingToolbarItemIds[index]);
    if (unchanged) return;
    await updateWorkspacePreferences((current) => ({ ...current, writingToolbarItemIds: itemIds }));
    setNotice("格式工具栏配置已保存并立即应用。");
  }

  async function cycleTheme() {
    try { await updateWorkspacePreferences((current) => ({ ...current, theme: current.theme === "system" ? "light" : current.theme === "light" ? "dark" : "system" })); }
    catch (error) { setNotice(`无法保存主题设置：${messageFrom(error)}`); }
  }

  async function discardRecoveryDraft() {
    const recoveryId = workspaceState.recoveryDraft?.recoveryId;
    if (!recoveryId) return;
    try {
      setWorkspaceState(normalizeWorkspaceState(await gateway.clearRecoveryDraft(recoveryId)));
      setNotice("已丢弃崩溃恢复草稿；磁盘文件未被修改。");
    } catch (error) { setNotice(`无法丢弃恢复草稿：${messageFrom(error)}`); }
  }

  function restoreRecoveryDraft() {
    if (exitActivity.frozen) return;
    const draft = workspaceState.recoveryDraft;
    if (imageImportInFlight.current) { setNotice("图片仍在导入，请稍候再恢复草稿。"); return; }
    if (!draft || recoveryMatch(draft, repository?.rootPath, document) !== "ready") return;
    recoveryScheduler.current.cancel();
    activeEditorText.current = draft.text; setEditorValue(draft.text); setEditorState("dirty");
    setNotice("恢复草稿已放入编辑缓冲区；尚未写入磁盘，请检查后保存。");
  }

  const activeRecovery = recoveryMatch(workspaceState.recoveryDraft, repository?.rootPath, document);
  const recoveryPreview = workspaceState.recoveryDraft ? recoveryDraftPreview(workspaceState.recoveryDraft.text) : null;
  const workspaceCommands: WorkspaceCommand[] = [
    { id: "metadata-batch", title: "批量标签与分类", detail: "选择文章，预览字段变化后确认执行", disabled: !repository || !capabilities?.metadataBatch || metadataBatchBusy, action: () => openWorkspaceDrawer("metadataBatch") },
    { id: "repository", title: "选择仓库", detail: "打开本地 RepoPress 仓库", shortcut: "Ctrl O", action: () => void chooseRepository() },
    { id: "save", title: "保存当前文档", detail: document?.writable ? editorStateLabel(editorState) : "打开可编辑 Markdown 文档后可用", shortcut: "Ctrl S", disabled: !canSaveDocument(editorState), action: () => void saveDocument() },
    { id: "new-article", title: "新建 Markdown 文章", detail: "在站点内容目录创建带 Front Matter 的草稿", shortcut: "Ctrl N", disabled: !repository || !capabilities?.localEdit, action: () => openDraftDialog("create") },
    { id: "rename-article", title: "重命名当前文章", detail: "安全移动或修改仓库内路径", disabled: !document?.writable || !capabilities?.localEdit || hasUnsavedWork(editorState), action: () => openDraftDialog("rename") },
    { id: "delete-article", title: "删除当前文章", detail: "确认后移入可恢复回收站，外部变化时拒绝执行", disabled: !document?.writable || !capabilities?.localEdit || hasUnsavedWork(editorState), action: () => openDraftDialog("delete") },
    { id: "draft-history", title: "打开版本历史与回收站", detail: "比较和恢复已保存版本，或恢复误删文章", disabled: !repository || !capabilities?.localEdit, action: openDraftHistoryCenter },
    { id: "general-drafts", title: "打开通用草稿库", detail: "跨仓库中转、批量导入和受保护撤销", disabled: !capabilities?.localEdit, action: openGeneralDraftCenter },
    { id: "insert-images", title: "插入本地图片", detail: "复制到当前站点的公开资源目录并插入 Markdown", disabled: !repository || !document?.writable || !capabilities?.localEdit || imageImportBusy, action: () => void chooseWritingImages() },
    { id: "image-workbench", title: "打开图片工作台", detail: "浏览、预览和复用当前仓库的图片", action: openImageWorkbench },
    { id: "site-profiles", title: "管理已保存站点", detail: "登记当前仓库、切换站点与编辑名称", action: () => openWorkspaceDrawer("sites") },
    { id: "operation-log", title: "打开操作日志", detail: "查看本机操作结果、筛选安全摘要和清空历史显示", action: () => openWorkspaceDrawer("activity") },
    { id: "internal-link", title: "插入站内链接", detail: "搜索当前仓库文章并生成站点路径", disabled: !repository || !document?.writable || !capabilities?.localEdit || imageImportBusy || files.length < 2, action: openInternalLinkPicker },
    { id: "snippet-library", title: "打开 Markdown 片段库", detail: "插入文章模板、正文片段或当前站点的自定义片段", disabled: !document?.writable || !capabilities?.localEdit || imageImportBusy, action: openSnippetLibrary },
    { id: "files", title: "搜索 Markdown 文件", detail: "按路径或正文搜索当前仓库", shortcut: "Ctrl Shift F", disabled: !repository, action: focusFileSearch },
    { id: "editor", title: "聚焦编辑器", detail: "返回当前 Markdown 编辑位置", shortcut: "Ctrl Shift E", disabled: !document, action: focusEditor },
    { id: "go-to-line", title: "跳转到指定行", detail: "按行号定位，并在代码围栏两端之间跳转", shortcut: "Ctrl L", disabled: !document, action: () => { setWorkspaceMode("writing"); setGoToLineRequestKey((current) => current + 1); } },
    { id: "git", title: "刷新 Git 状态", detail: capabilities?.gitStatus ? "仅读取仓库状态和 diff" : "当前系统未检测到 Git", disabled: !repository || !capabilities?.gitStatus, action: () => void refreshGitStatus() },
    { id: "publish", title: "打开发布中心", detail: "先检查计划，再确认执行 Git 或远端操作", shortcut: "Ctrl Shift P", disabled: !repository, action: () => openWorkspaceDrawer("publish") },
    { id: "tools", title: "打开智能工具", detail: "AI 编辑与对话、语义搜索、文档分析和内容健康", action: () => openWorkspaceDrawer("tools") },
    { id: "content-health", title: "打开仓库内容健康", detail: "进入本地只读扫描；仍需点击扫描按钮才会读取仓库", disabled: !repository || !capabilities?.contentHealth, action: () => openWorkspaceDrawer("tools", "health") },
    { id: "settings", title: "打开设置", detail: "外观、恢复和最近仓库", action: () => openWorkspaceDrawer("settings") },
    { id: "knowledge", title: "打开资料库", detail: "导入、搜索、阅读和导出资料", action: () => openWorkspaceDrawer("knowledge") },
    { id: "writing-workspace", title: "切换到写作工作区", detail: "仓库文件、Markdown 编辑与站点预览", action: () => selectWorkspaceSection("writing") },
    { id: "rss-workspace", title: "切换到阅读工作区", detail: "RSS 订阅、筛选、离线阅读与稍后阅读", action: () => selectWorkspaceSection("rss") },
    { id: "sync-workspace", title: "切换到站点工作区", detail: "站点检查、发布与已保存站点管理", action: () => selectWorkspaceSection("sync") },
    { id: "focus", title: focusMode ? "退出专注模式" : "进入专注模式", detail: "隐藏文件导航与预览，专注 Markdown 编辑", action: toggleFocusMode },
    { id: "preview", title: previewVisible ? "隐藏预览栏" : "显示预览栏", detail: "Markdown 与受信任的本机站点预览", action: () => setPreviewVisible((current) => !current) },
    { id: "writing-inspector", title: writingInspectorOpen && inspectorTab === "writing" ? "关闭写作面板" : "打开写作面板", detail: "写作诊断、快速修复、查找替换和大纲", shortcut: "Ctrl F", disabled: !document, action: () => toggleWritingInspector("writing") },
    { id: "metadata-inspector", title: "文章属性与 SEO 检查", detail: "本地检查元数据并定位到对应字段", disabled: !document, action: () => toggleWritingInspector("metadata") },
    { id: "article-state", title: "查看文章状态", detail: "根据当前缓冲区查看归属、草稿意图与日期问题", disabled: !document, action: () => showWritingInspector("state") },
    { id: "pinned-outline", title: outlinePinned ? "取消固定大纲" : "固定文章大纲", detail: "跟随当前章节、折叠层级与定位正文", disabled: !document, action: () => { setWorkspaceMode("writing"); setFocusMode(false); setOutlinePinned((current) => !current); } },
  ].map((command) => ({ ...command, title: t(command.title), detail: t(command.detail) }));

  const activeWorkspaceSection: WorkspaceSection = knowledgeLibraryOpen ? "library" : imageWorkbenchOpen ? "images"
    : publishCenterOpen || siteProfileCenterOpen || (advancedToolsOpen && advancedToolsActiveTab === "health") ? "sync" : workspaceMode;
  const workspaceNavigationBusy = exitState.open || metadataBatchBusy || imageImportBusy || repositorySwitchBusy || draftDialogBusy || conflictBusy;

  return <I18nProvider locale={locale}><main inert={exitState.open} className={darkMode ? "app-shell dark" : "app-shell"} style={{ "--editor-font-size": `${preferences.editorFontSize}px` } as React.CSSProperties}>
    <a className="skip-link" href="#workspace-content">{t("跳到工作区")}</a>
    <div className="studio-frame">
    <WorkspaceNavigation activeSection={activeWorkspaceSection} disabled={workspaceNavigationBusy} onSelect={selectWorkspaceSection}
      onTools={() => openWorkspaceDrawer("tools")} onDrafts={openGeneralDraftCenter}
      onActivity={() => openWorkspaceDrawer("activity")} onSettings={() => openWorkspaceDrawer("settings")} draftsEnabled={Boolean(capabilities?.localEdit)} />
    <div className="studio-content">
    <header className="topbar">
      <div className="brand" aria-label={t("RepoPress 桌面版")}><span className="brand-mark" aria-hidden="true">R</span><span>RepoPress</span><small>Studio</small></div>
      <div className="toolbar" aria-label={t("仓库操作")}>
        <button type="button" onClick={() => void chooseRepository()} disabled={imageImportBusy} aria-label={t("选择仓库")}>{t("选择仓库")}</button>
        <button type="button" onClick={() => openDraftDialog("create")} disabled={!repository || !capabilities?.localEdit || imageImportBusy} aria-label={t("新建 Markdown 文章")}>{t("新建文章")}</button>
        <button type="button" onClick={() => void saveDocument()} disabled={!canSaveDocument(editorState)} aria-label={t("保存当前 Markdown 文档")}>{t("保存")}</button>
        <button type="button" onClick={() => openWorkspaceDrawer("publish")} aria-label={t("打开发布中心")} aria-expanded={publishCenterOpen}>{t("发布中心")}</button>
        <button type="button" className="workspace-search-button" onClick={() => setCommandPaletteOpen(true)} aria-label={t("打开工作区命令面板")} aria-haspopup="dialog" aria-expanded={commandPaletteOpen}>{t("命令")}<kbd>Ctrl K</kbd></button>
        <WorkspaceActionMenu label={t("更多操作")} className="topbar-more">
          <button type="button" onClick={() => void refreshGitStatus()} disabled={!repository || !capabilities?.gitStatus} aria-label={t("刷新 Git 状态")} title={capabilities && !capabilities.gitStatus ? t("当前系统未检测到 Git；本地编辑仍可用") : undefined}>{t("刷新 Git 状态")}</button>
          <button type="button" onClick={() => void cycleTheme()} aria-label={t("切换主题")} title={t("当前主题：{theme}；点击切换", { theme: t(preferences.theme === "system" ? "跟随系统" : preferences.theme === "light" ? "浅色" : "深色") })}>{t("切换主题")}</button>
        </WorkspaceActionMenu>
      </div>
    </header>
    <p className="notice" role="status">{workspaceMode === "rss" ? t("RSS 订阅与阅读状态独立保存在本机，不随当前仓库切换。") : typeof notice === "string" ? t(notice) : renderUiMessage(notice, t)}</p>
    {capabilities && !capabilities.localEdit && <p className="demo-banner">{t("演示模式不访问本地磁盘，保存和 Git 状态不会执行。")}</p>}
    {workspaceMode === "writing" && capabilities?.localEdit && !capabilities.gitStatus && <p className="demo-banner">{t("未检测到 Git：本地 Markdown 编辑和预览仍可用，Git 状态已禁用。")}</p>}
    {workspaceMode === "writing" && editorState === "conflict" && <section className="recovery-banner recovery-warning" aria-label={t("保存冲突")}><div><strong>{t("磁盘文件已被外部修改")}</strong><span>{t("对照上次加载、本地原稿与磁盘版本，再手动处理差异。")}</span></div><button type="button" disabled={conflictBusy} onClick={() => void loadConflictReview()}>{t("审阅保存冲突")}</button></section>}
    {workspaceMode === "writing" && activeRecovery === "ready" && workspaceState.recoveryDraft && <section className="recovery-banner" aria-label={t("崩溃恢复草稿")}><div><strong>{t("发现未保存的恢复草稿")}</strong><span>{t("它尚未写入磁盘。")}</span></div><div><button type="button" onClick={restoreRecoveryDraft}>{t("恢复到编辑缓冲区")}</button><button type="button" onClick={() => void discardRecoveryDraft()}>{t("丢弃草稿")}</button></div></section>}
    {workspaceMode === "writing" && activeRecovery === "baseline-mismatch" && workspaceState.recoveryDraft && recoveryPreview && <section className="recovery-banner recovery-warning" aria-label={t("崩溃恢复草稿")}><div><strong>{t("磁盘内容已变化")}</strong><span>{t("为避免覆盖外部修改，恢复草稿不会自动应用。")}</span><details><summary>{t("查看恢复草稿")}{recoveryPreview.truncated ? t("（有界预览）") : ""}</summary><pre>{recoveryPreview.text}</pre></details></div><button type="button" onClick={() => void discardRecoveryDraft()}>{t("丢弃草稿")}</button></section>}
    <nav className="workspace-viewbar" aria-label={t("工作区视图")}>
      {workspaceMode !== "rss" && <SiteProfileSwitcher snapshot={siteProfiles} repository={repository} enabled={Boolean(capabilities?.siteProfiles)} busy={workspaceNavigationBusy} onSelect={(profile) => { void selectSiteProfile(profile); }} onManage={() => openWorkspaceDrawer("sites")} />}
      <span className="workspace-context-title">{t(workspaceMode === "writing" ? "写作工作区" : workspaceMode === "sync" ? "站点工作区" : "阅读工作区")}</span>
      {workspaceMode === "rss" && <span className="workspace-reading-scope">{t("RSS 订阅与阅读状态保存在本机")}</span>}
      {workspaceMode === "writing" && <>
        <button type="button" aria-pressed={sidebarVisible && !focusMode} onClick={() => { setFocusMode(false); setSidebarVisible((current) => !current); }}>{t("文件导航")}</button>
        <button type="button" aria-pressed={previewVisible && !focusMode} onClick={() => { setFocusMode(false); setPreviewVisible((current) => !current); }}>{t("预览")}</button>
        <button type="button" aria-pressed={focusMode} onClick={toggleFocusMode}>{t("专注模式")}</button>
        <button type="button" aria-pressed={writingInspectorOpen && !focusMode} disabled={!document || workspaceNavigationBusy || conflictOpen} onClick={() => {
          if (writingInspectorOpen && !focusMode) setWritingInspectorOpen(false); else showWritingInspector(inspectorTab);
        }}>{t("检查器")}</button>
        <small>{t("Ctrl/Cmd K 搜索命令 · Ctrl/Cmd Shift E 聚焦编辑器")}</small>
      </>}
    </nav>
    {workspaceMode === "sync" ? <SiteWorkspace repository={repository}
      profileName={siteProfiles?.profiles.find((profile) => profile.rootPath === repository?.rootPath)?.name ?? null}
      busy={workspaceNavigationBusy} canCheck={Boolean(capabilities?.contentHealth)} canManageSites={Boolean(capabilities?.siteProfiles)}
      focusOnMount={!publishCenterOpen && !advancedToolsOpen && !siteProfileCenterOpen}
      onChooseRepository={() => void chooseRepository()} onCheck={() => openWorkspaceDrawer("tools", "health")}
      onPublish={() => openWorkspaceDrawer("publish")} onManageSites={() => openWorkspaceDrawer("sites")} />
    : workspaceMode === "rss" ? <section id="workspace-content" className="rss-workspace-host" aria-label={t("RepoPress RSS 阅读工作区")} tabIndex={-1}>
      <DeferredSurface label={t("RSS 阅读器")}><RssReader
          gateway={rssGateway}
          active
          translationGateway={capabilities?.aiEditing ? gateway : undefined}
          onSaveToKnowledge={capabilities?.knowledgeLibrary ? saveRssArticleToKnowledge : undefined}
          onInsertReference={capabilities?.knowledgeLibrary && document?.writable && capabilities?.localEdit && !imageImportBusy ? insertRssReference : undefined}
          onCreateInspirationDraft={repository && capabilities?.knowledgeLibrary && capabilities?.localEdit && !imageImportBusy ? createRssInspirationDraft : undefined}
        /></DeferredSurface>
    </section> : null}
    <div className="writing-workspace-host" hidden={workspaceMode !== "writing"} inert={workspaceMode !== "writing"}>
    <ResizableWorkspace active={workspaceMode === "writing"} className={focusMode ? "workspace-focus-mode" : ""}
      sidebar={sidebarVisible && !focusMode ? <aside className="sidebar repository-panel" aria-label={t("仓库和 Markdown 文件")}>
        <div className="panel-heading"><span>{t("仓库")}</span><span className="readonly-badge">{t("本地")}</span></div>
        <p className="repository-name">{repository?.displayName ?? t("尚未选择仓库")}</p><p className="repository-path">{repository?.rootPath ?? t("使用顶部“选择仓库”开始")}</p>
        <div className="panel-heading files-heading"><span>{t("Markdown 文件")}</span><span>{files.length}</span></div>
        <div className="draft-list-actions" aria-label={t("文章管理")}>
          <button type="button" onClick={() => openWorkspaceDrawer("metadataBatch")} disabled={!repository || !capabilities?.metadataBatch || metadataBatchBusy} aria-haspopup="dialog" aria-expanded={metadataBatchOpen}>{t("批量标签与分类")}</button>
          <button type="button" onClick={() => openDraftDialog("create")} disabled={!repository || !capabilities?.localEdit}>{t("新建")}</button>
          <button type="button" onClick={() => openDraftDialog("rename")} disabled={!document?.writable || !capabilities?.localEdit || hasUnsavedWork(editorState)}>{t("重命名")}</button>
          <button type="button" className="danger" onClick={() => openDraftDialog("delete")} disabled={!document?.writable || !capabilities?.localEdit || hasUnsavedWork(editorState)}>{t("删除")}</button>
          <button type="button" onClick={openDraftHistoryCenter} disabled={!repository || !capabilities?.localEdit} aria-haspopup="dialog" aria-expanded={draftHistoryCenterOpen}>{t("历史与回收站")}</button>
          <button type="button" onClick={openGeneralDraftCenter} disabled={!capabilities?.localEdit} aria-haspopup="dialog" aria-expanded={generalDraftCenterOpen}>{t("通用草稿")}</button>
        </div>
        <FileNavigator files={files} selectedPath={document?.relativePath} sessionId={repository?.sessionId} onOpenFile={(file) => void selectDocument(file)} search={searchMarkdownFiles} onOpenSearchResult={openSearchResult} />
        {gitStatus && repository && <GitStatusPanel status={gitStatus} sessionId={repository.sessionId} getDiff={getGitFileDiff} />}
      </aside> : null}
      editor={<section className="editor-panel" aria-label={t("Markdown 编辑器")}>
        <div className="panel-heading"><span>{document?.relativePath ?? t("选择一个 Markdown 文件")}</span></div>
        <div className="writing-tools-row">
          <MarkdownWritingToolbar value={editorValue} selection={editorSelection} onFormat={applyWritingFormat} disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} density={writingToolDensity} onDensityChange={changeWritingToolDensity} itemIds={preferences.writingToolbarItemIds} onItemIdsChange={changeWritingToolbarItems} />
        </div>
        <div className="writing-context-row">
          <WorkspaceActionMenu label={t("写作工具")}>
          <MarkdownAdvancedEditingMenu value={editorValue} selection={editorSelection} disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} onApply={(result, status) => applyEditorChange(result.text, result.selection, status)} />
          <MarkdownTableEditingMenu value={editorValue} selection={editorSelection} disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} onApply={(result, status) => applyEditorChange(result.text, result.selection, status)} />
          <ChineseTypographyButton value={editorValue} selection={editorSelection} disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} onApply={(result, status) => applyEditorChange(result.text, result.selection, status)} />
          <button type="button" className="writing-image-button" disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} onClick={() => void chooseWritingImages()}>{imageImportBusy ? t("正在导入图片…") : t("插入图片")}</button>
          <button type="button" className="writing-library-button" disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy || files.length < 2} onClick={openInternalLinkPicker}>{t("站内链接")}</button>
          <button type="button" className="writing-library-button" disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} onClick={openSnippetLibrary}>{t("片段")}</button>
          <MarkdownDocumentExportMenu markdown={editorValue} fileName={document?.relativePath} title={snippetContext.title} disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} onSave={saveMarkdownDocumentExport} onSuccess={(plan) => setNotice(`已导出当前缓冲区：${plan.suggestedFileName}`)} onError={(error) => setNotice(`导出失败：${messageFrom(error)}`)} />
          </WorkspaceActionMenu>
          <button type="button" className="writing-inspector-toggle" aria-expanded={writingInspectorOpen && inspectorTab === "writing" && !focusMode} disabled={!document || workspaceNavigationBusy || conflictOpen} onClick={() => showWritingInspector("writing")}>{t("诊断 · 查找 · 大纲")}</button>
          <button type="button" className="writing-inspector-toggle" aria-expanded={writingInspectorOpen && inspectorTab === "metadata" && !focusMode} disabled={!document || workspaceNavigationBusy || conflictOpen} onClick={() => showWritingInspector("metadata")}>{t("属性 · SEO")}</button>
          <button type="button" className="writing-inspector-toggle" aria-expanded={writingInspectorOpen && inspectorTab === "state" && !focusMode} disabled={!document || workspaceNavigationBusy || conflictOpen} onClick={() => showWritingInspector("state")}>{t("文章状态")}</button>
          <button type="button" className="writing-inspector-toggle" aria-pressed={outlinePinned && !focusMode} disabled={!document} onClick={() => { setFocusMode(false); setOutlinePinned((current) => !current); }}>{t("固定大纲")}</button>
        </div>
        <MarkdownSSGComponentStrip occurrences={ssgComponentOccurrences} disabled={!document} onSelect={(range, status) => applyEditorChange(editorValue, range, status)} />
        <div className={`writing-editor-body${outlinePinned && !focusMode && document ? " writing-editor-body-with-outline" : ""}`}>
          {outlinePinned && !focusMode && document && <div className="writing-outline-dock"><MarkdownOutlinePanel key={editorDocumentKey} documentKey={editorDocumentKey} value={editorValue} selection={editorSelection} onClose={() => setOutlinePinned(false)} onLocate={(range, expectedText) => void navigateToDocument(document.relativePath, { kind: "range", range, expectedText }, "文章大纲")} /></div>}
          <div className="writing-editor-canvas">
            {document ? <DeferredSurface label={t("Markdown 编辑器")}><MarkdownEditorSurface ref={editorRef} value={editorValue} darkMode={darkMode} comfort={{ lineSpacing: preferences.editorLineSpacing, bodyWidth: preferences.editorBodyWidth, spellCheckEnabled: preferences.spellCheckEnabled, typewriterModeEnabled: preferences.typewriterModeEnabled, currentParagraphHighlightEnabled: preferences.currentParagraphHighlightEnabled, warmPaperBackgroundEnabled: preferences.warmPaperBackgroundEnabled, paragraphSpotlightEnabled: preferences.paragraphSpotlightEnabled }} onChange={updateDocument} onPasteCapture={handleEditorPaste} onBeforeInputCapture={handleEditorBeforeInput} onKeyDownCapture={(event) => {
              if (isImeCompositionKeyboardEvent(event.nativeEvent)) return;
              if (slashMenuOpen && !event.ctrlKey && !event.metaKey && !event.altKey) {
                if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); closeSlashMenu(); return; }
                if ((event.key === "ArrowDown" || event.key === "ArrowUp") && slashCommands.length) {
                  event.preventDefault(); event.stopPropagation();
                  const command = event.key === "ArrowDown" ? slashCommands[0] : slashCommands[slashCommands.length - 1];
                  window.document.getElementById(`markdown-slash-command-${command.id}`)?.focus(); return;
                }
                if (event.key === "Enter" && slashCommands.length) { event.preventDefault(); event.stopPropagation(); applySlashSelection(slashCommands[0]); return; }
              }
              if (!event.ctrlKey && !event.metaKey && !event.altKey && applyAutomaticPairing(event.key)) {
                event.preventDefault(); event.stopPropagation(); return;
              }
              if (event.key === "Enter" && !event.shiftKey && !event.ctrlKey && !event.metaKey && !event.altKey && editorSelection.from === editorSelection.to && findInternalLinkQuery(editorValue, editorSelection.to)) {
                event.preventDefault(); event.stopPropagation(); openInternalLinkPicker(); return;
              }
              if (event.key === "Tab" && !event.ctrlKey && !event.metaKey && !event.altKey) {
                const tableResult = planMarkdownTableEdit(editorValue, editorSelection, event.shiftKey ? "navigateBackward" : "navigateForward");
                if (tableResult) { event.preventDefault(); event.stopPropagation(); applyEditorChange(tableResult.text, tableResult.selection); return; }
                const result = applyMarkdownIndent(editorValue, editorSelection, event.shiftKey ? "outdent" : "indent");
                if (result.text !== editorValue) { event.preventDefault(); event.stopPropagation(); applyEditorChange(result.text, result.selection); }
                return;
              }
              if (event.key !== "Enter" || event.shiftKey || event.ctrlKey || event.metaKey || event.altKey || editorSelection.from !== editorSelection.to) return;
              const result = planMarkdownListContinuation(editorValue, editorSelection.from);
              if (!result) return;
              event.preventDefault(); event.stopPropagation(); applyEditorChange(result.text, result.selection);
            }} onSelectionChange={(next) => setEditorSelection((current) => current.from === next.from && current.to === next.to && current.text === next.text ? current : next)} onReady={fulfillPendingEditorFocus} editable={Boolean(document?.writable) && Boolean(capabilities?.localEdit) && !imageImportBusy && !metadataBatchBusy && !conflictOpen} /></DeferredSurface> : <p role="status">{t("请选择一个 Markdown 文件以加载编辑器。")}</p>}
            <div className="markdown-slash-popover"><MarkdownSlashMenu query={slashQuery?.query ?? ""} commands={slashCommands} builtinSnippetCommandIds={BUILT_IN_MARKDOWN_SNIPPETS.map((snippet) => `snippet:${snippet.id}`)} open={slashMenuOpen} onSelect={applySlashSelection} onClose={closeSlashMenu} /></div>
          </div>
        </div>
      </section>}
      preview={workspaceMode === "writing" && previewVisible && !focusMode ? <DeferredSurface label={t("预览")}><SitePreview sessionId={repository?.sessionId} markdownHtml={previewHtml} articlePath={articlePreviewPath} contextKey={sitePreviewContextKey} isContextCurrent={isSitePreviewContextCurrent} document={document ? { documentId: document.documentId, expectedSha256: document.baselineSha256, revision: document.revision } : null} unsaved={Boolean(document && editorValue !== document.text)} inspect={inspectSitePreview} plan={planSitePreview} start={startSitePreview} check={checkSitePreviewPage} stop={stopSitePreview} /></DeferredSurface> : null}
      inspectorVisible={writingInspectorOpen && !focusMode}
      inspector={document ? <WorkspaceInspector key={editorDocumentKey} activeTab={inspectorTab} onSelectTab={(tab) => {
        if (tab === "metadata" || tab === "writing" || tab === "state") {
          if (tab === "writing") setWritingInspectorLoaded(true);
          if (tab === "state") setArticleStateLoaded(true);
          setInspectorTab(tab); setInspectorRevealRequestKey((current) => current + 1);
        }
      }} onClose={() => { setWritingInspectorOpen(false); focusEditor(); }} disabled={workspaceNavigationBusy || conflictOpen}
        tabs={[
          { id: "metadata", label: t("属性 · SEO"), content: <>
            <FrontMatterPanel value={editorValue} selection={editorSelection} focusRequest={fieldFocusRequest?.documentKey === editorDocumentKey ? fieldFocusRequest : undefined}
              disabled={!document.writable || !capabilities?.localEdit || imageImportBusy || metadataBatchBusy || conflictOpen || repositorySwitchBusy || draftDialogBusy}
              onChange={(value, selection) => applyEditorChange(value, selection, undefined, false, false)} />
            <MetadataInspector value={editorValue} disabled={imageImportBusy || metadataBatchBusy || conflictOpen} onLocateField={locateMetadataField} />
          </> },
          { id: "state", label: t("文章状态"), content: articleStateLoaded && articleStateContext ? <DeferredSurface label={t("文章状态")}><ArticleStatePanel
            value={editorValue} context={articleStateContext} contextKey={articleStateContextKey}
            active={articleStateActive}
            disabled={workspaceNavigationBusy || conflictOpen || editorState === "saving" || editorState === "conflict"}
            onLocate={locateArticleStateIssue} onApplyChange={applyArticleStateChange} /></DeferredSurface> : null },
          { id: "writing", label: t("诊断 · 查找"), content: writingInspectorLoaded ? <DeferredSurface label={t("写作检查器")}><MarkdownWritingInspector focusFindRequestKey={findFocusRequest?.documentKey === editorDocumentKey ? findFocusRequest.key : 0} onFindFocusHandled={handleFindFocusHandled} documentKey={editorDocumentKey} value={editorValue} selection={editorSelection}
            stats={writingStats} diagnosticSession={writingDiagnosticSession} knownArticleTitles={knownArticleTitles}
            readOnly={!document.writable || !capabilities?.localEdit || imageImportBusy || metadataBatchBusy || conflictOpen || repositorySwitchBusy || draftDialogBusy}
            onChange={applyEditorChange} onLocate={(range, expectedText) => void navigateToDocument(document.relativePath, { kind: "range", range, expectedText }, "写作面板")} /></DeferredSurface> : null },
        ]} /> : null}
    /></div>
    {workspaceMode === "writing" && <WorkspaceStatusBar document={document ? { relativePath: document.relativePath,
      writable: document.writable && Boolean(capabilities?.localEdit), encoding: document.encoding, lineEnding: currentLineEnding } : undefined}
      state={editorState} stats={document ? writingStats : undefined} diagnostics={document ? diagnosticSummary : undefined}
      diagnosticStatus={document ? writingDiagnosticSession.status : undefined} diagnosticTruncated={writingDiagnosticSession.truncated}
      disabled={workspaceNavigationBusy || conflictOpen} onOpenDiagnostics={() => showWritingInspector("writing")}>
      <MarkdownCursorWorkflowControls value={editorValue} selection={editorSelection} openRequestKey={goToLineRequestKey}
        disabled={!document || workspaceNavigationBusy || conflictOpen} onSelect={(range, status) => applyEditorChange(editorValue, range, status)} />
    </WorkspaceStatusBar>}
    </div></div>
    {conflictLoaded && <DeferredSurface label={t("保存冲突审阅")}><SaveConflictReview open={conflictOpen} review={conflictReview} busy={conflictBusy} error={conflictError} onClose={closeConflictReview} onReload={() => void loadConflictReview()} onApply={applyConflictReview} /></DeferredSurface>}
    {metadataBatchLoaded && <DeferredSurface label={t("批量标签与分类")}><MetadataBatchCenter open={metadataBatchOpen} onClose={() => { if (!metadataBatchInFlight.current) setMetadataBatchOpen(false); }} sessionId={repository?.sessionId} files={files} enabled={Boolean(capabilities?.metadataBatch)} excludedPath={document && hasUnsavedWork(editorState) ? document.relativePath : undefined} plan={planMetadataBatch} execute={executeMetadataBatch} /></DeferredSurface>}
    {publishCenterLoaded && <DeferredSurface label={t("发布中心")}><PublishCenter open={publishCenterOpen} onClose={() => setPublishCenterOpen(false)} repository={repository} capabilities={capabilities} gateway={gateway} onGitStatusRefresh={refreshGitStatus} currentDocument={document ? { relativePath: document.relativePath, text: editorValue, knownArticleTitles, documentKey: editorDocumentKey } : null} onLocateIssue={(path, range, expectedText) => void navigateToDocument(path, { kind: "range", range, expectedText }, "发布中心审阅")} /></DeferredSurface>}
    {advancedToolsLoaded && <DeferredSurface label={t("智能工具")}><AdvancedTools open={advancedToolsOpen} onClose={() => setAdvancedToolsOpen(false)} repository={repository} capabilities={capabilities} gateway={gateway} document={document} currentDocumentText={editorValue} selection={editorSelection} onApplyAiReplacement={applyAiReplacement} onOpenSemanticPath={(path) => void openSemanticPath(path)} onOpenContentHealthIssue={(path, range, expectedDocumentText) => void openContentHealthIssue(path, range, expectedDocumentText)} requestedTab={advancedToolsRequestedTab} requestedTabKey={advancedToolsRequestedTabKey} onActiveTabChange={handleAdvancedToolTabChange} /></DeferredSurface>}
    {settingsLoaded && <DeferredSurface label={t("设置中心")}><SettingsCenter open={settingsOpen} onClose={() => setSettingsOpen(false)} preferences={preferences} recentRepositories={workspaceState.recentRepositories} canOpenRecent={Boolean(capabilities?.localEdit)} onSave={saveWorkspacePreferences} onOpenRecent={async (path) => { if (hasUnsavedWork(editorState) && !window.confirm(t("当前文档有未保存修改。仍要切换仓库吗？"))) return false; return openRepositoryPath(path); }} /></DeferredSurface>}
    {knowledgeLibraryLoaded && <DeferredSurface label={t("资料库")}><KnowledgeLibrary open={knowledgeLibraryOpen} targetItemId={knowledgeTargetItemId} targetRequestKey={knowledgeTargetRequestKey} onClose={() => { setKnowledgeLibraryOpen(false); setKnowledgeTargetItemId(null); }} gateway={gateway} repository={repository} /></DeferredSurface>}
    {draftHistoryCenterLoaded && <DeferredSurface label={t("版本历史与回收站")}><DraftHistoryCenter open={draftHistoryCenterOpen} onClose={() => setDraftHistoryCenterOpen(false)} gateway={gateway} repository={repository} document={document} currentText={editorValue} onRestoreDocument={applyDraftHistoryRestore} /></DeferredSurface>}
    {generalDraftCenterLoaded && <DeferredSurface label={t("通用草稿库")}><GeneralDraftCenter open={generalDraftCenterOpen} onClose={() => setGeneralDraftCenterOpen(false)} gateway={gateway} repository={repository} document={document} currentText={editorValue} hasUnsavedChanges={hasUnsavedWork(editorState)} onTransferApplied={applyGeneralDraftTransfer} /></DeferredSurface>}
    {imageWorkbenchLoaded && <DeferredSurface label={t("图片工作台")}><ImageWorkbench open={imageWorkbenchOpen} onClose={closeImageWorkbench} gateway={gateway} repository={repository} enabled={Boolean(capabilities?.imageWorkbench)} canInsert={Boolean(document?.writable && capabilities?.localEdit && !imageImportBusy)} onInsert={reuseRepositoryImage} referenceCheckEnabled={Boolean(capabilities?.contentHealth && capabilities?.imageWorkbench)} referenceOverlay={document ? { relativePath: document.relativePath, text: editorValue } : undefined} referenceDocumentKey={editorDocumentKey} onRepair={applyImageReferenceRepair} /></DeferredSurface>}
    {siteProfileCenterLoaded && <DeferredSurface label={t("站点管理")}><SiteProfileCenter open={siteProfileCenterOpen} onClose={() => setSiteProfileCenterOpen(false)} gateway={gateway} repository={repository} enabled={Boolean(capabilities?.siteProfiles)} onSnapshot={acceptSiteProfiles} onSelect={selectSiteProfile} /></DeferredSurface>}
    {operationLogLoaded && <DeferredSurface label={t("操作日志")}><OperationLogCenter open={operationLogOpen} onClose={() => setOperationLogOpen(false)} gateway={gateway} repository={repository} enabled={Boolean(capabilities?.operationLog)} /></DeferredSurface>}
    <DraftLifecycleDialog open={draftDialogMode !== null} mode={draftDialogMode ?? "create"} currentPath={document?.relativePath} suggestedPath={`${repository?.contentRoot ? `${repository.contentRoot.replace(/\/$/, "")}/` : ""}new-article.md`} busy={draftDialogBusy} error={draftDialogError} onClose={() => { if (!draftDialogBusy) { setDraftDialogMode(null); setRssInspirationDraftText(null); } }} onSubmit={submitDraftLifecycle} />
    <WorkspaceCommandPalette open={commandPaletteOpen} files={files} selectedPath={document?.relativePath} commands={workspaceCommands} onClose={() => setCommandPaletteOpen(false)} onOpenFile={(file) => void selectDocument(file)} />
    {repository && <MarkdownSnippetLibrary open={snippetLibraryOpen} scope={repository.rootPath} context={snippetContext} value={editorValue} selection={editorSelection} disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} onClose={() => { setSnippetLibraryOpen(false); window.requestAnimationFrame(() => editorRef.current?.view?.focus()); }} onChange={applyEditorChange} onCustomSnippetsChange={setCustomSnippets} />}
    {repository && <MarkdownInternalLinkPicker open={internalLinkPickerOpen} files={files} currentPath={document?.relativePath} repository={repository} value={editorValue} selection={editorSelection} disabled={!document?.writable || !capabilities?.localEdit || imageImportBusy} resolveSuggestion={async (suggestion) => {
      const metadata = await gateway.inspectMarkdownLinkMetadata(repository.sessionId, suggestion.path);
      const target = files.find((file) => file.relativePath === metadata.relativePath) ?? files.find((file) => file.relativePath === suggestion.path);
      if (!target) return suggestion;
      return {
        ...suggestion,
        label: metadata.title?.trim() || metadata.slug?.trim() || suggestion.label,
        url: destinationForMarkdownFile(target, repository, metadata.permalink),
      };
    }} onClose={() => { setInternalLinkPickerOpen(false); window.requestAnimationFrame(() => editorRef.current?.view?.focus()); }} onChange={applyEditorChange} />}
  </main><EditorExitDialog state={exitState} onCancel={() => exitController.current?.cancel()} onFinish={(mode) => { void exitController.current?.finish(mode); }} /></I18nProvider>;
}

function messageFrom(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "object" && error !== null && "message" in error && typeof error.message === "string") return error.message;
  if (typeof error === "string") return error;
  return "未知错误";
}
function isTauriRuntime(): boolean { return "__TAURI_INTERNALS__" in window; }
export default App;
