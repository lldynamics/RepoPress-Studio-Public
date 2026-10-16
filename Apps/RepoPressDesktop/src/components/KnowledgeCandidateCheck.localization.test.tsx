import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KNOWLEDGE_CANDIDATE_CHECK_LIMITS, type KnowledgeCandidateCheckGateway, type KnowledgeCandidateCheckReport, type KnowledgeCandidateRecheck } from "../contracts/knowledgeCandidateCheck";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { KnowledgeCandidateCheckPanel } from "./KnowledgeCandidateCheckPanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const clock = 1_700_000_000_000;
const stageId = "11111111-1111-4111-8111-111111111111";
const reportId = "22222222-2222-4222-8222-222222222222";
const nextId = "33333333-3333-4333-8333-333333333333";
const path = `/tmp/候选{candidatePath}-{state}/repopress-knowledge-stage-${stageId}`;
function report(extra: Partial<KnowledgeCandidateCheckReport> = {}): KnowledgeCandidateCheckReport {
  return {
    reportId, candidatePath: path, schemaVersion: 1, scope: "selectedKnowledgeCandidate", stagePlanId: stageId,
    sourcePackageSha256: "a".repeat(64), manifestSha256: "b".repeat(64), candidateInventorySha256: "c".repeat(64),
    candidateFileCount: 5, candidateByteSize: 1_234_567, itemCount: 3, revisionCount: 5, folderCount: 2,
    currentLibrary: { state: "checked", manifestSha256: "d".repeat(64), itemCount: 3, revisionCount: 5, folderCount: 2 },
    conflicts: { candidateOnlyItems: 0, currentOnlyItems: 0, identicalItems: 3, changedItems: 0, candidateOnlyFolders: 0, currentOnlyFolders: 0, identicalFolders: 2, changedFolders: 0 },
    limits: KNOWLEDGE_CANDIDATE_CHECK_LIMITS, candidateStructureVerified: true, candidateContentsVerified: true, privatePermissionsVerified: true,
    sourcePackageHashVerified: false, candidateAuthenticityVerified: false, currentLibraryResourcesVerified: false,
    comparisonScope: "manifestIdentityAndMetadataOnly", consistentSnapshot: false, filesystemWrites: false, currentLibraryChanged: false, restoreReady: false,
    checkedAtEpochMs: clock, expiresAtEpochMs: clock + 300_000, ...extra,
  };
}
function deferred<T>() {
  let resolve!: (value: T) => void; let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}
type Gateway = { [K in keyof KnowledgeCandidateCheckGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: Root; let gateway: Gateway;
beforeEach(() => {
  vi.useFakeTimers(); vi.setSystemTime(clock);
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  gateway = {
    selectKnowledgeCandidateDirectory: vi.fn(async () => path), inspectKnowledgeCandidate: vi.fn(async () => report()),
    recheckKnowledgeCandidate: vi.fn(async () => ({ report: report({ reportId: nextId }), comparison: "unchanged" })),
    discardKnowledgeCandidateCheck: vi.fn(async () => undefined),
  };
});
afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });
async function render(locale: UiLocale) {
  await act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(KnowledgeCandidateCheckPanel, { gateway: gateway as unknown as KnowledgeCandidateCheckGateway, enabled: true }) })));
}
function button(label: string) { return [...host.querySelectorAll<HTMLButtonElement>("button")].find(node => node.textContent === label)!; }
async function click(label: string) { await act(async () => button(label).click()); }
async function chooseAndInspect() { await click("选择候选目录"); await click("检查候选目录"); }

describe("candidate check live localization", () => {
  it("keeps a pending selection single-shot and interpolates the raw path once", async () => {
    const pending = deferred<string | null>(); gateway.selectKnowledgeCandidateDirectory.mockReturnValueOnce(pending.promise);
    await render("zh-CN"); await click("选择候选目录"); await render("en-US"); await render("zh-CN"); await render("en-US");
    expect(host.textContent).toContain("Selecting candidate directory…"); expect(button("Select candidate directory").disabled).toBe(true);
    expect(gateway.selectKnowledgeCandidateDirectory).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(path));
    expect(host.textContent).toContain(`Candidate path: ${path}`); expect(host.textContent?.split(path)).toHaveLength(2);
    expect(gateway.inspectKnowledgeCandidate).not.toHaveBeenCalled(); expect(gateway.discardKnowledgeCandidateCheck).not.toHaveBeenCalled();
  });

  it("preserves a pending inspection, report fields and the original expiry timer across locale changes", async () => {
    const pending = deferred<KnowledgeCandidateCheckReport>(); gateway.inspectKnowledgeCandidate.mockReturnValueOnce(pending.promise);
    await render("zh-CN"); await chooseAndInspect(); await render("en-US"); await render("zh-CN"); await render("en-US");
    expect(host.textContent).toContain("Reading candidate directory…"); expect(gateway.inspectKnowledgeCandidate).toHaveBeenCalledExactlyOnceWith(path);
    await act(async () => pending.resolve(report()));
    expect(host.textContent).toContain("size: 1,234,567 bytes"); expect(host.textContent).toContain("Knowledge items: candidate only 0; current only 0; identical 3; changed 0");
    expect(host.textContent).toContain("Folders: candidate only 0; current only 0; identical 2; changed 0");
    expect(host.textContent).toContain(`Candidate inventory SHA-256: ${"c".repeat(64)}`);
    expect(host.textContent).toContain(`Current knowledge manifest SHA-256: ${"d".repeat(64)}`);
    expect(host.textContent).toContain(path); expect(host.textContent).toContain("current resources");
    expect(gateway.discardKnowledgeCandidateCheck).not.toHaveBeenCalled();
    await act(async () => vi.advanceTimersByTime(299_999)); await render("zh-CN"); await render("en-US");
    expect(host.textContent).toContain("Candidate directory report (one-time, valid for 5 minutes)");
    await act(async () => vi.advanceTimersByTime(1));
    expect(gateway.discardKnowledgeCandidateCheck).toHaveBeenCalledExactlyOnceWith(reportId);
    expect(host.textContent).toContain("The report expired."); expect(gateway.inspectKnowledgeCandidate).toHaveBeenCalledTimes(1);
  });

  it("consumes the exact report once through a pending recheck and localizes its delayed result", async () => {
    const pending = deferred<KnowledgeCandidateRecheck>(); gateway.recheckKnowledgeCandidate.mockReturnValueOnce(pending.promise);
    await render("zh-CN"); await chooseAndInspect(); const recheck = button("一次性重新核对");
    await act(async () => { recheck.click(); recheck.click(); }); await render("en-US"); await render("zh-CN"); await render("en-US");
    expect(host.textContent).toContain("Rechecking candidate directory…"); expect(gateway.recheckKnowledgeCandidate).toHaveBeenCalledExactlyOnceWith(reportId);
    expect(gateway.discardKnowledgeCandidateCheck).not.toHaveBeenCalled();
    await act(async () => pending.resolve({ report: report({ reportId: nextId }), comparison: "unchanged" }));
    expect(host.textContent).toContain("Recheck result: Unchanged"); await render("zh-CN");
    expect(host.textContent).toContain("重新核对结果：未变化"); await render("en-US"); await click("Cancel report");
    expect(gateway.discardKnowledgeCandidateCheck).toHaveBeenCalledExactlyOnceWith(nextId); expect(gateway.recheckKnowledgeCandidate).toHaveBeenCalledTimes(1);
  });

  it("preserves missing-count semantics and a delayed inconclusive transition", async () => {
    const pending = deferred<KnowledgeCandidateRecheck>(); gateway.recheckKnowledgeCandidate.mockReturnValueOnce(pending.promise);
    gateway.inspectKnowledgeCandidate.mockResolvedValueOnce(report({ currentLibrary: { state: "missing", manifestSha256: null, itemCount: null, revisionCount: null, folderCount: null }, conflicts: null }));
    await render("zh-CN"); await chooseAndInspect(); await render("en-US");
    expect(host.textContent).toContain("Current knowledge base status: Missing, current counts unavailable");
    expect(host.textContent).not.toContain("Current knowledge manifest SHA-256:"); expect(host.textContent).not.toContain("Manifest conflict summary");
    await click("One-time recheck"); await render("zh-CN");
    await act(async () => pending.resolve({ report: report({ reportId: nextId }), comparison: "inconclusive" }));
    expect(host.textContent).toContain("重新核对结果：无法确定"); await render("en-US");
    expect(host.textContent).toContain("Recheck result: Inconclusive"); expect(host.textContent).toContain("Current knowledge base status: Verified");
    expect(gateway.recheckKnowledgeCandidate).toHaveBeenCalledExactlyOnceWith(reportId);
  });

  it("renders a delayed controlled error without exposing the private backend message or retrying", async () => {
    const pending = deferred<KnowledgeCandidateCheckReport>(); gateway.inspectKnowledgeCandidate.mockReturnValueOnce(pending.promise);
    await render("zh-CN"); await chooseAndInspect(); await render("en-US");
    await act(async () => pending.reject(new Error("secret /tmp/{candidatePath}.json")));
    expect(host.querySelector('[role="alert"]')?.textContent).toBe("The candidate directory report is invalid or exceeds the fixed limits.");
    await render("zh-CN"); await render("en-US"); expect(host.textContent).not.toContain("secret");
    expect(gateway.inspectKnowledgeCandidate).toHaveBeenCalledExactlyOnceWith(path); expect(gateway.discardKnowledgeCandidateCheck).not.toHaveBeenCalled();
  });
});
