import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KNOWLEDGE_BACKUP_EXCLUSIONS } from "../contracts/knowledgeBackup";
import type { KnowledgeRestoreArchiveEntry } from "../contracts/knowledgeRestoreArchive";
import type {
  KnowledgeRestoreHistoryExportGateway,
  KnowledgeRestoreHistoryExportPlan,
  KnowledgeRestoreHistoryExportReceipt,
  KnowledgeRestoreHistoryExportStatus,
} from "../contracts/knowledgeRestoreHistoryExport";
import { KnowledgeRestoreHistoryExportPanel } from "./KnowledgeRestoreHistoryExportPanel";

const now = 1_700_000_000_000;
const newestId = "11111111-1111-4111-8111-111111111111";
const logOnlyId = "22222222-2222-4222-8222-222222222222";
const olderId = "33333333-3333-4333-8333-333333333333";
const planId = "44444444-4444-4444-8444-444444444444";
const otherId = "55555555-5555-4555-8555-555555555555";
const destination = "/tmp/repopress-history-export.json";
const sha = (character: string) => character.repeat(64);
const clone = <T,>(value: T): T => JSON.parse(JSON.stringify(value)) as T;

function entry(overrides: Partial<KnowledgeRestoreArchiveEntry> = {}): KnowledgeRestoreArchiveEntry {
  return {
    transactionId: newestId,
    phase: "committed",
    previousManifestSha256: sha("1"),
    projectedManifestSha256: sha("2"),
    snapshotManifestSha256: sha("3"),
    snapshotPresent: true,
    snapshotFileCount: 6,
    snapshotByteSize: 900,
    archivedAtEpochMs: now - 1,
    ...overrides,
  };
}

const logOnly = () => entry({
  transactionId: logOnlyId,
  phase: "cancelled",
  snapshotManifestSha256: null,
  snapshotPresent: false,
  snapshotFileCount: 0,
  snapshotByteSize: 0,
  archivedAtEpochMs: now - 2,
});
const older = () => entry({ transactionId: olderId, phase: "rolledBack", snapshotManifestSha256: sha("4"), archivedAtEpochMs: now - 3 });

function ready(overrides: Partial<KnowledgeRestoreHistoryExportStatus> = {}): KnowledgeRestoreHistoryExportStatus {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreHistoryExportStatus",
    state: "ready",
    history: [entry(), logOnly(), older()],
    historyLimit: 4,
    libraryAccessBlocked: false,
    filesystemWrites: false,
    ...overrides,
  };
}

function empty(state: "none" | "blocked" | "unavailable"): KnowledgeRestoreHistoryExportStatus {
  return ready({ state, history: [], libraryAccessBlocked: state === "unavailable" });
}

function exportPlan(selected = entry(), overrides: Partial<KnowledgeRestoreHistoryExportPlan> = {}): KnowledgeRestoreHistoryExportPlan {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreHistoryExportPlan",
    planId,
    selected: clone(selected),
    destinationPath: destination,
    byteSize: 1200,
    sha256: sha("a"),
    manifestSha256: sha("b"),
    sourceManifestSha256: selected.snapshotManifestSha256!,
    itemCount: 3,
    revisionCount: 7,
    bodyFileCount: 3,
    archiveFileCount: 2,
    resourceByteSize: 800,
    exclusions: [...KNOWLEDGE_BACKUP_EXCLUSIONS],
    requiresSensitivePlaintextConsent: true,
    currentLibraryChanged: false,
    sourceHistoryChanged: false,
    restoreReady: false,
    includesCredentialStores: false,
    includesCompletedOperations: false,
    externalReferencesIncluded: false,
    consistentSnapshot: false,
    checkedAtEpochMs: now,
    expiresAtEpochMs: now + 300_000,
    ...overrides,
  };
}

function receipt(plan = exportPlan(), overrides: Partial<KnowledgeRestoreHistoryExportReceipt> = {}): KnowledgeRestoreHistoryExportReceipt {
  return {
    schemaVersion: 1,
    scope: "knowledgeRestoreHistoryExportReceipt",
    planId: plan.planId,
    selected: clone(plan.selected),
    destinationPath: plan.destinationPath,
    byteSize: plan.byteSize,
    sha256: plan.sha256,
    manifestSha256: plan.manifestSha256,
    sourceManifestSha256: plan.sourceManifestSha256,
    sourceRevalidated: true,
    contentsVerified: true,
    privatePermissionsVerified: true,
    currentLibraryChanged: false,
    sourceHistoryChanged: false,
    restoreReady: false,
    completedAtEpochMs: now,
    ...overrides,
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

type MockGateway = { [K in keyof KnowledgeRestoreHistoryExportGateway]: ReturnType<typeof vi.fn> };
let gateway: MockGateway;
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
const render = async (props: Partial<React.ComponentProps<typeof KnowledgeRestoreHistoryExportPanel>> = {}) => {
  await act(async () => root.render(createElement(KnowledgeRestoreHistoryExportPanel, {
    gateway: gateway as unknown as KnowledgeRestoreHistoryExportGateway,
    enabled: true,
    ...props,
  })));
};
const button = (label: string) => [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement | undefined;
const click = async (label: string) => { await act(async () => { button(label)!.click(); }); };
const radio = (id: string) => host.querySelector(`input[type="radio"][value="${id}"]`) as HTMLInputElement;
const select = async (id = newestId) => { await act(async () => { radio(id).click(); }); };
const acknowledge = async () => { await act(async () => { (host.querySelector('input[type="checkbox"]') as HTMLInputElement).click(); }); };
const inspect = async () => { await click("检查恢复历史快照"); };
const prepare = async (id = newestId) => {
  await inspect(); await select(id); await click("选择新的历史快照 JSON 路径"); await click("明确预览历史快照资料包");
};
function handler(element: Element) {
  const key = Object.keys(element).find((value) => value.startsWith("__reactProps"))!;
  return (element as unknown as Record<string, { onClick: () => void }>)[key].onClick;
}

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
describe("KnowledgeRestoreHistoryExportPanel", () => {
  beforeEach(() => {
    vi.useFakeTimers(); vi.setSystemTime(now);
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      inspectKnowledgeRestoreHistoryExport: vi.fn(async () => ready()),
      selectKnowledgeRestoreHistoryExportDestination: vi.fn(async () => destination),
      planKnowledgeRestoreHistoryExport: vi.fn(async () => exportPlan()),
      executeKnowledgeRestoreHistoryExport: vi.fn(async () => receipt()),
      discardKnowledgeRestoreHistoryExport: vi.fn(async () => undefined),
    };
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("is fully manual, shows only safe history metadata, and exports after sensitive consent", async () => {
    await render();
    expect(gateway.inspectKnowledgeRestoreHistoryExport).not.toHaveBeenCalled();
    expect(gateway.selectKnowledgeRestoreHistoryExportDestination).not.toHaveBeenCalled();
    expect(gateway.planKnowledgeRestoreHistoryExport).not.toHaveBeenCalled();
    await inspect();
    expect(host.textContent).toContain(newestId);
    expect(host.textContent).toContain("文件数：6");
    expect(host.textContent).toContain(sha("3"));
    expect(host.textContent).not.toContain(sha("1"));
    expect(host.textContent).not.toContain(sha("2"));
    expect(radio(logOnlyId).disabled).toBe(true);
    await select(); await click("选择新的历史快照 JSON 路径"); await click("明确预览历史快照资料包");
    expect(gateway.planKnowledgeRestoreHistoryExport).toHaveBeenCalledExactlyOnceWith(newestId, destination);
    expect(button("确认并一次性导出历史快照资料包")!.disabled).toBe(true);
    expect(host.querySelector('input[type="checkbox"]')?.parentElement?.textContent).toContain("敏感资料明文");
    await acknowledge(); await click("确认并一次性导出历史快照资料包");
    expect(gateway.executeKnowledgeRestoreHistoryExport).toHaveBeenCalledExactlyOnceWith(planId, true);
    expect(host.textContent).toContain("私有文件权限已确认");
    expect(host.textContent).toContain("独立选择该资料包");
    expect(host.textContent).toContain("不会自动安装");
    expect(host.textContent).toContain("不会自动安装或直接回滚整个资料库");
  });

  it("allows selecting a non-newest complete snapshot", async () => {
    const selected = older();
    gateway.planKnowledgeRestoreHistoryExport.mockResolvedValue(exportPlan(selected));
    gateway.executeKnowledgeRestoreHistoryExport.mockResolvedValue(receipt(exportPlan(selected)));
    await render(); await prepare(olderId); await acknowledge(); await click("确认并一次性导出历史快照资料包");
    expect(gateway.planKnowledgeRestoreHistoryExport).toHaveBeenCalledWith(olderId, destination);
    expect(host.textContent).toContain(`事务 UUID：${olderId}`);
  });

  it.each(["none", "blocked", "unavailable"] as const)("accepts non-actionable %s status", async (state) => {
    gateway.inspectKnowledgeRestoreHistoryExport.mockResolvedValue(empty(state));
    await render(); await inspect();
    expect(host.textContent).toContain("当前状态没有可选择的完整历史快照");
    expect(host.querySelectorAll('input[type="radio"]')).toHaveLength(0);
  });

  it("keeps a ready log-only history visible but not selectable", async () => {
    gateway.inspectKnowledgeRestoreHistoryExport.mockResolvedValue(ready({ history: [logOnly()] }));
    await render(); await inspect();
    expect(host.textContent).toContain("无（仅日志，不可导出）");
    expect(radio(logOnlyId).disabled).toBe(true);
    expect(button("选择新的历史快照 JSON 路径")).toBeUndefined();
  });

  it.each([null, "relative.json", "/tmp/not-json.sqlite", "/tmp/UPPER.JSON", "/tmp/../escape.json"])("rejects or cancels an invalid destination: %s", async (path) => {
    gateway.selectKnowledgeRestoreHistoryExportDestination.mockResolvedValue(path);
    await render(); await inspect(); await select(); await click("选择新的历史快照 JSON 路径");
    expect(gateway.planKnowledgeRestoreHistoryExport).not.toHaveBeenCalled();
    expect(button("明确预览历史快照资料包")).toBeUndefined();
    if (path !== null) expect(host.textContent).toContain("绝对小写 .json");
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreHistoryExportStatus) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["uppercase UUID", (value: KnowledgeRestoreHistoryExportStatus) => { value.history[0].transactionId = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"; }],
    ["uppercase SHA", (value: KnowledgeRestoreHistoryExportStatus) => { value.history[0].snapshotManifestSha256 = sha("A"); }],
    ["future archive time", (value: KnowledgeRestoreHistoryExportStatus) => { value.history[0].archivedAtEpochMs = now + 1; }],
    ["snapshot count", (value: KnowledgeRestoreHistoryExportStatus) => { value.history[0].snapshotFileCount = 2050; }],
    ["snapshot bytes", (value: KnowledgeRestoreHistoryExportStatus) => { value.history[0].snapshotByteSize = 66 * 1024 * 1024 + 1; }],
    ["inconsistent absent snapshot", (value: KnowledgeRestoreHistoryExportStatus) => { value.history[0].snapshotPresent = false; }],
    ["duplicate transaction", (value: KnowledgeRestoreHistoryExportStatus) => { value.history = [entry(), entry()]; }],
    ["too many histories", (value: KnowledgeRestoreHistoryExportStatus) => { value.history = [entry(), logOnly(), older(), entry({ transactionId: otherId }), entry({ transactionId: planId })]; }],
    ["ready empty", (value: KnowledgeRestoreHistoryExportStatus) => { value.history = []; }],
    ["ready access blocked", (value: KnowledgeRestoreHistoryExportStatus) => { value.libraryAccessBlocked = true; }],
    ["write claim", (value: KnowledgeRestoreHistoryExportStatus) => { value.filesystemWrites = true as false; }],
  ])("rejects malformed inspection status: %s", async (_label, mutate) => {
    const value = ready(); (mutate as (value: KnowledgeRestoreHistoryExportStatus) => void)(value);
    gateway.inspectKnowledgeRestoreHistoryExport.mockResolvedValue(value);
    await render(); await inspect();
    expect(host.textContent).toContain("读取失败不表示快照可导出");
    expect(host.querySelectorAll('input[type="radio"]')).toHaveLength(0);
  });

  it.each([
    ["none with history", ready({ state: "none" })],
    ["none blocked", empty("none")],
    ["blocked with history", ready({ state: "blocked" })],
    ["unavailable without lock", { ...empty("unavailable"), libraryAccessBlocked: false }],
  ] as const)("rejects invalid status matrix: %s", async (_label, value) => {
    if (_label === "none blocked") value.libraryAccessBlocked = true;
    gateway.inspectKnowledgeRestoreHistoryExport.mockResolvedValue(value);
    await render(); await inspect();
    expect(host.textContent).toContain("读取失败不表示快照可导出");
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreHistoryExportPlan) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["plan UUID", (value: KnowledgeRestoreHistoryExportPlan) => { value.planId = "bad"; }],
    ["selected entry", (value: KnowledgeRestoreHistoryExportPlan) => { value.selected.transactionId = olderId; }],
    ["destination", (value: KnowledgeRestoreHistoryExportPlan) => { value.destinationPath = "/tmp/other.json"; }],
    ["item count", (value: KnowledgeRestoreHistoryExportPlan) => { value.itemCount = 2001; }],
    ["revision relation", (value: KnowledgeRestoreHistoryExportPlan) => { value.revisionCount = 2; }],
    ["resource count", (value: KnowledgeRestoreHistoryExportPlan) => { value.bodyFileCount = 1024; value.archiveFileCount = 1; }],
    ["snapshot file binding", (value: KnowledgeRestoreHistoryExportPlan) => { value.archiveFileCount = 1; }],
    ["resource bytes", (value: KnowledgeRestoreHistoryExportPlan) => { value.resourceByteSize = 32 * 1024 * 1024 + 1; }],
    ["package bytes", (value: KnowledgeRestoreHistoryExportPlan) => { value.byteSize = 48 * 1024 * 1024 + 1; }],
    ["package SHA", (value: KnowledgeRestoreHistoryExportPlan) => { value.sha256 = sha("A"); }],
    ["source manifest binding", (value: KnowledgeRestoreHistoryExportPlan) => { value.sourceManifestSha256 = sha("9"); }],
    ["duplicate exclusion", (value: KnowledgeRestoreHistoryExportPlan) => { value.exclusions = [KNOWLEDGE_BACKUP_EXCLUSIONS[0], ...value.exclusions]; }],
    ["missing exclusion", (value: KnowledgeRestoreHistoryExportPlan) => { value.exclusions = value.exclusions.slice(1); }],
    ["consent flag", (value: KnowledgeRestoreHistoryExportPlan) => { value.requiresSensitivePlaintextConsent = false as true; }],
    ["library flag", (value: KnowledgeRestoreHistoryExportPlan) => { value.currentLibraryChanged = true as false; }],
    ["history flag", (value: KnowledgeRestoreHistoryExportPlan) => { value.sourceHistoryChanged = true as false; }],
    ["restore flag", (value: KnowledgeRestoreHistoryExportPlan) => { value.restoreReady = true as false; }],
    ["credentials flag", (value: KnowledgeRestoreHistoryExportPlan) => { value.includesCredentialStores = true as false; }],
    ["operations flag", (value: KnowledgeRestoreHistoryExportPlan) => { value.includesCompletedOperations = true as false; }],
    ["external flag", (value: KnowledgeRestoreHistoryExportPlan) => { value.externalReferencesIncluded = true as false; }],
    ["snapshot flag", (value: KnowledgeRestoreHistoryExportPlan) => { value.consistentSnapshot = true as false; }],
    ["TTL", (value: KnowledgeRestoreHistoryExportPlan) => { value.expiresAtEpochMs += 1; }],
    ["future checked time", (value: KnowledgeRestoreHistoryExportPlan) => { value.checkedAtEpochMs += 1; value.expiresAtEpochMs += 1; }],
  ])("rejects malformed fully bound plan: %s", async (_label, mutate) => {
    const value = exportPlan(); (mutate as (value: KnowledgeRestoreHistoryExportPlan) => void)(value);
    gateway.planKnowledgeRestoreHistoryExport.mockResolvedValue(value);
    await render(); await prepare();
    expect(host.textContent).toContain("计划无效");
    expect(button("确认并一次性导出历史快照资料包")).toBeUndefined();
    if (value.planId === planId) expect(gateway.discardKnowledgeRestoreHistoryExport).toHaveBeenCalledWith(planId);
  });

  it.each([
    ["extra key", (value: KnowledgeRestoreHistoryExportReceipt) => { (value as unknown as Record<string, unknown>).secret = "x"; }],
    ["plan binding", (value: KnowledgeRestoreHistoryExportReceipt) => { value.planId = otherId; }],
    ["selected binding", (value: KnowledgeRestoreHistoryExportReceipt) => { value.selected.projectedManifestSha256 = sha("9"); }],
    ["path binding", (value: KnowledgeRestoreHistoryExportReceipt) => { value.destinationPath = "/tmp/other.json"; }],
    ["byte binding", (value: KnowledgeRestoreHistoryExportReceipt) => { value.byteSize += 1; }],
    ["package hash", (value: KnowledgeRestoreHistoryExportReceipt) => { value.sha256 = sha("9"); }],
    ["manifest hash", (value: KnowledgeRestoreHistoryExportReceipt) => { value.manifestSha256 = sha("9"); }],
    ["source hash", (value: KnowledgeRestoreHistoryExportReceipt) => { value.sourceManifestSha256 = sha("9"); }],
    ["source revalidation", (value: KnowledgeRestoreHistoryExportReceipt) => { value.sourceRevalidated = false as true; }],
    ["contents", (value: KnowledgeRestoreHistoryExportReceipt) => { value.contentsVerified = false as true; }],
    ["permissions", (value: KnowledgeRestoreHistoryExportReceipt) => { value.privatePermissionsVerified = false as true; }],
    ["library changed", (value: KnowledgeRestoreHistoryExportReceipt) => { value.currentLibraryChanged = true as false; }],
    ["history changed", (value: KnowledgeRestoreHistoryExportReceipt) => { value.sourceHistoryChanged = true as false; }],
    ["restore claim", (value: KnowledgeRestoreHistoryExportReceipt) => { value.restoreReady = true as false; }],
    ["completion before plan", (value: KnowledgeRestoreHistoryExportReceipt) => { value.completedAtEpochMs = now - 1; }],
    ["future completion", (value: KnowledgeRestoreHistoryExportReceipt) => { value.completedAtEpochMs = now + 1; }],
  ])("consumes once and rejects malformed receipt: %s", async (_label, mutate) => {
    const value = receipt(); (mutate as (value: KnowledgeRestoreHistoryExportReceipt) => void)(value);
    gateway.executeKnowledgeRestoreHistoryExport.mockResolvedValue(value);
    await render(); await prepare(); await acknowledge(); await click("确认并一次性导出历史快照资料包");
    expect(gateway.executeKnowledgeRestoreHistoryExport).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("可能已经写入，但完成状态未知");
    expect(button("确认并一次性导出历史快照资料包")).toBeUndefined();
  });

  it("consumes capability before an ambiguous failure and never retries", async () => {
    gateway.executeKnowledgeRestoreHistoryExport.mockRejectedValue(new Error("transport lost"));
    await render(); await prepare(); await acknowledge();
    const invoke = handler(button("确认并一次性导出历史快照资料包")!);
    await act(async () => { invoke(); invoke(); });
    expect(gateway.executeKnowledgeRestoreHistoryExport).toHaveBeenCalledTimes(1);
    expect(gateway.inspectKnowledgeRestoreHistoryExport).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("重新手动检查并选择新的路径");
  });

  it("blocks repeated inspect, destination, plan, and execute invocations while busy", async () => {
    const inspection = deferred<KnowledgeRestoreHistoryExportStatus>();
    gateway.inspectKnowledgeRestoreHistoryExport.mockReturnValue(inspection.promise);
    await render();
    const invokeInspect = handler(button("检查恢复历史快照")!);
    act(() => { invokeInspect(); invokeInspect(); });
    expect(gateway.inspectKnowledgeRestoreHistoryExport).toHaveBeenCalledTimes(1);
    await act(async () => inspection.resolve(ready()));
    await select();

    const choosing = deferred<string | null>();
    gateway.selectKnowledgeRestoreHistoryExportDestination.mockReturnValue(choosing.promise);
    const invokeChoose = handler(button("选择新的历史快照 JSON 路径")!);
    act(() => { invokeChoose(); invokeChoose(); });
    expect(gateway.selectKnowledgeRestoreHistoryExportDestination).toHaveBeenCalledTimes(1);
    await act(async () => choosing.resolve(destination));

    const planning = deferred<KnowledgeRestoreHistoryExportPlan>();
    gateway.planKnowledgeRestoreHistoryExport.mockReturnValue(planning.promise);
    const invokePlan = handler(button("明确预览历史快照资料包")!);
    act(() => { invokePlan(); invokePlan(); });
    expect(gateway.planKnowledgeRestoreHistoryExport).toHaveBeenCalledTimes(1);
    await act(async () => planning.resolve(exportPlan()));
    await acknowledge();

    const execution = deferred<KnowledgeRestoreHistoryExportReceipt>();
    gateway.executeKnowledgeRestoreHistoryExport.mockReturnValue(execution.promise);
    const invokeExecute = handler(button("确认并一次性导出历史快照资料包")!);
    act(() => { invokeExecute(); invokeExecute(); });
    expect(gateway.executeKnowledgeRestoreHistoryExport).toHaveBeenCalledTimes(1);
    await act(async () => execution.resolve(receipt()));
  });

  it("discards a late plan through its original gateway after context replacement", async () => {
    const planning = deferred<KnowledgeRestoreHistoryExportPlan>();
    gateway.planKnowledgeRestoreHistoryExport.mockReturnValue(planning.promise);
    await render(); await inspect(); await select(); await click("选择新的历史快照 JSON 路径"); await click("明确预览历史快照资料包");
    const original = gateway;
    const replacement: MockGateway = {
      inspectKnowledgeRestoreHistoryExport: vi.fn(async () => ready()),
      selectKnowledgeRestoreHistoryExportDestination: vi.fn(async () => destination),
      planKnowledgeRestoreHistoryExport: vi.fn(async () => exportPlan()),
      executeKnowledgeRestoreHistoryExport: vi.fn(async () => receipt()),
      discardKnowledgeRestoreHistoryExport: vi.fn(async () => undefined),
    };
    await render({ gateway: replacement as unknown as KnowledgeRestoreHistoryExportGateway, refreshKey: 1 });
    await act(async () => planning.resolve(exportPlan()));
    expect(original.discardKnowledgeRestoreHistoryExport).toHaveBeenCalledWith(planId);
    expect(replacement.discardKnowledgeRestoreHistoryExport).not.toHaveBeenCalled();
    expect(button("确认并一次性导出历史快照资料包")).toBeUndefined();
  });

  it("invalidates a plan when the selected history or destination changes", async () => {
    await render(); await prepare();
    await select(olderId);
    expect(gateway.discardKnowledgeRestoreHistoryExport).toHaveBeenCalledWith(planId);
    expect(button("确认并一次性导出历史快照资料包")).toBeUndefined();
    gateway.planKnowledgeRestoreHistoryExport.mockResolvedValue(exportPlan(older()));
    await click("选择新的历史快照 JSON 路径"); await click("明确预览历史快照资料包");
    gateway.selectKnowledgeRestoreHistoryExportDestination.mockResolvedValue("/tmp/new-history.json");
    await click("选择新的历史快照 JSON 路径");
    expect(gateway.discardKnowledgeRestoreHistoryExport).toHaveBeenCalledTimes(2);
    expect(button("确认并一次性导出历史快照资料包")).toBeUndefined();
  });

  it("expires at five minutes and requires a complete new inspection", async () => {
    await render(); await prepare();
    await act(async () => { vi.advanceTimersByTime(300_000); });
    expect(gateway.discardKnowledgeRestoreHistoryExport).toHaveBeenCalledWith(planId);
    expect(host.textContent).toContain("计划已过期");
    expect(button("选择新的历史快照 JSON 路径")).toBeUndefined();
  });

  it("invalidates acknowledged capability when the clock rolls backward", async () => {
    await render(); await prepare(); await acknowledge();
    const invoke = handler(button("确认并一次性导出历史快照资料包")!);
    vi.setSystemTime(now - 1);
    await act(async () => { invoke(); });
    expect(gateway.executeKnowledgeRestoreHistoryExport).not.toHaveBeenCalled();
    expect(gateway.discardKnowledgeRestoreHistoryExport).toHaveBeenCalledWith(planId);
    expect(host.textContent).toContain("系统时间已变化");
  });

  it("defensively copies status, plan, and receipt objects", async () => {
    const sourceStatus = ready();
    const sourcePlan = exportPlan();
    const sourceReceipt = receipt();
    gateway.inspectKnowledgeRestoreHistoryExport.mockResolvedValue(sourceStatus);
    gateway.planKnowledgeRestoreHistoryExport.mockResolvedValue(sourcePlan);
    gateway.executeKnowledgeRestoreHistoryExport.mockResolvedValue(sourceReceipt);
    await render(); await inspect();
    sourceStatus.history[0].transactionId = otherId;
    await select(); await click("选择新的历史快照 JSON 路径"); await click("明确预览历史快照资料包");
    sourcePlan.selected.transactionId = otherId;
    await acknowledge(); await click("确认并一次性导出历史快照资料包");
    sourceReceipt.selected.transactionId = otherId;
    expect(host.textContent).toContain(`事务 UUID：${newestId}`);
    expect(host.textContent).not.toContain(`事务 UUID：${otherId}`);
  });

  it("clears and discards capability when disabled, refreshed, or hidden", async () => {
    await render(); await prepare();
    await render({ disabled: true });
    expect(gateway.discardKnowledgeRestoreHistoryExport).toHaveBeenCalledWith(planId);
    expect(button("检查恢复历史快照")!.disabled).toBe(true);
    await render({ refreshKey: 2 });
    expect(button("选择新的历史快照 JSON 路径")).toBeUndefined();
    await render({ enabled: false });
    expect(host.textContent).toBe("");
  });
});
