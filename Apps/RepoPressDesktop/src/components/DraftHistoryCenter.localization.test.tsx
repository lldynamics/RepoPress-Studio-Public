import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DocumentSnapshot, DraftVersion, DraftVersionSnapshot, RecycledDraft, RecycledDraftSnapshot, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { DraftHistoryCenter, type DraftHistoryCenterProps } from "./DraftHistoryCenter";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const repository: RepositorySessionSnapshot = { sessionId: "session-a", rootPath: "/repo/{path}", displayName: "关闭", siteKind: "zola", contentRoot: "content", isGitRepository: true, warnings: [] };
const rawBody = "--- 历史版本\n+++ 当前稿\n恢复所选版本\n正在恢复版本…\n{source} {path}";
const rawPath = "恢复所选版本";
const documentFor = (documentId = "doc-a", text = rawBody): DocumentSnapshot => ({ documentId, relativePath: `content/${documentId}.md`, text, encoding: "utf-8", lineEnding: "lf", byteSize: text.length, baselineSha256: "baseline-{path}", revision: 1, writable: true, readOnlyReason: null });
const versionList = (): DraftVersionSnapshot => ({ documentId: "doc-a", relativePath: "content/doc-a.md", versions: [
  { versionId: "version-a", relativePath: rawPath, reason: "beforeSave", createdAtEpochSeconds: 1_700_000_000, byteSize: 8, contentSha256: "关闭{sha}01234abcd" },
  { versionId: "version-b", relativePath: "beforeRestore", reason: "beforeRestore", createdAtEpochSeconds: 2, byteSize: 2048, contentSha256: "b".repeat(64) },
  { versionId: "version-c", relativePath: "deleted", reason: "deleted", createdAtEpochSeconds: Number.NaN, byteSize: 1048576, contentSha256: "c".repeat(64) },
] });
const recycleList = (truncated = false): RecycledDraftSnapshot => ({ entries: [
  { recycleId: "recycle-a", relativePath: rawPath, deletedAtEpochSeconds: 1_700_000_000, byteSize: 8, contentSha256: "a".repeat(64) },
  { recycleId: "recycle-b", relativePath: "content/{path}-{source}.md", deletedAtEpochSeconds: 2, byteSize: 8, contentSha256: "b".repeat(64) },
], total: truncated ? 20 : 2, truncated });
const versionDetail = (index = 0): DraftVersion => ({ ...versionList().versions[index], text: rawBody });
const recycleDetail = (index = 0): RecycledDraft => ({ ...recycleList().entries[index], text: rawBody });
const restored = documentFor("restored", "关闭\n{path}");
type GatewayMock = { [K in keyof Pick<RepositoryGateway, "listDraftVersions" | "getDraftVersion" | "restoreDraftVersion" | "listRecycledDrafts" | "getRecycledDraft" | "restoreRecycledDraft" | "deleteRecycledDraft">]: ReturnType<typeof vi.fn> };
function makeGateway(): GatewayMock { return {
  listDraftVersions: vi.fn(async () => versionList()),
  getDraftVersion: vi.fn(async (_session: string, _doc: string, id: string) => versionDetail(id === "version-b" ? 1 : id === "version-c" ? 2 : 0)),
  restoreDraftVersion: vi.fn(async () => restored),
  listRecycledDrafts: vi.fn(async () => recycleList()),
  getRecycledDraft: vi.fn(async (_session: string, id: string) => recycleDetail(id === "recycle-b" ? 1 : 0)),
  restoreRecycledDraft: vi.fn(async () => restored),
  deleteRecycledDraft: vi.fn(async () => recycleList()),
}; }
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (reason: unknown) => void; const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
let host: HTMLDivElement;
let root: Root;
let service: GatewayMock;
let props: DraftHistoryCenterProps;
let confirm: ReturnType<typeof vi.fn>;
async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }
async function render(locale: UiLocale = "zh-CN", changes: Partial<DraftHistoryCenterProps> = {}) {
  props = { ...props, ...changes };
  await act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(DraftHistoryCenter, props) })));
  await settle();
}
function button(label: string) { const found = [...host.querySelectorAll("button")].find((item) => item.textContent === label); expect(found, label).toBeDefined(); return found!; }
async function click(label: string) { await act(async () => button(label).click()); await settle(); }
async function choose(index: number) { await act(async () => (host.querySelectorAll<HTMLButtonElement>('[role="option"]')[index]).click()); await settle(); }
async function recycle(locale: UiLocale = "en-US") { await render(locale); await click(locale === "en-US" ? "Recycle bin" : "回收站"); }
async function editPath(value: string) { const input = host.querySelector("input")!; await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })); }); return input; }
function calls() { return [service.listDraftVersions.mock.calls.length, service.getDraftVersion.mock.calls.length, service.listRecycledDrafts.mock.calls.length, service.getRecycledDraft.mock.calls.length]; }
function diffLines() { return [...host.querySelectorAll<HTMLElement>('[role="table"] .draft-version-comparison__content')].map(cell => cell.textContent!); }

beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  service = makeGateway(); confirm = vi.fn(() => true);
  vi.stubGlobal("confirm", confirm);
  vi.stubGlobal("requestAnimationFrame", vi.fn((callback: FrameRequestCallback) => { callback(0); return 1; }));
  vi.stubGlobal("cancelAnimationFrame", vi.fn());
  props = { open: true, onClose: vi.fn(), gateway: service as unknown as RepositoryGateway, repository, document: documentFor(), currentText: rawBody, onRestoreDocument: vi.fn() };
});
afterEach(async () => { await act(async () => root.unmount()); host.remove(); await Promise.resolve(); vi.unstubAllGlobals(); vi.restoreAllMocks(); });

describe("DraftHistoryCenter localized presentation", () => {
  it("keeps version selection, focus and raw diff lines across zh-en-zh without rereading", async () => {
    await render(); await choose(1);
    const option = host.querySelector<HTMLButtonElement>('[role="option"][aria-selected="true"]')!; option.focus();
    const before = calls(); const lines = diffLines();
    await render("en-US");
    expect(host.querySelector("h2")!.textContent).toBe("Version history and trash");
    expect(host.querySelector('[role="tablist"]')!.getAttribute("aria-label")).toBe("Draft lifecycle");
    expect(host.querySelector('[role="listbox"]')!.getAttribute("aria-label")).toBe("Document versions");
    expect(host.querySelector('[role="table"]')!.getAttribute("aria-label")).toBe("Unified diff of the current draft and selected version");
    expect([...host.querySelectorAll('[role="columnheader"]')].map(cell => cell.textContent)).toEqual(["Source line", "Current draft line", "Diff content"]);
    expect(diffLines()).toEqual(lines);
    expect(lines).toContain(" --- 历史版本"); expect(lines).toContain(" +++ 当前稿"); expect(lines).toContain(" 恢复所选版本");
    expect(host.textContent).toContain("Local document protection records for 关闭");
    expect(host.textContent).toContain("Before save"); expect(host.textContent).toContain("Before restore"); expect(host.textContent).toContain("Before deletion");
    expect(host.textContent).toContain("Unknown time");
    expect(host.textContent).toContain(new Date(1_700_000_000_000).toLocaleString("en-US"));
    expect(document.activeElement).toBe(option);
    await render(); expect(diffLines()).toEqual(lines);
    expect(document.activeElement).toBe(option); expect(option.getAttribute("aria-selected")).toBe("true"); expect(calls()).toEqual(before);
    expect(service.restoreDraftVersion).not.toHaveBeenCalled();
  });

  it("keeps recycle tab, selection, edited brace path, raw preview, focus and parameter status", async () => {
    service.listRecycledDrafts.mockResolvedValue(recycleList(true));
    await recycle("zh-CN"); await choose(1); const input = await editPath(" content/{source}-{path}.md "); input.focus(); const before = calls();
    await render("en-US");
    expect(host.querySelector('[role="tab"][aria-selected="true"]')!.textContent).toBe("Recycle bin");
    expect(host.querySelector('[role="option"][aria-selected="true"] strong')!.textContent).toBe("content/{path}-{source}.md");
    expect(input.value).toBe(" content/{source}-{path}.md "); expect(document.activeElement).toBe(input);
    expect(host.querySelector("pre")!.textContent).toBe(rawBody); expect(host.querySelector("pre")!.getAttribute("aria-label")).toBe("Recycled document preview");
    expect(host.textContent).toContain("Showing only the most recent 2 recycle records.");
    await render(); expect(input.value).toBe(" content/{source}-{path}.md "); expect(document.activeElement).toBe(input); expect(calls()).toEqual(before);
    expect(host.textContent).toContain("仅显示最近 2 条回收记录。");
  });

  it("preserves dictionary collision names, SHA fragments and bodies exactly", async () => {
    await render("en-US");
    expect(host.textContent).toContain(versionList().versions[0].contentSha256.slice(0, 12));
    await click("Recycle bin");
    expect(host.querySelector('[role="option"] strong')!.textContent).toBe(rawPath);
    expect(host.querySelector("input")!.value).toBe(rawPath);
    expect(host.querySelector("pre")!.textContent).toBe(rawBody);
  });

  it("preserves added and removed code lines even when they equal controlled labels or headers", async () => {
    const current = "--- 历史版本\n+++ 当前稿\n关闭\n{source}";
    service.getDraftVersion.mockResolvedValue({ ...versionDetail(), text: "恢复所选版本\n--- 历史版本\n+++ 当前稿\n{path}" });
    await render("en-US", { document: documentFor("doc-a", current), currentText: current });
    const diff = diffLines().join("\n");
    expect(diff).toContain(" --- 历史版本\n +++ 当前稿"); expect(diff).toContain("-恢复所选版本"); expect(diff).toContain("+关闭"); expect(diff).toContain("+{source}"); expect(diff).toContain("-{path}");
    const bodyLines = diffLines(); const before = calls();
    await render(); expect(diffLines()).toEqual(bodyLines); expect(calls()).toEqual(before);
  });

  it("relocalizes the structured truncated diff without rereading detail", async () => {
    const body = Array.from({ length: 401 }, () => "--- 历史版本").join("\n");
    await render("zh-CN", { document: documentFor("doc-a", body), currentText: body });
    const before = calls(); expect(host.textContent).toContain("文稿超出比较上限，已仅显示统计信息。");
    await render("en-US"); expect(host.querySelector("pre")!.textContent).toBe("The document exceeds the comparison limit. Only statistics are shown."); expect(host.textContent).toContain("Truncated"); expect(calls()).toEqual(before);
  });

  it.each(["关闭", "无法读取版本历史。", "{message} {path}", ""])("never translates a raw gateway message %j", async (message) => {
    service.listDraftVersions.mockRejectedValue(new Error(message));
    await render("en-US"); expect(host.querySelector('[role="alert"]')?.textContent ?? "").toBe(message);
    await render(); expect(host.querySelector('[role="alert"]')?.textContent ?? "").toBe(message);
    expect(service.listDraftVersions).toHaveBeenCalledTimes(1);
    if (!message) expect(host.querySelector('[role="alert"]')).toBeNull();
  });

  it.each([
    ["listDraftVersions", "无法读取版本历史。", "Unable to read revision history.", false],
    ["getDraftVersion", "无法读取该版本。", "Unable to read this version.", false],
    ["listRecycledDrafts", "无法读取回收站。", "Unable to read the recycle bin.", true],
    ["getRecycledDraft", "无法读取回收条目。", "Unable to read this recycle entry.", true],
  ] as const)("relocalizes controlled fallback for %s without retrying", async (method, zh, en, inRecycle) => {
    service[method].mockRejectedValue(null);
    if (inRecycle) await recycle("zh-CN"); else await render();
    expect(host.querySelector('[role="alert"]')!.textContent).toBe(zh); const before = calls();
    await render("en-US"); expect(host.querySelector('[role="alert"]')!.textContent).toBe(en);
    await render(); expect(host.querySelector('[role="alert"]')!.textContent).toBe(zh); expect(calls()).toEqual(before);
  });

  it("translates all empty repository/document/list branches", async () => {
    await render("en-US", { repository: null }); expect(host.textContent).toContain("Select a repository to view protection records.");
    await click("Recycle bin"); expect(host.textContent).toContain("Select a repository to view the recycle bin.");
    await click("Revision history"); await render("en-US", { repository, document: null }); expect(host.textContent).toContain("Open a document to view versions");
    service.listDraftVersions.mockResolvedValue({ ...versionList(), versions: [] });
    service.listRecycledDrafts.mockResolvedValue({ entries: [], total: 0, truncated: false });
    await render("en-US", { document: documentFor() }); expect(host.textContent).toContain("This document has no available versions.");
    await click("Recycle bin"); expect(host.textContent).toContain("The recycle bin is empty.");
  });
});

describe("DraftHistoryCenter localized lifecycle and operations", () => {
  it.each(["resolve", "reject"] as const)("retains pending version list across languages and ignores stale %s after document changes", async (outcome) => {
    const pending = deferred<DraftVersionSnapshot>(); service.listDraftVersions.mockReturnValueOnce(pending.promise).mockResolvedValue({ ...versionList(), versions: [] });
    await render(); await render("en-US"); expect(host.textContent).toContain("Reading revision history…"); await render(); expect(service.listDraftVersions).toHaveBeenCalledTimes(1);
    await render("en-US", { document: documentFor("doc-b") });
    if (outcome === "resolve") pending.resolve(versionList()); else pending.reject(new Error("stale list error")); await settle();
    expect(host.querySelectorAll('[role="option"]')).toHaveLength(0); expect(host.querySelector('[role="alert"]')).toBeNull(); expect(host.textContent).toContain("This document has no available versions.");
  });

  it.each(["resolve", "reject"] as const)("retains pending version detail then ignores stale %s after document changes", async (outcome) => {
    const pending = deferred<DraftVersion>(); service.getDraftVersion.mockReturnValueOnce(pending.promise);
    await render(); await render("en-US"); expect(host.textContent).toContain("Loading version comparison…"); expect(service.getDraftVersion).toHaveBeenCalledTimes(1);
    await render("en-US", { document: documentFor("doc-b") }); const before = calls();
    if (outcome === "resolve") pending.resolve({ ...versionDetail(), text: "STALE VERSION" }); else pending.reject(new Error("stale detail error")); await settle();
    expect(host.textContent).not.toContain("STALE VERSION"); expect(host.querySelector('[role="alert"]')).toBeNull(); expect(calls()).toEqual(before);
  });

  it.each(["list", "detail"] as const)("retains pending recycle %s then ignores stale response after repository changes", async (kind) => {
    const pendingList = deferred<RecycledDraftSnapshot>(); const pendingDetail = deferred<RecycledDraft>();
    if (kind === "list") service.listRecycledDrafts.mockReturnValueOnce(pendingList.promise); else service.getRecycledDraft.mockReturnValueOnce(pendingDetail.promise);
    await recycle("zh-CN"); const before = calls(); await render("en-US"); expect(host.textContent).toContain(kind === "list" ? "Reading recycle bin…" : "Reading recycled document…"); await render(); expect(calls()).toEqual(before);
    await render("en-US", { repository: { ...repository, sessionId: "session-b" } });
    if (kind === "list") pendingList.resolve({ entries: [{ ...recycleList().entries[0], relativePath: "STALE PATH" }], total: 1, truncated: true }); else pendingDetail.resolve({ ...recycleDetail(), text: "STALE BODY", relativePath: "STALE PATH" }); await settle();
    expect(host.textContent).not.toContain("STALE"); expect(host.querySelector("input")!.value).toBe(rawPath); expect(host.querySelector('[role="alert"]')).toBeNull();
  });

  it("uses current document SHA and selection, preserves receipt identity and relocalizes pending restore without duplicate calls", async () => {
    const pending = deferred<DocumentSnapshot>(); service.restoreDraftVersion.mockReturnValue(pending.promise);
    await render(); await choose(1);
    await render("en-US", { document: { ...props.document!, baselineSha256: "current-{sha}" } });
    await choose(1); await click("Restore selected version");
    expect(confirm).toHaveBeenCalledWith("Restore the selected version? The current saved content will be preserved as a version first.");
    expect(service.restoreDraftVersion).toHaveBeenCalledWith("session-a", "doc-a", "version-b", "current-{sha}");
    expect(host.textContent).toContain("Restoring version…"); await render(); expect(host.textContent).toContain("正在恢复版本…"); await render("en-US"); expect(service.restoreDraftVersion).toHaveBeenCalledTimes(1);
    expect(button("Restore selected version").disabled).toBe(true); expect(button("Close").disabled).toBe(true);
    await act(async () => host.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    expect(props.onClose).not.toHaveBeenCalled(); pending.resolve(restored); await settle();
    expect(props.onRestoreDocument).toHaveBeenCalledWith(restored, "version"); expect(vi.mocked(props.onRestoreDocument).mock.calls[0][0]).toBe(restored);
    expect(host.textContent).toContain("Selected version restored."); await render(); expect(host.textContent).toContain("已恢复所选版本。"); expect(service.restoreDraftVersion).toHaveBeenCalledTimes(1);
  });

  it.each(["version", "recycle"] as const)("does not execute cancelled %s restore", async (kind) => {
    confirm.mockReturnValue(false);
    if (kind === "version") { await render("en-US"); await click("Restore selected version"); } else { await recycle(); await click("Restore document"); }
    expect(service.restoreDraftVersion).not.toHaveBeenCalled(); expect(service.restoreRecycledDraft).not.toHaveBeenCalled(); expect(props.onRestoreDocument).not.toHaveBeenCalled();
  });

  it("uses exact brace paths and localized confirmation when restoring recycle receipt", async () => {
    const pending = deferred<DocumentSnapshot>(); service.restoreRecycledDraft.mockReturnValue(pending.promise);
    await recycle(); await choose(1); await editPath(" content/{source}-{path}.md "); await click("Restore document");
    expect(confirm).toHaveBeenCalledWith("Restore “content/{path}-{source}.md” to “content/{source}-{path}.md”?");
    expect(service.restoreRecycledDraft).toHaveBeenCalledWith("session-a", "recycle-b", "content/{source}-{path}.md");
    await render(); expect(host.textContent).toContain("正在恢复回收文章…"); expect(host.querySelector("input")!.disabled).toBe(true); pending.resolve(restored); await settle();
    expect(props.onRestoreDocument).toHaveBeenCalledWith(restored, "recycle"); expect(vi.mocked(props.onRestoreDocument).mock.calls[0][0]).toBe(restored);
    await render("en-US"); expect(host.textContent).toContain("Document restored from the recycle bin."); expect(service.restoreRecycledDraft).toHaveBeenCalledTimes(1);
  });

  it.each([
    ["restoreDraftVersion", "Restore selected version", "恢复版本失败，当前文章未被切换。", "Unable to restore the version. The current document was not switched.", false],
    ["restoreRecycledDraft", "Restore document", "恢复回收文章失败。", "Unable to restore the recycled document.", true],
    ["deleteRecycledDraft", "Permanently delete", "永久删除失败。", "Unable to permanently delete.", true],
  ] as const)("relocalizes controlled operation fallback for %s", async (method, action, zh, en, inRecycle) => {
    service[method].mockRejectedValue(undefined);
    if (inRecycle) await recycle(); else await render("en-US"); await click(action);
    expect(host.querySelector('[role="alert"]')!.textContent).toBe(en); const count = service[method].mock.calls.length; expect(host.querySelector('[aria-live="polite"]')!.textContent).toBe("");
    await render(); expect(host.querySelector('[role="alert"]')!.textContent).toBe(zh); expect(service[method]).toHaveBeenCalledTimes(count); expect(props.onRestoreDocument).not.toHaveBeenCalled();
  });

  it.each([[false, true, 1], [true, false, 2]] as const)("requires both permanent delete confirmations (%s/%s)", async (first, second, count) => {
    confirm.mockReturnValueOnce(first).mockReturnValueOnce(second); await recycle(); await choose(1); await click("Permanently delete");
    expect(confirm).toHaveBeenCalledTimes(count); expect(confirm.mock.calls[0][0]).toBe("Permanently delete “content/{path}-{source}.md”?"); expect(service.deleteRecycledDraft).not.toHaveBeenCalled();
  });

  it("keeps double-confirm delete busy close guards and localized pending/completed status", async () => {
    const pending = deferred<RecycledDraftSnapshot>(); service.deleteRecycledDraft.mockReturnValue(pending.promise);
    await recycle(); await choose(1); await click("Permanently delete");
    expect(confirm.mock.calls.map((call) => call[0])).toEqual(["Permanently delete “content/{path}-{source}.md”?", "This operation cannot be undone. Permanently delete?"]);
    expect(service.deleteRecycledDraft).toHaveBeenCalledWith("session-a", "recycle-b"); expect(host.querySelector('[role="dialog"]')!.getAttribute("aria-busy")).toBe("true"); expect([...host.querySelectorAll("button")].every((item) => item.disabled)).toBe(true);
    await act(async () => { host.querySelector('[role="presentation"]')!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })); host.querySelector('[role="dialog"]')!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })); });
    expect(props.onClose).not.toHaveBeenCalled(); await render(); expect(host.textContent).toContain("正在永久删除…"); await render("en-US"); expect(service.deleteRecycledDraft).toHaveBeenCalledTimes(1);
    service.listRecycledDrafts.mockResolvedValue({ entries: [], total: 0, truncated: false }); pending.resolve(recycleList()); await settle();
    expect(host.textContent).toContain("Recycle entry permanently deleted."); await render(); expect(host.textContent).toContain("已永久删除回收条目。"); expect(props.onRestoreDocument).not.toHaveBeenCalled(); await click("关闭"); expect(props.onClose).toHaveBeenCalledTimes(1);
  });

  it("retains raw delete rejection and clears busy so close remains available", async () => {
    service.deleteRecycledDraft.mockRejectedValue(new Error("永久删除失败。")); await recycle(); await click("Permanently delete");
    expect(host.querySelector('[role="alert"]')!.textContent).toBe("永久删除失败。"); expect(button("Close").disabled).toBe(false);
    await render(); expect(host.querySelector('[role="alert"]')!.textContent).toBe("永久删除失败。"); expect(service.deleteRecycledDraft).toHaveBeenCalledTimes(1);
  });

  it.each(["dirty", "readonly"] as const)("preserves %s restore gating and delete readonly policy", async (mode) => {
    await render("en-US", mode === "dirty" ? { currentText: "unsaved" } : { document: { ...props.document!, writable: false } });
    expect(button("Restore selected version").disabled).toBe(true); if (mode === "dirty") expect(host.textContent).toContain("The current document has unsaved changes.");
    await click("Recycle bin"); expect(button("Restore document").disabled).toBe(true); expect(host.querySelector("input")!.disabled).toBe(true); expect(button("Permanently delete").disabled).toBe(mode === "readonly");
    await render(); expect(button("恢复文章").disabled).toBe(true); expect(service.restoreDraftVersion).not.toHaveBeenCalled(); expect(service.restoreRecycledDraft).not.toHaveBeenCalled(); expect(service.deleteRecycledDraft).not.toHaveBeenCalled(); expect(confirm).not.toHaveBeenCalled();
  });
});
