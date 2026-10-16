import { act, createElement, forwardRef, useEffect, useImperativeHandle } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot, RepositorySessionSnapshot } from "./contracts/repository";
import type { ArticleStateChangePlan } from "./contracts/articleStateChange";
import { planArticleStateChange } from "./features/writing/articleStateChange";
import type { ArticleStatePanelProps } from "./components/ArticleStatePanel";

const harness = vi.hoisted(() => {
  const draft = "---\ntitle: Article\ndraft: true\ndate: 2099-01-02T03:04:05+08:00\n---\n\nBody 中文";
  const repository: RepositorySessionSnapshot = { sessionId: "session-1", rootPath: "/repo", displayName: "Hugo", siteKind: "hugo", contentRoot: "content", isGitRepository: false, warnings: [] };
  const document: DocumentSnapshot = { documentId: "doc-1", relativePath: "content/a.md", text: draft, encoding: "utf-8", lineEnding: "lf", byteSize: new TextEncoder().encode(draft).byteLength, baselineSha256: "sha-1", revision: 1, writable: true, readOnlyReason: null };
  const capabilities = { localEdit: true, markdownPreview: true, gitStatus: false, siteRuntime: false, gitCommit: false, gitPush: false, gitFetch: false, gitIndex: false, remoteAuth: false, aiEditing: false, semanticSearch: false, pdfTextExtraction: false, ocrReadiness: false, knowledgeLibrary: false, contentHealth: false, imageWorkbench: false, operationLog: false, siteProfiles: false };
  const openDocument = vi.fn(async () => document);
  const saveDocument = vi.fn(async (_request: { text: string; sessionId: string; documentId: string; expectedSha256: string }) => ({ ...document, revision: document.revision + 1 }));
  const dispatch = vi.fn(); const focus = vi.fn(); const capture = vi.fn();
  const workspace = { lastRepositoryPath: "/repo", lastDocumentPath: "content/a.md", preferences: { restoreLastWorkspace: true } as unknown };
  const gateway = new Proxy({
    getCapabilities: async () => capabilities, getWorkspaceState: async () => ({ ...workspace }), saveRecoveryDraft: async () => ({ ...workspace }),
    openRepository: async () => repository, listMarkdownFiles: async () => [{ relativePath: "content/a.md", displayName: "a.md", directory: "content", byteSize: document.byteSize }], openDocument, saveDocument,
    gitStatus: async () => ({ available: false, branch: null, upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: [] }),
    inspectSitePreview: async () => ({ siteKind: "hugo", supported: false, runtimeAvailable: false, executable: null, version: null, reason: "", warning: null }),
  }, { get(target, key) { return key in target ? target[key as keyof typeof target] : async () => null; } });
  return { repository, document, capabilities, openDocument, saveDocument, dispatch, focus, capture, workspace, gateway };
});

vi.mock("./components/RssReader", () => ({ RssReader: () => null }));
vi.mock("./platform/repositoryGateway", () => ({ createRepositoryGateway: () => harness.gateway }));
vi.mock("./components/ArticleStatePanel", async (importOriginal) => {
  const actual = await importOriginal<typeof import("./components/ArticleStatePanel")>();
  return { ...actual, default: (props: Parameters<typeof actual.default>[0]) => { harness.capture(props); return createElement(actual.default, props); } };
});
vi.mock("./components/MarkdownEditorSurface", async (importOriginal) => ({ ...(await importOriginal<typeof import("./components/MarkdownEditorSurface")>()), default: forwardRef(function MockEditor(props: { value: string; onChange: (value: string) => void; onReady?: () => void }, ref) {
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

function currentPanel() { return harness.capture.mock.calls[harness.capture.mock.calls.length - 1][0] as ArticleStatePanelProps; }
function currentPlan() {
  const panel = currentPanel();
  const result = planArticleStateChange({ text: panel.value, context: panel.context, contextKey: panel.contextKey, nowEpochMs: Date.now() }, "ready");
  if (!result.ok) throw new Error(result.reason);
  return result.plan;
}
async function apply(plan: ArticleStateChangePlan) {
  let result = false;
  await act(async () => { result = await currentPanel().onApplyChange!(plan); });
  return result;
}

describe("App confirmed article state changes", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    vi.stubGlobal("matchMedia", () => ({ matches: false, media: "", onchange: null, addEventListener() {}, removeEventListener() {} }));
    harness.capabilities.localEdit = true;
    harness.openDocument.mockReset().mockResolvedValue(harness.document);
    harness.saveDocument.mockReset().mockImplementation(async (request) => ({ ...harness.document, text: request.text, baselineSha256: "sha-2", revision: 2 }));
    harness.dispatch.mockClear(); harness.focus.mockClear(); harness.capture.mockReset();
  });
  afterEach(async () => { await act(async () => root?.unmount()); root = null; host?.remove(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it("previews and cancels without editing, then confirms one field and saves only through ordinary Save", async () => {
    await mount(); await input(harness.document.text + " unsaved body"); await openState(); const originalEditor = editor();
    await click(button("预览设为待发布"));
    expect(host.querySelector(".article-state-change-preview")?.textContent).toContain("draft: true");
    expect(editor().value).toContain("draft: true"); expect(harness.dispatch).not.toHaveBeenCalled();
    await click(button("取消变更")); expect(editor().value).toContain("draft: true");
    await click(button("预览设为待发布")); await click(button("确认应用到编辑器"));
    const expected = harness.document.text.replace("draft: true", "draft: false") + " unsaved body";
    await until(() => editor().value === expected);
    expect(editor()).toBe(originalEditor); expect(harness.saveDocument).not.toHaveBeenCalled();
    expect(harness.dispatch).toHaveBeenCalledTimes(1);
    expect(harness.dispatch.mock.calls[0][0].changes).toEqual({ from: harness.document.text.indexOf("true"), to: harness.document.text.indexOf("true") + 4, insert: "false" });
    expect(host.textContent).toContain("文章状态已应用到编辑器，尚未保存。");
    await click(button("保存")); await until(() => harness.saveDocument.mock.calls.length === 1);
    expect(harness.saveDocument).toHaveBeenCalledWith({ sessionId: "session-1", documentId: "doc-1", text: expected, expectedSha256: "sha-1" });
  });

  it("applies once and rejects replay even if the text later returns to the original", async () => {
    await mount(); await openState(); const plan = currentPlan();
    expect(await apply(plan)).toBe(true); expect(await apply(plan)).toBe(false);
    await input(plan.expectedText); expect(await apply(plan)).toBe(false);
    expect(harness.dispatch).toHaveBeenCalledTimes(1); expect(harness.saveDocument).not.toHaveBeenCalled();
  });

  it.each(["target", "edit", "nextText", "beforeField", "afterField", "contextKey"])("rebuilds the plan and rejects forged %s", async (field) => {
    await mount(); await openState(); const plan = currentPlan();
    const altered = { ...plan, [field]: field === "target" ? "published" : field === "edit" ? { from: 0, to: plan.expectedText.length, insert: plan.nextText } : "forged" } as ArticleStateChangePlan;
    expect(await apply(altered)).toBe(false); expect(editor().value).toBe(harness.document.text);
    expect(harness.dispatch).not.toHaveBeenCalled(); expect(harness.saveDocument).not.toHaveBeenCalled();
  });

  it("invalidates old plans after editing away and back to identical text", async () => {
    await mount(); await openState(); const plan = currentPlan();
    await input(plan.expectedText + " changed"); await input(plan.expectedText);
    expect(await apply(plan)).toBe(false); expect(harness.dispatch).not.toHaveBeenCalled();
  });

  it("invalidates a plan when the inspector closes and reopens", async () => {
    await mount(); await openState(); const plan = currentPlan();
    await click(button("检查器"));
    await click(button("文章状态")); await until(() => Boolean(host.querySelector(".article-state-panel")));
    expect(await apply(plan)).toBe(false); expect(harness.dispatch).not.toHaveBeenCalled();
  });

  it("rejects an old plan after ordinary Save advances the baseline", async () => {
    await mount(); await input(harness.document.text + " dirty"); await openState(); const plan = currentPlan();
    await click(button("保存")); await until(() => host.textContent?.includes("已安全保存到本地仓库。") === true);
    expect(await apply(plan)).toBe(false); expect(harness.dispatch).not.toHaveBeenCalled();
  });

  it("invalidates a plan as soon as a document open starts, even before its response", async () => {
    await mount(); await openState(); const plan = currentPlan();
    let finish!: (value: DocumentSnapshot) => void;
    harness.openDocument.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    if (!host.querySelector(".file-button")) await click(host.querySelector(".tree-directory"));
    await click(host.querySelector(".file-button"));
    expect(await apply(plan)).toBe(false); expect(harness.dispatch).not.toHaveBeenCalled();
    await act(async () => finish({ ...harness.document, documentId: "doc-2", relativePath: "content/b.md" }));
    expect(await apply(plan)).toBe(false); expect(editor().value).toBe(harness.document.text);
  });

  it("rejects during an unfinished Save and preserves its pending content", async () => {
    let finish!: (value: DocumentSnapshot) => void;
    harness.saveDocument.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    await mount(); await input(harness.document.text + " pending"); await openState(); const plan = currentPlan();
    await click(button("保存")); expect(await apply(plan)).toBe(false);
    expect(editor().value).toBe(plan.expectedText); expect(harness.dispatch).not.toHaveBeenCalled();
    await act(async () => finish({ ...harness.document, text: plan.expectedText, revision: 2 }));
    expect(await apply(plan)).toBe(false);
  });

  it("rejects after a Save conflict and keeps the user's buffer intact", async () => {
    harness.saveDocument.mockRejectedValueOnce(Object.assign(new Error("保存冲突：文件已被其他程序修改"), { code: "save_conflict" }));
    await mount(); await input(harness.document.text + " conflict"); await openState(); const plan = currentPlan();
    await click(button("保存")); await until(() => host.textContent?.includes("文件已被外部修改；请审阅保存冲突。") === true);
    expect(await apply(plan)).toBe(false); expect(editor().value).toBe(plan.expectedText); expect(harness.dispatch).not.toHaveBeenCalled();
  });

  it("rechecks live edits while imports are pending and consumes both double-click requests", async () => {
    await mount(); await openState(); const plan = currentPlan(); let first = true; let second = true;
    await act(async () => {
      const callback = currentPanel().onApplyChange!;
      const pending = callback(plan); const repeated = callback(plan);
      const node = editor(); Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(node, plan.expectedText + " race");
      node.dispatchEvent(new Event("input", { bubbles: true }));
      first = await pending; second = await repeated;
    });
    expect(first).toBe(false); expect(second).toBe(false); expect(harness.dispatch).not.toHaveBeenCalled();
    expect(editor().value).toBe(plan.expectedText + " race");
  });

  it("rejects read-only documents even when given a plan built with writable context", async () => {
    harness.openDocument.mockResolvedValue({ ...harness.document, writable: false });
    await mount(); await openState(); const panel = currentPanel();
    const result = planArticleStateChange({ text: panel.value, context: { kind: "repository", repository: harness.repository, documentId: harness.document.documentId, relativePath: harness.document.relativePath, writable: true }, contextKey: panel.contextKey, nowEpochMs: Date.now() }, "ready");
    if (!result.ok) throw new Error(result.reason);
    expect(button("预览设为待发布")).toBeNull(); expect(await apply(result.plan)).toBe(false); expect(harness.dispatch).not.toHaveBeenCalled();
  });

  it("fails closed when editor dispatch fails without saving or replacing the buffer", async () => {
    await mount(); await openState(); const plan = currentPlan();
    harness.dispatch.mockImplementationOnce(() => { throw new Error("view unavailable"); });
    expect(await apply(plan)).toBe(false); expect(editor().value).toBe(plan.expectedText);
    expect(harness.saveDocument).not.toHaveBeenCalled(); expect(await apply(plan)).toBe(false);
  });
});
