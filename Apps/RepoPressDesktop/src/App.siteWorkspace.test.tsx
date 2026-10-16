import { act, createElement, forwardRef, useEffect, useImperativeHandle, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot, GitStatusSnapshot, RepositorySessionSnapshot } from "./contracts/repository";
import type { SiteProfileSnapshot } from "./contracts/sites";
import { useDrawerFocus } from "./features/workspace/drawerFocus";

const harness = vi.hoisted(() => {
  const initialText = "# 当前文章\n\n正文";
  const initialRepository: RepositorySessionSnapshot = {
    sessionId: "session-current",
    rootPath: "/srv/sites/current-literal-root",
    displayName: "仓库显示名",
    siteKind: "hugo",
    contentRoot: "content",
    isGitRepository: true,
    warnings: [],
  };
  const otherRepository: RepositorySessionSnapshot = {
    ...initialRepository,
    sessionId: "session-other",
    rootPath: "/srv/sites/other-literal-root",
    displayName: "另一个仓库",
  };
  const document: DocumentSnapshot = {
    documentId: "doc-current",
    relativePath: "content/article.md",
    text: initialText,
    encoding: "utf-8",
    lineEnding: "lf",
    byteSize: initialText.length,
    baselineSha256: "sha-current",
    revision: 1,
    writable: true,
    readOnlyReason: null,
  };
  const siteProfiles: SiteProfileSnapshot = {
    profiles: [
      { profileId: "profile-current", name: "登记的站点名称", rootPath: initialRepository.rootPath, createdAtEpochMs: 1 },
      { profileId: "profile-other", name: "另一个站点", rootPath: otherRepository.rootPath, createdAtEpochMs: 2 },
    ],
    revision: 2,
    persistent: true,
    writable: true,
    warning: null,
  };
  const capabilities = {
    metadataBatch: false,
    localEdit: true,
    markdownPreview: true,
    gitStatus: true,
    siteRuntime: false,
    gitCommit: false,
    gitPush: false,
    gitFetch: false,
    gitIndex: false,
    remoteAuth: false,
    aiEditing: false,
    semanticSearch: false,
    pdfTextExtraction: false,
    ocrReadiness: false,
    knowledgeLibrary: false,
    contentHealth: true,
    imageWorkbench: false,
    operationLog: false,
    siteProfiles: true,
  };
  const workspace = {
    lastRepositoryPath: initialRepository.rootPath,
    lastDocumentPath: document.relativePath,
    preferences: { restoreLastWorkspace: true, uiLanguage: "system" } as unknown,
  };
  const openRepository = vi.fn(async () => initialRepository);
  const openSiteProfile = vi.fn(async () => otherRepository);
  const listMarkdownFiles = vi.fn(async (sessionId: string) => [{
    relativePath: document.relativePath,
    displayName: sessionId === otherRepository.sessionId ? "other.md" : "article.md",
    directory: "content",
    byteSize: initialText.length,
  }]);
  const openDocument = vi.fn(async () => document);
  const inspectContentHealthSources = vi.fn(async (sessionId: string) => ({
    sessionId,
    sources: [],
    warnings: [],
    truncated: false,
    scannedFileCount: 1,
    skippedFileCount: 0,
    totalBytes: 0,
  }));
  const gitStatus = vi.fn<(sessionId: string) => Promise<GitStatusSnapshot>>(async () => ({ available: false, branch: null, upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: [] }));
  const planGitOperation = vi.fn();
  const executeGitOperation = vi.fn();
  const dispatch = vi.fn();
  const focus = vi.fn();
  const gateway = new Proxy({
    getCapabilities: async () => capabilities,
    getWorkspaceState: async () => ({ ...workspace }),
    saveRecoveryDraft: async () => ({ ...workspace }),
    openRepository,
    openSiteProfile,
    getSiteProfiles: async () => siteProfiles,
    listMarkdownFiles,
    openDocument,
    inspectContentHealthSources,
    gitStatus,
    planGitOperation,
    executeGitOperation,
    searchMarkdownFiles: async () => ({ query: "", truncated: false, results: [] }),
    inspectSitePreview: async () => ({ siteKind: "hugo", supported: false, runtimeAvailable: false, executable: null, version: null, reason: "", warning: null }),
  }, { get(target, key) { return key in target ? target[key as keyof typeof target] : async () => null; } });
  return {
    initialText,
    initialRepository,
    otherRepository,
    document,
    siteProfiles,
    workspace,
    openRepository,
    openSiteProfile,
    listMarkdownFiles,
    openDocument,
    inspectContentHealthSources,
    gitStatus,
    planGitOperation,
    executeGitOperation,
    dispatch,
    focus,
    gateway,
  };
});

vi.mock("./platform/repositoryGateway", () => ({ createRepositoryGateway: () => harness.gateway }));
vi.mock("./components/RssReader", () => ({ RssReader: () => <section data-testid="rss-reader">RSS reader</section> }));
vi.mock("./components/MarkdownEditorSurface", () => ({
  default: forwardRef(function MockEditor(props: { value: string; onChange: (value: string) => void; onReady?: () => void }, ref) {
    useImperativeHandle(ref, () => ({
      view: {
        state: { doc: { toString: () => props.value, length: props.value.length } },
        dispatch: (transaction: { changes?: { from: number; to: number; insert: string } }) => {
          harness.dispatch(transaction);
          if (transaction.changes) {
            const change = transaction.changes;
            props.onChange(props.value.slice(0, change.from) + change.insert + props.value.slice(change.to));
          }
        },
        focus: harness.focus,
      },
    }));
    useEffect(() => { props.onReady?.(); }, [props.onReady]);
    return <textarea data-testid="editor" value={props.value} onChange={(event) => props.onChange(event.target.value)} />;
  }),
}));

interface DrawerProps {
  open: boolean;
  onClose: () => void;
}

function TestDrawer({ open, onClose, label, children }: DrawerProps & { label: string; children?: React.ReactNode }) {
  const drawer = useRef<HTMLElement>(null);
  useDrawerFocus(open, drawer, onClose);
  return <aside ref={drawer} role="dialog" aria-label={label} aria-hidden={!open} inert={!open} tabIndex={-1}>
    <button type="button" onClick={onClose}>关闭</button>
    {children}
  </aside>;
}

vi.mock("./components/PublishCenter", () => ({
  PublishCenter: (props: DrawerProps & { onLocateIssue?: (path: string, range: { from: number; to: number }, expected: string) => void }) =>
    <TestDrawer open={props.open} onClose={props.onClose} label="发布中心抽屉">
      <button type="button" onClick={() => props.onLocateIssue?.(harness.document.relativePath, { from: 0, to: 1 }, harness.initialText)}>定位发布问题</button>
    </TestDrawer>,
}));

vi.mock("./components/AdvancedTools", () => ({
  AdvancedTools: (props: DrawerProps & {
    repository: RepositorySessionSnapshot | null;
    gateway: { inspectContentHealthSources: (sessionId: string) => Promise<unknown> };
    currentDocumentText: string;
    requestedTab?: string | null;
    onOpenContentHealthIssue: (path: string, range: { from: number; to: number }, expected: string) => void;
  }) => {
    const [scannedSession, setScannedSession] = useState<string | null>(null);
    useEffect(() => { if (!props.open) setScannedSession(null); }, [props.open]);
    return <TestDrawer open={props.open} onClose={props.onClose} label={`智能工具抽屉:${props.requestedTab ?? "none"}`}>
      <button type="button" onClick={async () => {
        const sessionId = props.repository?.sessionId;
        if (!sessionId) return;
        await props.gateway.inspectContentHealthSources(sessionId);
        setScannedSession(sessionId);
      }}>扫描仓库内容</button>
      {scannedSession === props.repository?.sessionId && <button type="button" onClick={() => props.onOpenContentHealthIssue(harness.document.relativePath, { from: 0, to: 1 }, props.currentDocumentText)}>定位健康问题</button>}
    </TestDrawer>;
  },
}));

vi.mock("./components/SiteProfileCenter", () => ({
  default: (props: DrawerProps) => <TestDrawer open={props.open} onClose={props.onClose} label="站点管理抽屉" />,
  SiteProfileCenter: (props: DrawerProps) => <TestDrawer open={props.open} onClose={props.onClose} label="站点管理抽屉" />,
}));

vi.mock("./components/GitStatusPanel", () => ({
  GitStatusPanel: ({ status, sessionId }: { status: { branch: string | null }; sessionId: string }) =>
    <section data-testid="git-status" data-session={sessionId}>{status.branch}</section>,
}));

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot> | null = null;
let languageSpy: ReturnType<typeof vi.spyOn>;
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function until(check: () => boolean) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (check()) return;
    await act(async () => { await pause(10); });
  }
  expect(check(), "UI condition did not become true").toBe(true);
}

async function mount() {
  const { default: App } = await import("./App");
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  await act(async () => { root!.render(createElement(App)); });
  await until(() => Boolean(host.querySelector("textarea[data-testid='editor']")));
}

function button(label: string) {
  return [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label) ?? null;
}

async function click(node: HTMLElement | null) {
  if (!node) throw new Error("Required control did not render");
  await act(async () => { node.click(); });
}

async function input(node: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  await act(async () => {
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

function editor() {
  const node = host.querySelector<HTMLTextAreaElement>("textarea[data-testid='editor']");
  if (!node) throw new Error("Editor did not mount");
  return node;
}

async function selectProfile(profileId: string) {
  const select = host.querySelector<HTMLSelectElement>(".site-profile-switcher select");
  if (!select) throw new Error("Site profile switcher did not mount");
  await act(async () => {
    select.value = profileId;
    select.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

function deferredRepository() {
  let resolve!: (repository: RepositorySessionSnapshot) => void;
  harness.openSiteProfile.mockImplementationOnce(() => new Promise((done) => { resolve = done; }));
  return async () => { await act(async () => { resolve(harness.otherRepository); }); };
}

function deferredGitStatus() {
  let resolve!: (status: GitStatusSnapshot) => void;
  let reject!: (reason: unknown) => void;
  harness.gitStatus.mockImplementationOnce(() => new Promise((done, fail) => { resolve = done; reject = fail; }));
  return { resolve: (status: GitStatusSnapshot) => resolve(status), reject: (reason: unknown) => reject(reason) };
}

describe("App site workspace integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

  beforeEach(() => {
    vi.stubGlobal("matchMedia", () => ({ matches: false, media: "", onchange: null, addEventListener() {}, removeEventListener() {} }));
    languageSpy = vi.spyOn(navigator, "languages", "get").mockReturnValue(["zh-CN"]);
    harness.workspace.preferences = { restoreLastWorkspace: true, uiLanguage: "system" };
    harness.openRepository.mockReset().mockResolvedValue(harness.initialRepository);
    harness.openSiteProfile.mockReset().mockResolvedValue(harness.otherRepository);
    harness.listMarkdownFiles.mockClear();
    harness.openDocument.mockReset().mockResolvedValue(harness.document);
    harness.inspectContentHealthSources.mockClear();
    harness.gitStatus.mockClear();
    harness.planGitOperation.mockClear();
    harness.executeGitOperation.mockClear();
    harness.dispatch.mockClear();
    harness.focus.mockClear();
  });

  afterEach(async () => {
    await act(async () => { root?.unmount(); });
    root = null;
    host?.remove();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("keeps the dirty editor through writing, site, and reading workspaces without implicit repository work", async () => {
    await mount();
    const originalEditor = editor();
    const writingHost = host.querySelector<HTMLElement>(".writing-workspace-host");
    expect(writingHost).not.toBeNull();
    const dirtyText = `${harness.initialText}\n\n尚未保存`;
    await input(originalEditor, dirtyText);
    originalEditor.focus();

    await click(button("站点"));
    await until(() => Boolean(host.querySelector("section.site-workspace")));
    await until(() => document.activeElement === host.querySelector("#site-workspace-title"));
    expect(writingHost?.hidden).toBe(true);
    expect(writingHost?.hasAttribute("inert")).toBe(true);
    expect(editor()).toBe(originalEditor);
    expect(writingHost?.contains(document.activeElement)).toBe(false);
    expect(host.querySelector("h1")?.textContent).toBe("站点工作区");
    expect(host.textContent).toContain("登记的站点名称");
    expect(host.textContent).toContain(harness.initialRepository.rootPath);
    expect(harness.inspectContentHealthSources).not.toHaveBeenCalled();
    expect(harness.gitStatus).not.toHaveBeenCalled();
    expect(harness.planGitOperation).not.toHaveBeenCalled();
    expect(harness.executeGitOperation).not.toHaveBeenCalled();

    await click(button("阅读"));
    await until(() => Boolean(host.querySelector("[data-testid='rss-reader']")));
    expect(writingHost?.hidden).toBe(true);
    expect(writingHost?.hasAttribute("inert")).toBe(true);
    expect(editor()).toBe(originalEditor);
    expect(host.querySelector(".site-profile-switcher")).toBeNull();
    expect(host.textContent).toContain("RSS 订阅与阅读状态独立保存在本机");

    await click(button("写作"));
    await until(() => writingHost?.hidden === false);
    expect(writingHost?.hasAttribute("inert")).toBe(false);
    expect(editor()).toBe(originalEditor);
    expect(originalEditor.value).toBe(dirtyText);
    expect(document.activeElement?.isConnected).toBe(true);
    expect(harness.openDocument).toHaveBeenCalledOnce();
  });

  it("opens site actions over the site background and scans only after the explicit scan action", async () => {
    await mount();
    await click(button("站点"));
    await until(() => Boolean(host.querySelector("section.site-workspace")));

    await click(button("打开站点检查"));
    await until(() => host.querySelector("[aria-label='智能工具抽屉:health']")?.getAttribute("aria-hidden") === "false");
    expect(host.querySelector("section.site-workspace")).not.toBeNull();
    expect(harness.inspectContentHealthSources).not.toHaveBeenCalled();
    await click(button("扫描仓库内容"));
    await until(() => Boolean(button("定位健康问题")));
    expect(harness.inspectContentHealthSources).toHaveBeenCalledExactlyOnceWith(harness.initialRepository.sessionId);
    await click(host.querySelector("[aria-label='智能工具抽屉:health'] button"));
    expect(host.querySelector("section.site-workspace")).not.toBeNull();

    const publishTrigger = button("打开发布中心");
    if (!publishTrigger) throw new Error("Publish trigger did not render");
    publishTrigger.focus();
    await click(publishTrigger);
    const publishDrawer = host.querySelector<HTMLElement>("[aria-label='发布中心抽屉']");
    await until(() => publishDrawer?.getAttribute("aria-hidden") === "false");
    await act(async () => {
      publishDrawer!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
      await Promise.resolve();
    });
    expect(publishDrawer?.getAttribute("aria-hidden")).toBe("true");
    expect(document.activeElement).toBe(publishTrigger);
    expect(host.querySelector("section.site-workspace")).not.toBeNull();

    await click(button("管理已保存站点"));
    await until(() => host.querySelector("[aria-label='站点管理抽屉']")?.getAttribute("aria-hidden") === "false");
    await click(host.querySelector("[aria-label='站点管理抽屉'] button"));
    expect(host.querySelector("section.site-workspace")).not.toBeNull();
  });

  it("returns a health issue to the preserved writing buffer", async () => {
    await mount();
    const dirtyText = `X${harness.initialText.slice(1)}\n编辑后内容`;
    await input(editor(), dirtyText);
    await click(button("站点"));
    await click(button("打开站点检查"));
    await until(() => Boolean(button("扫描仓库内容")));
    await click(button("扫描仓库内容"));
    await until(() => Boolean(button("定位健康问题")));
    await click(button("定位健康问题"));
    await until(() => harness.dispatch.mock.calls.length > 0);
    expect(editor().value).toBe(dirtyText);
    expect(harness.dispatch).toHaveBeenCalledWith({ selection: { anchor: 0, head: 1 }, scrollIntoView: true });
    expect(host.querySelector("section.site-workspace")).toBeNull();
  });

  it("cancels a dirty site-profile switch without changing the repository or editor", async () => {
    await mount();
    const dirtyText = `${harness.initialText}\n拒绝切换`;
    await input(editor(), dirtyText);
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    await selectProfile("profile-other");
    expect(confirm).toHaveBeenCalledWith("当前文档有未保存修改。仍要切换站点吗？");
    expect(harness.openSiteProfile).not.toHaveBeenCalled();
    expect(editor().value).toBe(dirtyText);
    expect(host.textContent).toContain(harness.initialRepository.rootPath);
    expect(host.textContent).not.toContain(harness.otherRepository.rootPath);
  });

  it("rejects a delayed site open after fresh editor input", async () => {
    await mount();
    const beforeOpen = `${harness.initialText}\n允许开始切换`;
    await input(editor(), beforeOpen);
    vi.spyOn(window, "confirm").mockReturnValue(true);
    const finishOpen = deferredRepository();
    await selectProfile("profile-other");
    expect(harness.openSiteProfile).toHaveBeenCalledExactlyOnceWith("profile-other");

    const latestText = `${beforeOpen}\n延迟期间的新输入`;
    await input(editor(), latestText);
    await finishOpen();
    await until(() => host.textContent?.includes("已保留当前内容") ?? false);
    expect(editor().value).toBe(latestText);
    expect(host.textContent).toContain(harness.initialRepository.rootPath);
    expect(host.textContent).not.toContain(harness.otherRepository.rootPath);
    expect(harness.listMarkdownFiles).toHaveBeenCalledTimes(1);
  });

  it.each(["result", "error"] as const)("ignores a stale Git %s after a successful site switch", async (outcome) => {
    await mount();
    const pending = deferredGitStatus();
    await click(host.querySelector(".workspace-search-button"));
    await click(host.querySelector("#git"));
    expect(harness.gitStatus).toHaveBeenCalledExactlyOnceWith(harness.initialRepository.sessionId);

    await selectProfile("profile-other");
    await until(() => host.textContent?.includes(harness.otherRepository.rootPath) ?? false);
    expect(host.querySelector("[data-testid='git-status']")).toBeNull();
    expect(host.querySelector(".notice")?.textContent).toContain("已打开：另一个仓库");

    await act(async () => {
      if (outcome === "result") pending.resolve({ available: true, branch: "stale-main", upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: [] });
      else pending.reject(new Error("stale git failure"));
      await Promise.resolve();
    });
    expect(host.querySelector("[data-testid='git-status']")).toBeNull();
    expect(host.querySelector(".notice")?.textContent).toContain("已打开：另一个仓库");
    expect(host.textContent).not.toContain("stale-main");
    expect(host.textContent).not.toContain("stale git failure");
  });

  it("keeps the legacy command ids reachable in Chinese and English", async () => {
    await mount();
    await click(host.querySelector(".workspace-search-button"));
    expect(host.querySelector("#sync-workspace strong")?.textContent).toBe("切换到站点工作区");
    expect(host.querySelector("#rss-workspace strong")?.textContent).toBe("切换到阅读工作区");
    expect(host.querySelector("#rss-workspace small")?.textContent).toContain("RSS");
    await click(host.querySelector("#sync-workspace"));
    await until(() => Boolean(host.querySelector("section.site-workspace")));

    languageSpy.mockReturnValue(["en-US"]);
    await act(async () => { window.dispatchEvent(new Event("languagechange")); });
    await until(() => document.documentElement.lang === "en-US");
    const labels = [...host.querySelectorAll<HTMLButtonElement>("[aria-label='Main navigation'] button")].map((item) => item.textContent);
    expect(labels).toContain("Site");
    expect(labels).toContain("Reading");
    await click(host.querySelector(".workspace-search-button"));
    expect(host.querySelector("#sync-workspace strong")?.textContent).toMatch(/site workspace/i);
    expect(host.querySelector("#rss-workspace strong")?.textContent).toMatch(/reading workspace/i);
    expect(host.querySelector("#rss-workspace small")?.textContent).toMatch(/RSS/i);
  });

});
