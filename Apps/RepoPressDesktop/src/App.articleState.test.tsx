import { act, createElement, forwardRef, useEffect, useImperativeHandle } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot, RepositorySessionSnapshot } from "./contracts/repository";
import type { ArticleStateLocation } from "./contracts/articleState";
import type { ArticleStatePanelProps } from "./components/ArticleStatePanel";

const harness = vi.hoisted(() => {
  const draft = "---\ntitle: Article\ndraft: true\ndate: 2099-01-02T03:04:05+08:00\n---\n\nBody 中文";
  const repository: RepositorySessionSnapshot = { sessionId: "session-1", rootPath: "/repo", displayName: "Hugo", siteKind: "hugo", contentRoot: "content", isGitRepository: false, warnings: [] };
  const document: DocumentSnapshot = { documentId: "doc-1", relativePath: "content/a.md", text: draft, encoding: "utf-8", lineEnding: "lf", byteSize: new TextEncoder().encode(draft).byteLength, baselineSha256: "sha-1", revision: 1, writable: true, readOnlyReason: null };
  const capabilities = { localEdit: true, markdownPreview: true, gitStatus: false, siteRuntime: false, gitCommit: false, gitPush: false, gitFetch: false, gitIndex: false, remoteAuth: false, aiEditing: false, semanticSearch: false, pdfTextExtraction: false, ocrReadiness: false, knowledgeLibrary: false, contentHealth: false, imageWorkbench: false, operationLog: false, siteProfiles: false };
  const openDocument = vi.fn(async () => document);
  const saveDocument = vi.fn(async () => ({ ...document, revision: document.revision + 1 }));
  const dispatch = vi.fn(); const focus = vi.fn(); const capture = vi.fn();
  const workspace = { lastRepositoryPath: "/repo", lastDocumentPath: "content/a.md", preferences: { restoreLastWorkspace: true } as unknown };
  const gateway = new Proxy({
    getCapabilities: async () => capabilities, getWorkspaceState: async () => ({ ...workspace }), saveRecoveryDraft: async () => ({ ...workspace }),
    openRepository: async () => repository, listMarkdownFiles: async () => [{ relativePath: "content/a.md", displayName: "a.md", directory: "content", byteSize: document.byteSize }], openDocument, saveDocument,
    gitStatus: async () => ({ available: false, branch: null, upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: [] }),
    inspectSitePreview: async () => ({ siteKind: "hugo", supported: false, runtimeAvailable: false, executable: null, version: null, reason: "", warning: null }),
  }, { get(target, key) { return key in target ? target[key as keyof typeof target] : async () => null; } });
  return { document, capabilities, openDocument, saveDocument, dispatch, focus, capture, workspace, gateway };
});

vi.mock("./components/RssReader", () => ({ RssReader: () => null }));
vi.mock("./platform/repositoryGateway", () => ({ createRepositoryGateway: () => harness.gateway }));
vi.mock("./components/ArticleStatePanel", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./components/ArticleStatePanel")>();
  return { ...actual, default: (props: Parameters<typeof actual.default>[0]) => { harness.capture(props); return createElement(actual.default, props); } };
});
vi.mock("./components/MarkdownEditorSurface", () => ({ default: forwardRef(function MockEditor(props: { value: string; onChange: (value: string) => void; onReady?: () => void }, ref) {
  useImperativeHandle(ref, () => ({ view: { state: { doc: { toString: () => props.value, length: props.value.length } }, dispatch: (transaction: { changes?: { from: number; to: number; insert: string }; selection?: unknown }) => {
    harness.dispatch(transaction);
    if (transaction.changes) { const { from, to, insert } = transaction.changes; props.onChange(props.value.slice(0, from) + insert + props.value.slice(to)); }
  }, focus: harness.focus } }));
  useEffect(() => { props.onReady?.(); }, [props.onReady]);
  return createElement("textarea", { "data-testid": "editor", value: props.value, onChange: (event) => props.onChange((event.target as HTMLTextAreaElement).value) });
}) }));

let host: HTMLDivElement; let root: ReturnType<typeof createRoot> | null = null;
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check: () => boolean) { for (let attempt = 0; attempt < 100; attempt += 1) { if (check()) return; await act(async () => { await pause(10); }); } expect(check()).toBe(true); }
function button(label: string) { return [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label) ?? null; }
async function click(node: HTMLElement | null) { if (!node) throw new Error("control not found"); await act(async () => node.click()); }
function editor() { return host.querySelector<HTMLTextAreaElement>("textarea[data-testid='editor']")!; }
async function input(value: string) { await act(async () => { const node = editor(); Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(node, value); node.dispatchEvent(new Event("input", { bubbles: true })); }); }
async function mount(restoreDocument = true) { const { default: App } = await import("./App"); host = document.createElement("div"); document.body.append(host); root = createRoot(host); await act(async () => root!.render(createElement(App))); if (restoreDocument) await until(() => Boolean(host.querySelector("textarea[data-testid='editor']"))); }
async function openState() { await click(button("文章状态")); await until(() => Boolean(host.querySelector(".article-state-panel"))); }

describe("App article state integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.stubGlobal("matchMedia", () => ({ matches: false, media: "", onchange: null, addEventListener() {}, removeEventListener() {} })); harness.capabilities.localEdit = true; harness.openDocument.mockReset().mockResolvedValue(harness.document); harness.dispatch.mockClear(); harness.focus.mockClear(); harness.saveDocument.mockClear(); harness.capture.mockReset(); });
  afterEach(async () => { await act(async () => root?.unmount()); root = null; host?.remove(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it("projects Hugo draft intent live without changing the editor or saving", async () => {
    await mount(); await openState(); expect(host.querySelector(".article-state-label")?.textContent).toBe("草稿"); const original = editor();
    await input(harness.document.text.replace("draft: true", "draft: false"));
    await until(() => host.querySelector(".article-state-label")?.textContent === "待发布");
    expect(editor()).toBe(original); expect(harness.saveDocument).not.toHaveBeenCalled(); expect(harness.dispatch).not.toHaveBeenCalled();
  });

  it("locates a missing draft field without writing a value", async () => {
    await mount(); await input(harness.document.text.replace("draft: true\n", "")); await openState();
    await click(host.querySelector("button[aria-label^='定位问题']")); await until(() => Boolean(host.querySelector(".front-matter-summary"))); await click(host.querySelector(".front-matter-summary")); await until(() => Boolean(host.querySelector(".front-matter-fields")));
    expect(host.querySelector<HTMLInputElement>(".front-matter-fields input[name='draft']")?.value ?? "").toBe("");
    expect(harness.saveDocument).not.toHaveBeenCalled(); expect(editor().value).not.toContain("draft: false");
  });

  it("keeps zoned future date text and locates its UTF-16 range", async () => {
    await mount(); await openState(); const dateIssue = [...host.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.getAttribute("aria-label")?.includes("日期在未来"));
    await click(dateIssue ?? null); await until(() => harness.dispatch.mock.calls.length > 0);
    const expected = "2099-01-02T03:04:05+08:00"; const from = harness.document.text.indexOf(expected);
    const selection = harness.dispatch.mock.calls[0][0].selection as { anchor: number; head: number }; expect(selection.anchor).toBeLessThanOrEqual(from); expect(selection.head).toBeGreaterThanOrEqual(from + expected.length); expect(editor().value).toContain(expected);
  });

  it("keeps read-only documents projected and locatable", async () => {
    harness.openDocument.mockResolvedValue({ ...harness.document, writable: false }); await mount(); await openState();
    expect(host.querySelector(".article-state-panel")?.textContent).toContain("只读");
    const publishing = [...host.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === "查看发布证据"); await click(publishing ?? null);
    expect(editor().value).toBe(harness.document.text); expect(harness.saveDocument).not.toHaveBeenCalled();
  });

  it("uses the application edit capability even when a gateway document says writable", async () => {
    harness.capabilities.localEdit = false;
    await mount(false);
    await click(button("选择仓库"));
    await until(() => Boolean(host.querySelector(".tree-directory")));
    await click(host.querySelector(".tree-directory"));
    await until(() => Boolean(host.querySelector(".file-button")));
    await click(host.querySelector(".file-button"));
    await until(() => Boolean(editor()));
    await openState();
    expect(host.querySelector(".article-state-panel")?.textContent).toContain("只读");
    const dateIssue = host.querySelector<HTMLButtonElement>("button[aria-label*='日期在未来']");
    await click(dateIssue);
    await until(() => harness.dispatch.mock.calls.length > 0);
    expect(editor().value).toBe(harness.document.text);
    expect(harness.saveDocument).not.toHaveBeenCalled();
  });

  it("does not expose stale panel callbacks after text changes", async () => {
    await mount(); await openState(); const stale = harness.capture.mock.calls[0][0] as ArticleStatePanelProps; await input(harness.document.text.replace("draft: true", "draft: false"));
    await act(async () => stale.onLocate!({ kind: "publishing" }, stale.value, stale.contextKey));
    expect(host.textContent).toContain("文章状态检查已过期"); expect(harness.dispatch).not.toHaveBeenCalled(); expect(harness.focus).not.toHaveBeenCalled();
  });

  it.each<ArticleStateLocation>([{ kind: "publishing" }, { kind: "site" }, { kind: "field", field: "draft" }, { kind: "range", from: 0, to: 3 }])("rejects a captured $kind callback after saving the same text at a new revision", async (location) => {
    await mount(); await input(harness.document.text.replace("draft: true", "draft: false")); await openState();
    const stale = harness.capture.mock.calls[0][0] as ArticleStatePanelProps;
    const savedText = editor().value;
    harness.saveDocument.mockResolvedValueOnce({ ...harness.document, text: savedText, revision: harness.document.revision + 1, baselineSha256: "sha-2" });
    await click(button("保存")); await until(() => harness.saveDocument.mock.calls.length === 1 && Boolean(host.textContent?.includes("已安全保存到本地仓库。")));
    expect(stale.value).toBe(savedText);
    const current = harness.capture.mock.calls[harness.capture.mock.calls.length - 1][0] as ArticleStatePanelProps;
    expect(current.contextKey).not.toBe(stale.contextKey);
    await act(async () => stale.onLocate!(location, stale.value, stale.contextKey));
    expect(host.textContent).toContain("文章状态检查已过期"); expect(harness.dispatch).not.toHaveBeenCalled(); expect(harness.focus).not.toHaveBeenCalled();
    expect(host.querySelector(".publish-center.open, .site-workspace")).toBeNull();
  });
});
