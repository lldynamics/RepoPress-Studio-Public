import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { WorkspaceBackupGateway, WorkspaceBackupRecheck, WorkspaceBackupReport } from "../contracts/workspaceBackup";
import { WORKSPACE_BACKUP_EXCLUSIONS, WORKSPACE_BACKUP_SOURCES } from "../contracts/workspaceBackup";
import { WorkspaceBackupPreflightPanel } from "./WorkspaceBackupPreflightPanel";

const report: WorkspaceBackupReport = {
  reportId: "11111111-1111-4111-8111-111111111111", schemaVersion: 1, scope: "applicationPrivateData", checkedAtEpochMs: 1_700_000_000_000,
  expiresAtEpochMs: 1_700_000_300_000, selectedSources: [...WORKSPACE_BACKUP_SOURCES],
  sources: [
    { source: "knowledge", status: "metadataOnly", fileCount: 2, byteCount: 100, omittedEntries: 0, issues: [], requiresDatabaseSnapshot: false },
    { source: "rss", status: "notFound", fileCount: 0, byteCount: 0, omittedEntries: 0, issues: [], requiresDatabaseSnapshot: true },
    { source: "generalDrafts", status: "unavailable", fileCount: null, byteCount: null, omittedEntries: null, issues: ["storageUnavailable"], requiresDatabaseSnapshot: true },
    { source: "draftHistory", status: "limited", fileCount: 1, byteCount: 200, omittedEntries: 3, issues: ["entryLimit"], requiresDatabaseSnapshot: true },
    ...WORKSPACE_BACKUP_SOURCES.slice(4).map((source) => ({ source, status: "metadataOnly" as const, fileCount: 1, byteCount: 10, omittedEntries: 0, issues: [], requiresDatabaseSnapshot: false })),
  ],
  exclusions: [...WORKSPACE_BACKUP_EXCLUSIONS], contentVerified: false, consistentSnapshot: false,
};
const completeReport: WorkspaceBackupReport = { ...report, sources: report.sources.map((item) => ({ ...item, status: "metadataOnly" as const, fileCount: 1, byteCount: 10, omittedEntries: 0, issues: [] })) };
const recheck = (comparison: WorkspaceBackupRecheck["comparison"], base: WorkspaceBackupReport = completeReport): WorkspaceBackupRecheck => { const checkedAtEpochMs = Date.now(); return { report: { ...base, reportId: "22222222-2222-4222-8222-222222222222", checkedAtEpochMs, expiresAtEpochMs: checkedAtEpochMs + 300_000 }, comparison }; };
type Gateway = { [K in keyof WorkspaceBackupGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: Gateway;
async function render(props: Partial<React.ComponentProps<typeof WorkspaceBackupPreflightPanel>> = {}) { await act(async () => root.render(createElement(WorkspaceBackupPreflightPanel, { gateway: gateway as unknown as WorkspaceBackupGateway, enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function inspect() { await settle(); const action = button(/检查|扫描|预检/); expect(action).toBeDefined(); await act(async () => action!.click()); await settle(); await settle(); }

describe("WorkspaceBackupPreflightPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(report.checkedAtEpochMs); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { inspectWorkspaceBackup: vi.fn(async () => report), recheckWorkspaceBackup: vi.fn(async () => recheck("unchanged")), discardWorkspaceBackup: vi.fn(async () => undefined) } as unknown as Gateway; });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("does not inspect automatically, sends the exact selected seven-source scope, and shows metadata-only limits", async () => {
    await render(); await settle();
    expect(gateway.inspectWorkspaceBackup).not.toHaveBeenCalled(); expect(gateway.recheckWorkspaceBackup).not.toHaveBeenCalled(); expect(gateway.discardWorkspaceBackup).not.toHaveBeenCalled();
    await inspect();
    expect(gateway.inspectWorkspaceBackup).toHaveBeenCalledWith([...WORKSPACE_BACKUP_SOURCES]);
    expect(host.textContent).toContain("3"); expect(host.textContent).toContain("不可用"); expect(host.textContent).toContain("元数据");
    expect(host.textContent).toContain("不验证内容"); expect(host.textContent).not.toContain("备份成功");
    expect(host.textContent).toContain("凭据（Secret Service"); expect(host.textContent).toContain("加密聊天内容"); expect(host.textContent).toContain("仓库文件");
    expect(host.textContent).toContain("可能包含正文、URL 和路径");
  });

  it.each([
    ["bad flag", { ...report, contentVerified: true }], ["bad source", { ...report, selectedSources: ["unknown"] as never }],
    ["duplicate source", { ...report, selectedSources: ["knowledge", "knowledge"] as never }], ["bad count", { ...report, sources: [{ ...report.sources[0], fileCount: 2049 }, ...report.sources.slice(1)] }], ["bad omitted count", { ...report, sources: [report.sources[0], report.sources[1], report.sources[2], { ...report.sources[3], omittedEntries: 2050 }, ...report.sources.slice(4)] }],
    ["aggregate file count", { ...report, sources: report.sources.map((item) => item.status === "metadataOnly" ? { ...item, fileCount: 2048 } : item) }], ["aggregate byte count", { ...report, sources: report.sources.map((item) => item.status === "metadataOnly" ? { ...item, byteCount: 2 * 1024 * 1024 * 1024 } : item) }],
    ["unsafe time", { ...report, checkedAtEpochMs: 0 }], ["missing exclusions", { ...report, exclusions: [] }],
  ])("rejects malformed %s reports without healthy fallback", async (_name, invalid) => {
    gateway.inspectWorkspaceBackup.mockResolvedValueOnce(invalid);
    await render(); await inspect();
    expect(host.textContent).toMatch(/无法|失败|无效/); expect(host.textContent).not.toContain("检查完成");
  });

  it("accepts the 2049 omitted-entry sentinel when the limited source has no enumerated files", async () => {
    const sentinel: WorkspaceBackupReport = { ...report, sources: report.sources.map((item) => item.source === "draftHistory" ? { ...item, status: "limited" as const, fileCount: 0, byteCount: 0, omittedEntries: 2049, issues: ["entryLimit"] } : item) };
    gateway.inspectWorkspaceBackup.mockResolvedValueOnce(sentinel);
    await render(); await inspect();
    expect(host.textContent).toContain("2,049"); expect(host.textContent).toContain("条目数量达到上限");
  });

  it.each([["unchanged", "未变化"], ["changed", "已变化"], ["inconclusive", "无法确定"]] as const)("renders literal %s recheck status and uses one explicit call", async (comparison, label) => {
    gateway.inspectWorkspaceBackup.mockResolvedValueOnce(comparison === "inconclusive" ? report : completeReport);
    gateway.recheckWorkspaceBackup.mockResolvedValueOnce(recheck(comparison));
    await render(); await inspect();
    const action = button(/重新检查|复核|再次/); expect(action).toBeDefined(); await act(async () => action!.click()); await settle(); await settle();
    expect(gateway.recheckWorkspaceBackup).toHaveBeenCalledWith(report.reportId); expect(host.textContent).toContain(label);
  });

  it("rejects stale recheck results and expires/reset reports without empty or healthy fallback", async () => {
    let resolve!: (value: WorkspaceBackupRecheck) => void;
    gateway.recheckWorkspaceBackup.mockImplementationOnce(() => new Promise((r) => { resolve = r; }));
    gateway.inspectWorkspaceBackup.mockResolvedValueOnce(completeReport);
    await render(); await inspect();
    const action = button(/重新检查|复核|再次/); await act(async () => action!.click());
    await render({ refreshKey: 1 }); resolve(recheck("changed")); await settle();
    expect(host.textContent).not.toContain("已变化");
    await render(); await inspect(); await act(async () => { vi.advanceTimersByTime(300_001); }); await settle();
    expect(host.textContent).toMatch(/过期|重新/);
  });

  it("does not issue a recheck after a clock jump expires the report before timer delivery", async () => {
    await render(); await inspect();
    await act(async () => { vi.setSystemTime(report.expiresAtEpochMs + 1); });
    const action = button(/重新检查|复核|再次/); expect(action).toBeDefined(); await act(async () => action!.click()); await settle();
    expect(gateway.recheckWorkspaceBackup).not.toHaveBeenCalled();
    expect(host.textContent).toMatch(/过期|重新/);
  });

  it("forces unavailable-only old or new reports to inconclusive", async () => {
    const unavailable: WorkspaceBackupReport = { ...completeReport, sources: completeReport.sources.map((item) => item.source === "generalDrafts" ? { ...item, status: "unavailable" as const, fileCount: null, byteCount: null, omittedEntries: null, issues: ["storageUnavailable"] as const } : item) };
    gateway.inspectWorkspaceBackup.mockResolvedValueOnce(unavailable);
    gateway.recheckWorkspaceBackup.mockResolvedValueOnce(recheck("changed", completeReport));
    await render(); await inspect();
    const action = button(/重新检查|复核|再次/); await act(async () => action!.click()); await settle(); await settle();
    expect(gateway.recheckWorkspaceBackup).toHaveBeenCalledWith(unavailable.reportId);
    expect(host.textContent).toContain("无法确定");
  });
});
