import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { WorkspaceConfigBackupGateway, WorkspaceConfigBackupPlan, WorkspaceConfigBackupResult } from "../contracts/workspaceConfigBackup";
import { WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES, WORKSPACE_CONFIG_BACKUP_SOURCES } from "../contracts/workspaceConfigBackup";
import { WORKSPACE_BACKUP_EXCLUSIONS } from "../contracts/workspaceBackup";
import { WorkspaceConfigBackupPanel } from "./WorkspaceConfigBackupPanel";

const clock = Date.now(); const destinationPath = "/tmp/repopress-workspace-config.json";
const makePlan = (overrides: Partial<WorkspaceConfigBackupPlan> = {}): WorkspaceConfigBackupPlan => ({
  planId: "11111111-1111-4111-8111-111111111111", scope: "applicationPrivateConfiguration", format: "repopress-workspace-config", schemaVersion: 1,
  destinationPath, selectedSources: [...WORKSPACE_CONFIG_BACKUP_SOURCES], sources: WORKSPACE_CONFIG_BACKUP_SOURCES.map((source) => ({ source, sourceByteSize: 100, itemCount: source === "workspace" ? 1 : 2, recoveryDraftCount: 0 as const })),
  excludedSources: [...WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES], exclusions: [...WORKSPACE_BACKUP_EXCLUSIONS], structureVerified: true, consistentSnapshot: false, includesCredentials: false,
  byteSize: 800, sha256: "a".repeat(64), createdAtEpochMs: clock, expiresAtEpochMs: clock + 300_000, ...overrides,
});
const result: WorkspaceConfigBackupResult = { planId: makePlan().planId, destinationPath, selectedSources: [...WORKSPACE_CONFIG_BACKUP_SOURCES], byteSize: 800, sha256: "a".repeat(64) };
type Gateway = { [K in keyof WorkspaceConfigBackupGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: Gateway;
async function render(props: Partial<React.ComponentProps<typeof WorkspaceConfigBackupPanel>> = {}) { await act(async () => root.render(createElement(WorkspaceConfigBackupPanel, { gateway: gateway as unknown as WorkspaceConfigBackupGateway, enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function selectAllSources() { await settle(); for (const input of [...host.querySelectorAll('input[type="checkbox"]')] as HTMLInputElement[]) if (!input.checked) await act(async () => input.click()); await settle(); }
async function inspect() { const action = button(/检查|预览|计划/); expect(action).toBeDefined(); await act(async () => action!.click()); await settle(); await settle(); }
async function chooseAndInspect() { const choose = button(/选择.*JSON|目的地/); expect(choose).toBeDefined(); await act(async () => choose!.click()); await settle(); await inspect(); }

describe("WorkspaceConfigBackupPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(clock); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { selectWorkspaceConfigBackupDestination: vi.fn(async () => destinationPath), planWorkspaceConfigBackup: vi.fn(async () => makePlan()), executeWorkspaceConfigBackup: vi.fn(async () => result), discardWorkspaceConfigBackup: vi.fn(async () => undefined) } as unknown as Gateway; });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("defaults to workspace, performs no automatic read, and sends the exact sorted selected scope only after explicit preview", async () => {
    await render(); await settle();
    expect(gateway.selectWorkspaceConfigBackupDestination).not.toHaveBeenCalled(); expect(gateway.planWorkspaceConfigBackup).not.toHaveBeenCalled(); expect(gateway.executeWorkspaceConfigBackup).not.toHaveBeenCalled();
    await selectAllSources(); await chooseAndInspect();
    expect(gateway.planWorkspaceConfigBackup).toHaveBeenCalledWith([...WORKSPACE_CONFIG_BACKUP_SOURCES], destinationPath);
    expect(host.textContent).toContain("明文"); expect(host.textContent).toContain("凭据独立排除"); expect(host.textContent).not.toContain("已导出");
    expect(host.textContent).toContain("知识库正文"); expect(host.textContent).toContain("RSS 正文"); expect(host.textContent).toContain("普通草稿正文"); expect(host.textContent).toContain("草稿历史正文");
  });

  it("requires explicit destination selection and plaintext consent before execute", async () => {
    await render(); await selectAllSources();
    const choose = button(/选择|目的地/); expect(choose).toBeDefined(); await act(async () => choose!.click()); await settle();
    await inspect(); expect(gateway.selectWorkspaceConfigBackupDestination).toHaveBeenCalledTimes(1); expect(gateway.executeWorkspaceConfigBackup).not.toHaveBeenCalled();
    const execute = button(/导出|执行|确认/); if (execute) expect(execute.disabled).toBe(true);
    const consent = host.querySelector('#workspace-config-backup-consent:checked'); expect(consent).toBeNull();
  });

  it.each([
    ["scope", { scope: "wrong" as never }], ["format", { format: "json" as never }], ["source", { selectedSources: ["aiProfiles", "workspace"] as never }],
    ["count", { sources: [{ ...makePlan().sources[0], itemCount: -1 }, ...makePlan().sources.slice(1)] }], ["zero source bytes", { sources: [{ ...makePlan().sources[0], sourceByteSize: 0 }, ...makePlan().sources.slice(1)] }], ["flags", { structureVerified: false, includesCredentials: true }],
    ["time", { createdAtEpochMs: clock + 1_000_000, expiresAtEpochMs: clock + 1_300_000 }], ["exclusions", { exclusions: [] }],
  ])("rejects malformed %s plans without execute", async (_name, invalid) => {
    gateway.planWorkspaceConfigBackup.mockResolvedValueOnce(makePlan(invalid as Partial<WorkspaceConfigBackupPlan>));
    await render(); await selectAllSources(); await chooseAndInspect();
    expect(host.textContent).toMatch(/无法|失败|无效/); expect(gateway.executeWorkspaceConfigBackup).not.toHaveBeenCalled();
  });

  it("cancels save without planning and discards on refresh/session/selection invalidation", async () => {
    gateway.selectWorkspaceConfigBackupDestination.mockResolvedValueOnce(null);
    await render(); await selectAllSources(); const choose = button(/选择|目的地/); await act(async () => choose!.click()); await settle();
    expect(gateway.planWorkspaceConfigBackup).not.toHaveBeenCalled();
    gateway.selectWorkspaceConfigBackupDestination.mockResolvedValueOnce(destinationPath); await act(async () => choose!.click()); await settle(); await inspect();
    await render({ refreshKey: 1 }); await settle(); expect(gateway.discardWorkspaceConfigBackup).toHaveBeenCalledWith(makePlan().planId);
  });

  it("expires before execute and consumes a failed export token without retry", async () => {
    gateway.executeWorkspaceConfigBackup.mockRejectedValueOnce(new Error("write failed"));
    await render(); await selectAllSources(); const choose = button(/选择|目的地/); await act(async () => choose!.click()); await settle(); await inspect();
    await act(async () => { vi.advanceTimersByTime(300_001); }); await settle();
    expect(gateway.executeWorkspaceConfigBackup).not.toHaveBeenCalled();
  });

  it("consumes a failed export exactly once", async () => {
    gateway.executeWorkspaceConfigBackup.mockRejectedValueOnce(new Error("write failed"));
    await render(); await selectAllSources(); await chooseAndInspect();
    const consent = host.querySelector("#workspace-config-backup-consent") as HTMLInputElement; await act(async () => consent.click());
    const execute = button(/明确一次性导出/); expect(execute).toBeDefined(); await act(async () => execute!.click()); await settle(); await settle();
    expect(gateway.executeWorkspaceConfigBackup).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("不会自动重试");
  });

  it("discards a late preview when refresh or enabled context changes", async () => {
    let resolvePlan!: (value: WorkspaceConfigBackupPlan) => void;
    gateway.planWorkspaceConfigBackup.mockImplementationOnce(() => new Promise((resolve) => { resolvePlan = resolve; }));
    await render(); await selectAllSources();
    const choose = button(/选择.*JSON|目的地/); await act(async () => choose!.click()); await settle();
    const preview = button(/明确预览/); await act(async () => preview!.click());
    await render({ refreshKey: 1 }); resolvePlan(makePlan()); await settle();
    expect(gateway.discardWorkspaceConfigBackup).toHaveBeenCalledWith(makePlan().planId);

    gateway.planWorkspaceConfigBackup.mockResolvedValueOnce(makePlan());
    await render({ refreshKey: 2 }); await selectAllSources(); await chooseAndInspect();
    await render({ disabled: true }); await settle();
    expect(gateway.discardWorkspaceConfigBackup).toHaveBeenCalledWith(makePlan().planId);
  });

  it("rejects a result whose selected scope or digest does not match the approved plan", async () => {
    gateway.executeWorkspaceConfigBackup.mockResolvedValueOnce({ ...result, selectedSources: undefined as never, sha256: "b".repeat(64) });
    await render(); await selectAllSources(); await chooseAndInspect();
    const consent = host.querySelector("#workspace-config-backup-consent") as HTMLInputElement; await act(async () => consent.click());
    const execute = button(/明确一次性导出/); await act(async () => execute!.click()); await settle(); await settle();
    expect(host.textContent).toContain("结果未明"); expect(host.textContent).not.toContain("已导出并核验");
  });

  it("cannot export an approved plan after its source scope is cancelled, even before the DOM rerender", async () => {
    await render(); await selectAllSources(); await chooseAndInspect();
    const consent = host.querySelector("#workspace-config-backup-consent") as HTMLInputElement; await act(async () => consent.click());
    const execute = button(/明确一次性导出/); const workspace = [...host.querySelectorAll('input[type="checkbox"]')].find((input) => !(input as HTMLInputElement).id) as HTMLInputElement;
    expect(execute).toBeDefined(); expect(workspace).toBeDefined();
    await act(async () => { workspace.click(); execute!.click(); }); await settle();
    expect(gateway.executeWorkspaceConfigBackup).not.toHaveBeenCalled();
  });

  it("discards a late plan through its original gateway when the gateway context changes", async () => {
    const oldGateway = gateway;
    let resolvePlan!: (value: WorkspaceConfigBackupPlan) => void;
    oldGateway.planWorkspaceConfigBackup.mockImplementationOnce(() => new Promise((resolve) => { resolvePlan = resolve; }));
    await render(); await selectAllSources(); const choose = button(/选择.*JSON|目的地/); await act(async () => choose!.click()); await settle();
    const preview = button(/明确预览/); await act(async () => preview!.click());
    gateway = { selectWorkspaceConfigBackupDestination: vi.fn(async () => destinationPath), planWorkspaceConfigBackup: vi.fn(), executeWorkspaceConfigBackup: vi.fn(), discardWorkspaceConfigBackup: vi.fn(async () => undefined) } as unknown as Gateway;
    await render({ refreshKey: 1 }); resolvePlan(makePlan()); await settle();
    expect(oldGateway.discardWorkspaceConfigBackup).toHaveBeenCalledWith(makePlan().planId);
    expect(gateway.executeWorkspaceConfigBackup).not.toHaveBeenCalled();
  });
});
