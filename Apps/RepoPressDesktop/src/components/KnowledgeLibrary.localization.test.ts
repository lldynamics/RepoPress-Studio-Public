import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type {
  BrowserCaptureStatus,
  KnowledgeArchiveExportPlan,
  KnowledgeExportPlan,
  KnowledgeItem,
  KnowledgeItemSummary,
  RepositoryGateway,
  RepositorySessionSnapshot,
} from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { knowledgeMessages } from "../i18n/knowledgeMessages";
import { renderUiMessage } from "../i18n/uiMessage";
import { KnowledgeLibrary } from "./KnowledgeLibrary";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

const clock = 1_700_000_000_000;
const folder = { folderId: "folder-1", name: "原始分类", createdAtEpochSeconds: 1_699_999_900 };
const item: KnowledgeItem = {
  itemId: "item-1", title: "资料库", sourceKind: "web", sourceName: "正文", sourceUrl: "https://example.com/source",
  byteSize: 512, createdAtEpochSeconds: 1_699_999_800, updatedAtEpochSeconds: 1_699_999_900,
  readingProgressPercent: 34, allowsLocalSemanticIndex: true, allowsRemoteAiUse: true, folderId: folder.folderId,
  revisionNumber: 2, revisionCount: 2, text: "导入资料库",
  archive: { format: "mhtml", byteSize: 768, embeddedResourceCount: 1_234, missingResourceCount: 2, wasTruncated: true },
};
const repository: RepositorySessionSnapshot = {
  sessionId: "session-1", rootPath: "/repo", displayName: "Repo", siteKind: "generic",
  contentRoot: null, isGitRepository: true, warnings: [],
};
const browser: BrowserCaptureStatus = {
  running: true, endpoint: "http://127.0.0.1:49361/资料库", connectionToken: "资料库-token", tokenExpiresAt: 1_700_000_300,
  allowedOrigins: [], maximumInputBytes: 1_024, summary: "浏览器扩展配对", warning: "分类",
};
const currentRevision = { revisionNumber: 2, createdAtEpochSeconds: 1_699_999_900, byteSize: 512, contentSha256: "b".repeat(64), archive: item.archive };
const oldRevision = { revisionNumber: 1, createdAtEpochSeconds: 1_699_999_700, byteSize: 256, contentSha256: "a".repeat(64), archive: null };
const futureEpochSeconds = clock / 1_000 + 300;
const exportPlan: KnowledgeExportPlan = {
  planId: "export-plan", itemId: item.itemId, relativePath: "knowledge/frozen.md", title: item.title,
  contentSha256: "c".repeat(64), expiresAtEpochSeconds: futureEpochSeconds, summary: "资料库", warnings: ["分类"],
};
const archivePlan: KnowledgeArchiveExportPlan = {
  planId: "archive-plan", itemId: item.itemId, relativePath: "knowledge/frozen.mhtml", format: "mhtml",
  archiveSha256: "d".repeat(64), byteSize: 768, expiresAtEpochSeconds: futureEpochSeconds, summary: "正文", warnings: ["导入资料库"],
};

type StubGateway = Record<string, ReturnType<typeof vi.fn>>;
let host: HTMLDivElement;
let root: Root;
let gateway: StubGateway;

function render(locale: "zh-CN" | "en-US") {
  const library = createElement(KnowledgeLibrary, { open: true, onClose: vi.fn(), gateway: gateway as unknown as RepositoryGateway, repository });
  act(() => root.render(createElement(I18nProvider, { locale, children: library })));
}
async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); }); }
function button(label: string) {
  const result = [...host.querySelectorAll<HTMLButtonElement>("button")].find((candidate) => candidate.textContent === label);
  if (!result) throw new Error(`Missing button: ${label}`);
  return result;
}
async function click(label: string) { await act(async () => button(label).click()); await settle(); }
function field(id: string) {
  const result = host.querySelector<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(`#${id}`);
  if (!result) throw new Error(`Missing field: ${id}`);
  return result;
}
async function setValue(node: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, value: string) {
  await act(async () => {
    const prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : node instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event(node instanceof HTMLSelectElement ? "change" : "input", { bubbles: true }));
  });
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => { resolve = resolvePromise; reject = rejectPromise; });
  return { promise, resolve, reject };
}
async function selectItem() {
  const control = host.querySelector<HTMLButtonElement>(".knowledge-item");
  if (!control) throw new Error("Missing knowledge item");
  await act(async () => control.click());
  await settle();
}

beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(clock);
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  gateway = {
    knowledgeLibraryStatus: vi.fn(async () => ({ ready: true, persistent: true, itemCount: 1, totalBytes: item.byteSize, summary: "资料库", warning: "正文" })),
    listKnowledgeItems: vi.fn(async () => ({ items: [item], total: 1, truncated: false })),
    browserCaptureStatus: vi.fn(async () => browser),
    listKnowledgeFolders: vi.fn(async () => ({ folders: [folder], total: 1 })),
    getKnowledgeItem: vi.fn(async () => item),
    listKnowledgeRevisions: vi.fn(async () => ({ itemId: item.itemId, revisions: [currentRevision, oldRevision] })),
    getKnowledgeRevision: vi.fn(async () => ({ ...oldRevision, text: "历史正文" })),
    createKnowledgeFolder: vi.fn(), moveKnowledgeItem: vi.fn(),
    importKnowledgeText: vi.fn(async () => ({ item, deduplicated: false, summary: "资料库" })),
    setKnowledgeRemoteAiPermission: vi.fn(async () => item),
    searchKnowledgeItems: vi.fn(async (query: string) => ({ query, modelId: "local", encodingVersion: 1, results: [{ item, score: 1, lexicalScore: 1, semanticScore: 0, snippet: "删除资料", reason: "正文" }], truncated: false })),
    updateKnowledgeProgress: vi.fn(async (request: { progressPercent: number }) => ({ ...item, readingProgressPercent: request.progressPercent })),
    deleteKnowledgeItem: vi.fn(),
    planKnowledgeExport: vi.fn(async () => exportPlan), executeKnowledgeExport: vi.fn(async () => ({ itemId: item.itemId, relativePath: exportPlan.relativePath, byteSize: 512, summary: "正文" })),
    planKnowledgeArchiveExport: vi.fn(async () => archivePlan), executeKnowledgeArchiveExport: vi.fn(async () => ({ itemId: item.itemId, relativePath: archivePlan.relativePath, format: archivePlan.format, byteSize: 512, summary: "资料库" })),
    rotateBrowserCaptureToken: vi.fn(async () => browser),
  };
});
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); vi.useRealTimers(); });

describe("KnowledgeLibrary live localization", () => {
  it("keeps the pending load, selection, search, filter, query, and progress node across zh/en/zh", async () => {
    const pendingItems = deferred<{ items: KnowledgeItemSummary[]; total: number; truncated: boolean }>();
    gateway.listKnowledgeItems.mockImplementationOnce(() => pendingItems.promise);
    render("zh-CN"); expect(host.textContent).toContain("正在加载…");
    render("en-US"); expect(host.textContent).toContain("Loading…");
    render("zh-CN");
    expect(gateway.knowledgeLibraryStatus).toHaveBeenCalledTimes(1); expect(gateway.listKnowledgeItems).toHaveBeenCalledTimes(1);
    expect(gateway.browserCaptureStatus).toHaveBeenCalledTimes(1); expect(gateway.listKnowledgeFolders).toHaveBeenCalledTimes(1);
    await act(async () => pendingItems.resolve({ items: [item], total: 1, truncated: false })); await settle();
    await selectItem();
    const query = field("knowledge-query") as HTMLInputElement;
    const filter = field("knowledge-folder-filter") as HTMLSelectElement;
    const progress = field("knowledge-progress") as HTMLInputElement;
    await setValue(query, "needle"); await setValue(filter, folder.folderId); await setValue(progress, "61");
    const pendingSearch = deferred<Awaited<ReturnType<RepositoryGateway["searchKnowledgeItems"]>>>();
    gateway.searchKnowledgeItems.mockImplementationOnce(() => pendingSearch.promise);
    await act(async () => button("搜索").click());
    render("en-US"); render("zh-CN");
    expect(gateway.searchKnowledgeItems).toHaveBeenCalledTimes(1); expect(gateway.searchKnowledgeItems).toHaveBeenCalledWith("needle", 30);
    expect(field("knowledge-query")).toBe(query); expect(query.value).toBe("needle");
    expect(field("knowledge-folder-filter")).toBe(filter); expect(filter.value).toBe(folder.folderId);
    expect(field("knowledge-progress")).toBe(progress); expect(progress.value).toBe("61");
    expect(host.textContent).toContain(item.text); expect(gateway.getKnowledgeItem).toHaveBeenCalledTimes(1);
    await act(async () => pendingSearch.resolve({ query: "needle", modelId: "local", encodingVersion: 1, results: [{ item, score: 1, lexicalScore: 1, semanticScore: 0, snippet: "删除资料", reason: "正文" }], truncated: false }));
    await settle(); render("en-US");
    expect(query.value).toBe("needle"); expect(host.textContent).toContain("删除资料");
    expect(gateway.knowledgeLibraryStatus).toHaveBeenCalledTimes(1);
  });

  it("retains a pending web import form and submits the exact consent-bearing payload once", async () => {
    const pendingImport = deferred<Awaited<ReturnType<RepositoryGateway["importKnowledgeText"]>>>();
    gateway.importKnowledgeText.mockImplementationOnce(() => pendingImport.promise);
    render("zh-CN"); await settle();
    await setValue(field("knowledge-source-kind"), "web");
    const title = field("knowledge-title-input") as HTMLInputElement;
    const sourceName = field("knowledge-source-name") as HTMLInputElement;
    const sourceUrl = field("knowledge-source-url") as HTMLInputElement;
    const text = field("knowledge-text") as HTMLTextAreaElement;
    await setValue(title, "  原始标题  "); await setValue(sourceName, "  原始来源  ");
    await setValue(sourceUrl, "https://example.com/source"); await setValue(text, "  原始正文  ");
    const consents = [...host.querySelectorAll<HTMLInputElement>(".knowledge-form input[type=checkbox]")];
    await act(async () => { consents[0]!.click(); consents[1]!.click(); });
    await act(async () => button("导入资料库").click());
    expect(gateway.importKnowledgeText).toHaveBeenCalledTimes(1);
    expect(gateway.importKnowledgeText).toHaveBeenCalledWith({ sourceKind: "web", title: "原始标题", sourceName: "原始来源", sourceUrl: "https://example.com/source", text: "原始正文", allowsLocalSemanticIndex: true, allowsRemoteAiUse: true });
    render("en-US");
    expect(field("knowledge-title-input")).toBe(title); expect(title.value).toBe("  原始标题  ");
    expect(sourceName.value).toBe("  原始来源  "); expect(sourceUrl.value).toBe("https://example.com/source"); expect(text.value).toBe("  原始正文  ");
    expect(consents[0]!.checked).toBe(true); expect(consents[1]!.checked).toBe(true);
    await act(async () => pendingImport.resolve({ item, deduplicated: false, summary: "资料库" })); await settle();
    expect(gateway.importKnowledgeText).toHaveBeenCalledTimes(1);
  });

  it("keeps a frozen Markdown export plan across locale changes and rerenders its completed byte notice", async () => {
    const pendingPlan = deferred<KnowledgeExportPlan>();
    const pendingExecution = deferred<Awaited<ReturnType<RepositoryGateway["executeKnowledgeExport"]>>>();
    gateway.planKnowledgeExport.mockImplementationOnce(() => pendingPlan.promise);
    gateway.executeKnowledgeExport.mockImplementationOnce(() => pendingExecution.promise);
    render("zh-CN"); await settle(); await selectItem();
    const path = field("knowledge-export-path") as HTMLInputElement;
    await setValue(path, "knowledge/frozen.md");
    await act(async () => button("生成导出计划").click());
    render("en-US");
    expect(gateway.planKnowledgeExport).toHaveBeenCalledTimes(1);
    expect(gateway.planKnowledgeExport).toHaveBeenCalledWith({ sessionId: repository.sessionId, itemId: item.itemId, relativePath: "knowledge/frozen.md" });
    expect(field("knowledge-export-path")).toBe(path); expect(path.value).toBe("knowledge/frozen.md");
    await act(async () => pendingPlan.resolve(exportPlan)); await settle();
    expect(host.textContent).toContain("资料库"); expect(host.textContent).toContain("分类");
    expect(host.querySelector(".operation-plan code")?.textContent).toBe(exportPlan.contentSha256);
    expect(host.textContent).toContain(new Date(futureEpochSeconds * 1_000).toLocaleString("en-US"));
    render("zh-CN"); expect(host.textContent).toContain(new Date(futureEpochSeconds * 1_000).toLocaleString("zh-CN"));
    render("en-US"); await act(async () => button("Confirm export").click());
    expect(gateway.executeKnowledgeExport).toHaveBeenCalledTimes(1);
    render("zh-CN"); await act(async () => button("确认执行导出").click());
    expect(gateway.executeKnowledgeExport).toHaveBeenCalledTimes(1);
    await act(async () => pendingExecution.resolve({ itemId: item.itemId, relativePath: "knowledge/frozen.md", byteSize: 512, summary: "正文" })); await settle();
    expect(host.querySelector('[role="status"]')?.textContent).toContain("已写入 knowledge/frozen.md（512 字节）；尚未暂存或提交。");
    render("en-US"); expect(host.querySelector('[role="status"]')?.textContent).toContain("Wrote knowledge/frozen.md (512 bytes); it has not been staged or committed.");
    render("zh-CN"); expect(host.querySelector('[role="status"]')?.textContent).toContain("512 字节");
  });

  it("keeps a frozen archive export plan and executes it once while the language changes", async () => {
    const pendingPlan = deferred<KnowledgeArchiveExportPlan>();
    const pendingExecution = deferred<Awaited<ReturnType<RepositoryGateway["executeKnowledgeArchiveExport"]>>>();
    gateway.planKnowledgeArchiveExport.mockImplementationOnce(() => pendingPlan.promise);
    gateway.executeKnowledgeArchiveExport.mockImplementationOnce(() => pendingExecution.promise);
    render("zh-CN"); await settle(); await selectItem();
    const path = field("knowledge-archive-path") as HTMLInputElement;
    await setValue(path, "knowledge/frozen.mhtml");
    await act(async () => button("生成归档导出计划").click());
    render("en-US"); expect(gateway.planKnowledgeArchiveExport).toHaveBeenCalledTimes(1);
    expect(gateway.planKnowledgeArchiveExport).toHaveBeenCalledWith({ sessionId: repository.sessionId, itemId: item.itemId, relativePath: "knowledge/frozen.mhtml" });
    await act(async () => pendingPlan.resolve(archivePlan)); await settle();
    expect(host.textContent).toContain("正文"); expect(host.textContent).toContain("导入资料库");
    expect(host.textContent).toContain(new Date(futureEpochSeconds * 1_000).toLocaleString("en-US"));
    render("zh-CN"); expect(host.textContent).toContain(new Date(futureEpochSeconds * 1_000).toLocaleString("zh-CN"));
    render("en-US"); await act(async () => button("Explicitly export archive").click());
    render("zh-CN"); await act(async () => button("明确执行归档导出").click());
    expect(gateway.executeKnowledgeArchiveExport).toHaveBeenCalledTimes(1);
    expect(gateway.executeKnowledgeArchiveExport).toHaveBeenCalledWith({ sessionId: repository.sessionId, planId: archivePlan.planId });
    await act(async () => pendingExecution.resolve({ itemId: item.itemId, relativePath: archivePlan.relativePath, format: "mhtml", byteSize: 512, summary: "资料库" })); await settle();
    expect(host.querySelector('[role="status"]')?.textContent).toContain("已写入离线归档 knowledge/frozen.mhtml（512 字节）");
    render("en-US"); expect(host.querySelector('[role="status"]')?.textContent).toContain("Wrote offline archive knowledge/frozen.mhtml (512 bytes)");
  });

  it("keeps backend, item, snippet, endpoint, token, and dictionary-looking text literal while local masks follow locale", async () => {
    gateway.getKnowledgeItem.mockResolvedValueOnce({ ...item, createdAtEpochSeconds: Number.NaN });
    render("en-US"); await settle();
    expect(host.textContent).toContain("资料库"); expect(host.textContent).toContain("正文");
    expect(host.textContent).toContain(browser.summary); expect(host.textContent).toContain(browser.warning!);
    expect(host.textContent).toContain(browser.endpoint!); expect(host.textContent).toContain(browser.connectionToken!);
    await selectItem();
    expect(host.textContent).toContain(item.title); expect(host.textContent).toContain(item.sourceName); expect(host.textContent).toContain(item.text);
    expect(host.textContent).toContain("Unknown"); expect(host.textContent).toContain("1,234");
    await setValue(field("knowledge-query"), "raw"); await click("Search");
    expect(host.textContent).toContain("删除资料");
    const markerLookingText = "\u{E000}repopress-local-file\u{E001}";
    gateway.searchKnowledgeItems.mockRejectedValueOnce(new Error(`正文 [本地文件] ${markerLookingText} /tmp/private-secret`));
    await setValue(field("knowledge-query"), "mask"); await click("Search");
    const error = host.querySelector('[role="status"]')?.textContent ?? "";
    expect(error).toContain(`Search failed: 正文 [本地文件] ${markerLookingText} [Local file]`); expect(error).not.toContain("private-secret");
    render("zh-CN");
    expect(host.querySelector('[role="status"]')?.textContent).toContain(`搜索失败：正文 [本地文件] ${markerLookingText} [本地文件]`);
  });

  it("builds delete and token-rotation confirmations from the locale active at click time", async () => {
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    render("en-US"); await settle(); await selectItem();
    await click("Delete knowledge");
    expect(confirm).toHaveBeenLastCalledWith(`Delete “${item.title}”? This cannot be undone.`);
    render("zh-CN"); await click("删除资料");
    expect(confirm).toHaveBeenLastCalledWith(`删除“${item.title}”？此操作不可撤销。`);
    render("en-US"); await click("Rotate token");
    expect(confirm).toHaveBeenLastCalledWith("Rotate the browser token? The old token saved in the extension will immediately become invalid.");
    render("zh-CN"); await click("轮换令牌");
    expect(confirm).toHaveBeenLastCalledWith("确定轮换浏览器令牌？扩展中保存的旧令牌将立即失效。");
    expect(gateway.deleteKnowledgeItem).not.toHaveBeenCalled(); expect(gateway.rotateBrowserCaptureToken).not.toHaveBeenCalled();
  });
});

describe("KnowledgeLibrary localization contract", () => {
  it("keeps source values stable while translating their labels", () => {
    expect(knowledgeMessages["网页"]).toBe("Web"); expect(knowledgeMessages["文字"]).toBe("Text");
    expect(knowledgeMessages["离线 HTML（自包含）"]).toContain("Offline HTML");
  });
  it("renders a delayed local notice from a template and raw parameter", () => {
    const notice = { source: "导出失败：{message}", parameters: { message: "raw backend error" } };
    expect(renderUiMessage(notice, (source, parameters) => source === notice.source ? `Export failed: ${parameters?.message}` : source)).toBe("Export failed: raw backend error");
  });
  it("preserves backend literals outside the local catalog", () => {
    const summary = "资料库后端摘要 · token-abc"; expect(knowledgeMessages[summary]).toBeUndefined(); expect(summary).toContain("token-abc");
  });
  it("provides locale-aware dynamic templates for bytes, dates, and quantities", () => {
    expect(knowledgeMessages["{bytes} 字节"]).toBe("{bytes} bytes");
    expect(knowledgeMessages["{count} 个资源未能保留"]).toContain("{count}"); expect(knowledgeMessages["有效至：{date}"]).toContain("Expires");
  });
});
