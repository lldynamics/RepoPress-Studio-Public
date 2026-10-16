import { act, createElement, forwardRef, useEffect, useImperativeHandle } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot } from "./contracts/repository";

const harness = vi.hoisted(() => {
  const baseline: DocumentSnapshot = { documentId: "doc", relativePath: "article.md", text: "# 原稿\n初始", encoding: "utf-8", lineEnding: "lf", byteSize: 13, baselineSha256: "base", revision: 1, writable: true, readOnlyReason: null };
  const repository = { sessionId: "session", rootPath: "/repo", displayName: "Repo", siteKind: "none", contentRoot: null, isGitRepository: false, warnings: [] };
  const openDocument = vi.fn();
  const saveDocument = vi.fn();
  const prepare = vi.fn();
  const complete = vi.fn();
  const selectExportDirectory = vi.fn();
  let workspaceWarning: string | null = null;
  let noWritableDocument = false;
  const gateway = new Proxy({
    getCapabilities: async () => ({ localEdit: true, markdownPreview: true, imageWorkbench: true, contentHealth: false, gitStatus: false }),
    getWorkspaceState: async () => ({ lastRepositoryPath: "/repo", lastDocumentPath: "article.md", warning: workspaceWarning, preferences: { theme: "system", editorFontSize: 15, restoreLastWorkspace: true, recoveryEnabled: true } }),
    openRepository: async () => repository,
    listMarkdownFiles: async () => [{ relativePath: "article.md", displayName: "article.md", directory: "", byteSize: baseline.byteSize }],
    openDocument, saveDocument,
    getGeneralDraft: async () => null,
    updateWorkspacePreferences: async (preferences: unknown) => ({ preferences }),
    gitStatus: async () => ({ available: false, changedFiles: [], warnings: [] }),
  }, { get(target, key) { return key in target ? target[key as keyof typeof target] : async () => null; } });
  let closeListener: (() => void) | null = null;
  const editorExitGateway = { prepare, complete, selectExportDirectory };
  return { baseline, repository, gateway, openDocument, saveDocument, prepare, complete, selectExportDirectory, editorExitGateway, setCloseListener: (handler: () => void) => { closeListener = handler; }, get closeListener() { return closeListener; }, setFixture: (warning: string | null, writable: boolean) => { workspaceWarning = warning; noWritableDocument = !writable; openDocument.mockImplementation(async () => ({ ...baseline, writable: !noWritableDocument })); }, change: (_text: string) => {} };
});

vi.mock("./platform/repositoryGateway", () => ({ createRepositoryGateway: () => harness.gateway }));
vi.mock("./platform/editorExitGateway", () => ({
  editorExitGateway: harness.editorExitGateway,
  listenForEditorClose: vi.fn(async (handler: () => void) => { harness.setCloseListener(handler); return () => harness.setCloseListener(() => {}); }),
}));
vi.mock("./components/RssReader", () => ({ RssReader: () => null }));
vi.mock("./components/MarkdownEditorSurface", () => ({ default: forwardRef(function MockEditor(props: { value: string; editable: boolean; onChange: (value: string) => void; onReady?: () => void }, ref) {
  harness.change = props.onChange;
  useImperativeHandle(ref, () => ({ view: { state: { doc: { toString: () => props.value, length: props.value.length } }, dispatch: (transaction: { changes?: { insert: string } }) => { if (transaction.changes) props.onChange(transaction.changes.insert); }, focus: vi.fn() } }));
  useEffect(() => { props.onReady?.(); }, [props.onReady]);
  return createElement("textarea", { "data-testid": "editor", value: props.value, readOnly: !props.editable, onChange: (event) => props.onChange((event.target as HTMLTextAreaElement).value) });
}) }));

let host: HTMLDivElement; let root: ReturnType<typeof createRoot> | null = null;
async function until(check: () => boolean) {
  for (let n = 0; n < 100; n++) { if (check()) return; await act(async () => { await new Promise((resolve) => setTimeout(resolve, 10)); }); }
  expect(check(), "App did not reach the expected state").toBe(true);
}
function editor() { return host.querySelector<HTMLTextAreaElement>("[data-testid='editor']")!; }
function button(label: string) { const found = [...host.querySelectorAll("button")].find((node) => node.textContent === label); if (!found) throw new Error(`Missing button ${label}`); return found as HTMLButtonElement; }
async function click(label: string) { await act(async () => button(label).click()); }
async function mount() {
  const { default: App } = await import("./App"); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  await act(async () => root!.render(createElement(App))); await until(() => Boolean(editor()));
}
async function closeRequest() { await until(() => Boolean(harness.closeListener)); await act(async () => harness.closeListener!()); await until(() => Boolean(host.querySelector<HTMLDialogElement>(".editor-exit-dialog")?.open)); }

describe("App editor exit integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} }));
    Object.defineProperty(window, "__TAURI_INTERNALS__", { configurable: true, value: {} });
    Object.defineProperty(HTMLDialogElement.prototype, "showModal", { configurable: true, value: vi.fn(function(this: HTMLDialogElement) { this.open = true; }) });
    Object.defineProperty(HTMLDialogElement.prototype, "close", { configurable: true, value: vi.fn(function(this: HTMLDialogElement) { this.open = false; }) });
    harness.openDocument.mockReset(); harness.setFixture(null, true);
    harness.saveDocument.mockReset().mockResolvedValue({ ...harness.baseline, text: "# 原稿\n初始" });
    harness.prepare.mockReset().mockResolvedValue({ planId: "plan", exportPath: null });
    harness.complete.mockReset().mockResolvedValue(undefined);
    harness.selectExportDirectory.mockReset().mockResolvedValue("/exports");
    harness.change = () => {};
  });
  afterEach(async () => { await act(async () => root?.unmount()); root = null; host?.remove(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

  it("opens on the native close event and prepares the exact dirty buffer", async () => {
    await mount();
    await act(async () => harness.change("中文🙂\n"));
    await closeRequest();
    await click("保存恢复草稿并退出");
    expect(harness.prepare).toHaveBeenCalledWith({ sessionId: "session", documentId: "doc", text: "中文🙂\n", expectedSha256: "base" }, null);
    expect(harness.complete).toHaveBeenCalledWith("plan");
  });

  it("ignores edits and Ctrl+S while frozen, while cancel permits continued editing", async () => {
    await mount(); await act(async () => harness.change("冻结前")); await closeRequest();
    await act(async () => { harness.change("冻结中"); window.dispatchEvent(new KeyboardEvent("keydown", { key: "s", ctrlKey: true, bubbles: true })); });
    expect(editor().value).toBe("冻结前"); expect(harness.saveDocument).not.toHaveBeenCalled();
    const navigation = host.querySelector('[aria-label="主导航"]')!;
    for (const control of navigation.querySelectorAll<HTMLButtonElement>("button")) {
      expect(control.disabled).toBe(true);
      await act(async () => control.click());
    }
    expect(host.querySelector("#editor-exit-title")).not.toBeNull();
    expect(host.querySelector('[aria-label="RepoPress 编辑工作区"]')).not.toBeNull();
    await click("返回编辑"); await act(async () => harness.change("取消后"));
    expect(editor().value).toBe("取消后");
  });

  it("keeps the main buffer and exit dialog when prepare fails", async () => {
    await mount(); await act(async () => harness.change("保留原稿")); await closeRequest();
    harness.prepare.mockRejectedValueOnce(new Error("prepare failed")); await click("保存恢复草稿并退出");
    await until(() => Boolean(host.querySelector("[role='alert']")));
    expect(editor().value).toBe("保留原稿"); expect(host.querySelector("#editor-exit-title")).not.toBeNull(); expect(harness.complete).not.toHaveBeenCalled();
  });

  it("preserves a corrupt recovery file when there is no writable draft", async () => {
    harness.setFixture("已有恢复文件无法读取", false);
    await mount();
    await closeRequest();
    expect(host.textContent).toContain("已有恢复文件无法读取");
    expect(host.textContent).toContain("保留原恢复文件");
    await click("保留恢复文件并退出");
    expect(harness.prepare).toHaveBeenCalledWith(null, null);
    expect(harness.complete).toHaveBeenCalledWith("plan");
    expect(harness.selectExportDirectory).not.toHaveBeenCalled();
    expect(editor().value).toBe(harness.baseline.text);
  });

  it("rejects close while save is pending, then prepares with the newest baseline", async () => {
    await mount(); await act(async () => harness.change("待保存"));
    let finishSave!: (value: DocumentSnapshot) => void;
    harness.saveDocument.mockImplementationOnce(() => new Promise((resolve) => { finishSave = resolve; }));
    await click("保存"); await until(() => host.textContent!.includes("正在保存"));
    await act(async () => harness.closeListener!());
    expect(harness.prepare).not.toHaveBeenCalled(); expect(host.textContent).toContain("请先完成");
    await act(async () => finishSave({ ...harness.baseline, text: "待保存", baselineSha256: "new-baseline", revision: 2 }));
    await until(() => editor().readOnly === false);
    await act(async () => harness.change("保存后新修改")); await closeRequest(); await click("保存恢复草稿并退出");
    expect(harness.prepare).toHaveBeenLastCalledWith({ sessionId: "session", documentId: "doc", text: "保存后新修改", expectedSha256: "new-baseline" }, null);
  });
});
