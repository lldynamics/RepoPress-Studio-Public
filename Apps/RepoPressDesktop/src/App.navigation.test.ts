import { act, createElement, forwardRef, useEffect, useImperativeHandle } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot, MarkdownSearchSnapshot } from "./contracts/repository";

const harness = vi.hoisted(() => {
  const text = "# Article\n\nneedle in the paragraph";
  const document: DocumentSnapshot = { documentId: "doc-1", relativePath: "article.md", text, encoding: "utf-8", lineEnding: "lf", byteSize: text.length, baselineSha256: "sha", revision: 1, writable: true, readOnlyReason: null };
  const openDocument = vi.fn(async () => document);
  const saveDocument = vi.fn(async (request: { text: string }) => ({ ...document, text: request.text, revision: document.revision + 1 }));
  const searchMarkdownFiles = vi.fn(async (_session: string, query: string): Promise<MarkdownSearchSnapshot> => ({ query, truncated: false, results: [{ relativePath: "article.md", displayName: "article.md", directory: "", matchKind: "content", lineNumber: 3, snippet: "needle in the paragraph" }] }));
  const dispatch = vi.fn(); const focus = vi.fn();
  const workspace = { lastRepositoryPath: "/repo", lastDocumentPath: "article.md", preferences: { restoreLastWorkspace: true } as unknown };
  const updateWorkspacePreferences = vi.fn(async (preferences: unknown) => { workspace.preferences = preferences; return { ...workspace }; });
  const capabilities = { localEdit: true, markdownPreview: true, gitStatus: false, siteRuntime: false, gitCommit: false, gitPush: false, gitFetch: false, gitIndex: false, remoteAuth: false, aiEditing: false, semanticSearch: false, pdfTextExtraction: false, ocrReadiness: false, knowledgeLibrary: false, contentHealth: false, imageWorkbench: false, operationLog: false, siteProfiles: false };
  const gateway = new Proxy({
    getCapabilities: async () => capabilities,
    getWorkspaceState: async () => ({ ...workspace }),
    saveRecoveryDraft: async () => ({ ...workspace }),
    openRepository: async () => ({ sessionId: "session-1", rootPath: "/repo", displayName: "Repo", siteKind: "none", contentRoot: null, isGitRepository: false, warnings: [] }),
    listMarkdownFiles: async () => [{ relativePath: "article.md", displayName: "article.md", directory: "", byteSize: text.length }],
    openDocument, saveDocument, searchMarkdownFiles, updateWorkspacePreferences,
    gitStatus: async () => ({ available: false, branch: null, upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: [] }),
    inspectSitePreview: async () => ({ siteKind: "none", supported: false, runtimeAvailable: false, executable: null, version: null, reason: "", warning: null }),
  }, { get(target, key) { return key in target ? target[key as keyof typeof target] : async () => null; } });
  return { document, openDocument, saveDocument, searchMarkdownFiles, dispatch, focus, updateWorkspacePreferences, workspace, gateway };
});

vi.mock("./components/RssReader", () => ({ RssReader: () => null }));
vi.mock("./platform/repositoryGateway", () => ({ createRepositoryGateway: () => harness.gateway }));
vi.mock("./components/MarkdownEditorSurface", () => ({ default: forwardRef(function MockEditor(props: { value: string; onChange: (value: string) => void; onReady?: () => void }, ref) {
  useImperativeHandle(ref, () => ({ view: { state: { doc: { toString: () => props.value, length: props.value.length } }, dispatch: (transaction: { changes?: { from: number; to: number; insert: string } }) => {
    harness.dispatch(transaction);
    if (transaction.changes) {
      const change = transaction.changes;
      props.onChange(props.value.slice(0, change.from) + change.insert + props.value.slice(change.to));
    }
  }, focus: harness.focus } }));
  useEffect(() => { props.onReady?.(); }, [props.onReady]);
  return createElement("textarea", { "data-testid": "editor", value: props.value, onChange: (event) => props.onChange((event.target as HTMLTextAreaElement).value) });
}) }));

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot> | null = null;
const pause = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(check: () => boolean) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (check()) return;
    await act(async () => { await pause(10); });
  }
  expect(check(), "UI condition did not become true").toBe(true);
}
function editor() {
  const node = host.querySelector<HTMLTextAreaElement>("textarea[data-testid='editor']");
  if (!node) throw new Error("Editor did not mount");
  return node;
}
async function mount() {
  const { default: App } = await import("./App");
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  await act(async () => { root!.render(createElement(App)); });
  await until(() => Boolean(host.querySelector("textarea[data-testid='editor']")));
}
async function input(node: HTMLInputElement | HTMLTextAreaElement, value: string) {
  const prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  await act(async () => {
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
async function search(query = "needle") {
  const node = host.querySelector<HTMLInputElement>("#markdown-search");
  if (!node) throw new Error("FileNavigator did not mount");
  await input(node, query);
  await until(() => Boolean(host.querySelector(".search-results button")));
}
async function click(node: HTMLElement | null) {
  if (!node) throw new Error("Required control did not render");
  await act(async () => { node.click(); });
}
function result(index = 0) { return host.querySelectorAll<HTMLButtonElement>(".search-results button")[index]; }
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label) ?? null; }
function useOtherResults(paths = ["other.md"]) {
  harness.searchMarkdownFiles.mockImplementation(async (_session, query) => ({ query, truncated: false,
    results: paths.map((relativePath) => ({ relativePath, displayName: relativePath, directory: "", matchKind: "content", lineNumber: 1, snippet: "needle" })),
  }));
}
function deferOpen() {
  let resolve!: (value: DocumentSnapshot) => void;
  harness.openDocument.mockImplementationOnce(() => new Promise((done) => { resolve = done; }));
  return async (path = "other.md") => {
    await act(async () => { resolve({ ...harness.document, documentId: path, relativePath: path, text: "needle" }); });
  };
}

describe("App search and issue navigation", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    vi.stubGlobal("matchMedia", () => ({ matches: false, media: "", onchange: null, addEventListener() {}, removeEventListener() {} }));
    harness.openDocument.mockReset().mockResolvedValue(harness.document);
    harness.saveDocument.mockReset().mockImplementation(async (request) => ({ ...harness.document, text: request.text, revision: harness.document.revision + 1 }));
    harness.searchMarkdownFiles.mockReset().mockImplementation(async (_session, query) => ({ query, truncated: false,
      results: [{ relativePath: "article.md", displayName: "article.md", directory: "", matchKind: "content", lineNumber: 3, snippet: "needle in the paragraph" }],
    }));
    harness.dispatch.mockClear(); harness.focus.mockClear();
    harness.workspace.preferences = { restoreLastWorkspace: true };
    harness.updateWorkspacePreferences.mockReset().mockImplementation(async (preferences) => { harness.workspace.preferences = preferences; return { ...harness.workspace }; });
  });
  afterEach(async () => {
    await act(async () => { root?.unmount(); });
    root = null; host?.remove(); vi.restoreAllMocks(); vi.unstubAllGlobals();
  });

  it("keeps the dirty editor mounted when changing the visible panes", async () => {
    await mount(); await input(editor(), "# 未保存文章\n中文正文");
    const originalEditor = editor();
    await click(button("文件导航")); await click(button("预览"));
    expect(editor()).toBe(originalEditor);
    expect(editor().value).toBe("# 未保存文章\n中文正文");
    await click(button("文件导航")); await click(button("预览"));
    expect(editor()).toBe(originalEditor);
    expect(harness.openDocument).toHaveBeenCalledTimes(1);
    expect(harness.dispatch).not.toHaveBeenCalled();
  });

  it("derives the selected module from an opened surface and closes it when returning to writing", async () => {
    await mount();
    const navigation = host.querySelector('[aria-label="主导航"]')!;
    const current = () => navigation.querySelector<HTMLButtonElement>('[aria-current="page"]');
    expect(current()?.textContent).toBe("写作");
    await click(button("图片工作台"));
    await until(() => Boolean(host.querySelector('[aria-label="关闭图片工作台"]')));
    expect(current()?.textContent).toBe("图片工作台");
    await click(host.querySelector('[aria-label="关闭图片工作台"]'));
    expect(current()?.textContent).toBe("写作");
    await click(button("发布中心"));
    await until(() => Boolean(host.querySelector(".publish-center.open")));
    expect(current()?.textContent).toBe("站点");
    await click(button("阅读"));
    expect(host.querySelector(".publish-center.open")).toBeNull();
    expect(current()?.textContent).toBe("阅读");
    expect(host.querySelectorAll('[aria-label="主导航"] [aria-current="page"]')).toHaveLength(1);
    await click(button("写作"));
    await until(() => Boolean(host.querySelector("textarea[data-testid='editor']")));
    expect(editor().value).toBe(harness.document.text);
    expect(current()?.textContent).toBe("写作");
  });

  it("changes saved UI language without remounting or losing editor, search, find, and metadata inputs", async () => {
    await mount();
    const text = "---\ntitle: 中文标题\ntags: [原标签]\n---\n# 未保存文章\n中文正文 needle";
    await input(editor(), text); await search("中文正文");
    const originalEditor = editor();
    const fileSearch = host.querySelector<HTMLInputElement>("#markdown-search")!;
    await click(button("诊断 · 查找 · 大纲"));
    await until(() => Boolean(host.querySelector("#markdown-document-find")));
    const find = host.querySelector<HTMLInputElement>("#markdown-document-find")!;
    await input(find, "中文正文");
    await click(host.querySelector(".front-matter-summary"));
    const tags = [...host.querySelectorAll<HTMLLabelElement>(".front-matter-fields label")].find((label) => label.textContent === "标签")!.querySelector<HTMLInputElement>("input")!;
    await input(tags, "尚未提交的标签");
    await click(button("设置"));
    await until(() => Boolean(host.querySelector(".settings-center.open")));
    const select = host.querySelectorAll<HTMLSelectElement>(".settings-center select")[2];
    await act(async () => { select.value = "en-US"; select.dispatchEvent(new Event("change", { bubbles: true })); });
    expect(document.documentElement.lang).toBe("zh-CN");
    await click(button("保存设置"));
    await until(() => document.documentElement.lang === "en-US" && Boolean(button("Save settings")));
    expect(harness.updateWorkspacePreferences).toHaveBeenCalledWith(expect.objectContaining({ uiLanguage: "en-US", restoreLastWorkspace: true }));
    expect(host.querySelector('[aria-label="Main navigation"]')).not.toBeNull();
    expect(host.querySelector("#markdown-search")).toBe(fileSearch);
    expect(fileSearch.value).toBe("中文正文");
    expect(host.querySelector("#markdown-document-find")).toBe(find);
    expect(find.value).toBe("中文正文");
    expect(tags.isConnected).toBe(true); expect(tags.value).toBe("尚未提交的标签");
    expect(editor()).toBe(originalEditor); expect(editor().value).toBe(text);
    expect(host.querySelector('[aria-label="Workspace status bar"]')?.textContent).toContain("Unsaved changes");
    expect(harness.openDocument).toHaveBeenCalledTimes(1); expect(harness.dispatch).not.toHaveBeenCalled();
    await click(host.querySelector('[aria-label="Close Settings Center"]'));
    await click(button("Settings"));
    await until(() => Boolean(host.querySelector(".settings-center.open")));
    await act(async () => { select.value = "zh-CN"; select.dispatchEvent(new Event("change", { bubbles: true })); });
    await click(button("Save settings"));
    await until(() => document.documentElement.lang === "zh-CN");
    expect(editor()).toBe(originalEditor); expect(editor().value).toBe(text);
    expect(find.value).toBe("中文正文"); expect(tags.value).toBe("尚未提交的标签");
  });

  it("updates a writing quick-fix notice with system language while preserving the applied source", async () => {
    const languages = vi.spyOn(navigator, "languages", "get").mockReturnValue(["zh-CN"]);
    harness.workspace.preferences = { restoreLastWorkspace: true, uiLanguage: "system" };
    await mount();
    await input(editor(), "# 标题\n### 设置");
    const originalEditor = editor();
    await click(button("诊断 · 查找 · 大纲"));
    await until(() => Boolean(button("快速修复")));
    await click(button("快速修复"));
    expect(host.querySelector(".notice")?.textContent).toBe("已修复：标题层级跳跃");
    expect(editor().value).toBe("# 标题\n## 设置");
    languages.mockReturnValue(["en-US"]);
    await act(async () => { window.dispatchEvent(new Event("languagechange")); });
    expect(host.querySelector(".notice")?.textContent).toBe("Fixed: Heading level skipped");
    expect(editor()).toBe(originalEditor); expect(editor().value).toBe("# 标题\n## 设置");
    expect(harness.openDocument).toHaveBeenCalledTimes(1);
    languages.mockReturnValue(["zh-CN"]);
    await act(async () => { window.dispatchEvent(new Event("languagechange")); });
    expect(host.querySelector(".notice")?.textContent).toBe("已修复：标题层级跳跃");
    expect(editor().value).toBe("# 标题\n## 设置");
  });

  it("updates writing navigation notices across languages without translating the document path", async () => {
    const languages = vi.spyOn(navigator, "languages", "get").mockReturnValue(["en-US"]);
    harness.workspace.preferences = { restoreLastWorkspace: true, uiLanguage: "system" };
    harness.openDocument.mockResolvedValue({ ...harness.document, relativePath: "标题.md", text: "# 标题\n### 设置" });
    await mount(); await click(button("Diagnostics · Find · Outline"));
    await until(() => Boolean(button("Locate"))); await click(button("Locate"));
    await until(() => host.querySelector(".notice")?.textContent === "Located from Writing panel: 标题.md");
    expect(editor().value).toBe("# 标题\n### 设置");
    languages.mockReturnValue(["zh-CN"]);
    await act(async () => { window.dispatchEvent(new Event("languagechange")); });
    expect(host.querySelector(".notice")?.textContent).toBe("已从写作面板定位：标题.md");
    expect(editor().value).toBe("# 标题\n### 设置");
  });

  it("keeps a publishing document report through system language changes and locates the original buffer", async () => {
    const languages = vi.spyOn(navigator, "languages", "get").mockReturnValue(["zh-CN"]);
    harness.workspace.preferences = { restoreLastWorkspace: true, uiLanguage: "system" };
    await mount(); await input(editor(), "# 标题\n### 设置");
    const originalEditor = editor();
    await click(button("发布中心")); await until(() => Boolean(button("检查当前文稿")));
    await click(button("检查当前文稿"));
    expect(host.querySelector('[aria-label="当前文稿写作检查"]')?.textContent).toContain("标题层级跳跃");
    languages.mockReturnValue(["en-US"]);
    await act(async () => { window.dispatchEvent(new Event("languagechange")); });
    const report = host.querySelector('[aria-label="Current document writing check"]')!;
    expect(report.textContent).toContain("Heading level skipped");
    expect(report.textContent).toContain("article.md");
    await click(report.querySelector("li button"));
    await until(() => host.querySelector(".notice")?.textContent === "Located from Publishing center review: article.md");
    expect(editor()).toBe(originalEditor); expect(editor().value).toBe("# 标题\n### 设置");
    expect(harness.openDocument).toHaveBeenCalledTimes(1);
    expect(harness.updateWorkspacePreferences).not.toHaveBeenCalled();
  });

  it("keeps read-only document controls disabled after changing language", async () => {
    harness.openDocument.mockResolvedValue({ ...harness.document, writable: false });
    await mount(); await click(button("设置"));
    await until(() => Boolean(host.querySelector(".settings-center.open")));
    const select = host.querySelectorAll<HTMLSelectElement>(".settings-center select")[2];
    await act(async () => { select.value = "en-US"; select.dispatchEvent(new Event("change", { bubbles: true })); });
    await click(button("保存设置")); await until(() => document.documentElement.lang === "en-US" && Boolean(button("Save settings")));
    expect(host.querySelector<HTMLButtonElement>('[aria-label="Save current Markdown document"]')?.disabled).toBe(true);
    expect(host.querySelector('[aria-label="Workspace status bar"]')?.textContent).toContain("Read-only");
    expect(host.querySelector('[aria-label="Workspace status bar"]')?.textContent).not.toContain("Just saved");
    expect(editor().value).toBe(harness.document.text);
  });

  it("uses English unsaved-work confirmations and preserves the buffer when each switch is cancelled", async () => {
    await mount(); await click(button("设置"));
    await until(() => Boolean(host.querySelector(".settings-center.open")));
    const select = host.querySelectorAll<HTMLSelectElement>(".settings-center select")[2];
    await act(async () => { select.value = "en-US"; select.dispatchEvent(new Event("change", { bubbles: true })); });
    await click(button("保存设置")); await until(() => document.documentElement.lang === "en-US" && Boolean(button("Save settings")));
    await click(host.querySelector('[aria-label="Close Settings Center"]'));
    const text = `${harness.document.text}\n未保存中文`;
    await input(editor(), text);
    const originalEditor = editor();
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    await click(host.querySelector('[aria-label="Select repository"]'));
    expect(confirm).toHaveBeenLastCalledWith(expect.stringMatching(/unsaved changes\. Switch repositories anyway\?/));
    await click(host.querySelector('[aria-label="New Markdown article"]'));
    expect(confirm).toHaveBeenLastCalledWith("The current article has unsaved changes. Create and switch to a new article anyway?");
    useOtherResults(); await search(); await click(result());
    expect(confirm).toHaveBeenLastCalledWith("The current document has unsaved changes. Switch documents anyway?");
    expect(confirm).toHaveBeenCalledTimes(3);
    expect(editor()).toBe(originalEditor); expect(editor().value).toBe(text);
    expect(harness.openDocument).toHaveBeenCalledTimes(1); expect(harness.dispatch).not.toHaveBeenCalled();
  });

  it("uses real FileNavigator to select the exact match without rewriting text", async () => {
    await mount(); await search(); await click(result());
    await until(() => harness.dispatch.mock.calls.length > 0);
    expect(harness.openDocument).toHaveBeenCalledTimes(1);
    expect(harness.dispatch).toHaveBeenCalledWith({ selection: { anchor: 11, head: 17 }, scrollIntoView: true });
    expect(editor().value).toBe(harness.document.text);
    expect(harness.focus).toHaveBeenCalled();
  });

  it("preserves dirty same-document buffers and does not reopen or ask to discard", async () => {
    await mount(); const text = `${harness.document.text}\nnew input`;
    await input(editor(), text); const confirm = vi.spyOn(window, "confirm");
    await search(); await click(result()); await until(() => harness.dispatch.mock.calls.length > 0);
    expect(harness.openDocument).toHaveBeenCalledTimes(1);
    expect(confirm).not.toHaveBeenCalled(); expect(editor().value).toBe(text);
  });

  it("cancels cross-document navigation before opening or focusing", async () => {
    await mount(); useOtherResults(); await input(editor(), `${harness.document.text}\nunsaved`);
    await search(); const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    await click(result());
    expect(confirm).toHaveBeenCalledTimes(1); expect(harness.openDocument).toHaveBeenCalledTimes(1);
    expect(harness.dispatch).not.toHaveBeenCalled(); expect(harness.focus).not.toHaveBeenCalled();
  });

  it("rejects a delayed open after new editor input", async () => {
    await mount(); useOtherResults(); await search(); const finish = deferOpen();
    await click(result()); expect(harness.openDocument).toHaveBeenCalledTimes(2);
    const text = `${harness.document.text}\ninput during load`;
    await input(editor(), text); await finish();
    expect(editor().value).toBe(text); expect(harness.dispatch).not.toHaveBeenCalled();
    expect(host.textContent).toContain("已保留新输入");
  });

  it("does not cancel accepted B when a later navigation to C is declined", async () => {
    await mount(); useOtherResults(["b.md", "c.md"]);
    await input(editor(), `${harness.document.text}\nunsaved`); await search();
    const confirm = vi.spyOn(window, "confirm").mockReturnValueOnce(true).mockReturnValueOnce(false);
    const finish = deferOpen(); await click(result(0)); await click(result(1));
    expect(confirm).toHaveBeenCalledTimes(2); expect(harness.openDocument).toHaveBeenCalledTimes(2);
    await finish("b.md"); await until(() => harness.dispatch.mock.calls.length > 0);
    expect(editor().value).toBe("needle");
    expect(harness.dispatch).toHaveBeenCalledWith({ selection: { anchor: 0, head: 6 }, scrollIntoView: true });
  });

  it("refuses changed search lines instead of selecting a guessed range", async () => {
    await mount(); await search(); await input(editor(), "# Article\n\nchanged line");
    await click(result());
    expect(harness.dispatch).not.toHaveBeenCalled(); expect(host.textContent).toContain("位置已变化或无法核验");
    expect(editor().value).toBe("# Article\n\nchanged line");
  });

  it("routes a real publishing check back to the editor with the complete buffer snapshot", async () => {
    await mount(); const text = "# Article\n\n![](cover.png)"; await input(editor(), text);
    await click(button("发布中心")); await until(() => Boolean(button("检查当前文稿")));
    await click(button("检查当前文稿")); await click(button("定位"));
    await until(() => harness.dispatch.mock.calls.length > 0);
    expect(editor().value).toBe(text);
    expect(harness.dispatch.mock.calls[0][0]).not.toHaveProperty("changes");
    expect(harness.dispatch.mock.calls[0][0].selection.anchor).toBeGreaterThanOrEqual(text.indexOf("![]"));
    expect(host.querySelector("[aria-label='当前文稿写作检查']")).toBeNull();
  });
  it("waits for the editor to remount when locating an issue from RSS mode", async () => {
    await mount(); const text = "# Article\n\n![](cover.png)"; await input(editor(), text);
    await click(button("阅读"));
    await until(() => Boolean(host.querySelector<HTMLElement>(".writing-workspace-host")?.hidden));
    await click(button("发布中心")); await until(() => Boolean(button("检查当前文稿")));
    await click(button("检查当前文稿")); await click(button("定位"));
    await until(() => harness.dispatch.mock.calls.length > 0);
    expect(editor().value).toBe(text); expect(harness.focus).toHaveBeenCalled();
    expect(harness.dispatch.mock.calls[0][0]).not.toHaveProperty("changes");
  });

  it("routes pinned outline headings through the complete current buffer without editing", async () => {
    await mount(); const text = "# 中文章\n\n第一段\n\n## 第二章\n正文";
    await input(editor(), text); await click(button("固定大纲"));
    expect(button("固定大纲")?.getAttribute("aria-pressed")).toBe("true");
    const heading = [...host.querySelectorAll<HTMLButtonElement>(".markdown-outline-panel__item")].find((item) => item.textContent?.includes("第二章"));
    await click(heading ?? null); await until(() => harness.dispatch.mock.calls.length > 0);
    expect(harness.dispatch.mock.calls[0][0]).toEqual({ selection: { anchor: text.indexOf("##"), head: text.indexOf("\n正文") }, scrollIntoView: true });
    expect(editor().value).toBe(text);
    await click(host.querySelector('[aria-label="关闭文章大纲"]'));
    expect(host.querySelector('[aria-label="文章大纲"]')).toBeNull();
  });

  it("routes a missing metadata report to the add button without creating front matter", async () => {
    await mount(); await click(button("属性 · SEO")); await click(button("生成本地报告"));
    await click(button("打开对应字段"));
    await until(() => document.activeElement === button("添加基础属性"));
    expect(editor().value).toBe(harness.document.text);
    expect(harness.dispatch).not.toHaveBeenCalled();
    expect(host.querySelector(".metadata-inspector")?.closest<HTMLElement>('[role="tabpanel"]')?.hidden).toBe(false);
  });

  it("opens the precise metadata field and keeps keyboard focus while editing it", async () => {
    await mount(); const text = '---\ntitle: "Article"\ncustom: keep\n---\n\n# Body';
    await input(editor(), text); await click(button("属性 · SEO")); await click(button("生成本地报告"));
    const issue = [...host.querySelectorAll(".metadata-inspector li")].find((item) => item.textContent?.includes("缺少摘要"));
    await click(issue?.querySelector("button") ?? null);
    await until(() => document.activeElement?.tagName === "INPUT");
    const field = document.activeElement as HTMLInputElement;
    expect(field.closest("label")?.textContent).toBe("摘要");
    expect(harness.dispatch).not.toHaveBeenCalled();
    await input(field, "新的摘要");
    expect(editor().value).toContain('description: "新的摘要"');
    expect(editor().value).toContain("custom: keep");
    expect(editor().value.endsWith("# Body")).toBe(true);
    expect(harness.focus).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(field);
  });

  it("discards metadata reports after editing and resets the inspector across identical documents", async () => {
    await mount(); await click(button("属性 · SEO")); await click(button("生成本地报告"));
    await input(editor(), "# Changed");
    expect(button("打开对应字段")).toBeNull();
    await click(button("生成本地报告"));
    harness.searchMarkdownFiles.mockImplementation(async (_session, query) => ({ query, truncated: false, results: [{ relativePath: "other.md", displayName: "other.md", directory: "", matchKind: "path", lineNumber: null, snippet: "" }] }));
    harness.openDocument.mockResolvedValueOnce({ ...harness.document, documentId: "other", relativePath: "other.md", text: "# Changed" });
    vi.spyOn(window, "confirm").mockReturnValue(true);
    await search(); await click(result());
    await until(() => harness.openDocument.mock.calls.length === 2);
    expect(button("打开对应字段")).toBeNull();
    expect(editor().value).toBe("# Changed");
  });

  it("uses the writing view command to leave the metadata tab and restores find from focus mode", async () => {
    await mount(); await click(button("属性 · SEO")); await click(button("诊断 · 查找 · 大纲"));
    expect(host.querySelector(".metadata-inspector")?.closest<HTMLElement>('[role="tabpanel"]')?.hidden).toBe(true);
    expect(host.querySelector("#markdown-document-find")).not.toBeNull();
    await click(button("专注模式"));
    expect(host.querySelector<HTMLElement>(".workspace-inspector-slot")?.hidden).toBe(true);
    await act(async () => { editor().dispatchEvent(new KeyboardEvent("keydown", { key: "f", ctrlKey: true, bubbles: true })); });
    await until(() => document.activeElement?.id === "markdown-document-find");
    expect(editor().value).toBe(harness.document.text);
  });

  it("keeps inspector state and the dirty buffer while switching tabs, closing, and restoring", async () => {
    await mount();
    const originalEditor = editor();
    await click(button("生成本地报告"));
    const report = host.querySelector(".metadata-inspector-report");
    await click(button("诊断 · 查找 · 大纲"));
    const find = host.querySelector<HTMLInputElement>("#markdown-document-find")!;
    await input(find, "needle");
    await click(button("属性 · SEO"));
    expect(host.querySelector(".metadata-inspector-report")).toBe(report);
    await click(host.querySelector('[aria-label="关闭文章检查器"]'));
    expect(host.querySelector<HTMLElement>(".workspace-inspector-slot")?.hidden).toBe(true);
    await click(button("诊断 · 查找 · 大纲"));
    expect(host.querySelector("#markdown-document-find")).toBe(find);
    expect(find.value).toBe("needle");
    await input(editor(), "# 未保存\n中文正文");
    await click(button("专注模式")); await click(button("专注模式"));
    expect(editor()).toBe(originalEditor);
    expect(editor().value).toBe("# 未保存\n中文正文");
    expect(harness.openDocument).toHaveBeenCalledTimes(1);
  });

  it("consumes Ctrl-F focus before saving remounts the inspector", async () => {
    await mount();
    await act(async () => { editor().dispatchEvent(new KeyboardEvent("keydown", { key: "f", ctrlKey: true, bubbles: true })); });
    await until(() => document.activeElement?.id === "markdown-document-find");
    await input(editor(), "# Saved after find\n\nBody");
    const originalEditor = editor();
    originalEditor.focus();
    await act(async () => { originalEditor.dispatchEvent(new KeyboardEvent("keydown", { key: "s", ctrlKey: true, bubbles: true })); });
    await until(() => harness.saveDocument.mock.calls.length === 1 && Boolean(host.textContent?.includes("已安全保存到本地仓库")));
    await act(async () => { await pause(50); });
    expect(editor()).toBe(originalEditor);
    expect(document.activeElement).toBe(originalEditor);
  });

  it("updates the unified status from the live buffer and opens the matching diagnostics", async () => {
    await mount();
    const text = "# 中文\n\n![](cover.png)";
    await input(editor(), text);
    const status = host.querySelector('[aria-label="工作区状态栏"]')!;
    expect(status.textContent).toContain("有未保存修改");
    expect(status.textContent).toContain(`${Array.from(text).length} 字符`);
    expect(status.textContent).toContain("UTF-8");
    expect(status.textContent).toContain("LF");
    const diagnostics = status.querySelector<HTMLButtonElement>(".workspace-status-bar__diagnostics")!;
    const inspectorSlot = host.querySelector<HTMLElement>(".workspace-inspector-slot")!;
    inspectorSlot.scrollIntoView = vi.fn();
    expect(diagnostics.getAttribute("aria-label")).toContain("个警告");
    await click(diagnostics);
    expect(inspectorSlot.scrollIntoView).toHaveBeenCalledWith({ block: "nearest", inline: "nearest" });
    expect(host.querySelector('[role="tab"][aria-selected="true"]')?.textContent).toBe("诊断 · 查找");
    expect(host.querySelector(".markdown-diagnostics__list")?.textContent).toContain("图片");
    expect(host.querySelector(".writing-inspector-drawer")).toBeNull();
    expect(status.contains(host.querySelector(".markdown-cursor-workflow"))).toBe(true);
    expect(harness.dispatch).not.toHaveBeenCalled();
  });

});
