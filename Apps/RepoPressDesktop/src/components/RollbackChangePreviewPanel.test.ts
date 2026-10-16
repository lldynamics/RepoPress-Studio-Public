import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type { RollbackChangePreviewGateway } from "../contracts/rollbackChangePreview";
import { RollbackChangePreviewPanel } from "./RollbackChangePreviewPanel";

const target = "a".repeat(40); const parent = "b".repeat(40); const obj = "c".repeat(40);
const entry: ReleaseLedgerEntry = { source: "gitPush", recordId: "push-1", revision: 4, operation: "push", branch: "main", targetBranch: null, expectedSha: target, remoteUrl: "https://example.test/repo.git", startedAtEpochMs: 1_000, checkedAtEpochMs: 2_000, status: "pushVerified" };
const file = (overrides: Record<string, unknown> = {}) => ({ path: "docs/a.md", action: "replace" as const, published: { mode: "100644", objectId: obj, byteSize: 10 }, restore: { mode: "100644", objectId: parent, byteSize: 11 }, verification: "verified" as const, issues: [], ...overrides });
const preview = (overrides: Record<string, unknown> = {}) => ({ sessionId: "session", recordId: "push-1", revision: 4, branch: "main", remoteUrl: entry.remoteUrl, expectedSha: target, parentSha: parent, status: "complete" as const, changes: [file()], omittedPaths: 0, blockers: [], warnings: [], summary: { visible: 1, deleteFiles: 0, restoreFiles: 0, replaceFiles: 1, unsupportedFiles: 0, verifiedFiles: 1 }, checkedAtEpochMs: 3_000, ...overrides });
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: RollbackChangePreviewGateway & { inspectRollbackChanges: ReturnType<typeof vi.fn> };
function render(props: Partial<React.ComponentProps<typeof RollbackChangePreviewPanel>> = {}) { root.render(createElement(RollbackChangePreviewPanel, { gateway, sessionId: "session", entry, enabled: true, ...props })); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement; }

describe("RollbackChangePreviewPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { inspectRollbackChanges: vi.fn(async () => preview()) }; });
  afterEach(() => { root.unmount(); host.remove(); });

  it("does not inspect until the explicit preview click and renders inverse metadata", async () => {
    await act(async () => { render(); }); expect(gateway.inspectRollbackChanges).not.toHaveBeenCalled();
    await act(async () => button("预览单提交逆向变更").click()); await settle();
    expect(gateway.inspectRollbackChanges).toHaveBeenCalledWith("session", "push-1", 4); expect(host.textContent).toContain("已发布（冻结提交）"); expect(host.textContent).toContain("替换"); expect(host.textContent).toContain("单个冻结提交相对父提交");
  });

  it("shows all supported directions and paginates at fifty rows", async () => {
    const changes = [file({ path: "delete", action: "delete", restore: null }), file({ path: "restore", action: "restore", published: null }), file({ path: "unsupported", action: "unsupported", published: { mode: "100644", objectId: obj, byteSize: null }, restore: { mode: "040000", objectId: parent, byteSize: null }, verification: "unsupported", issues: ["unsupportedType"] })];
    gateway.inspectRollbackChanges.mockResolvedValueOnce(preview({ status: "partial", changes, omittedPaths: 1, warnings: ["unsafePathsOmitted"], summary: { visible: 3, deleteFiles: 1, restoreFiles: 1, replaceFiles: 0, unsupportedFiles: 1, verifiedFiles: 2 } }));
    await act(async () => { render(); }); await act(async () => button("预览单提交逆向变更").click()); await settle(); expect(host.textContent).toContain("删除"); expect(host.textContent).toContain("恢复"); expect(host.textContent).toContain("不支持");
    const many = Array.from({ length: 51 }, (_, i) => file({ path: `f${i}` })); gateway.inspectRollbackChanges.mockResolvedValueOnce(preview({ changes: many, summary: { visible: 51, deleteFiles: 0, restoreFiles: 0, replaceFiles: 51, unsupportedFiles: 0, verifiedFiles: 51 } })); await act(async () => button("预览单提交逆向变更").click()); await settle(); expect(host.textContent).toContain("第 1/2 页"); await act(async () => [...host.querySelectorAll("button")].find((b) => b.textContent === "下一页")?.click()); expect(host.textContent).toContain("第 2/2 页");
  });

  it("rejects unsafe paths, duplicate paths, bad summaries and contradictory complete responses", async () => {
    for (const bad of ["../secret", "a//b", "a/.GIT/x", "CON.txt", "com1/x", "a./b", "a /b", "a< b", "LPT9.log/x"].map((path) => preview({ changes: [file({ path })] })).concat([preview({ changes: [file(), file()] }), preview({ summary: { visible: 2, deleteFiles: 0, restoreFiles: 0, replaceFiles: 2, unsupportedFiles: 0, verifiedFiles: 2 } }), preview({ parentSha: null })])) {
      gateway.inspectRollbackChanges.mockResolvedValueOnce(bad); await act(async () => { render(); }); await act(async () => button("预览单提交逆向变更").click()); await settle(); expect(host.textContent).toContain("无法读取");
    }
  });

  it("accepts blocked responses with no parent and labels blockers", async () => {
    gateway.inspectRollbackChanges.mockResolvedValueOnce(preview({ status: "blocked", parentSha: null, changes: [], omittedPaths: null, blockers: ["rootCommit"], warnings: [], summary: { visible: 0, deleteFiles: 0, restoreFiles: 0, replaceFiles: 0, unsupportedFiles: 0, verifiedFiles: 0 } })); await act(async () => { render(); }); await act(async () => button("预览单提交逆向变更").click()); await settle(); expect(host.textContent).toContain("目标是根提交，缺少父提交");
  });

  it("rejects blocked responses with omissions, warnings, or remote blockers", async () => {
    for (const bad of [preview({ status: "blocked", parentSha: null, changes: [], omittedPaths: 1, blockers: ["rootCommit"], warnings: [] }), preview({ status: "blocked", parentSha: null, changes: [], omittedPaths: null, blockers: ["rootCommit"], warnings: ["objectsUnavailable"] }), preview({ status: "blocked", parentSha: null, changes: [], omittedPaths: null, blockers: ["remoteUnavailable"], warnings: [] })]) {
      gateway.inspectRollbackChanges.mockResolvedValueOnce(bad); await act(async () => { render(); }); await act(async () => button("预览单提交逆向变更").click()); await settle(); expect(host.textContent).toContain("无法读取");
    }
  });

  it("accepts an unsupported directory row while keeping it unverified", async () => {
    const directory = file({ path: "assets", action: "unsupported", published: { mode: "100644", objectId: obj, byteSize: null }, restore: { mode: "040000", objectId: parent, byteSize: null }, verification: "unsupported", issues: ["unsupportedType"] });
    gateway.inspectRollbackChanges.mockResolvedValueOnce(preview({ status: "partial", changes: [directory], omittedPaths: 0, warnings: ["unsupportedTypes"], summary: { visible: 1, deleteFiles: 0, restoreFiles: 0, replaceFiles: 0, unsupportedFiles: 1, verifiedFiles: 0 } })); await act(async () => { render(); }); await act(async () => button("预览单提交逆向变更").click()); await settle(); expect(host.textContent).toContain("目录"); expect(host.textContent).toContain("不支持");
  });

  it("rejects partial blockers and malformed or unverifiable sides", async () => {
    const invalid = [
      preview({ status: "partial", blockers: ["rootCommit"], warnings: ["objectsUnavailable"], omittedPaths: 1 }),
      preview({ changes: [file({ published: { mode: "999999", objectId: obj, byteSize: 1 } })] }),
      preview({ changes: [file({ published: { mode: "100644", objectId: obj, byteSize: null } })] }),
      preview({ changes: [file({ action: "unsupported", published: null, restore: null, verification: "unsupported", issues: ["unsupportedType"] })], status: "partial", omittedPaths: 1, warnings: ["unsupportedTypes"], summary: { visible: 1, deleteFiles: 0, restoreFiles: 0, replaceFiles: 0, unsupportedFiles: 1, verifiedFiles: 0 } }),
      preview({ changes: [file({ verification: "unavailable", issues: [] })] }),
    ];
    for (const bad of invalid) { gateway.inspectRollbackChanges.mockResolvedValueOnce(bad); await act(async () => { render(); }); await act(async () => button("预览单提交逆向变更").click()); await settle(); expect(host.textContent).toContain("无法读取"); }
  });

  it("invalidates in-flight results when identity or enabled state changes", async () => {
    let resolve!: (value: ReturnType<typeof preview>) => void; gateway.inspectRollbackChanges.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await act(async () => { render(); }); await act(async () => button("预览单提交逆向变更").click()); await act(async () => { render({ sessionId: "other" }); }); resolve(preview()); await settle(); expect(host.textContent).not.toContain("冻结 SHA"); await act(async () => { render({ sessionId: "session", disabled: true }); }); expect(button("预览单提交逆向变更").disabled).toBe(true);
  });
});
