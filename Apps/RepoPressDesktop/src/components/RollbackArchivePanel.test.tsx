import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RollbackArchiveGateway, RollbackArchivePlan, RollbackArchiveResult } from "../contracts/rollbackArchive";
import { RollbackArchivePanel } from "./RollbackArchivePanel";

const plan: RollbackArchivePlan = {
  planId: "11111111-1111-4111-8111-111111111111", sessionId: "session-1", repositoryPath: "/repo",
  destinationPath: "/tmp/repopress-rollback-evidence.json", schemaVersion: 1, recordCount: 2,
  unresolvedCount: 1, historicalObservationCount: 1, byteSize: 4096, sha256: "a".repeat(64),
  createdAtEpochMs: 1_700_000_000_000, expiresAtEpochMs: 1_700_000_300_000,
};
const result: RollbackArchiveResult = { planId: plan.planId, sessionId: plan.sessionId, destinationPath: plan.destinationPath, recordCount: 2, byteSize: 4096, sha256: plan.sha256 };
type Gateway = { [K in keyof RollbackArchiveGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: Gateway;
async function render(props: Partial<React.ComponentProps<typeof RollbackArchivePanel>> = {}) { await act(async () => root.render(createElement(RollbackArchivePanel, { gateway: gateway as unknown as RollbackArchiveGateway, sessionId: "session-1", enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function prepare() {
  await settle();
  const choose = button(/选择|目标/); if (choose) await act(async () => choose.click());
  await settle();
  const planButton = button(/计划|预览|生成/); if (planButton) await act(async () => planButton.click());
  await settle(); await settle();
}
async function consentAndExecute() {
  const checkbox = host.querySelector('input[type="checkbox"]') as HTMLInputElement | null;
  if (checkbox) await act(async () => { checkbox.click(); });
  const execute = button(/执行|导出|确认/); if (execute) await act(async () => execute.click());
  await settle(); await settle();
}

describe("RollbackArchivePanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    vi.useFakeTimers(); vi.setSystemTime(plan.createdAtEpochMs); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = { selectRollbackArchiveDestination: vi.fn(async () => plan.destinationPath), planRollbackArchive: vi.fn(async () => plan), executeRollbackArchive: vi.fn(async () => result), discardRollbackArchive: vi.fn(async () => undefined) } as unknown as Gateway;
  });
  afterEach(() => { root.unmount(); host.remove(); vi.useRealTimers(); });

  it("requires an explicit destination, preview, plaintext privacy consent, and execution", async () => {
    await render(); await settle();
    expect(gateway.selectRollbackArchiveDestination).not.toHaveBeenCalled(); expect(gateway.planRollbackArchive).not.toHaveBeenCalled(); expect(gateway.executeRollbackArchive).not.toHaveBeenCalled();
    await prepare();
    expect(gateway.selectRollbackArchiveDestination).toHaveBeenCalledTimes(1); expect(gateway.planRollbackArchive).toHaveBeenCalledWith("session-1", plan.destinationPath); expect(gateway.executeRollbackArchive).not.toHaveBeenCalled();
    expect(host.textContent).toContain("明文");
    const executeBeforeConsent = button(/执行|导出|确认/); if (executeBeforeConsent) expect(executeBeforeConsent.disabled).toBe(true);
    await consentAndExecute();
    expect(gateway.executeRollbackArchive).toHaveBeenCalledWith("session-1", plan.planId); expect(host.textContent).toContain("导出");
  });

  it("cancels a preview without planning or writing and discards invalidated tokens", async () => {
    await render(); await prepare();
    const cancel = button(/取消/); expect(cancel).toBeDefined(); await act(async () => cancel!.click()); await settle();
    expect(gateway.executeRollbackArchive).not.toHaveBeenCalled(); expect(gateway.discardRollbackArchive).toHaveBeenCalledWith("session-1", plan.planId);
    await render({ refreshKey: 1 }); await settle();
    expect(host.textContent).not.toContain(plan.planId);
  });

  it("does not plan or export when the native destination dialog is cancelled", async () => {
    gateway.selectRollbackArchiveDestination.mockResolvedValueOnce(null);
    await render(); await prepare();
    expect(gateway.selectRollbackArchiveDestination).toHaveBeenCalledTimes(1);
    expect(gateway.planRollbackArchive).not.toHaveBeenCalled();
    expect(gateway.executeRollbackArchive).not.toHaveBeenCalled();
  });

  it.each([
    ["bad UUID", { ...plan, planId: "bad" }],
    ["wrong session", { ...plan, sessionId: "other" }],
    ["relative repository", { ...plan, repositoryPath: "repo" }],
    ["wrong schema", { ...plan, schemaVersion: 2 as 1 }],
    ["bad digest", { ...plan, sha256: "G".repeat(64) }],
    ["bad counts", { ...plan, recordCount: 0 }],
    ["zero byte size", { ...plan, byteSize: 0 }],
    ["future created time", { ...plan, createdAtEpochMs: plan.createdAtEpochMs + 86_400_000, expiresAtEpochMs: plan.expiresAtEpochMs + 86_400_000 }],
    ["expired time", { ...plan, createdAtEpochMs: plan.createdAtEpochMs - 600_000, expiresAtEpochMs: plan.expiresAtEpochMs - 600_000 }],
  ])("rejects %s preview", async (_name, invalid) => {
    gateway.planRollbackArchive.mockResolvedValueOnce(invalid);
    await render(); await prepare();
    expect(host.textContent).toMatch(/无法|无效|失败/); expect(gateway.executeRollbackArchive).not.toHaveBeenCalled();
  });

  it("rejects a malformed execution result without clobbering the error state or retrying", async () => {
    gateway.executeRollbackArchive.mockResolvedValueOnce(null);
    await render(); await prepare(); await consentAndExecute();
    expect(host.textContent).toContain("未明");
    expect(host.textContent).not.toContain("已导出并核验");
    await render({ refreshKey: 4 }); await settle();
    expect(gateway.executeRollbackArchive).toHaveBeenCalledTimes(1);
  });

  it("expires a plan, invalidates on session/disabled changes, and discards late plans", async () => {
    await render(); await prepare();
    await act(async () => { vi.advanceTimersByTime(300_001); }); await settle();
    expect(host.textContent).toMatch(/过期|重新/); expect(gateway.discardRollbackArchive).toHaveBeenCalledWith("session-1", plan.planId);
    let resolve!: (value: RollbackArchivePlan) => void;
    gateway.planRollbackArchive.mockImplementationOnce(() => new Promise((r) => { resolve = r; }));
    await render({ refreshKey: 2 }); await prepare();
    await render({ sessionId: "session-2", enabled: false }); resolve(plan); await settle();
    expect(gateway.discardRollbackArchive).toHaveBeenCalledWith("session-1", plan.planId);
    expect(gateway.executeRollbackArchive).not.toHaveBeenCalled();
  });

  it("consumes an execution token after failure and never retries automatically", async () => {
    gateway.executeRollbackArchive.mockRejectedValueOnce(new Error("write failed"));
    await render(); await prepare(); await consentAndExecute();
    expect(gateway.executeRollbackArchive).toHaveBeenCalledTimes(1);
    await render({ refreshKey: 3 }); await settle();
    expect(gateway.executeRollbackArchive).toHaveBeenCalledTimes(1);
  });
});
