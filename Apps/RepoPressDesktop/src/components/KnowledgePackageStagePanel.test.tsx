import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS, KNOWLEDGE_PACKAGE_CHECK_LIMITS, type KnowledgePackageCheckReport } from "../contracts/knowledgePackageCheck";
import { KNOWLEDGE_PACKAGE_STAGE_LIMITS, type KnowledgePackageStageGateway, type KnowledgePackageStagePlan } from "../contracts/knowledgePackageStage";
import { KnowledgePackageStagePanel } from "./KnowledgePackageStagePanel";

const now = 1_700_000_000_000; const source = "/tmp/selected-knowledge.json"; const parent = "/tmp"; const planId = "11111111-1111-4111-8111-111111111111";
const report = (o: Partial<KnowledgePackageCheckReport> = {}): KnowledgePackageCheckReport => ({ reportId: planId, sourcePath: source, format: "repopress-knowledge-saved-files", schemaVersion: 1, sourceManifestSchemaVersion: 4, scope: "selectedKnowledgePackage", itemCount: 3, revisionCount: 5, bodyFileCount: 2, archiveFileCount: 1, resourceByteSize: 800, byteSize: 1200, sha256: "a".repeat(64), manifestSha256: "b".repeat(64), exclusions: [...KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS], limits: KNOWLEDGE_PACKAGE_CHECK_LIMITS, structureVerified: true, contentVerified: true, allSavedReferencesIncluded: true, sourceManifestHashVerified: false, consistentSnapshot: false, includesCredentialStores: false, includesCompletedOperations: false, externalReferencesIncluded: false, filesystemWrites: false, currentLibraryChanged: false, restoreReady: false, checkedAtEpochMs: now, expiresAtEpochMs: now + 300000, ...o });
const candidate = `/tmp/repopress-knowledge-stage-${planId}`;
const plan = (o: Partial<KnowledgePackageStagePlan> = {}): KnowledgePackageStagePlan => ({ planId, sourcePath: source, parentPath: parent, candidatePath: candidate, format: "repopress-knowledge-isolated-candidate", schemaVersion: 1, package: report(), candidateFileCount: 5, candidateByteSize: 900, candidateInventorySha256: "c".repeat(64), limits: KNOWLEDGE_PACKAGE_STAGE_LIMITS, requiresSensitivePlaintextConsent: true, candidateOnly: true, currentLibraryChanged: false, restoreReady: false, createdAtEpochMs: now, expiresAtEpochMs: now + 300000, ...o });
const result = (o: Record<string, unknown> = {}) => ({ planId, sourcePath: source, candidatePath: candidate, packageSha256: "a".repeat(64), manifestSha256: "b".repeat(64), candidateFileCount: 5, candidateByteSize: 900, candidateInventorySha256: "c".repeat(64), privatePermissionsVerified: true, contentsVerified: true, sourceRevalidated: true, candidateOnly: true, currentLibraryChanged: false, restoreReady: false, ...o });
type Gateway = { [K in keyof KnowledgePackageStageGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: Gateway;
async function render(props: Partial<React.ComponentProps<typeof KnowledgePackageStagePanel>> = {}) { await act(async () => root.render(createElement(KnowledgePackageStagePanel, { gateway: gateway as unknown as KnowledgePackageStageGateway, enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(re: RegExp) { return [...host.querySelectorAll("button")].find((x) => re.test(x.textContent ?? "")) as HTMLButtonElement | undefined; }
async function prepare() { await act(async () => button(/选择资料 JSON 文件/)!.click()); await settle(); await act(async () => button(/选择候选文件夹/)!.click()); await settle(); await act(async () => button(/生成候选预览/)!.click()); await settle(); await settle(); }

describe("KnowledgePackageStagePanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(now); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { selectKnowledgePackageStageSource: vi.fn(async () => source), selectKnowledgePackageStageParent: vi.fn(async () => parent), planKnowledgePackageStage: vi.fn(async () => plan()), executeKnowledgePackageStage: vi.fn(async () => result()), discardKnowledgePackageStage: vi.fn(async () => undefined) } as unknown as Gateway; });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("requires both explicit selections and previews only safe fields", async () => { await render(); expect(button(/生成候选预览/)).toBeUndefined(); await prepare(); expect(gateway.planKnowledgePackageStage).toHaveBeenCalledWith(source, parent); expect(host.textContent).toContain("候选清单 SHA-256"); expect(host.textContent).not.toMatch(/title|secret|https?:\/\//i); });
  it.each([["extra key", { backendSecret: "secret" }], ["wrong path", { candidatePath: "/tmp/other" }], ["wrong count", { candidateFileCount: 4 }], ["wrong bytes", { candidateByteSize: 35 * 1024 * 1024 + 4097 }], ["wrong flags", { currentLibraryChanged: true }]])("rejects malformed plan %s", async (_name, o) => { gateway.planKnowledgePackageStage.mockResolvedValueOnce({ ...plan(), ...o }); await render(); await prepare(); expect(host.textContent).toMatch(/无法生成候选预览/); expect(gateway.discardKnowledgePackageStage).toHaveBeenCalledWith(planId); });
  it.each([
    ["report ID", report({ reportId: "22222222-2222-4222-8222-222222222222" })],
    ["report timestamps", report({ checkedAtEpochMs: now - 1, expiresAtEpochMs: now + 299999 })],
  ])("rejects a valid report with mismatched plan association: %s", async (_name, nested) => {
    gateway.planKnowledgePackageStage.mockResolvedValueOnce(plan({ package: nested }));
    await render(); await prepare();
    expect(host.textContent).toContain("无法生成候选预览");
    expect(gateway.discardKnowledgePackageStage).toHaveBeenCalledWith(planId);
    expect(host.querySelector("input[type=checkbox]")).toBeNull();
  });
  it("requires sensitive plaintext consent and validates the exact result", async () => { await render(); await prepare(); const checkbox = host.querySelector("input[type=checkbox]") as HTMLInputElement; expect(button(/明确创建一次性候选副本/)!.disabled).toBe(true); await act(async () => { checkbox.click(); button(/明确创建一次性候选副本/)!.click(); }); await settle(); expect(gateway.executeKnowledgePackageStage).toHaveBeenCalledWith(planId, true); expect(host.textContent).toContain("候选副本已创建并核验"); });
  it.each([["result key", { backendSecret: "secret" }], ["result path", { candidatePath: "/bad" }], ["result hash", { candidateInventorySha256: "d".repeat(64) }], ["result flags", { restoreReady: true }]])("rejects malformed %s without retry", async (_name, o) => { gateway.executeKnowledgePackageStage.mockResolvedValueOnce(result(o)); await render(); await prepare(); await act(async () => { (host.querySelector("input[type=checkbox]") as HTMLInputElement).click(); button(/明确创建一次性候选副本/)!.click(); }); await settle(); await settle(); expect(host.textContent).toMatch(/结果未明|不会自动重试/); expect(gateway.executeKnowledgePackageStage).toHaveBeenCalledTimes(1); });
  it("shows the known candidate path after an execution error and consumes the plan", async () => { gateway.executeKnowledgePackageStage.mockRejectedValueOnce(new Error("fixture-secret")); await render(); await prepare(); await act(async () => { (host.querySelector("input[type=checkbox]") as HTMLInputElement).click(); button(/明确创建一次性候选副本/)!.click(); }); await settle(); expect(host.textContent).toContain(candidate); expect(host.textContent).not.toContain("fixture-secret"); });
  it("expires and discards plans", async () => { await render(); await prepare(); await act(async () => { vi.advanceTimersByTime(300001); }); expect(host.textContent).toMatch(/过期|生成候选预览/); expect(gateway.discardKnowledgePackageStage).toHaveBeenCalledWith(planId); });
  it("clears the old plan and blocks an old DOM execute during a new selection", async () => { await render(); await prepare(); const old = button(/明确创建一次性候选副本/)!; let resolve!: (v: string | null) => void; gateway.selectKnowledgePackageStageSource.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await act(async () => { button(/选择资料 JSON 文件/)!.click(); old.click(); }); expect(gateway.executeKnowledgePackageStage).not.toHaveBeenCalled(); resolve(null); await settle(); expect(host.textContent).not.toContain("候选预览（一次性"); });
  it("accepts an empty package with two candidate files and positive bytes", async () => { gateway.planKnowledgePackageStage.mockResolvedValueOnce(plan({ package: report({ itemCount: 0, revisionCount: 0, bodyFileCount: 0, archiveFileCount: 0, resourceByteSize: 0, byteSize: 1 }), candidateFileCount: 2, candidateByteSize: 1 })); await render(); await prepare(); expect(host.textContent).toContain("文件：2"); });
  it.each([["parent alias", "/tmp/../tmp"], ["parent duplicate slash", "/tmp//stage"], ["parent trailing slash", "/tmp/stage/"], ["source alias", "/tmp/../selected-knowledge.json"]])("rejects malformed selected path: %s", async (_name, invalid) => { if (_name.startsWith("source")) gateway.selectKnowledgePackageStageSource.mockResolvedValueOnce(invalid); else gateway.selectKnowledgePackageStageParent.mockResolvedValueOnce(invalid); await render(); await act(async () => button(_name.startsWith("source") ? /选择资料 JSON 文件/ : /选择候选文件夹/)!.click()); await settle(); expect(host.textContent).toMatch(/无法选择/); });
  it("rejects a candidate path that exceeds its 4096-byte cap", async () => { const oversized = `${parent}/repopress-knowledge-stage-${planId}${"x".repeat(4096)}`; gateway.planKnowledgePackageStage.mockResolvedValueOnce(plan({ candidatePath: oversized })); await render(); await prepare(); expect(host.textContent).toContain("无法生成候选预览"); expect(gateway.discardKnowledgePackageStage).toHaveBeenCalledWith(planId); });
  it("discards a late plan through its original gateway after replacement", async () => { let resolve!: (value: KnowledgePackageStagePlan) => void; gateway.planKnowledgePackageStage.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await render(); await act(async () => button(/选择资料 JSON 文件/)!.click()); await settle(); await act(async () => button(/选择候选文件夹/)!.click()); await settle(); await act(async () => button(/生成候选预览/)!.click()); const old = gateway; const replacement = { selectKnowledgePackageStageSource: vi.fn(), selectKnowledgePackageStageParent: vi.fn(), planKnowledgePackageStage: vi.fn(), executeKnowledgePackageStage: vi.fn(), discardKnowledgePackageStage: vi.fn(async () => undefined) } as unknown as Gateway; gateway = replacement; await render({ refreshKey: 1 }); resolve(plan()); await settle(); expect(old.discardKnowledgePackageStage).toHaveBeenCalledWith(planId); expect(host.textContent).not.toContain("候选预览（一次性"); });
  it("clears consent and result when either selector starts a new attempt", async () => { await render(); await prepare(); await act(async () => { (host.querySelector("input[type=checkbox]") as HTMLInputElement).click(); }); const old = button(/明确创建一次性候选副本/)!; await act(async () => { button(/选择候选文件夹/)!.click(); old.click(); }); expect(gateway.executeKnowledgePackageStage).not.toHaveBeenCalled(); expect(host.textContent).not.toContain("候选预览（一次性"); });
  it("requires fresh consent after replacing an already consented plan", async () => {
    const nextId = "33333333-3333-4333-8333-333333333333";
    const nextCandidate = `/tmp/repopress-knowledge-stage-${nextId}`;
    const nextPlan = plan({ planId: nextId, candidatePath: nextCandidate, package: report({ reportId: nextId }), candidateInventorySha256: "d".repeat(64) });
    await render(); await prepare();
    const oldCheckbox = host.querySelector("input[type=checkbox]") as HTMLInputElement;
    expect(oldCheckbox.checked).toBe(false); expect(host.contains(oldCheckbox)).toBe(true);
    await act(async () => { oldCheckbox.click(); });
    expect(oldCheckbox.checked).toBe(true);
    gateway.planKnowledgePackageStage.mockResolvedValueOnce(nextPlan);
    await act(async () => { button(/生成候选预览/)!.click(); await Promise.resolve(); });
    await settle();
    expect(gateway.executeKnowledgePackageStage).not.toHaveBeenCalled();
    const newCheckbox = host.querySelector("input[type=checkbox]") as HTMLInputElement;
    expect(newCheckbox).not.toBe(oldCheckbox); expect(newCheckbox.checked).toBe(false);
    await act(async () => { newCheckbox.click(); button(/明确创建一次性候选副本/)!.click(); }); await settle();
    expect(gateway.executeKnowledgePackageStage).toHaveBeenCalledWith(nextId, true);
  });
});
