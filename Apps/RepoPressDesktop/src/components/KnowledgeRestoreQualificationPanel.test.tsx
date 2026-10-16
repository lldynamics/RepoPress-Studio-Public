import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KNOWLEDGE_CANDIDATE_CHECK_LIMITS, type KnowledgeCandidateCheckReport } from "../contracts/knowledgeCandidateCheck";
import type { KnowledgeRestoreQualificationGateway, KnowledgeRestoreQualificationPlan } from "../contracts/knowledgeRestoreQualification";
import { KnowledgeRestoreQualificationPanel } from "./KnowledgeRestoreQualificationPanel";
const now = 1700000000000;
const stage = "11111111-1111-4111-8111-111111111111";
const path = `/tmp/repopress-knowledge-stage-${stage}`;
const sha = (letter: string) => letter.repeat(64);
const candidate = (overrides: Partial<KnowledgeCandidateCheckReport> = {}): KnowledgeCandidateCheckReport => ({
    reportId: "22222222-2222-4222-8222-222222222222", candidatePath: path, schemaVersion: 1, scope: "selectedKnowledgeCandidate", stagePlanId: stage,
    sourcePackageSha256: sha("a"), manifestSha256: sha("b"), candidateInventorySha256: sha("c"), candidateFileCount: 5, candidateByteSize: 900,
    itemCount: 3, revisionCount: 5, folderCount: 2, currentLibrary: { state: "checked", manifestSha256: sha("d"), itemCount: 3, revisionCount: 5, folderCount: 2 },
    conflicts: { candidateOnlyItems: 0, currentOnlyItems: 0, identicalItems: 3, changedItems: 0, candidateOnlyFolders: 0, currentOnlyFolders: 0, identicalFolders: 2, changedFolders: 0 }, limits: KNOWLEDGE_CANDIDATE_CHECK_LIMITS,
    candidateStructureVerified: true, candidateContentsVerified: true, privatePermissionsVerified: true, sourcePackageHashVerified: false, candidateAuthenticityVerified: false,
    currentLibraryResourcesVerified: false, comparisonScope: "manifestIdentityAndMetadataOnly", consistentSnapshot: false, filesystemWrites: false, currentLibraryChanged: false, restoreReady: false,
    checkedAtEpochMs: now, expiresAtEpochMs: now + 300000, ...overrides,
});
const plan = (overrides: Partial<KnowledgeRestoreQualificationPlan> = {}): KnowledgeRestoreQualificationPlan => ({
    schemaVersion: 1, scope: "knowledgeRestoreQualification", planId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", targetScope: "currentAppKnowledgeLibrary", candidate: candidate(),
    currentResources: { state: "checked", fileCount: 5, byteSize: 900, inventorySha256: sha("e"), unreferencedFilesVerified: false, externalReferencesVerified: false }, strategy: "requireNoIdentityConflicts",
    qualification: { state: "evidenceReady", reason: "none", addItems: 0, retainItems: 3, skipCandidateItems: 3, addFolders: 0, retainFolders: 2, skipCandidateFolders: 2 }, currentOnlyPreserved: true,
    candidatePermissionsApplied: false, projectedManifestValidated: false, consistentSnapshot: false, filesystemWrites: false, restoreReady: false, checkedAtEpochMs: now, expiresAtEpochMs: now + 300000, ...overrides,
});
type MockGateway = {
    [K in keyof KnowledgeRestoreQualificationGateway]: ReturnType<typeof vi.fn>;
};
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let gateway: MockGateway;
function render(props: Partial<React.ComponentProps<typeof KnowledgeRestoreQualificationPanel>> = {}) { root.render(createElement(KnowledgeRestoreQualificationPanel, { gateway: gateway as unknown as KnowledgeRestoreQualificationGateway, enabled: true, ...props })); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(text: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === text) as HTMLButtonElement | undefined; }
async function generate() { await act(async () => button("选择候选目录")!.click()); await settle(); await act(async () => button("生成只读资格计划")!.click()); await settle(); }
describe("KnowledgeRestoreQualificationPanel", () => {
    Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
    beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(now); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { selectKnowledgeCandidateDirectory: vi.fn(async () => path), planKnowledgeRestoreQualification: vi.fn(async () => plan()), recheckKnowledgeRestoreQualification: vi.fn(async () => ({ plan: plan({ planId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", candidate: candidate({ reportId: "33333333-3333-4333-8333-333333333333" }) }), comparison: "unchanged" })), discardKnowledgeRestoreQualification: vi.fn(async () => undefined) }; });
    afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });
    it("requires explicit selection and never displays item titles or URLs", async () => { await act(async () => render()); expect(button("生成只读资格计划")).toBeUndefined(); await generate(); expect(gateway.planKnowledgeRestoreQualification).toHaveBeenCalledWith(path, "requireNoIdentityConflicts"); expect(host.textContent).toContain("候选清单 SHA-256"); expect(host.textContent).not.toMatch(/title|https?:\/\//i); });
    it.each([
        ["extra field", { secret: "do not display" }],
        ["unsafe resources", { currentResources: { state: "checked", fileCount: 1025, byteSize: 900, inventorySha256: sha("e"), unreferencedFilesVerified: false, externalReferencesVerified: false } }],
        ["contradictory flags", { restoreReady: true }],
    ])("rejects malformed plans: %s", async (_label, overrides) => { gateway.planKnowledgeRestoreQualification.mockResolvedValueOnce({ ...plan(), ...overrides }); await act(async () => render()); await generate(); expect(host.textContent).toContain("资格计划无效"); expect(gateway.discardKnowledgeRestoreQualification).toHaveBeenCalledWith("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"); });
    it("blocks unknown current manifests and clears all counts", async () => { gateway.planKnowledgeRestoreQualification.mockResolvedValueOnce(plan({ candidate: candidate({ currentLibrary: { state: "missing", manifestSha256: null, itemCount: null, revisionCount: null, folderCount: null }, conflicts: null }), currentResources: { state: "notChecked", fileCount: null, byteSize: null, inventorySha256: null, unreferencedFilesVerified: false, externalReferencesVerified: false }, qualification: { state: "blocked", reason: "currentManifestUnavailable", addItems: null, retainItems: null, skipCandidateItems: null, addFolders: null, retainFolders: null, skipCandidateFolders: null } })); await act(async () => render()); await generate(); expect(host.textContent).toContain("currentManifestUnavailable"); expect(host.textContent).toContain("新增资料项 未知"); });
    it("rejects changed identity conflicts for the default strategy", async () => { gateway.planKnowledgeRestoreQualification.mockResolvedValueOnce(plan({ candidate: candidate({ conflicts: { candidateOnlyItems: 0, currentOnlyItems: 0, identicalItems: 2, changedItems: 1, candidateOnlyFolders: 0, currentOnlyFolders: 0, identicalFolders: 2, changedFolders: 0 } }), qualification: { state: "blocked", reason: "identityConflicts", addItems: null, retainItems: null, skipCandidateItems: null, addFolders: null, retainFolders: null, skipCandidateFolders: null } })); await act(async () => render()); await generate(); expect(host.textContent).toContain("identityConflicts"); });
    it("consumes old plans before recheck and rejects an unchanged snapshot drift", async () => { gateway.recheckKnowledgeRestoreQualification.mockResolvedValueOnce({ plan: plan({ planId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", candidate: candidate({ reportId: "33333333-3333-4333-8333-333333333333", candidateByteSize: 901 }) }), comparison: "unchanged" }); await act(async () => render()); await generate(); await act(async () => button("一次性重新核对")!.click()); await settle(); expect(gateway.recheckKnowledgeRestoreQualification).toHaveBeenCalledWith("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"); expect(host.textContent).toContain("旧资格计划已消耗"); });
    it("discards recognizable late plans through the original gateway", async () => { let resolve!: (value: KnowledgeRestoreQualificationPlan) => void; gateway.planKnowledgeRestoreQualification.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await act(async () => render()); await act(async () => button("选择候选目录")!.click()); await settle(); await act(async () => button("生成只读资格计划")!.click()); const old = gateway; const replacement = { selectKnowledgeCandidateDirectory: vi.fn(), planKnowledgeRestoreQualification: vi.fn(), recheckKnowledgeRestoreQualification: vi.fn(), discardKnowledgeRestoreQualification: vi.fn(async () => undefined) } as MockGateway; await act(async () => { gateway = replacement; render({ refreshKey: 1 }); }); resolve(plan()); await settle(); expect(old.discardKnowledgeRestoreQualification).toHaveBeenCalledWith("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"); });
    const fresh = (overrides: Partial<KnowledgeRestoreQualificationPlan> = {}) => plan({ planId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", candidate: candidate({ reportId: "33333333-3333-4333-8333-333333333333" }), ...overrides });
    const unknown = (): KnowledgeRestoreQualificationPlan => fresh({ candidate: candidate({ reportId: "33333333-3333-4333-8333-333333333333", currentLibrary: { state: "missing", manifestSha256: null, itemCount: null, revisionCount: null, folderCount: null }, conflicts: null }), currentResources: { state: "notChecked", fileCount: null, byteSize: null, inventorySha256: null, unreferencedFilesVerified: false, externalReferencesVerified: false }, qualification: { state: "blocked", reason: "currentManifestUnavailable", addItems: null, retainItems: null, skipCandidateItems: null, addFolders: null, retainFolders: null, skipCandidateFolders: null } });
    it("accepts changed even when public bytes and digests match after an inode replacement", async () => {
        gateway.recheckKnowledgeRestoreQualification.mockResolvedValueOnce({ plan: fresh(), comparison: "changed" });
        await act(async () => render());
        await generate();
        await act(async () => button("一次性重新核对")!.click());
        await settle();
        expect(host.textContent).toContain("重新核对结果：已变化");
        expect(host.textContent).not.toContain("重新核对失败");
    });
    it("accepts inconclusive with a missing current library", async () => {
        gateway.recheckKnowledgeRestoreQualification.mockResolvedValueOnce({ plan: unknown(), comparison: "inconclusive" });
        await act(async () => render());
        await generate();
        await act(async () => button("一次性重新核对")!.click());
        await settle();
        expect(host.textContent).toContain("重新核对结果：无法确定");
        expect(host.textContent).toContain("currentManifestUnavailable");
    });
    it.each(["unchanged", "changed"])("rejects %s when the new current library is unknown", async (comparison) => {
        gateway.recheckKnowledgeRestoreQualification.mockResolvedValueOnce({ plan: unknown(), comparison });
        await act(async () => render());
        await generate();
        await act(async () => button("一次性重新核对")!.click());
        await settle();
        expect(host.textContent).toContain("重新核对失败");
        expect(gateway.discardKnowledgeRestoreQualification).toHaveBeenCalledWith("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    });
    it("accepts unchanged evidence regardless of nested property order", async () => {
        const next = fresh();
        next.currentResources = Object.fromEntries(Object.entries(next.currentResources).reverse()) as typeof next.currentResources;
        next.candidate.currentLibrary = Object.fromEntries(Object.entries(next.candidate.currentLibrary).reverse()) as typeof next.candidate.currentLibrary;
        gateway.recheckKnowledgeRestoreQualification.mockResolvedValueOnce({ plan: next, comparison: "unchanged" });
        await act(async () => render());
        await generate();
        await act(async () => button("一次性重新核对")!.click());
        await settle();
        expect(host.textContent).toContain("重新核对结果：未变化");
    });
    it("discards a recognizable malformed wrapper before dereferencing its candidate", async () => {
        gateway.recheckKnowledgeRestoreQualification.mockResolvedValueOnce({ plan: { planId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" }, comparison: "unchanged" });
        await act(async () => render());
        await generate();
        await act(async () => button("一次性重新核对")!.click());
        await settle();
        expect(host.textContent).toContain("重新核对失败");
        expect(gateway.discardKnowledgeRestoreQualification).toHaveBeenCalledWith("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    });
    it.each([
        ["non UUID", { planId: "plan-not-a-uuid" }],
        ["plan time unrelated", { checkedAtEpochMs: now - 1 }],
        ["candidate stage mismatch", { candidate: candidate({ stagePlanId: "44444444-4444-4444-8444-444444444444" }) }],
        ["empty current resources despite references", { currentResources: { state: "checked", fileCount: 0, byteSize: 0, inventorySha256: sha("e"), unreferencedFilesVerified: false, externalReferencesVerified: false } }],
    ])("rejects association failure %s", async (_label, changes) => {
        gateway.planKnowledgeRestoreQualification.mockResolvedValueOnce({ ...plan(), ...changes });
        await act(async () => render());
        await generate();
        expect(host.textContent).toContain("资格计划无效");
        expect(button("一次性重新核对")).toBeUndefined();
    });
    it("consumes the rendered plan synchronously to prevent double recheck", async () => {
        await act(async () => render());
        await generate();
        const target = button("一次性重新核对")!;
        await act(async () => { target.click(); target.click(); });
        await settle();
        expect(gateway.recheckKnowledgeRestoreQualification).toHaveBeenCalledTimes(1);
    });
    it("expires on wall time before the timeout callback and refuses the old handler", async () => {
        await act(async () => render());
        await generate();
        const target = button("一次性重新核对")!;
        vi.setSystemTime(now + 300001);
        await act(async () => target.click());
        expect(gateway.recheckKnowledgeRestoreQualification).not.toHaveBeenCalled();
        await act(async () => vi.advanceTimersByTime(300001));
        expect(gateway.discardKnowledgeRestoreQualification).toHaveBeenCalledWith("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
    });
    it("invalidates an existing plan on strategy change and binds the next policy", async () => {
        await act(async () => render());
        await generate();
        const select = host.querySelector("select")!;
        await act(async () => { select.value = "keepCurrentIdentities"; select.dispatchEvent(new Event("change", { bubbles: true })); });
        expect(button("一次性重新核对")).toBeUndefined();
        expect(gateway.discardKnowledgeRestoreQualification).toHaveBeenCalledWith("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa");
        gateway.planKnowledgeRestoreQualification.mockResolvedValueOnce(plan({ strategy: "keepCurrentIdentities" }));
        await act(async () => button("生成只读资格计划")!.click());
        await settle();
        expect(gateway.planKnowledgeRestoreQualification).toHaveBeenLastCalledWith(path, "keepCurrentIdentities");
        expect(host.textContent).toContain("策略：保留当前身份");
    });
    it("rejects an old generate handler after a synchronous selection change", async () => {
        await act(async () => render());
        await act(async () => button("选择候选目录")!.click());
        await settle();
        const old = button("生成只读资格计划")!;
        const stage2 = "55555555-5555-4555-8555-555555555555";
        gateway.selectKnowledgeCandidateDirectory.mockResolvedValueOnce("/tmp/repopress-knowledge-stage-" + stage2);
        await act(async () => { button("选择候选目录")!.click(); await Promise.resolve(); old.click(); });
        await settle();
        expect(gateway.planKnowledgeRestoreQualification).not.toHaveBeenCalled();
    });
});
