import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { DraftVersionSnapshot, RecycledDraftSnapshot, RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import { DraftHistoryCenter, type DraftHistoryCenterProps } from "./DraftHistoryCenter";

let root: Root | null = null;
let container: HTMLDivElement | null = null;
(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const repository: RepositorySessionSnapshot = { sessionId: "session-a", rootPath: "/repo", displayName: "测试仓库", siteKind: "zola", contentRoot: "content", isGitRepository: true, warnings: [] };
const documentFor = (id = "document-a", text = "# 当前稿") => ({ documentId: id, relativePath: `content/${id}.md`, text, encoding: "utf-8", lineEnding: "lf" as const, byteSize: text.length, baselineSha256: `sha-${id}`, revision: 1, writable: true, readOnlyReason: null });
const versions = (documentId = "document-a"): DraftVersionSnapshot => ({ documentId, relativePath: `content/${documentId}.md`, versions: [{ versionId: "version-a", relativePath: `content/${documentId}.md`, reason: "beforeSave", createdAtEpochSeconds: 2, byteSize: 8, contentSha256: "version-sha" }] });
const recycled = (): RecycledDraftSnapshot => ({ entries: [{ recycleId: "recycle-a", relativePath: "content/deleted.md", deletedAtEpochSeconds: 2, byteSize: 8, contentSha256: "recycle-sha" }], total: 1, truncated: false });

function gateway(overrides: Partial<RepositoryGateway> = {}): RepositoryGateway {
  return {
    listDraftVersions: vi.fn().mockResolvedValue(versions()),
    getDraftVersion: vi.fn().mockResolvedValue({ ...versions().versions[0], text: "# 历史稿" }),
    restoreDraftVersion: vi.fn().mockResolvedValue(documentFor("document-a", "# 历史稿")),
    listRecycledDrafts: vi.fn().mockResolvedValue(recycled()),
    getRecycledDraft: vi.fn().mockResolvedValue({ ...recycled().entries[0], text: "# 回收稿" }),
    restoreRecycledDraft: vi.fn().mockResolvedValue(documentFor("restored", "# 回收稿")),
    deleteRecycledDraft: vi.fn().mockResolvedValue({ entries: [], total: 0, truncated: false }),
    ...overrides,
  } as RepositoryGateway;
}

function mount(overrides: Partial<DraftHistoryCenterProps> = {}) {
  container = document.createElement("div"); document.body.append(container); root = createRoot(container);
  const props: DraftHistoryCenterProps = { open: true, onClose: vi.fn(), gateway: gateway(), repository, document: documentFor(), currentText: "# 当前稿", onRestoreDocument: vi.fn(), ...overrides };
  act(() => root?.render(createElement(DraftHistoryCenter, props)));
  return props;
}

async function flush() { await act(async () => { await new Promise((resolve) => window.setTimeout(resolve, 0)); }); }
function button(text: string): HTMLButtonElement { const value = [...container!.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent?.includes(text)); if (!value) throw new Error(`missing button: ${text}`); return value; }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((next) => { resolve = next; }); return { promise, resolve }; }

beforeAll(() => { vi.stubGlobal("requestAnimationFrame", (callback: FrameRequestCallback) => { callback(0); return 1; }); });
afterEach(() => { if (root) act(() => root?.unmount()); root = null; container?.remove(); container = null; vi.unstubAllGlobals(); });

describe("DraftHistoryCenter", () => {
  it("does not allow a stale version-list response to replace a changed document", async () => {
    const first = deferred<DraftVersionSnapshot>();
    const service = gateway({ listDraftVersions: vi.fn().mockReturnValueOnce(first.promise).mockResolvedValueOnce({ documentId: "document-b", relativePath: "content/document-b.md", versions: [] }) });
    const props = mount({ gateway: service }); await flush();
    await act(async () => { root?.render(createElement(DraftHistoryCenter, { ...props, document: documentFor("document-b") })); await Promise.resolve(); });
    first.resolve(versions()); await flush();
    expect(container?.textContent).toContain("尚无可用版本");
    expect(container?.querySelectorAll('[role="option"]')).toHaveLength(0);
  });

  it("shows a clear empty state when no current document is open", async () => {
    mount({ document: null }); await flush();
    expect(container?.textContent).toContain("打开一篇文章后");
  });

  it("does not restore when confirmation is cancelled", async () => {
    const service = gateway(); mount({ gateway: service }); await flush(); await flush();
    vi.stubGlobal("confirm", vi.fn().mockReturnValue(false));
    await act(async () => { button("恢复所选版本").click(); await Promise.resolve(); });
    expect(service.restoreDraftVersion).not.toHaveBeenCalled();
  });

  it("restores a confirmed version and reports it to the owner", async () => {
    const service = gateway(); const onRestoreDocument = vi.fn(); mount({ gateway: service, onRestoreDocument }); await flush(); await flush();
    vi.stubGlobal("confirm", vi.fn().mockReturnValue(true));
    await act(async () => { button("恢复所选版本").click(); await new Promise((resolve) => window.setTimeout(resolve, 0)); });
    expect(service.restoreDraftVersion).toHaveBeenCalledWith("session-a", "document-a", "version-a", "sha-document-a");
    expect(onRestoreDocument).toHaveBeenCalledWith(expect.objectContaining({ documentId: "document-a" }), "version");
    expect(container?.textContent).toContain("已恢复所选版本");
  });

  it("keeps the dialog open and announces a failed restore", async () => {
    const service = gateway({ restoreDraftVersion: vi.fn().mockRejectedValue(new Error("磁盘已变化")) }); mount({ gateway: service }); await flush(); await flush();
    vi.stubGlobal("confirm", vi.fn().mockReturnValue(true));
    await act(async () => { button("恢复所选版本").click(); await new Promise((resolve) => window.setTimeout(resolve, 0)); });
    expect(container?.querySelector('[role="dialog"]')).toBeTruthy();
    expect(container?.querySelector('[role="alert"]')?.textContent).toContain("磁盘已变化");
  });

  it("edits the recovery path before restoring a recycled article", async () => {
    const service = gateway(); mount({ gateway: service, document: null }); await flush();
    await act(async () => { button("回收站").click(); await Promise.resolve(); }); await flush(); await flush();
    const input = container!.querySelector<HTMLInputElement>("input"); expect(input).toBeTruthy();
    await act(async () => {
      const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
      setValue?.call(input, "content/restored.md");
      input!.dispatchEvent(new Event("input", { bubbles: true }));
    });
    vi.stubGlobal("confirm", vi.fn().mockReturnValue(true));
    await act(async () => { button("恢复文章").click(); await new Promise((resolve) => window.setTimeout(resolve, 0)); });
    expect(service.restoreRecycledDraft).toHaveBeenCalledWith("session-a", "recycle-a", "content/restored.md");
  });

  it("disables every restore action while the current editor buffer is dirty", async () => {
    mount({ currentText: "# 尚未保存" }); await flush(); await flush();
    expect(button("恢复所选版本").disabled).toBe(true);
    await act(async () => { button("回收站").click(); await Promise.resolve(); }); await flush(); await flush();
    expect(button("恢复文章").disabled).toBe(true);
  });
});
