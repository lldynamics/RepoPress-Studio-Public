import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { KnowledgeBackupGateway, KnowledgeBackupPlan, KnowledgeBackupResult } from "../contracts/knowledgeBackup";
import { KNOWLEDGE_BACKUP_EXCLUSIONS, KNOWLEDGE_BACKUP_LIMITS } from "../contracts/knowledgeBackup";
import { KnowledgeBackupPanel } from "./KnowledgeBackupPanel";

const clock = 1_700_000_000_000;
const destination = "/tmp/repopress-knowledge.json";
const makePlan = (overrides: Partial<KnowledgeBackupPlan> = {}): KnowledgeBackupPlan => ({
  planId: "11111111-1111-4111-8111-111111111111", scope: "applicationSavedKnowledge", format: "repopress-knowledge-saved-files", schemaVersion: 1,
  sourceManifestSchemaVersion: 4, destinationPath: destination, itemCount: 3, revisionCount: 7, bodyFileCount: 3, archiveFileCount: 2,
  resourceByteSize: 800, byteSize: 1200, sha256: "a".repeat(64), exclusions: [...KNOWLEDGE_BACKUP_EXCLUSIONS], limits: KNOWLEDGE_BACKUP_LIMITS,
  structureVerified: true, contentVerified: true, allSavedReferencesIncluded: true, consistentSnapshot: false, includesCredentialStores: false,
  includesCompletedOperations: false, externalReferencesIncluded: false, createdAtEpochMs: clock, expiresAtEpochMs: clock + 300_000, ...overrides,
});
const resultFor = (plan: KnowledgeBackupPlan): KnowledgeBackupResult => ({ planId: plan.planId, destinationPath: plan.destinationPath, byteSize: plan.byteSize, sha256: plan.sha256 });
type Gateway = { [K in keyof KnowledgeBackupGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: Gateway;
async function render(props: Partial<React.ComponentProps<typeof KnowledgeBackupPanel>> = {}) { await act(async () => root.render(createElement(KnowledgeBackupPanel, { gateway: gateway as unknown as KnowledgeBackupGateway, enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(pattern: RegExp) { return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }
async function preview() { await settle(); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); await act(async () => button(/明确预览资料备份包/)!.click()); await settle(); await settle(); }

describe("KnowledgeBackupPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(clock); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = {
    selectKnowledgeBackupDestination: vi.fn(async () => destination), planKnowledgeBackup: vi.fn(async () => makePlan()), executeKnowledgeBackup: vi.fn(async (id: string) => resultFor(makePlan({ planId: id }))), discardKnowledgeBackup: vi.fn(async () => undefined),
  } as unknown as Gateway; });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("is lazy and requires an explicitly selected JSON path, preview, and sensitive consent", async () => {
    await render(); await settle(); expect(host.textContent).toContain("资料保存文件备份包"); expect(gateway.selectKnowledgeBackupDestination).not.toHaveBeenCalled(); expect(gateway.planKnowledgeBackup).not.toHaveBeenCalled();
    await preview(); expect(gateway.planKnowledgeBackup).toHaveBeenCalledWith(destination); expect(host.textContent).toContain("敏感资料明文"); expect(button(/明确一次性导出资料备份包/)!.disabled).toBe(true);
    await act(async () => (host.querySelector("#knowledge-backup-consent") as HTMLInputElement).click()); await act(async () => button(/明确一次性导出资料备份包/)!.click()); await settle(); await settle();
    expect(gateway.executeKnowledgeBackup).toHaveBeenCalledWith(makePlan().planId, true); expect(host.textContent).toContain("已导出并核验"); expect(host.textContent).not.toMatch(/secret|password|fixture-secret/);
  });

  it("does not plan cancelled, relative, or wrong-extension destinations", async () => {
    await render(); gateway.selectKnowledgeBackupDestination.mockResolvedValueOnce(null); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); expect(gateway.planKnowledgeBackup).not.toHaveBeenCalled();
    gateway.selectKnowledgeBackupDestination.mockResolvedValueOnce("relative.json"); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); expect(gateway.planKnowledgeBackup).not.toHaveBeenCalled();
    gateway.selectKnowledgeBackupDestination.mockResolvedValueOnce("/tmp/wrong.sqlite"); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); expect(gateway.planKnowledgeBackup).not.toHaveBeenCalled();
    gateway.selectKnowledgeBackupDestination.mockResolvedValueOnce("/tmp/UPPER.JSON"); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); expect(gateway.planKnowledgeBackup).not.toHaveBeenCalled(); expect(host.textContent).toMatch(/小写|无法/);
  });

  it.each([
    ["scope", { scope: "wrong" as never }], ["format", { format: "json" as never }], ["schema", { schemaVersion: 2 }], ["manifest version", { sourceManifestSchemaVersion: 3 }],
    ["counts", { itemCount: -1 }], ["too many items", { itemCount: 2001 }], ["unsafe counts", { revisionCount: Number.MAX_SAFE_INTEGER + 1 }], ["body count", { bodyFileCount: 2001 }], ["revisions per item", { revisionCount: 97 }], ["nonempty body with zero items", { itemCount: 0, bodyFileCount: 1 }], ["too many resource files", { bodyFileCount: 1024, archiveFileCount: 1 }],
    ["body exceeds revisions", { bodyFileCount: 8, revisionCount: 7 }], ["archive exceeds revisions", { archiveFileCount: 8, revisionCount: 7 }], ["empty items revisions with archive", { itemCount: 0, revisionCount: 0, bodyFileCount: 0, archiveFileCount: 1 }], ["resource bytes", { resourceByteSize: KNOWLEDGE_BACKUP_LIMITS.resourceBytes + 1 }], ["package smaller than resources", { resourceByteSize: 800, byteSize: 799 }], ["empty files with resources", { bodyFileCount: 0, archiveFileCount: 0, resourceByteSize: 1 }], ["package bytes", { byteSize: KNOWLEDGE_BACKUP_LIMITS.packageBytes + 1 }], ["manifest bytes", { resourceByteSize: KNOWLEDGE_BACKUP_LIMITS.manifestBytes + 1 }],
    ["flags", { structureVerified: false }], ["content flag", { contentVerified: false }], ["reference flag", { allSavedReferencesIncluded: false }], ["credentials", { includesCredentialStores: true }], ["completed", { includesCompletedOperations: true }], ["external", { externalReferencesIncluded: true }],
    ["limits", { limits: { ...KNOWLEDGE_BACKUP_LIMITS, durationMs: 1 } as never }], ["exclusions", { exclusions: [KNOWLEDGE_BACKUP_EXCLUSIONS[0], ...KNOWLEDGE_BACKUP_EXCLUSIONS] }], ["SHA", { sha256: "Z".repeat(64) }],
    ["future", { createdAtEpochMs: clock + 1, expiresAtEpochMs: clock + 300_001 }], ["expired", { createdAtEpochMs: clock - 300_001, expiresAtEpochMs: clock - 1 }], ["TTL", { expiresAtEpochMs: clock + 299_999 }], ["path", { destinationPath: "/tmp/other.json" }],
  ])("rejects malformed %s plans and never enables execute", async (_name, invalid) => { gateway.planKnowledgeBackup.mockResolvedValueOnce(makePlan(invalid as Partial<KnowledgeBackupPlan>)); await render(); await preview(); expect(host.textContent).toMatch(/无法|失败|无效/); expect(gateway.executeKnowledgeBackup).not.toHaveBeenCalled(); });

  it("accepts a semantically valid limits object whose key order differs", async () => { const reordered = { durationMs: 5000, packageBytes: 48 * 1024 * 1024, resourceBytes: 32 * 1024 * 1024, resourceFiles: 1024, manifestBytes: 2 * 1024 * 1024 }; gateway.planKnowledgeBackup.mockResolvedValueOnce(makePlan({ limits: reordered as never })); await render(); await preview(); expect(host.textContent).toContain("资料备份包预览"); expect(gateway.executeKnowledgeBackup).not.toHaveBeenCalled(); });

  it.each(["limits", "exclusions", "missing nested objects"])("rejects null or missing %s DTO members and discards an identifiable plan", async (kind) => { const plan = makePlan(); const invalid = kind === "limits" ? { ...plan, limits: null } : kind === "exclusions" ? { ...plan, exclusions: null } : (() => { const { limits: _, ...rest } = plan; return rest; })(); gateway.planKnowledgeBackup.mockResolvedValueOnce(invalid as never); await render(); await preview(); expect(host.textContent).toMatch(/无法|失败|无效/); expect(gateway.discardKnowledgeBackup).toHaveBeenCalledWith(plan.planId); });

  it("requires the checkbox after preview, consumes double clicks and failures once, and never claims malformed receipts", async () => {
    await render(); await preview(); const consent = host.querySelector("#knowledge-backup-consent") as HTMLInputElement; const execute = button(/明确一次性导出资料备份包/)!; await act(async () => execute.click()); expect(gateway.executeKnowledgeBackup).not.toHaveBeenCalled(); await act(async () => consent.click());
    gateway.executeKnowledgeBackup.mockResolvedValueOnce({ ...resultFor(makePlan()), sha256: "b".repeat(64) }); await act(async () => { execute.click(); execute.click(); }); await settle(); await settle(); expect(gateway.executeKnowledgeBackup).toHaveBeenCalledTimes(1); expect(host.textContent).not.toContain("已导出并核验");
    await render(); await preview(); await act(async () => (host.querySelector("#knowledge-backup-consent") as HTMLInputElement).click()); gateway.executeKnowledgeBackup.mockRejectedValueOnce(new Error("unavailable")); const retry = button(/明确一次性导出资料备份包/)!; await act(async () => retry.click()); await settle(); await settle(); await act(async () => retry.click()); expect(gateway.executeKnowledgeBackup).toHaveBeenCalledTimes(2); expect(host.textContent).toMatch(/失败|无法/);
  });

  it("invalidates consent and captured old DOM actions on cancel or new destination", async () => { await render(); await preview(); await act(async () => (host.querySelector("#knowledge-backup-consent") as HTMLInputElement).click()); const oldExecute = button(/明确一次性导出资料备份包/)!; await act(async () => button(/取消资料备份计划/)!.click()); await act(async () => oldExecute.click()); expect(gateway.executeKnowledgeBackup).not.toHaveBeenCalled();
    await render(); await preview(); await act(async () => (host.querySelector("#knowledge-backup-consent") as HTMLInputElement).click()); const second = button(/明确一次性导出资料备份包/)!; gateway.selectKnowledgeBackupDestination.mockResolvedValueOnce("/tmp/repopress-knowledge-new.json"); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); await act(async () => second.click()); expect(gateway.executeKnowledgeBackup).not.toHaveBeenCalled(); expect(gateway.discardKnowledgeBackup).toHaveBeenCalledWith(makePlan().planId); });

  it("repeatedly selects from an existing plan, clears consent on success or cancel, and allows a new prepare", async () => { await render(); await preview(); await act(async () => (host.querySelector("#knowledge-backup-consent") as HTMLInputElement).click()); gateway.selectKnowledgeBackupDestination.mockResolvedValueOnce("/tmp/repopress-knowledge-new.json"); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); expect(host.querySelector("#knowledge-backup-consent")).toBeNull(); expect(button(/明确预览资料备份包/)).toBeDefined(); await act(async () => button(/明确预览资料备份包/)!.click()); await settle(); await settle(); expect(gateway.planKnowledgeBackup).toHaveBeenLastCalledWith("/tmp/repopress-knowledge-new.json");
    gateway.selectKnowledgeBackupDestination.mockResolvedValueOnce(null); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); expect(host.querySelector("#knowledge-backup-consent")).toBeNull(); expect(button(/明确预览资料备份包/)).toBeUndefined(); });

  it("does not let a captured checkbox grant consent while a new selection is busy", async () => { let resolve!: (value: string | null) => void; await render(); await preview(); gateway.planKnowledgeBackup.mockResolvedValueOnce(makePlan({ destinationPath: "/tmp/repopress-knowledge-new.json" })); gateway.selectKnowledgeBackupDestination.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); const oldCheckbox = host.querySelector("#knowledge-backup-consent") as HTMLInputElement; await act(async () => { button(/选择新的资料 JSON 文件路径/)!.click(); oldCheckbox.click(); }); resolve("/tmp/repopress-knowledge-new.json"); await settle(); await settle(); await act(async () => button(/明确预览资料备份包/)!.click()); await settle(); await settle(); const freshCheckbox = host.querySelector("#knowledge-backup-consent") as HTMLInputElement; expect(freshCheckbox.checked).toBe(false); expect(button(/明确一次性导出资料备份包/)!.disabled).toBe(true); await act(async () => freshCheckbox.click()); await act(async () => button(/明确一次性导出资料备份包/)!.click()); await settle(); await settle(); expect(gateway.executeKnowledgeBackup).toHaveBeenCalledTimes(1); });

  it("ignores a late execute receipt after refresh and blocks captured controls while disabled", async () => { let resolve!: (value: KnowledgeBackupResult) => void; gateway.executeKnowledgeBackup.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await render(); await preview(); await act(async () => (host.querySelector("#knowledge-backup-consent") as HTMLInputElement).click()); const oldConsent = host.querySelector("#knowledge-backup-consent") as HTMLInputElement; const oldExecute = button(/明确一次性导出资料备份包/)!; await act(async () => oldExecute.click()); await render({ refreshKey: 3, enabled: false }); await act(async () => { oldConsent.click(); oldExecute.click(); }); resolve(resultFor(makePlan())); await settle(); await settle(); expect(gateway.executeKnowledgeBackup).toHaveBeenCalledTimes(1); expect(host.textContent).not.toContain("已导出并核验"); });

  it("discards on refresh, enabled, gateway replacement, and unmount, including a late plan via the original gateway", async () => { let resolve!: (plan: KnowledgeBackupPlan) => void; gateway.planKnowledgeBackup.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await render(); await act(async () => button(/选择新的资料 JSON 文件路径/)!.click()); await settle(); await act(async () => button(/明确预览资料备份包/)!.click()); const old = gateway; const replacement = { selectKnowledgeBackupDestination: vi.fn(), planKnowledgeBackup: vi.fn(), executeKnowledgeBackup: vi.fn(), discardKnowledgeBackup: vi.fn(async () => undefined) } as unknown as Gateway; gateway = replacement; await render({ refreshKey: 1 }); resolve({ ...makePlan(), format: "wrong" as never }); await settle(); expect(old.discardKnowledgeBackup).toHaveBeenCalledWith(makePlan().planId); expect(replacement.executeKnowledgeBackup).not.toHaveBeenCalled();
    await render({ enabled: false }); expect(host.textContent).not.toContain("已导出并核验"); await act(async () => root.unmount()); });
});
