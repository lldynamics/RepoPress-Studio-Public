import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RssSnapshotBackupGateway, RssSnapshotBackupPlan, RssSnapshotBackupResult } from "../contracts/rssSnapshotBackup";
import { RSS_SNAPSHOT_EXCLUSIONS, RSS_SNAPSHOT_TABLES } from "../contracts/rssSnapshotBackup";
import { RssSnapshotBackupPanel } from "./RssSnapshotBackupPanel";

const clock = Date.now(); const destinationPath = "/tmp/repopress-rss-snapshot.sqlite";
const makePlan = (overrides: Partial<RssSnapshotBackupPlan> = {}): RssSnapshotBackupPlan => ({
  planId: "11111111-1111-4111-8111-111111111111", scope: "applicationRssDatabase", format: "sqlite3", schemaVersion: 1, databaseSchemaVersion: 4,
  destinationPath, tables: RSS_SNAPSHOT_TABLES.map((table, index) => ({ table, rowCount: index })), exclusions: [...RSS_SNAPSHOT_EXCLUSIONS],
  structureVerified: true, consistentSnapshot: true, includesCredentialStores: false, includesUndoActions: true, compactedCopy: true,
  byteSize: 4096, sha256: "a".repeat(64), createdAtEpochMs: clock, expiresAtEpochMs: clock + 300_000, ...overrides,
});
const result: RssSnapshotBackupResult = { planId: makePlan().planId, destinationPath, byteSize: 4096, sha256: "a".repeat(64) };
type Gateway = { [K in keyof RssSnapshotBackupGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: Gateway;
async function render(props: Partial<React.ComponentProps<typeof RssSnapshotBackupPanel>> = {}) { await act(async () => root.render(createElement(RssSnapshotBackupPanel, { gateway: gateway as unknown as RssSnapshotBackupGateway, enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function preview() { await settle(); const choose = button(/选择新的 SQLite/); expect(choose).toBeDefined(); await act(async () => choose!.click()); await settle(); const planButton = button(/明确预览 RSS/); expect(planButton).toBeDefined(); await act(async () => planButton!.click()); await settle(); await settle(); }

describe("RssSnapshotBackupPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(clock); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { selectRssSnapshotBackupDestination: vi.fn(async () => destinationPath), planRssSnapshotBackup: vi.fn(async () => makePlan()), executeRssSnapshotBackup: vi.fn(async () => result), discardRssSnapshotBackup: vi.fn(async () => undefined) } as unknown as Gateway; });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("does not read automatically and requires explicit path, preview, sensitive consent, and one export", async () => {
    await render(); await settle(); expect(gateway.selectRssSnapshotBackupDestination).not.toHaveBeenCalled(); expect(gateway.planRssSnapshotBackup).not.toHaveBeenCalled();
    await preview(); expect(gateway.planRssSnapshotBackup).toHaveBeenCalledWith(destinationPath); expect(host.textContent).toContain("敏感 RSS 明文"); expect(host.textContent).toContain("RSS 数据库快照");
    const execute = button(/明确一次性导出 RSS 快照/); expect(execute).toBeDefined(); expect(execute!.disabled).toBe(true);
    const consent = host.querySelector("#rss-snapshot-backup-consent") as HTMLInputElement; await act(async () => consent.click()); await act(async () => execute!.click()); await settle(); await settle();
    expect(gateway.executeRssSnapshotBackup).toHaveBeenCalledWith(makePlan().planId, true);
  });

  it("does not plan when save is cancelled and rejects relative or wrong-extension paths", async () => {
    gateway.selectRssSnapshotBackupDestination.mockResolvedValueOnce(null); await render(); await act(async () => button(/选择新的 SQLite/)!.click()); await settle(); expect(gateway.planRssSnapshotBackup).not.toHaveBeenCalled();
    gateway.selectRssSnapshotBackupDestination.mockResolvedValueOnce("relative.sqlite"); await act(async () => button(/选择新的 SQLite/)!.click()); await settle(); expect(gateway.planRssSnapshotBackup).not.toHaveBeenCalled();
    gateway.selectRssSnapshotBackupDestination.mockResolvedValueOnce("/tmp/wrong.json"); await act(async () => button(/选择新的 SQLite/)!.click()); await settle(); expect(gateway.planRssSnapshotBackup).not.toHaveBeenCalled();
  });

  it.each([
    ["scope", { scope: "wrong" as never }], ["format", { format: "sqlite2" as never }], ["protocol schema", { schemaVersion: 2 }], ["database schema", { databaseSchemaVersion: 3 }],
    ["tables", { tables: [{ table: "meta", rowCount: -1 }] as never }], ["table order", { tables: [...makePlan().tables].reverse() }], ["exclusions", { exclusions: [] }], ["duplicate exclusion", { exclusions: [RSS_SNAPSHOT_EXCLUSIONS[0], ...RSS_SNAPSHOT_EXCLUSIONS] }],
    ["flags", { structureVerified: false }], ["snapshot flag", { consistentSnapshot: false }], ["credential flag", { includesCredentialStores: true }], ["undo flag", { includesUndoActions: false }], ["compaction flag", { compactedCopy: false }], ["zero size", { byteSize: 0 }],
    ["too large", { byteSize: 32 * 1024 * 1024 + 1 }], ["expired", { createdAtEpochMs: clock - 300_001, expiresAtEpochMs: clock - 1 }], ["TTL", { expiresAtEpochMs: clock + 299_999 }], ["bad SHA", { sha256: "Z".repeat(64) }], ["destination", { destinationPath: "/tmp/other.sqlite" }],
  ])("rejects malformed %s plans without execute", async (_name, invalid) => { gateway.planRssSnapshotBackup.mockResolvedValueOnce(makePlan(invalid as Partial<RssSnapshotBackupPlan>)); await render(); await preview(); expect(host.textContent).toMatch(/无法|失败|无效/); expect(gateway.executeRssSnapshotBackup).not.toHaveBeenCalled(); });

  it.each([
    ["id", { planId: "22222222-2222-4222-8222-222222222222" }], ["path", { destinationPath: "/tmp/other.sqlite" }], ["bytes", { byteSize: 1 }], ["hash", { sha256: "b".repeat(64) }],
  ])("rejects mismatched %s result and makes only one execute attempt", async (_name, invalid) => {
    gateway.executeRssSnapshotBackup.mockResolvedValueOnce({ ...result, ...invalid }); await render(); await preview();
    const consent = host.querySelector("#rss-snapshot-backup-consent") as HTMLInputElement; await act(async () => consent.click()); const execute = button(/明确一次性导出 RSS 快照/); await act(async () => execute!.click()); await settle(); await settle();
    expect(gateway.executeRssSnapshotBackup).toHaveBeenCalledTimes(1); expect(host.textContent).not.toContain("已导出并核验");
  });

  it("expires, cancels, invalidates late plans, and consumes unknown receipts without retry", async () => {
    await render(); await preview(); const consent = host.querySelector("#rss-snapshot-backup-consent") as HTMLInputElement; await act(async () => consent.click());
    await act(async () => vi.advanceTimersByTime(300_001)); await settle(); expect(gateway.executeRssSnapshotBackup).not.toHaveBeenCalled();
    gateway.executeRssSnapshotBackup.mockRejectedValueOnce(new Error("unknown")); gateway.planRssSnapshotBackup.mockResolvedValueOnce(makePlan({ createdAtEpochMs: Date.now(), expiresAtEpochMs: Date.now() + 300_000 })); await render({ refreshKey: 1 }); await preview();
    const nextConsent = host.querySelector("#rss-snapshot-backup-consent") as HTMLInputElement; await act(async () => nextConsent.click()); const execute = button(/明确一次性导出 RSS 快照/); await act(async () => execute!.click()); await settle(); await settle(); expect(gateway.executeRssSnapshotBackup).toHaveBeenCalledTimes(1);
  });

  it("discards a late plan on gateway/refresh change and cannot use consent after cancellation", async () => {
    let resolve!: (value: RssSnapshotBackupPlan) => void; gateway.planRssSnapshotBackup.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await render(); const choose = button(/选择新的 SQLite/); await act(async () => choose!.click()); await settle(); const planButton = button(/明确预览 RSS/); await act(async () => planButton!.click());
    const oldGateway = gateway; gateway = { selectRssSnapshotBackupDestination: vi.fn(async () => destinationPath), planRssSnapshotBackup: vi.fn(), executeRssSnapshotBackup: vi.fn(), discardRssSnapshotBackup: vi.fn(async () => undefined) } as unknown as Gateway; await render({ refreshKey: 2 }); resolve(makePlan()); await settle(); expect(oldGateway.discardRssSnapshotBackup).toHaveBeenCalledWith(makePlan().planId); expect(gateway.executeRssSnapshotBackup).not.toHaveBeenCalled();
  });

  it("clears plan and consent when disabled, closed, unmounted, or destination is replaced", async () => {
    await render(); await preview();
    await render({ enabled: false }); await settle(); expect(gateway.discardRssSnapshotBackup).toHaveBeenCalledWith(makePlan().planId);
    await render({ enabled: true }); await preview(); await render({ disabled: true }); await settle(); expect(gateway.discardRssSnapshotBackup).toHaveBeenCalledWith(makePlan().planId);
    await render({ disabled: false }); await preview(); const oldChoose = button(/选择新的 SQLite/); await act(async () => oldChoose!.click()); await settle(); expect(gateway.discardRssSnapshotBackup).toHaveBeenCalledWith(makePlan().planId);
    await act(async () => root.unmount()); expect(gateway.discardRssSnapshotBackup).toHaveBeenCalled(); root = createRoot(host);
  });

  it("cannot execute an approved plan after consent is revoked and cancelled in the same batch", async () => {
    await render(); await preview(); const consent = host.querySelector("#rss-snapshot-backup-consent") as HTMLInputElement; await act(async () => consent.click()); const execute = button(/明确一次性导出 RSS 快照/); const cancel = button(/取消 RSS 快照计划/); await act(async () => { consent.click(); cancel!.click(); execute!.click(); }); await settle();
    expect(gateway.executeRssSnapshotBackup).not.toHaveBeenCalled();
  });
});
