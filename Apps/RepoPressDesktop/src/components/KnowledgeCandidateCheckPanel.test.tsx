import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KNOWLEDGE_CANDIDATE_CHECK_LIMITS, type KnowledgeCandidateCheckGateway, type KnowledgeCandidateCheckReport } from "../contracts/knowledgeCandidateCheck";
import { KnowledgeCandidateCheckPanel } from "./KnowledgeCandidateCheckPanel";
const now = 1700000000000;
const id = "11111111-1111-4111-8111-111111111111";
const path = `/tmp/repopress-knowledge-stage-${id}`;
const sha = (c: string) => c.repeat(64);
const report = (o: Partial<KnowledgeCandidateCheckReport> = {}): KnowledgeCandidateCheckReport => ({ reportId: "22222222-2222-4222-8222-222222222222", candidatePath: path, schemaVersion: 1, scope: "selectedKnowledgeCandidate", stagePlanId: id, sourcePackageSha256: sha("a"), manifestSha256: sha("b"), candidateInventorySha256: sha("c"), candidateFileCount: 5, candidateByteSize: 900, itemCount: 3, revisionCount: 5, folderCount: 2, currentLibrary: { state: "checked", manifestSha256: sha("d"), itemCount: 3, revisionCount: 5, folderCount: 2 }, conflicts: { candidateOnlyItems: 0, currentOnlyItems: 0, identicalItems: 3, changedItems: 0, candidateOnlyFolders: 0, currentOnlyFolders: 0, identicalFolders: 2, changedFolders: 0 }, limits: KNOWLEDGE_CANDIDATE_CHECK_LIMITS, candidateStructureVerified: true, candidateContentsVerified: true, privatePermissionsVerified: true, sourcePackageHashVerified: false, candidateAuthenticityVerified: false, currentLibraryResourcesVerified: false, comparisonScope: "manifestIdentityAndMetadataOnly", consistentSnapshot: false, filesystemWrites: false, currentLibraryChanged: false, restoreReady: false, checkedAtEpochMs: now, expiresAtEpochMs: now + 300000, ...o });
type G = {
    [K in keyof KnowledgeCandidateCheckGateway]: ReturnType<typeof vi.fn>;
};
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let gateway: G;
async function render(props: Partial<React.ComponentProps<typeof KnowledgeCandidateCheckPanel>> = {}) { await act(async () => root.render(createElement(KnowledgeCandidateCheckPanel, { gateway: gateway as unknown as KnowledgeCandidateCheckGateway, enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(re: RegExp) { return [...host.querySelectorAll("button")].find((x) => re.test(x.textContent ?? "")) as HTMLButtonElement | undefined; }
async function inspect() { await act(async () => button(/选择候选目录/)!.click()); await settle(); await act(async () => button(/检查候选目录/)!.click()); await settle(); }
describe("KnowledgeCandidateCheckPanel", () => {
    Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
    beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(now); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { selectKnowledgeCandidateDirectory: vi.fn(async () => path), inspectKnowledgeCandidate: vi.fn(async () => report()), recheckKnowledgeCandidate: vi.fn(async () => ({ report: report({ reportId: "33333333-3333-4333-8333-333333333333" }), comparison: "changed" })), discardKnowledgeCandidateCheck: vi.fn(async () => undefined) } as unknown as G; });
    afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });
    it("requires explicit select and inspect, showing only safe summaries", async () => { await render(); expect(button(/检查候选目录/)).toBeUndefined(); await inspect(); expect(host.textContent).toContain("候选清单 SHA-256"); expect(host.textContent).not.toMatch(/title|secret|https?:\/\//i); });
    it.each([["extra", { backendSecret: "secret" }], ["path", { candidatePath: "/tmp/other" }], ["flags", { restoreReady: true }], ["limits", { limits: { ...KNOWLEDGE_CANDIDATE_CHECK_LIMITS, jsonNodes: 1 } }], ["current", { currentLibrary: { state: "missing", manifestSha256: sha("d"), itemCount: 1, revisionCount: 1, folderCount: 1 } }]])("rejects malformed report %s", async (_n, o) => { gateway.inspectKnowledgeCandidate.mockResolvedValueOnce({ ...report(), ...o }); await render(); await inspect(); expect(host.textContent).toMatch(/无效|固定限制/); expect(gateway.discardKnowledgeCandidateCheck).toHaveBeenCalledWith(report().reportId); });
    it("consumes and accepts a changed recheck", async () => { await render(); await inspect(); await act(async () => button(/一次性重新核对/)!.click()); await settle(); expect(gateway.recheckKnowledgeCandidate).toHaveBeenCalledWith(report().reportId); expect(host.textContent).toContain("已变化"); });
    it("rejects unchanged when current library is not checked", async () => { gateway.recheckKnowledgeCandidate.mockResolvedValueOnce({ report: report({ reportId: "33333333-3333-4333-8333-333333333333", currentLibrary: { state: "missing", manifestSha256: null, itemCount: null, revisionCount: null, folderCount: null }, conflicts: null }), comparison: "unchanged" }); await render(); await inspect(); await act(async () => button(/一次性重新核对/)!.click()); await settle(); expect(host.textContent).toMatch(/失败|旧清单已消耗/); });
    it("expires and discards the report", async () => { await render(); await inspect(); await act(async () => { vi.advanceTimersByTime(300001); }); expect(gateway.discardKnowledgeCandidateCheck).toHaveBeenCalledWith(report().reportId); expect(host.textContent).toMatch(/过期|检查候选目录/); });
    it("renders checked current metadata and both conflict partitions", async () => { await render(); await inspect(); expect(host.textContent).toContain("当前资料库清单 SHA-256"); expect(host.textContent).toContain("候选新增 0"); expect(host.textContent).toContain("当前独有 0"); expect(host.textContent).toContain("同一 ID 的完整保存元数据或历史不同也算变化"); });
    it.each([["nested extra", { currentLibrary: { ...report().currentLibrary, extra: true } }], ["partition mismatch", { conflicts: { ...report().conflicts!, identicalItems: 2 } }], ["checked null", { currentLibrary: { state: "checked", manifestSha256: null, itemCount: null, revisionCount: null, folderCount: null }, conflicts: null }], ["extra top key", { backendSecret: "secret" }]])("rejects malformed nested or exact-key report: %s", async (_n, o) => { gateway.inspectKnowledgeCandidate.mockResolvedValueOnce({ ...report(), ...o }); await render(); await inspect(); expect(host.textContent).toMatch(/无效|固定限制/); expect(gateway.discardKnowledgeCandidateCheck).toHaveBeenCalledWith(report().reportId); });
    it.each([["stage id", { stagePlanId: "44444444-4444-4444-8444-444444444444" }], ["empty counts", { itemCount: 0, revisionCount: 1, candidateFileCount: 2 }], ["zero bytes", { candidateByteSize: 0 }], ["folder limit", { folderCount: 129, conflicts: { ...report().conflicts!, identicalFolders: 129 } }]])("rejects cross-field report mismatch: %s", async (_n, o) => { gateway.inspectKnowledgeCandidate.mockResolvedValueOnce({ ...report(), ...o }); await render(); await inspect(); expect(host.textContent).toMatch(/无效|固定限制/); });
    it("requires unchanged recheck summaries to match", async () => { gateway.recheckKnowledgeCandidate.mockResolvedValueOnce({ report: report({ reportId: "33333333-3333-4333-8333-333333333333", candidateByteSize: 901 }), comparison: "unchanged" }); await render(); await inspect(); await act(async () => button(/一次性重新核对/)!.click()); await settle(); expect(host.textContent).toMatch(/失败|旧清单已消耗/); });
    it.each(["sourcePackageSha256", "manifestSha256", "candidateInventorySha256"])("rejects unchanged when %s changes and discards the returned report", async (field) => { gateway.recheckKnowledgeCandidate.mockResolvedValueOnce({ report: report({ reportId: "33333333-3333-4333-8333-333333333333", [field]: sha("e") }), comparison: "unchanged" }); await render(); await inspect(); await act(async () => button(/一次性重新核对/)!.click()); await settle(); expect(host.textContent).toMatch(/失败|旧清单已消耗/); expect(gateway.discardKnowledgeCandidateCheck).toHaveBeenCalledWith("33333333-3333-4333-8333-333333333333"); });
    it("does not start stale selector or inspect while context is disabled", async () => { await render(); await render({ enabled: false }); await act(async () => button(/选择候选目录/)!.click()); expect(gateway.selectKnowledgeCandidateDirectory).not.toHaveBeenCalled(); await render({ enabled: true }); await act(async () => button(/选择候选目录/)!.click()); await settle(); await render({ disabled: true }); await act(async () => button(/检查候选目录/)?.click()); expect(gateway.inspectKnowledgeCandidate).not.toHaveBeenCalled(); });
    it("shows missing current metadata without pretending that an empty library was checked", async () => {
        gateway.inspectKnowledgeCandidate.mockResolvedValueOnce(report({
            currentLibrary: { state: "missing", manifestSha256: null, itemCount: null, revisionCount: null, folderCount: null },
            conflicts: null,
        }));
        await render(); await inspect();
        expect(host.textContent).toContain("缺失，当前统计不可用");
        expect(host.textContent).not.toContain("当前资料库清单 SHA-256");
        expect(host.textContent).not.toContain("清单冲突摘要");
        expect(host.textContent).not.toContain("候选目录清单无效");
    });
    it("accepts an inconclusive transition to a checked current manifest", async () => {
        gateway.inspectKnowledgeCandidate.mockResolvedValueOnce(report({
            currentLibrary: { state: "invalid", manifestSha256: null, itemCount: null, revisionCount: null, folderCount: null },
            conflicts: null,
        }));
        gateway.recheckKnowledgeCandidate.mockResolvedValueOnce({
            report: report({ reportId: "33333333-3333-4333-8333-333333333333" }),
            comparison: "inconclusive",
        });
        await render(); await inspect();
        await act(async () => button(/一次性重新核对/)!.click()); await settle();
        expect(host.textContent).toContain("重新核对结果：无法确定");
        expect(host.textContent).toContain("清单冲突摘要");
    });
    it("rejects expired reports by wall clock before the expiry timer runs", async () => {
        await render(); await inspect();
        vi.setSystemTime(now + 300001);
        await act(async () => button(/一次性重新核对/)!.click()); await settle();
        expect(gateway.recheckKnowledgeCandidate).not.toHaveBeenCalled();
    });
    it("consumes a report once when a pending recheck button is clicked twice", async () => {
        let resolve!: (v: unknown) => void;
        gateway.recheckKnowledgeCandidate.mockImplementationOnce(() => new Promise((r) => { resolve = r; }));
        await render(); await inspect();
        const old = button(/一次性重新核对/)!;
        await act(async () => { old.click(); old.click(); });
        expect(gateway.recheckKnowledgeCandidate).toHaveBeenCalledTimes(1);
        resolve({ report: report({ reportId: "33333333-3333-4333-8333-333333333333" }), comparison: "unchanged" });
        await settle();
        expect(host.textContent).toContain("重新核对结果：未变化");
    });
    it("releases a recognizable report inside an invalid recheck wrapper", async () => {
        gateway.recheckKnowledgeCandidate.mockResolvedValueOnce({
            report: report({ reportId: "33333333-3333-4333-8333-333333333333" }),
            comparison: "unchanged", secret: "do not display",
        });
        await render(); await inspect();
        await act(async () => button(/一次性重新核对/)!.click()); await settle();
        expect(host.textContent).toContain("重新核对失败");
        expect(host.textContent).not.toContain("do not display");
        expect(gateway.discardKnowledgeCandidateCheck).toHaveBeenCalledWith("33333333-3333-4333-8333-333333333333");
    });
    it("rejects a selected candidate path with an ancestor alias", async () => {
        gateway.selectKnowledgeCandidateDirectory.mockResolvedValueOnce(path.replace("/tmp/", "/tmp/../tmp/"));
        await render(); await act(async () => button(/选择候选目录/)!.click()); await settle();
        expect(gateway.inspectKnowledgeCandidate).not.toHaveBeenCalled();
        expect(host.textContent).toContain("无法选择候选目录");
    });
    it("discards late reports through the original gateway", async () => { let resolve!: (v: KnowledgeCandidateCheckReport) => void; gateway.inspectKnowledgeCandidate.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await render(); await act(async () => button(/选择候选目录/)!.click()); await settle(); await act(async () => button(/检查候选目录/)!.click()); const old = gateway; const replacement = { selectKnowledgeCandidateDirectory: vi.fn(), inspectKnowledgeCandidate: vi.fn(), recheckKnowledgeCandidate: vi.fn(), discardKnowledgeCandidateCheck: vi.fn(async () => undefined) } as unknown as G; gateway = replacement; await render({ refreshKey: 1 }); resolve(report()); await settle(); expect(old.discardKnowledgeCandidateCheck).toHaveBeenCalledWith(report().reportId); });
});
