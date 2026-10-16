import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DraftSnapshotBackupGateway, DraftSnapshotBackupPlan, DraftSnapshotBackupResult, DraftSnapshotSource } from "../contracts/draftSnapshotBackup";
import { DRAFT_SNAPSHOT_EXCLUSIONS, DRAFT_SNAPSHOT_MAX_BYTES, DRAFT_SNAPSHOT_TABLES } from "../contracts/draftSnapshotBackup";
import { DraftSnapshotBackupPanel } from "./DraftSnapshotBackupPanel";

const clock = Date.now();
const destinations = { generalDrafts: "/tmp/repopress-general-drafts.sqlite", draftHistory: "/tmp/repopress-draft-history.sqlite" } as const;
const makePlan = (source: DraftSnapshotSource = "generalDrafts", overrides: Partial<DraftSnapshotBackupPlan> = {}): DraftSnapshotBackupPlan => ({
  planId: source === "generalDrafts" ? "11111111-1111-4111-8111-111111111111" : "22222222-2222-4222-8222-222222222222", scope: "applicationDraftDatabase", format: "sqlite3", schemaVersion: 1,
  source, sourceSchema: "unversionedInstalledLayout", destinationPath: destinations[source], tables: DRAFT_SNAPSHOT_TABLES[source].map((table, index) => ({ table, rowCount: index })),
  exclusions: [...DRAFT_SNAPSHOT_EXCLUSIONS], structureVerified: true, contentVerified: true, consistentSnapshot: true, multiDatabaseSnapshot: false, includesCredentialStores: false,
  includesRecycledDrafts: source === "draftHistory", compactedCopy: true, byteSize: 800, sha256: "a".repeat(64), createdAtEpochMs: clock, expiresAtEpochMs: clock + 300_000, ...overrides,
});
const resultFor = (plan: DraftSnapshotBackupPlan): DraftSnapshotBackupResult => ({ planId: plan.planId, source: plan.source, destinationPath: plan.destinationPath, byteSize: plan.byteSize, sha256: plan.sha256 });
type Gateway = { [K in keyof DraftSnapshotBackupGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: Gateway;
async function render(props: Partial<React.ComponentProps<typeof DraftSnapshotBackupPanel>> = {}) { await act(async () => root.render(createElement(DraftSnapshotBackupPanel, { gateway: gateway as unknown as DraftSnapshotBackupGateway, enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function preview(source: DraftSnapshotSource = "generalDrafts") { await settle(); if (source === "draftHistory") { const input = host.querySelectorAll<HTMLInputElement>("input[type=radio]")[1]; expect(input).toBeDefined(); await act(async () => input!.click()); await settle(); } await act(async () => button(/选择新的草稿 SQLite/)!.click()); await settle(); await act(async () => button(/明确预览草稿快照/)!.click()); await settle(); await settle(); }

describe("DraftSnapshotBackupPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(clock); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { selectDraftSnapshotBackupDestination: vi.fn(async (source: DraftSnapshotSource) => destinations[source]), planDraftSnapshotBackup: vi.fn(async (source: DraftSnapshotSource) => makePlan(source)), executeDraftSnapshotBackup: vi.fn(async (id: string) => resultFor(id === makePlan("draftHistory").planId ? makePlan("draftHistory") : makePlan())), discardDraftSnapshotBackup: vi.fn(async () => undefined) } as unknown as Gateway; });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("does not read automatically and requires path, preview, sensitive consent, and one export", async () => {
    await render(); await settle(); expect(gateway.selectDraftSnapshotBackupDestination).not.toHaveBeenCalled(); expect(gateway.planDraftSnapshotBackup).not.toHaveBeenCalled();
    await preview(); expect(gateway.planDraftSnapshotBackup).toHaveBeenCalledWith("generalDrafts", destinations.generalDrafts); expect(host.textContent).toContain("敏感草稿明文");
    const execute = button(/明确一次性导出草稿快照/)!; expect(execute.disabled).toBe(true); const consent = host.querySelector("#draft-snapshot-backup-consent") as HTMLInputElement; await act(async () => consent.click()); await act(async () => execute.click()); await settle(); await settle();
    expect(gateway.executeDraftSnapshotBackup).toHaveBeenCalledWith(makePlan().planId, true); expect(host.textContent).toContain("已导出并核验");
  });

  it("supports exact single-source scopes and explains history across repositories and recycle content", async () => {
    await render(); await preview("draftHistory"); expect(gateway.planDraftSnapshotBackup).toHaveBeenCalledWith("draftHistory", destinations.draftHistory); expect(host.textContent).toContain("历史草稿"); expect(host.textContent).toContain("版本"); expect(host.textContent).toContain("回收草稿"); expect(host.textContent).toMatch(/跨所有仓库|回收/);
  });

  it("validates unsafe row counts across the complete three-table history scope", async () => {
    gateway.planDraftSnapshotBackup.mockResolvedValueOnce(makePlan("draftHistory", { tables: [{ table: "drafts", rowCount: 0 }, { table: "versions", rowCount: Number.MAX_SAFE_INTEGER + 1 }, { table: "recycled_drafts", rowCount: 0 }] as never }));
    await render(); await preview("draftHistory"); expect(host.textContent).toMatch(/无法|失败|无效/); expect(gateway.executeDraftSnapshotBackup).not.toHaveBeenCalled();
  });

  it("does not plan cancelled, relative, or wrong-extension destinations", async () => {
    await render(); gateway.selectDraftSnapshotBackupDestination.mockResolvedValueOnce(null); await act(async () => button(/选择新的草稿 SQLite/)!.click()); await settle(); expect(gateway.planDraftSnapshotBackup).not.toHaveBeenCalled();
    gateway.selectDraftSnapshotBackupDestination.mockResolvedValueOnce("relative.sqlite"); await act(async () => button(/选择新的草稿 SQLite/)!.click()); await settle(); expect(gateway.planDraftSnapshotBackup).not.toHaveBeenCalled();
    gateway.selectDraftSnapshotBackupDestination.mockResolvedValueOnce("/tmp/not-json.json"); await act(async () => button(/选择新的草稿 SQLite/)!.click()); await settle(); expect(gateway.planDraftSnapshotBackup).not.toHaveBeenCalled();
  });

  it.each([
    ["scope", { scope: "wrong" as never }], ["source schema", { sourceSchema: "v2" as never }], ["format", { format: "sqlite" as never }], ["protocol", { schemaVersion: 2 }],
    ["table count", { tables: [] as never }], ["table order", { tables: [{ table: "wrong_table", rowCount: 0 }] as never }], ["negative rows", { tables: [{ table: "general_drafts", rowCount: -1 }] as never }], ["unsafe rows", { tables: [{ table: "general_drafts", rowCount: Number.MAX_SAFE_INTEGER + 1 }] as never }],
    ["duplicate exclusions", { exclusions: [DRAFT_SNAPSHOT_EXCLUSIONS[0], ...DRAFT_SNAPSHOT_EXCLUSIONS] }], ["structure flag", { structureVerified: false }], ["content flag", { contentVerified: false }], ["consistent flag", { consistentSnapshot: false }], ["multi database", { multiDatabaseSnapshot: true }], ["credentials", { includesCredentialStores: true }], ["recycled flag", { includesRecycledDrafts: true }], ["compacted flag", { compactedCopy: false }],
    ["zero bytes", { byteSize: 0 }], ["too large", { byteSize: DRAFT_SNAPSHOT_MAX_BYTES + 1 }], ["bad SHA", { sha256: "Z".repeat(64) }], ["future", { createdAtEpochMs: clock + 1, expiresAtEpochMs: clock + 300001 }], ["expired", { createdAtEpochMs: clock - 300001, expiresAtEpochMs: clock - 1 }], ["TTL", { expiresAtEpochMs: clock + 299999 }], ["destination", { destinationPath: "/tmp/other.sqlite" }],
  ])("rejects malformed %s plans without execute", async (_name, invalid) => { gateway.planDraftSnapshotBackup.mockResolvedValueOnce(makePlan("generalDrafts", invalid as Partial<DraftSnapshotBackupPlan>)); await render(); await preview(); expect(host.textContent).toMatch(/无法|失败|无效/); expect(gateway.executeDraftSnapshotBackup).not.toHaveBeenCalled(); });

  it.each([["id", { planId: "33333333-3333-4333-8333-333333333333" }], ["source", { source: "draftHistory" as never }], ["path", { destinationPath: "/tmp/other.sqlite" }], ["bytes", { byteSize: 1 }], ["hash", { sha256: "b".repeat(64) }]])("rejects mismatched %s receipt and consumes it once", async (_name, invalid) => { const plan = makePlan(); gateway.executeDraftSnapshotBackup.mockResolvedValueOnce({ ...resultFor(plan), ...invalid }); await render(); await preview(); await act(async () => (host.querySelector("#draft-snapshot-backup-consent") as HTMLInputElement).click()); await act(async () => button(/明确一次性导出草稿快照/)!.click()); await settle(); await settle(); expect(gateway.executeDraftSnapshotBackup).toHaveBeenCalledTimes(1); expect(host.textContent).not.toContain("已导出并核验"); });

  it("requires consent, consumes failures without retry, and synchronously blocks a cancelled old DOM action", async () => { await render(); await preview(); const consent = host.querySelector("#draft-snapshot-backup-consent") as HTMLInputElement; const execute = button(/明确一次性导出草稿快照/)!; expect(execute.disabled).toBe(true); await act(async () => consent.click()); gateway.executeDraftSnapshotBackup.mockRejectedValueOnce(new Error("unknown")); await act(async () => execute.click()); await settle(); await settle(); expect(gateway.executeDraftSnapshotBackup).toHaveBeenCalledTimes(1); await act(async () => execute.click()); expect(gateway.executeDraftSnapshotBackup).toHaveBeenCalledTimes(1);
    await render(); await preview(); const oldExecute = button(/明确一次性导出草稿快照/)!; await act(async () => { (host.querySelector("#draft-snapshot-backup-consent") as HTMLInputElement).click(); button(/取消草稿快照计划/)!.click(); oldExecute.click(); }); expect(gateway.executeDraftSnapshotBackup).toHaveBeenCalledTimes(1); });

  it("guards consent revocation and plan cancellation independently", async () => {
    await render(); await preview(); const consent = host.querySelector("#draft-snapshot-backup-consent") as HTMLInputElement; await act(async () => consent.click()); await act(async () => consent.click()); const executeAfterRevoke = button(/明确一次性导出草稿快照/)!; await act(async () => executeAfterRevoke.click()); expect(gateway.executeDraftSnapshotBackup).not.toHaveBeenCalled();
    await render(); await preview(); await act(async () => (host.querySelector("#draft-snapshot-backup-consent") as HTMLInputElement).click()); const executeAfterCancel = button(/明确一次性导出草稿快照/)!; await act(async () => button(/取消草稿快照计划/)!.click()); await act(async () => executeAfterCancel.click()); expect(gateway.executeDraftSnapshotBackup).not.toHaveBeenCalled();
  });

  it("invalidates an approved plan when the source changes, including an old DOM execute click", async () => {
    await render(); await preview(); await act(async () => (host.querySelector("#draft-snapshot-backup-consent") as HTMLInputElement).click()); const oldExecute = button(/明确一次性导出草稿快照/)!; await act(async () => host.querySelectorAll<HTMLInputElement>("input[type=radio]")[1].click()); await settle(); await act(async () => oldExecute.click()); expect(gateway.executeDraftSnapshotBackup).not.toHaveBeenCalled(); expect(gateway.discardDraftSnapshotBackup).toHaveBeenCalledWith(makePlan().planId);
  });

  it("discards and drops consent on source, destination, refresh, disabled, gateway, close, or unmount changes", async () => { await render(); await preview(); const first = makePlan(); await render({ refreshKey: 1 }); expect(gateway.discardDraftSnapshotBackup).toHaveBeenCalledWith(first.planId); expect(gateway.executeDraftSnapshotBackup).not.toHaveBeenCalled(); await render(); await preview(); await act(async () => host.querySelectorAll<HTMLInputElement>("input[type=radio]")[1].click()); await settle(); expect(gateway.discardDraftSnapshotBackup).toHaveBeenCalled(); await render(); await preview(); await render({ enabled: false }); expect(gateway.discardDraftSnapshotBackup).toHaveBeenCalled(); expect(gateway.executeDraftSnapshotBackup).not.toHaveBeenCalled(); await render({ enabled: true }); await preview(); const old = gateway; gateway = { ...gateway, discardDraftSnapshotBackup: vi.fn(async () => undefined) }; await render({ refreshKey: 2 }); expect(old.discardDraftSnapshotBackup).toHaveBeenCalled(); expect(gateway.executeDraftSnapshotBackup).not.toHaveBeenCalled(); await act(async () => root.unmount()); expect(old.discardDraftSnapshotBackup).toHaveBeenCalled(); root = createRoot(host); });

  it("discards a late plan through the original gateway and never uses it", async () => { let resolve!: (plan: DraftSnapshotBackupPlan) => void; gateway.planDraftSnapshotBackup.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await render(); await act(async () => button(/选择新的草稿 SQLite/)!.click()); await settle(); await act(async () => button(/明确预览草稿快照/)!.click()); const old = gateway; const replacement = { selectDraftSnapshotBackupDestination: vi.fn(), planDraftSnapshotBackup: vi.fn(), executeDraftSnapshotBackup: vi.fn(), discardDraftSnapshotBackup: vi.fn(async () => undefined) } as unknown as Gateway; gateway = replacement; await render({ refreshKey: 1 }); resolve(makePlan()); await settle(); expect(old.discardDraftSnapshotBackup).toHaveBeenCalledWith(makePlan().planId); expect(replacement.executeDraftSnapshotBackup).not.toHaveBeenCalled(); });
});
