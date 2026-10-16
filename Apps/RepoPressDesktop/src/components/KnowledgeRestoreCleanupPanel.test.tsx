import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { KnowledgeRestoreArchiveEntry } from "../contracts/knowledgeRestoreArchive";
import type {
  KnowledgeRestoreCleanupAction,
  KnowledgeRestoreCleanupGateway,
  KnowledgeRestoreCleanupPlan,
  KnowledgeRestoreCleanupReceipt,
  KnowledgeRestoreCleanupStatus,
} from "../contracts/knowledgeRestoreCleanup";
import { KnowledgeRestoreCleanupPanel } from "./KnowledgeRestoreCleanupPanel";

const now = 1_700_000_000_000;
const transactionId = "11111111-1111-4111-8111-111111111111";
const cleanupId = "22222222-2222-4222-8222-222222222222";
const planId = "33333333-3333-4333-8333-333333333333";
const otherId = "44444444-4444-4444-8444-444444444444";
const sha = (character: string) => character.repeat(64);
const clone = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

function selected(overrides: Partial<KnowledgeRestoreArchiveEntry> = {}): KnowledgeRestoreArchiveEntry {
  return {
    transactionId,
    phase: "committed",
    previousManifestSha256: sha("1"),
    projectedManifestSha256: sha("2"),
    snapshotManifestSha256: sha("3"),
    snapshotPresent: true,
    snapshotFileCount: 4,
    snapshotByteSize: 4096,
    archivedAtEpochMs: now - 1,
    ...overrides,
  };
}

function eligible(overrides: Partial<KnowledgeRestoreCleanupStatus> = {}): KnowledgeRestoreCleanupStatus {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreCleanupStatus",
    state: "eligible",
    cleanupId: null,
    selected: selected(),
    historyCount: 4,
    historyLimit: 4,
    receiptCount: 3,
    receiptLimit: 128,
    currentManifestSha256: sha("a"),
    remainingFileCount: 6,
    remainingByteSize: 8192,
    canDelete: true,
    canResume: false,
    historySlotReleased: false,
    libraryAccessBlocked: false,
    filesystemWrites: false,
    ...overrides,
  };
}

function pending(state: "cleaning" | "cleaned" = "cleaning", overrides: Partial<KnowledgeRestoreCleanupStatus> = {}): KnowledgeRestoreCleanupStatus {
  return eligible({
    state,
    cleanupId,
    historyCount: state === "cleaned" ? 3 : 4,
    remainingFileCount: state === "cleaned" ? 0 : 3,
    remainingByteSize: state === "cleaned" ? 0 : 2048,
    canDelete: false,
    canResume: true,
    historySlotReleased: state === "cleaned",
    libraryAccessBlocked: true,
    ...overrides,
  });
}

function empty(state: "none" | "blocked" | "unavailable" = "none"): KnowledgeRestoreCleanupStatus {
  if (state === "none") {
    return eligible({ state, cleanupId: null, selected: null, historyCount: 0, currentManifestSha256: null,
      remainingFileCount: null, remainingByteSize: null, canDelete: false, canResume: false,
      historySlotReleased: false, libraryAccessBlocked: false });
  }
  return eligible({ state, cleanupId: null, selected: null, historyCount: null, receiptCount: null,
    currentManifestSha256: null, remainingFileCount: null, remainingByteSize: null,
    canDelete: false, canResume: false, historySlotReleased: false,
    libraryAccessBlocked: state === "unavailable" });
}

function cleanupPlan(
  action: KnowledgeRestoreCleanupAction = "delete",
  status = action === "delete" ? eligible() : pending(),
): KnowledgeRestoreCleanupPlan {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreCleanupPlan",
    planId,
    action,
    status: clone(status),
    requiresAcknowledgement: true,
    irreversible: true,
    currentLibraryChanged: false,
    deletesSnapshot: status.selected!.snapshotPresent,
    deletesHistory: true,
    preservesAuditReceipt: true,
    reclaimsHistorySlot: true,
    physicalSpaceReclaimedUnknown: true,
    checkedAtEpochMs: now,
    expiresAtEpochMs: now + 300_000,
  };
}

function cleanupReceipt(
  action: KnowledgeRestoreCleanupAction = "delete",
  status = action === "delete" ? eligible() : pending(),
): KnowledgeRestoreCleanupReceipt {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreCleanupReceipt",
    planId,
    cleanupId,
    transactionId: status.selected!.transactionId,
    action,
    state: "cleaned",
    selected: clone(status.selected!),
    removedFileCount: status.selected!.snapshotFileCount + 2,
    removedByteSize: 8192,
    currentLibraryChanged: false,
    historySlotReleased: true,
    auditReceiptPersisted: true,
    physicalSpaceReclaimedUnknown: true,
    completedAtEpochMs: now,
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

type MockGateway = { [K in keyof KnowledgeRestoreCleanupGateway]: ReturnType<typeof vi.fn> };
let gateway: MockGateway;
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
const render = async (props: Partial<React.ComponentProps<typeof KnowledgeRestoreCleanupPanel>> = {}) => {
  await act(async () => root.render(createElement(KnowledgeRestoreCleanupPanel, {
    gateway: gateway as unknown as KnowledgeRestoreCleanupGateway,
    enabled: true,
    ...props,
  })));
};
const button = (label: string) => [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement | undefined;
const click = async (label: string) => { await act(async () => { button(label)!.click(); }); };
const acknowledge = async () => {
  const checkbox = host.querySelector('input[type="checkbox"]') as HTMLInputElement;
  await act(async () => { checkbox.click(); });
};
const inspect = async () => { await click("检查永久清理状态"); };
const prepare = async (label = "准备永久删除计划") => { await inspect(); await click(label); };
function handler(element: Element) {
  const key = Object.keys(element).find((value) => value.startsWith("__reactProps"))!;
  return (element as unknown as Record<string, { onClick: () => void }>)[key].onClick;
}

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
describe("KnowledgeRestoreCleanupPanel", () => {
  beforeEach(() => {
    vi.useFakeTimers(); vi.setSystemTime(now);
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      inspectKnowledgeRestoreCleanup: vi.fn(async () => eligible()),
      planKnowledgeRestoreCleanup: vi.fn(async () => cleanupPlan()),
      executeKnowledgeRestoreCleanup: vi.fn(async () => cleanupReceipt()),
      discardKnowledgeRestoreCleanup: vi.fn(async () => undefined),
    };
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("requires manual inspection, a bound plan, and explicit acknowledgement before deleting once", async () => {
    await render();
    expect(gateway.inspectKnowledgeRestoreCleanup).not.toHaveBeenCalled();
    expect(gateway.planKnowledgeRestoreCleanup).not.toHaveBeenCalled();
    expect(host.textContent).toContain("完整快照、原始事务日志和历史记录");
    expect(host.textContent).toContain("逻辑字节数，不保证磁盘物理空间");
    await prepare();
    expect(gateway.planKnowledgeRestoreCleanup).toHaveBeenCalledExactlyOnceWith(transactionId, "delete");
    expect(button("确认并执行永久清理")!.disabled).toBe(true);
    const acknowledgement = host.querySelector("label")!.textContent!;
    expect(acknowledgement).toContain("仅保留精简审计回执");
    expect(acknowledgement).toContain("当前资料库保持不变");
    await acknowledge(); await click("确认并执行永久清理");
    expect(gateway.executeKnowledgeRestoreCleanup).toHaveBeenCalledExactlyOnceWith(planId, true);
    expect(host.textContent).toContain("历史槽已释放");
    expect(host.textContent).toContain("精简审计回执已持久化");
    expect(gateway.inspectKnowledgeRestoreCleanup).toHaveBeenCalledTimes(1);
  });

  it.each(["cleaning", "cleaned"] as const)("requires a fresh resume plan for %s state", async (state) => {
    const status = pending(state);
    gateway.inspectKnowledgeRestoreCleanup.mockResolvedValue(status);
    gateway.planKnowledgeRestoreCleanup.mockResolvedValue(cleanupPlan("resume", status));
    gateway.executeKnowledgeRestoreCleanup.mockResolvedValue(cleanupReceipt("resume", status));
    await render(); await inspect();
    expect(button("准备永久删除计划")).toBeUndefined();
    await click("准备恢复清理计划");
    expect(gateway.planKnowledgeRestoreCleanup).toHaveBeenCalledWith(transactionId, "resume");
    await acknowledge(); await click("确认并执行永久清理");
    expect(gateway.executeKnowledgeRestoreCleanup).toHaveBeenCalledWith(planId, true);
  });

  it("resumes a cleaning intent after the selected source has moved into private quarantine", async () => {
    const status = pending("cleaning", { historyCount: 3, historySlotReleased: true, remainingFileCount: 6, remainingByteSize: 8192 });
    gateway.inspectKnowledgeRestoreCleanup.mockResolvedValue(status);
    gateway.planKnowledgeRestoreCleanup.mockResolvedValue(cleanupPlan("resume", status));
    gateway.executeKnowledgeRestoreCleanup.mockResolvedValue(cleanupReceipt("resume", status));
    await render(); await prepare("准备恢复清理计划"); await acknowledge(); await click("确认并执行永久清理");
    expect(gateway.planKnowledgeRestoreCleanup).toHaveBeenCalledWith(transactionId, "resume");
    expect(host.textContent).toContain("历史槽已释放");
  });

  it.each([
    ["none", empty("none")],
    ["blocked", empty("blocked")],
    ["blocked with access lock", { ...empty("blocked"), libraryAccessBlocked: true }],
    ["unavailable", empty("unavailable")],
    ["receipt capacity reached", eligible({ receiptCount: 128, canDelete: false })],
  ] as const)("shows valid non-actionable status: %s", async (_label, status) => {
    gateway.inspectKnowledgeRestoreCleanup.mockResolvedValue(status);
    await render(); await inspect();
    expect(host.textContent).toContain("当前状态没有可准备的永久清理操作");
    expect(button("准备永久删除计划")).toBeUndefined();
    expect(button("准备恢复清理计划")).toBeUndefined();
  });

  it("accepts an eligible cancelled history entry without a snapshot", async () => {
    const noSnapshot = selected({ phase: "cancelled", snapshotManifestSha256: null, snapshotPresent: false, snapshotFileCount: 0, snapshotByteSize: 0 });
    const status = eligible({ selected: noSnapshot, remainingFileCount: 2, remainingByteSize: 128 });
    gateway.inspectKnowledgeRestoreCleanup.mockResolvedValue(status);
    gateway.planKnowledgeRestoreCleanup.mockResolvedValue(cleanupPlan("delete", status));
    gateway.executeKnowledgeRestoreCleanup.mockResolvedValue(cleanupReceipt("delete", status));
    await render(); await prepare(); await acknowledge(); await click("确认并执行永久清理");
    expect(gateway.executeKnowledgeRestoreCleanup).toHaveBeenCalledWith(planId, true);
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreCleanupStatus) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["uppercase transaction UUID", (value: KnowledgeRestoreCleanupStatus) => { value.selected!.transactionId = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"; }],
    ["uppercase SHA", (value: KnowledgeRestoreCleanupStatus) => { value.currentManifestSha256 = sha("A"); }],
    ["future entry", (value: KnowledgeRestoreCleanupStatus) => { value.selected!.archivedAtEpochMs = now + 1; }],
    ["history count", (value: KnowledgeRestoreCleanupStatus) => { value.historyCount = 0; }],
    ["receipt count", (value: KnowledgeRestoreCleanupStatus) => { value.receiptCount = 129; }],
    ["remaining files binding", (value: KnowledgeRestoreCleanupStatus) => { value.remainingFileCount = 5; }],
    ["remaining bytes floor", (value: KnowledgeRestoreCleanupStatus) => { value.remainingByteSize = 4095; }],
    ["remaining bytes ceiling", (value: KnowledgeRestoreCleanupStatus) => { value.remainingByteSize = 69 * 1024 * 1024 + 1; }],
    ["action matrix", (value: KnowledgeRestoreCleanupStatus) => { value.canResume = true; }],
    ["slot claim", (value: KnowledgeRestoreCleanupStatus) => { value.historySlotReleased = true; }],
    ["write claim", (value: KnowledgeRestoreCleanupStatus) => { value.filesystemWrites = true as false; }],
  ])("rejects malformed readonly status: %s", async (_label, mutate) => {
    const value = eligible(); (mutate as (value: KnowledgeRestoreCleanupStatus) => void)(value);
    gateway.inspectKnowledgeRestoreCleanup.mockResolvedValue(value);
    await render(); await inspect();
    expect(host.textContent).toContain("读取失败不表示可以删除");
    expect(button("准备永久删除计划")).toBeUndefined();
  });

  it.each([
    ["cleaning without source slot", pending("cleaning", { historyCount: 0 })],
    ["moved cleaning still reports four histories", pending("cleaning", { historySlotReleased: true })],
    ["cleaned still has four histories", pending("cleaned", { historyCount: 4 })],
    ["cleaned without an audit receipt", pending("cleaned", { receiptCount: 0 })],
    ["cleaned files remain", pending("cleaned", { remainingFileCount: 1 })],
    ["cleaned bytes remain", pending("cleaned", { remainingByteSize: 1 })],
    ["unavailable without access lock", { ...empty("unavailable"), libraryAccessBlocked: false }],
  ] as const)("rejects an invalid cleanup state matrix: %s", async (_label, status) => {
    gateway.inspectKnowledgeRestoreCleanup.mockResolvedValue(status);
    await render(); await inspect();
    expect(host.textContent).toContain("读取失败不表示可以删除");
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreCleanupPlan) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["uppercase plan UUID", (value: KnowledgeRestoreCleanupPlan) => { value.planId = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"; }],
    ["wrong action", (value: KnowledgeRestoreCleanupPlan) => { value.action = "resume"; }],
    ["nested status", (value: KnowledgeRestoreCleanupPlan) => { value.status.remainingByteSize! += 1; }],
    ["acknowledgement flag", (value: KnowledgeRestoreCleanupPlan) => { value.requiresAcknowledgement = false as true; }],
    ["irreversible flag", (value: KnowledgeRestoreCleanupPlan) => { value.irreversible = false as true; }],
    ["snapshot binding", (value: KnowledgeRestoreCleanupPlan) => { value.deletesSnapshot = false; }],
    ["history deletion flag", (value: KnowledgeRestoreCleanupPlan) => { value.deletesHistory = false as true; }],
    ["audit flag", (value: KnowledgeRestoreCleanupPlan) => { value.preservesAuditReceipt = false as true; }],
    ["physical-space flag", (value: KnowledgeRestoreCleanupPlan) => { value.physicalSpaceReclaimedUnknown = false as true; }],
    ["TTL", (value: KnowledgeRestoreCleanupPlan) => { value.expiresAtEpochMs += 1; }],
    ["future checked time", (value: KnowledgeRestoreCleanupPlan) => { value.checkedAtEpochMs += 1; value.expiresAtEpochMs += 1; }],
  ])("rejects malformed bound plan and discards recognizable IDs: %s", async (_label, mutate) => {
    const value = cleanupPlan(); (mutate as (value: KnowledgeRestoreCleanupPlan) => void)(value);
    gateway.planKnowledgeRestoreCleanup.mockResolvedValue(value);
    await render(); await prepare();
    expect(host.textContent).toContain("永久清理计划无效");
    expect(button("确认并执行永久清理")).toBeUndefined();
    if (value.planId === planId) expect(gateway.discardKnowledgeRestoreCleanup).toHaveBeenCalledWith(planId);
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreCleanupReceipt) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["plan binding", (value: KnowledgeRestoreCleanupReceipt) => { value.planId = otherId; }],
    ["transaction binding", (value: KnowledgeRestoreCleanupReceipt) => { value.transactionId = otherId; }],
    ["action binding", (value: KnowledgeRestoreCleanupReceipt) => { value.action = "resume"; }],
    ["selected full binding", (value: KnowledgeRestoreCleanupReceipt) => { value.selected.previousManifestSha256 = sha("9"); }],
    ["removed files", (value: KnowledgeRestoreCleanupReceipt) => { value.removedFileCount -= 1; }],
    ["removed bytes floor", (value: KnowledgeRestoreCleanupReceipt) => { value.removedByteSize = 4095; }],
    ["current library", (value: KnowledgeRestoreCleanupReceipt) => { value.currentLibraryChanged = true as false; }],
    ["slot result", (value: KnowledgeRestoreCleanupReceipt) => { value.historySlotReleased = false as true; }],
    ["audit result", (value: KnowledgeRestoreCleanupReceipt) => { value.auditReceiptPersisted = false as true; }],
    ["physical-space result", (value: KnowledgeRestoreCleanupReceipt) => { value.physicalSpaceReclaimedUnknown = false as true; }],
    ["completion time", (value: KnowledgeRestoreCleanupReceipt) => { value.completedAtEpochMs = now + 1; }],
  ])("consumes once and rejects malformed execution receipt: %s", async (_label, mutate) => {
    const value = cleanupReceipt(); (mutate as (value: KnowledgeRestoreCleanupReceipt) => void)(value);
    gateway.executeKnowledgeRestoreCleanup.mockResolvedValue(value);
    await render(); await prepare(); await acknowledge(); await click("确认并执行永久清理");
    expect(gateway.executeKnowledgeRestoreCleanup).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("永久清理可能已经发生，但完成状态未知");
    expect(button("确认并执行永久清理")).toBeUndefined();
    expect(button("检查永久清理状态")).toBeDefined();
  });

  it("binds resume receipts to the persisted cleanup ID", async () => {
    const status = pending();
    const bad = cleanupReceipt("resume", status); bad.cleanupId = otherId;
    gateway.inspectKnowledgeRestoreCleanup.mockResolvedValue(status);
    gateway.planKnowledgeRestoreCleanup.mockResolvedValue(cleanupPlan("resume", status));
    gateway.executeKnowledgeRestoreCleanup.mockResolvedValue(bad);
    await render(); await prepare("准备恢复清理计划"); await acknowledge(); await click("确认并执行永久清理");
    expect(host.textContent).toContain("完成状态未知");
  });

  it("consumes capability before an ambiguous gateway failure and never retries automatically", async () => {
    gateway.executeKnowledgeRestoreCleanup.mockRejectedValue(new Error("transport lost"));
    await render(); await prepare(); await acknowledge();
    const executeButton = button("确认并执行永久清理")!;
    const invoke = handler(executeButton);
    await act(async () => { invoke(); invoke(); });
    expect(gateway.executeKnowledgeRestoreCleanup).toHaveBeenCalledTimes(1);
    expect(gateway.inspectKnowledgeRestoreCleanup).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("请重新手动检查");
  });

  it("blocks repeated inspect and prepare calls while each request is busy", async () => {
    const inspection = deferred<KnowledgeRestoreCleanupStatus>();
    gateway.inspectKnowledgeRestoreCleanup.mockReturnValue(inspection.promise);
    await render();
    const inspectButton = button("检查永久清理状态")!;
    const invokeInspect = handler(inspectButton);
    act(() => { invokeInspect(); invokeInspect(); });
    expect(gateway.inspectKnowledgeRestoreCleanup).toHaveBeenCalledTimes(1);
    await act(async () => inspection.resolve(eligible()));

    const planning = deferred<KnowledgeRestoreCleanupPlan>();
    gateway.planKnowledgeRestoreCleanup.mockReturnValue(planning.promise);
    const prepareButton = button("准备永久删除计划")!;
    const invokePrepare = handler(prepareButton);
    act(() => { invokePrepare(); invokePrepare(); });
    expect(gateway.planKnowledgeRestoreCleanup).toHaveBeenCalledTimes(1);
    await act(async () => planning.resolve(cleanupPlan()));
  });

  it("invalidates and discards a late plan through the gateway that created it", async () => {
    const planning = deferred<KnowledgeRestoreCleanupPlan>();
    gateway.planKnowledgeRestoreCleanup.mockReturnValue(planning.promise);
    await render(); await inspect(); await click("准备永久删除计划");
    const original = gateway;
    const replacement: MockGateway = {
      inspectKnowledgeRestoreCleanup: vi.fn(async () => eligible()),
      planKnowledgeRestoreCleanup: vi.fn(async () => cleanupPlan()),
      executeKnowledgeRestoreCleanup: vi.fn(async () => cleanupReceipt()),
      discardKnowledgeRestoreCleanup: vi.fn(async () => undefined),
    };
    await render({ gateway: replacement as unknown as KnowledgeRestoreCleanupGateway, refreshKey: 1 });
    await act(async () => planning.resolve(cleanupPlan()));
    expect(original.discardKnowledgeRestoreCleanup).toHaveBeenCalledWith(planId);
    expect(replacement.discardKnowledgeRestoreCleanup).not.toHaveBeenCalled();
    expect(button("确认并执行永久清理")).toBeUndefined();
  });

  it("expires and discards an unconsumed plan at exactly five minutes", async () => {
    await render(); await prepare();
    await act(async () => { vi.advanceTimersByTime(300_000); });
    expect(gateway.discardKnowledgeRestoreCleanup).toHaveBeenCalledWith(planId);
    expect(host.textContent).toContain("永久清理计划已过期");
    expect(button("确认并执行永久清理")).toBeUndefined();
    expect(button("准备永久删除计划")).toBeUndefined();
  });

  it("invalidates acknowledged capability when the clock rolls behind checkedAt", async () => {
    await render(); await prepare(); await acknowledge();
    const execute = handler(button("确认并执行永久清理")!);
    vi.setSystemTime(now - 1);
    await act(async () => { execute(); });
    expect(gateway.executeKnowledgeRestoreCleanup).not.toHaveBeenCalled();
    expect(gateway.discardKnowledgeRestoreCleanup).toHaveBeenCalledWith(planId);
    expect(host.textContent).toContain("系统时间已变化");
    expect(button("准备永久删除计划")).toBeUndefined();
  });

  it("defensively copies status, plan, and receipt values", async () => {
    const sourceStatus = eligible();
    const sourcePlan = cleanupPlan("delete", sourceStatus);
    const sourceReceipt = cleanupReceipt("delete", sourceStatus);
    gateway.inspectKnowledgeRestoreCleanup.mockResolvedValue(sourceStatus);
    gateway.planKnowledgeRestoreCleanup.mockResolvedValue(sourcePlan);
    gateway.executeKnowledgeRestoreCleanup.mockResolvedValue(sourceReceipt);
    await render(); await inspect();
    sourceStatus.selected!.transactionId = otherId;
    await click("准备永久删除计划");
    sourcePlan.status.selected!.transactionId = otherId;
    await acknowledge(); await click("确认并执行永久清理");
    sourceReceipt.selected.transactionId = otherId;
    expect(host.textContent).toContain(`事务 ID：${transactionId}`);
    expect(host.textContent).not.toContain(`事务 ID：${otherId}`);
  });

  it("clears all capability when disabled and does not render when not enabled", async () => {
    await render(); await prepare();
    await render({ disabled: true });
    expect(gateway.discardKnowledgeRestoreCleanup).toHaveBeenCalledWith(planId);
    expect(button("检查永久清理状态")!.disabled).toBe(true);
    expect(button("确认并执行永久清理")).toBeUndefined();
    await render({ enabled: false });
    expect(host.textContent).toBe("");
  });
});
