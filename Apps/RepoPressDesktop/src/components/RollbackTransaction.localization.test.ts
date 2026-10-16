import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type { RollbackRecord, RollbackTransactionGateway, RollbackTransactionPlan } from "../contracts/rollbackTransaction";
import { I18nProvider } from "../i18n/i18n";
import { RollbackHistoryPanel, RollbackTransactionPanel } from "./RollbackTransactionPanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

const sha = (letter: string) => letter.repeat(40);
const now = 1_700_000_000_000;
const entry: ReleaseLedgerEntry = { source: "gitPush", recordId: "223e4567-e89b-12d3-a456-426614174001", revision: 4, operation: "push", branch: "设置-main", targetBranch: null, expectedSha: sha("a"), remoteUrl: "https://example.test/repo.git", startedAtEpochMs: now - 10_000, checkedAtEpochMs: now, status: "pushVerified" };
const plan = (overrides: Partial<RollbackTransactionPlan> = {}): RollbackTransactionPlan => ({ sessionId: "session", recordId: entry.recordId, revision: 4, branch: entry.branch, remoteUrl: entry.remoteUrl, expectedSha: entry.expectedSha, parentSha: sha("b"), status: "ready", planId: "123e4567-e89b-12d3-a456-426614174000", sourceTreeSha: sha("c"), targetTreeSha: sha("d"), changedPaths: 2, targetFiles: 1, blockers: [], checkedAtEpochMs: now + 1_000, expiresAtEpochMs: now + 61_000, candidateSha: sha("e"), observedRemoteSha: entry.expectedSha, ...overrides });
const record = (overrides: Partial<RollbackRecord> = {}): RollbackRecord => ({ sessionId: "session", planId: "123e4567-e89b-12d3-a456-426614174000", recordId: "323e4567-e89b-12d3-a456-426614174001", revision: 2, source: { recordId: entry.recordId, revision: 4, evidence: { repositoryPath: "/repo", repositoryIdentity: "repo-id", operation: "push", remote: "origin", branch: entry.branch, remoteUrl: entry.remoteUrl, expectedSha: entry.expectedSha, observedBeforeSha: sha("b"), changedPaths: ["docs/a.md"], }, outcome: "verified", observedRemoteSha: entry.expectedSha, startedAtEpochMs: now - 10_000, checkedAtEpochMs: now }, parentSha: sha("b"), sourceTreeSha: sha("c"), targetTreeSha: sha("d"), candidateSha: sha("e"), changedPaths: 2, targetFiles: 1, outcome: "candidateObserved", observedRemoteSha: sha("e"), candidateObservedAtEpochMs: now + 3_000, startedAtEpochMs: now + 2_000, checkedAtEpochMs: now + 3_000, ...overrides });
type GatewayMocks = { [K in keyof RollbackTransactionGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement;
let root: Root;
let gateway: GatewayMocks;

function renderPanel(locale: "zh-CN" | "en-US") {
  const child = createElement(RollbackTransactionPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "session", entry, enabled: true });
  act(() => root.render(createElement(I18nProvider, { locale, children: child })));
}
function renderHistory(locale: "zh-CN" | "en-US") {
  const child = createElement(RollbackHistoryPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "session", enabled: true });
  act(() => root.render(createElement(I18nProvider, { locale, children: child })));
}
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(matcher: string | RegExp) { return [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => typeof matcher === "string" ? item.textContent === matcher : matcher.test(item.textContent ?? "")); }
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>((done) => { resolve = done; }); return { promise, resolve }; }

describe("RollbackTransaction localization", () => {
  beforeEach(() => {
    vi.useFakeTimers(); vi.setSystemTime(now); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = { planRollbackTransaction: vi.fn(async () => plan()), executeRollbackTransaction: vi.fn(async () => record({ revision: 3 })), discardRollbackTransaction: vi.fn(async () => undefined), listRollbackRecords: vi.fn(async () => []), verifyRollbackRecord: vi.fn(async () => record({ revision: 3 })) } as unknown as GatewayMocks;
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); });

  it("keeps a pending plan request and frozen evidence across locale changes, and double confirm executes once", async () => {
    const request = deferred<RollbackTransactionPlan>();
    gateway.planRollbackTransaction.mockReturnValueOnce(request.promise);
    renderPanel("zh-CN");
    await act(async () => button(/准备.*回滚|准备.*计划/)!.click());
    renderPanel("en-US");
    await act(async () => { request.resolve(plan()); }); await settle();
    expect(gateway.planRollbackTransaction).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain(entry.remoteUrl); expect(host.textContent).toContain(entry.expectedSha); expect(host.textContent).toContain(entry.branch);
    const confirm = button("Confirm appending remote rollback commit")!;
    await act(async () => { confirm.click(); confirm.click(); }); await settle();
    expect(gateway.executeRollbackTransaction).toHaveBeenCalledTimes(1);
    expect(gateway.executeRollbackTransaction).toHaveBeenCalledWith("session", plan().planId);
    expect(host.textContent).toContain("Remote recovery result recorded");
  });

  it("does not restart or extend the expiry timer when switching locale", async () => {
    renderPanel("zh-CN");
    gateway.planRollbackTransaction.mockResolvedValueOnce(plan({ expiresAtEpochMs: now + 2_000 }));
    await act(async () => button(/准备.*回滚|准备.*计划/)!.click()); await settle();
    renderPanel("en-US");
    await act(async () => { vi.advanceTimersByTime(2_001); }); await settle();
    expect(gateway.discardRollbackTransaction).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("The plan expired. Prepare it again.");
    renderPanel("zh-CN");
    expect(host.textContent).toContain("计划已过期，请重新准备。");
    await act(async () => { vi.advanceTimersByTime(20_000); });
    expect(gateway.discardRollbackTransaction).toHaveBeenCalledTimes(1);
  });

  it("keeps history loading and pending verification stable while translating dates and preserving raw evidence", async () => {
    const list = deferred<RollbackRecord[]>();
    gateway.listRollbackRecords.mockReturnValueOnce(list.promise);
    renderHistory("zh-CN");
    renderHistory("en-US");
    expect(gateway.listRollbackRecords).toHaveBeenCalledTimes(1);
    const listed = record({ revision: 2 });
    await act(async () => { list.resolve([listed]); }); await settle();
    expect(host.textContent).toContain(entry.branch); expect(host.textContent).toContain(new Date(listed.startedAtEpochMs).toLocaleString("en-US"));
    const verifyResult = deferred<RollbackRecord>();
    gateway.verifyRollbackRecord.mockReturnValueOnce(verifyResult.promise);
    await act(async () => button(/Query remote recovery result/)!.click());
    renderHistory("zh-CN");
    expect(gateway.verifyRollbackRecord).toHaveBeenCalledTimes(1);
    expect(gateway.verifyRollbackRecord).toHaveBeenCalledWith("session", listed.recordId, listed.revision);
    await act(async () => { verifyResult.resolve(record({ recordId: listed.recordId, revision: 3 })); }); await settle();
    expect(host.textContent).toContain("已刷新该记录的只读远端观察");
    expect(host.textContent).toContain(entry.branch);
  });

  it("explains blocked safety state in English without authorizing execution or exposing backend errors", async () => {
    gateway.planRollbackTransaction.mockResolvedValueOnce(plan({ status: "blocked", planId: null, parentSha: null, sourceTreeSha: null, targetTreeSha: null, candidateSha: null, observedRemoteSha: sha("f"), changedPaths: 0, targetFiles: 0, expiresAtEpochMs: null, blockers: ["remoteDifferent"] }));
    renderPanel("en-US");
    await act(async () => button(/Prepare remote rollback plan/)!.click()); await settle();
    expect(host.textContent).toContain("remote branch changed");
    expect(button(/Confirm appending remote rollback commit/)).toBeUndefined();
    expect(gateway.executeRollbackTransaction).not.toHaveBeenCalled();

    gateway.planRollbackTransaction.mockRejectedValueOnce({ message: "backend-secret-should-not-leak" });
    await act(async () => button(/Prepare remote rollback plan/)!.click()); await settle();
    expect(host.textContent).toContain("Unable to read remote rollback conditions. Try again later.");
    expect(host.textContent).not.toContain("backend-secret-should-not-leak");
    expect(gateway.executeRollbackTransaction).not.toHaveBeenCalled();
  });
});
