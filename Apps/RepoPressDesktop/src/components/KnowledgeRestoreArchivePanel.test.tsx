import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type {
  KnowledgeRestoreArchiveAction,
  KnowledgeRestoreArchiveEntry,
  KnowledgeRestoreArchiveGateway,
  KnowledgeRestoreArchivePlan,
  KnowledgeRestoreArchiveReceipt,
  KnowledgeRestoreArchiveStatus,
} from "../contracts/knowledgeRestoreArchive";
import { KnowledgeRestoreArchivePanel } from "./KnowledgeRestoreArchivePanel";

const now = 1_700_000_000_000;
const transactionId = "11111111-1111-4111-8111-111111111111";
const planId = "22222222-2222-4222-8222-222222222222";
const otherTransactionId = "33333333-3333-4333-8333-333333333333";
const sha = (character: string) => character.repeat(64);

const clone = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;
function entry(overrides: Partial<KnowledgeRestoreArchiveEntry> = {}): KnowledgeRestoreArchiveEntry {
  return {
    transactionId: otherTransactionId,
    phase: "rolledBack",
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
function eligible(overrides: Partial<KnowledgeRestoreArchiveStatus> = {}): KnowledgeRestoreArchiveStatus {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreArchiveStatus",
    state: "eligible",
    transactionId,
    phase: "committed",
    currentManifestSha256: sha("a"),
    transactionJournalSha256: sha("b"),
    snapshotManifestSha256: sha("c"),
    snapshotPresent: true,
    snapshotFileCount: 7,
    snapshotByteSize: 8192,
    history: [],
    historyLimit: 4,
    canArchive: true,
    canResume: false,
    transactionSlotReleased: false,
    libraryAccessBlocked: false,
    filesystemWrites: false,
    ...overrides,
  };
}
function interrupted(state: "archiving" | "archived" = "archiving"): KnowledgeRestoreArchiveStatus {
  return eligible({ state, canArchive: false, canResume: true, libraryAccessBlocked: true });
}
function empty(state: "none" | "blocked" | "unavailable" = "none"): KnowledgeRestoreArchiveStatus {
  return {
    ...eligible(), state, transactionId: null, phase: null, currentManifestSha256: null,
    transactionJournalSha256: null, snapshotManifestSha256: null, snapshotPresent: false,
    snapshotFileCount: null, snapshotByteSize: null, history: [], canArchive: false, canResume: false,
    transactionSlotReleased: state === "none", libraryAccessBlocked: state === "unavailable",
  };
}
function archivePlan(action: KnowledgeRestoreArchiveAction = "archive", status = action === "archive" ? eligible() : interrupted()): KnowledgeRestoreArchivePlan {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreArchivePlan",
    planId,
    action,
    status: clone(status),
    requiresAcknowledgement: true,
    preservesSnapshot: true,
    currentLibraryChanged: false,
    disablesDirectRollback: true,
    releasesTransactionSlot: true,
    checkedAtEpochMs: now,
    expiresAtEpochMs: now + 300_000,
  };
}
function receipt(action: KnowledgeRestoreArchiveAction = "archive", status = action === "archive" ? eligible() : interrupted()): KnowledgeRestoreArchiveReceipt {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreArchiveReceipt",
    planId,
    transactionId,
    action,
    state: "archived",
    entry: {
      transactionId,
      phase: status.phase!,
      previousManifestSha256: sha("d"),
      projectedManifestSha256: sha("e"),
      snapshotManifestSha256: status.snapshotManifestSha256,
      snapshotPresent: status.snapshotPresent,
      snapshotFileCount: status.snapshotFileCount!,
      snapshotByteSize: status.snapshotByteSize!,
      archivedAtEpochMs: now,
    },
    snapshotRetained: status.snapshotPresent,
    currentLibraryChanged: false,
    transactionSlotReleased: true,
    journalArchived: true,
    libraryAccessBlocked: false,
    completedAtEpochMs: now,
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

type MockGateway = { [K in keyof KnowledgeRestoreArchiveGateway]: ReturnType<typeof vi.fn> };
let gateway: MockGateway;
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
const render = async (props: Partial<React.ComponentProps<typeof KnowledgeRestoreArchivePanel>> = {}) => {
  await act(async () => root.render(createElement(KnowledgeRestoreArchivePanel, {
    gateway: gateway as unknown as KnowledgeRestoreArchiveGateway,
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
const inspect = async () => { await click("检查归档状态"); };
const prepare = async (label = "准备归档计划") => { await inspect(); await click(label); };
function handler(element: Element) {
  const key = Object.keys(element).find((value) => value.startsWith("__reactProps"))!;
  return (element as unknown as Record<string, { onClick: () => void }>)[key].onClick;
}

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
describe("KnowledgeRestoreArchivePanel", () => {
  beforeEach(() => {
    vi.useFakeTimers(); vi.setSystemTime(now);
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      inspectKnowledgeRestoreArchive: vi.fn(async () => eligible()),
      planKnowledgeRestoreArchive: vi.fn(async () => archivePlan()),
      executeKnowledgeRestoreArchive: vi.fn(async () => receipt()),
      discardKnowledgeRestoreArchive: vi.fn(async () => undefined),
    };
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("uses a manual inspect, prepare, explicit acknowledgement, and one-use archive flow", async () => {
    await render();
    expect(gateway.inspectKnowledgeRestoreArchive).not.toHaveBeenCalled();
    expect(gateway.planKnowledgeRestoreArchive).not.toHaveBeenCalled();
    expect(host.textContent).toContain("最多 4 条的私有历史");
    expect(host.textContent).toContain("不会删除快照、回收磁盘空间");
    await prepare();
    expect(gateway.planKnowledgeRestoreArchive).toHaveBeenCalledExactlyOnceWith(transactionId, "archive");
    expect(host.textContent).toContain("P52 直接回滚将不可用");
    expect(host.textContent).toContain("私密明文");
    expect(button("确认并执行归档")!.disabled).toBe(true);
    await acknowledge(); await click("确认并执行归档");
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledExactlyOnceWith(planId, true);
    expect(host.textContent).toContain("唯一事务槽已释放");
    expect(host.textContent).toContain("完整私有快照继续保留，不会自动清理");
    expect(gateway.inspectKnowledgeRestoreArchive).toHaveBeenCalledTimes(1);
  });

  it.each(["archiving", "archived"] as const)("requires a newly prepared resume plan for interrupted %s state", async (state) => {
    const status = interrupted(state);
    gateway.inspectKnowledgeRestoreArchive.mockResolvedValue(status);
    gateway.planKnowledgeRestoreArchive.mockResolvedValue(archivePlan("resume", status));
    gateway.executeKnowledgeRestoreArchive.mockResolvedValue(receipt("resume", status));
    await render(); await inspect();
    expect(button("准备归档计划")).toBeUndefined();
    expect(button("确认并执行归档")).toBeUndefined();
    await click("准备恢复归档计划");
    expect(gateway.planKnowledgeRestoreArchive).toHaveBeenCalledWith(transactionId, "resume");
    await acknowledge(); await click("确认并执行归档");
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledWith(planId, true);
  });

  it("accepts a resume receipt whose persisted archive intent predates the fresh resume plan", async () => {
    const status = interrupted();
    const resumePlan = archivePlan("resume", status);
    resumePlan.checkedAtEpochMs = now + 60_000;
    resumePlan.expiresAtEpochMs = now + 360_000;
    const resumeReceipt = receipt("resume", status);
    resumeReceipt.entry.archivedAtEpochMs = now;
    resumeReceipt.completedAtEpochMs = now + 60_001;
    gateway.inspectKnowledgeRestoreArchive.mockResolvedValue(status);
    gateway.planKnowledgeRestoreArchive.mockResolvedValue(resumePlan);
    gateway.executeKnowledgeRestoreArchive.mockResolvedValue(resumeReceipt);
    vi.setSystemTime(now + 60_001);
    await render(); await inspect(); await click("准备恢复归档计划"); await acknowledge(); await click("确认并执行归档");
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledWith(planId, true);
    expect(host.textContent).toContain("唯一事务槽已释放");
  });

  it.each([
    ["archive intent before its plan", "archive", now - 1],
    ["resume intent after its fresh plan", "resume", now + 1],
  ] as const)("rejects action-inverted archive timing: %s", async (_label, action, archivedAtEpochMs) => {
    const status = action === "archive" ? eligible() : interrupted();
    const valuePlan = archivePlan(action, status);
    const valueReceipt = receipt(action, status);
    valueReceipt.entry.archivedAtEpochMs = archivedAtEpochMs;
    if (action === "resume") valueReceipt.completedAtEpochMs = now + 2;
    gateway.inspectKnowledgeRestoreArchive.mockResolvedValue(status);
    gateway.planKnowledgeRestoreArchive.mockResolvedValue(valuePlan);
    gateway.executeKnowledgeRestoreArchive.mockResolvedValue(valueReceipt);
    await render(); await inspect(); await click(action === "archive" ? "准备归档计划" : "准备恢复归档计划");
    if (action === "resume") vi.setSystemTime(now + 2);
    await acknowledge(); await click("确认并执行归档");
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("归档可能已写入，但完成状态未知");
  });

  it.each([
    ["none", empty("none")],
    ["blocked", empty("blocked")],
    ["blocked without access lock", empty("blocked")],
    ["unavailable", empty("unavailable")],
    ["full private history", eligible({ history: [
      entry({ transactionId: "30000000-0000-4000-8000-000000000001" }),
      entry({ transactionId: "30000000-0000-4000-8000-000000000002" }),
      entry({ transactionId: "30000000-0000-4000-8000-000000000003" }),
      entry({ transactionId: "30000000-0000-4000-8000-000000000004" }),
    ], canArchive: false })],
  ] as const)("shows valid non-actionable status: %s", async (_label, status) => {
    gateway.inspectKnowledgeRestoreArchive.mockResolvedValue(status);
    await render(); await inspect();
    expect(host.textContent).toContain("当前状态没有可准备的归档操作");
    expect(button("准备归档计划")).toBeUndefined();
    expect(button("准备恢复归档计划")).toBeUndefined();
  });

  it("accepts a known cancelled terminal transaction without falsely claiming a snapshot", async () => {
    const status = eligible({ phase: "cancelled", snapshotPresent: false, snapshotManifestSha256: null, snapshotFileCount: 0, snapshotByteSize: 0 });
    gateway.inspectKnowledgeRestoreArchive.mockResolvedValue(status);
    gateway.planKnowledgeRestoreArchive.mockResolvedValue(archivePlan("archive", status));
    gateway.executeKnowledgeRestoreArchive.mockResolvedValue(receipt("archive", status));
    await render(); await prepare();
    expect(host.textContent).toContain("完整快照：未形成");
    await acknowledge(); await click("确认并执行归档");
    expect(host.textContent).toContain("没有完整快照");
    expect(host.textContent).not.toContain("完整私有快照继续保留");
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreArchiveStatus) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["transaction UUID", (value: KnowledgeRestoreArchiveStatus) => { value.transactionId = "bad"; }],
    ["manifest SHA", (value: KnowledgeRestoreArchiveStatus) => { value.currentManifestSha256 = sha("A"); }],
    ["snapshot count", (value: KnowledgeRestoreArchiveStatus) => { value.snapshotFileCount = 2050; }],
    ["snapshot bytes", (value: KnowledgeRestoreArchiveStatus) => { value.snapshotByteSize = 66 * 1024 * 1024 + 1; }],
    ["absent snapshot fields", (value: KnowledgeRestoreArchiveStatus) => { value.snapshotPresent = false; }],
    ["action matrix", (value: KnowledgeRestoreArchiveStatus) => { value.canResume = true; }],
    ["duplicate history IDs", (value: KnowledgeRestoreArchiveStatus) => { value.history = [entry(), entry()]; }],
    ["current target in history", (value: KnowledgeRestoreArchiveStatus) => { value.history = [entry({ transactionId })]; }],
    ["history entry SHA", (value: KnowledgeRestoreArchiveStatus) => { value.history = [entry({ previousManifestSha256: "bad" })]; }],
    ["future history", (value: KnowledgeRestoreArchiveStatus) => { value.history = [entry({ archivedAtEpochMs: now + 1 })]; }],
    ["write claim", (value: KnowledgeRestoreArchiveStatus) => { value.filesystemWrites = true as false; }],
  ])("rejects malformed readonly status: %s", async (_label, mutate) => {
    const value = eligible(); (mutate as (value: KnowledgeRestoreArchiveStatus) => void)(value);
    gateway.inspectKnowledgeRestoreArchive.mockResolvedValue(value);
    await render(); await inspect();
    expect(host.textContent).toContain("读取失败不表示事务槽可用");
    expect(button("准备归档计划")).toBeUndefined();
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreArchivePlan) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["plan UUID", (value: KnowledgeRestoreArchivePlan) => { value.planId = "bad"; }],
    ["wrong action", (value: KnowledgeRestoreArchivePlan) => { value.action = "resume"; }],
    ["nested status", (value: KnowledgeRestoreArchivePlan) => { value.status.currentManifestSha256 = sha("f"); }],
    ["ack flag", (value: KnowledgeRestoreArchivePlan) => { value.requiresAcknowledgement = false as true; }],
    ["snapshot flag", (value: KnowledgeRestoreArchivePlan) => { value.preservesSnapshot = false as true; }],
    ["rollback flag", (value: KnowledgeRestoreArchivePlan) => { value.disablesDirectRollback = false as true; }],
    ["slot flag", (value: KnowledgeRestoreArchivePlan) => { value.releasesTransactionSlot = false as true; }],
    ["TTL", (value: KnowledgeRestoreArchivePlan) => { value.expiresAtEpochMs += 1; }],
    ["future checked time", (value: KnowledgeRestoreArchivePlan) => { value.checkedAtEpochMs += 1; value.expiresAtEpochMs += 1; }],
  ])("rejects malformed bound plan and discards recognizable IDs: %s", async (_label, mutate) => {
    const value = archivePlan(); (mutate as (value: KnowledgeRestoreArchivePlan) => void)(value);
    gateway.planKnowledgeRestoreArchive.mockResolvedValue(value);
    await render(); await prepare();
    expect(host.textContent).toContain("归档计划无效");
    expect(button("确认并执行归档")).toBeUndefined();
    if (value.planId === planId) expect(gateway.discardKnowledgeRestoreArchive).toHaveBeenCalledWith(planId);
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreArchiveReceipt) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["plan binding", (value: KnowledgeRestoreArchiveReceipt) => { value.planId = otherTransactionId; }],
    ["transaction binding", (value: KnowledgeRestoreArchiveReceipt) => { value.transactionId = otherTransactionId; }],
    ["action binding", (value: KnowledgeRestoreArchiveReceipt) => { value.action = "resume"; }],
    ["entry previous SHA", (value: KnowledgeRestoreArchiveReceipt) => { value.entry.previousManifestSha256 = "bad"; }],
    ["entry phase", (value: KnowledgeRestoreArchiveReceipt) => { value.entry.phase = "rolledBack"; }],
    ["entry snapshot hash", (value: KnowledgeRestoreArchiveReceipt) => { value.entry.snapshotManifestSha256 = sha("f"); }],
    ["entry snapshot count", (value: KnowledgeRestoreArchiveReceipt) => { value.entry.snapshotFileCount += 1; }],
    ["snapshot retained", (value: KnowledgeRestoreArchiveReceipt) => { value.snapshotRetained = false; }],
    ["archive time", (value: KnowledgeRestoreArchiveReceipt) => { value.entry.archivedAtEpochMs = now + 1; }],
    ["completion time", (value: KnowledgeRestoreArchiveReceipt) => { value.completedAtEpochMs = now + 1; }],
    ["slot result", (value: KnowledgeRestoreArchiveReceipt) => { value.transactionSlotReleased = false as true; }],
    ["journal result", (value: KnowledgeRestoreArchiveReceipt) => { value.journalArchived = false as true; }],
  ])("consumes once and rejects malformed execution receipt: %s", async (_label, mutate) => {
    const value = receipt(); (mutate as (value: KnowledgeRestoreArchiveReceipt) => void)(value);
    gateway.executeKnowledgeRestoreArchive.mockResolvedValue(value);
    await render(); await prepare(); await acknowledge(); await click("确认并执行归档");
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("归档可能已写入，但完成状态未知");
    expect(button("确认并执行归档")).toBeUndefined();
    expect(button("检查归档状态")).toBeDefined();
  });

  it("copies accepted status and plan DTOs before binding execution", async () => {
    const serverStatus = eligible();
    const serverPlan = archivePlan("archive", serverStatus);
    gateway.inspectKnowledgeRestoreArchive.mockResolvedValue(serverStatus);
    gateway.planKnowledgeRestoreArchive.mockResolvedValue(serverPlan);
    await render(); await inspect();
    serverStatus.transactionId = otherTransactionId;
    await click("准备归档计划");
    serverPlan.planId = otherTransactionId;
    serverPlan.status.currentManifestSha256 = sha("f");
    await acknowledge(); await click("确认并执行归档");
    expect(gateway.planKnowledgeRestoreArchive).toHaveBeenCalledWith(transactionId, "archive");
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledWith(planId, true);
  });

  it("discards a recognizable late plan through its original gateway after refresh invalidation", async () => {
    const pending = deferred<KnowledgeRestoreArchivePlan>();
    gateway.planKnowledgeRestoreArchive.mockReturnValue(pending.promise);
    await render(); await inspect(); await click("准备归档计划");
    const original = gateway;
    await render({ refreshKey: 1 });
    await act(async () => pending.resolve(archivePlan()));
    expect(original.discardKnowledgeRestoreArchive).toHaveBeenCalledWith(planId);
    expect(button("确认并执行归档")).toBeUndefined();
  });

  it("ignores late inspection and execution responses after disabling", async () => {
    const lateStatus = deferred<KnowledgeRestoreArchiveStatus>();
    gateway.inspectKnowledgeRestoreArchive.mockReturnValueOnce(lateStatus.promise);
    await render(); await act(async () => { button("检查归档状态")!.click(); });
    await render({ disabled: true });
    await act(async () => lateStatus.resolve(eligible()));
    expect(host.textContent).not.toContain(transactionId);

    await render({ disabled: false, refreshKey: 1 }); await prepare(); await acknowledge();
    const lateReceipt = deferred<KnowledgeRestoreArchiveReceipt>();
    gateway.executeKnowledgeRestoreArchive.mockReturnValueOnce(lateReceipt.promise);
    await click("确认并执行归档"); await render({ disabled: true, refreshKey: 1 });
    await act(async () => lateReceipt.resolve(receipt()));
    expect(host.textContent).not.toContain("唯一事务槽已释放");
  });

  it("consumes synchronously to block duplicate execution and stale handlers", async () => {
    const pending = deferred<KnowledgeRestoreArchiveReceipt>();
    gateway.executeKnowledgeRestoreArchive.mockReturnValue(pending.promise);
    await render(); await prepare(); await acknowledge();
    const invoke = handler(button("确认并执行归档")!);
    await act(async () => { invoke(); invoke(); });
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(receipt()));
    await act(async () => invoke());
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledTimes(1);
  });

  it("expires plans and rejects an old callback after the wall clock rolls backward", async () => {
    await render(); await prepare(); await acknowledge();
    const expiredInvoke = handler(button("确认并执行归档")!);
    vi.setSystemTime(now + 300_000);
    await act(async () => expiredInvoke());
    expect(gateway.executeKnowledgeRestoreArchive).not.toHaveBeenCalled();
    expect(gateway.discardKnowledgeRestoreArchive).toHaveBeenCalledWith(planId);
    expect(host.textContent).toContain("已过期");

    vi.setSystemTime(now); await inspect(); await click("准备归档计划"); await acknowledge();
    const rollbackInvoke = handler(button("确认并执行归档")!);
    vi.setSystemTime(now - 1);
    await act(async () => rollbackInvoke());
    expect(gateway.executeKnowledgeRestoreArchive).not.toHaveBeenCalled();
    expect(host.textContent).toContain("系统时间已变化");
  });

  it("reports an unknown write outcome without retrying or automatically inspecting", async () => {
    gateway.executeKnowledgeRestoreArchive.mockRejectedValue(new Error("ambiguous"));
    await render(); await prepare(); await acknowledge(); await click("确认并执行归档");
    expect(gateway.executeKnowledgeRestoreArchive).toHaveBeenCalledTimes(1);
    expect(gateway.inspectKnowledgeRestoreArchive).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("计划已消耗");
    expect(host.textContent).toContain("不会自动重试");
    expect(host.textContent).not.toContain("事务槽已释放");
  });

  it("hides when disabled by feature availability, disables interaction when locked, and never steals focus", async () => {
    const sentinel = document.createElement("button"); document.body.append(sentinel); sentinel.focus();
    await render({ enabled: false });
    expect(host.textContent).toBe("");
    expect(document.activeElement).toBe(sentinel);
    await render({ enabled: true, disabled: true });
    expect(button("检查归档状态")!.disabled).toBe(true);
    button("检查归档状态")!.click();
    expect(gateway.inspectKnowledgeRestoreArchive).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(sentinel);
    sentinel.remove();
  });
});
