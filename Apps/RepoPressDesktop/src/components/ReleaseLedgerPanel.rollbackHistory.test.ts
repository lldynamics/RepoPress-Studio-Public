import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerGateway, ReleaseLedgerSnapshot } from "../contracts/releaseLedger";
import type { RollbackRecord, RollbackTransactionGateway } from "../contracts/rollbackTransaction";
import { ReleaseLedgerPanel } from "./ReleaseLedgerPanel";

const sha = (letter: string) => letter.repeat(40);
const sharedRecordId = "11111111-1111-4111-8111-111111111111";
const historyRecordId = "22222222-2222-4222-8222-222222222222";
const sourceRecord = (recordId = sharedRecordId, revision = 1) => ({
  recordId, revision, outcome: "verified" as const, checkedAtEpochMs: 2_000, startedAtEpochMs: 1_000,
  observedRemoteSha: sha("a"), evidence: { repositoryPath: "/repo", repositoryIdentity: "repo-id", operation: "push" as const, remote: "origin", remoteUrl: "https://example.test/repo.git", branch: "main", expectedSha: sha("a"), observedBeforeSha: sha("b"), changedPaths: ["docs/a.md"] },
});
const pushEntry = (overrides: Partial<ReleaseLedgerSnapshot["entries"][number]> = {}) => ({
  source: "gitPush" as const, recordId: sharedRecordId, revision: 1, operation: "push" as const, branch: "main", targetBranch: null,
  expectedSha: sha("a"), remoteUrl: "https://example.test/repo.git", startedAtEpochMs: 1_000, checkedAtEpochMs: 2_000,
  status: "pushVerified" as const, ...overrides,
});
const rollbackDetail = (overrides: Record<string, unknown> = {}) => ({
  sourceRecordId: sharedRecordId, sourceRevision: 1, sourceSha: sha("f"), parentSha: sha("b"), sourceTreeSha: sha("c"), targetTreeSha: sha("d"),
  changedPaths: 2, targetFiles: 4, latestObservation: "candidateObserved" as const, observedRemoteSha: sha("e"), candidateObservedAtEpochMs: 3_000, ...overrides,
});
const rollbackEntry = (overrides: Partial<ReleaseLedgerSnapshot["entries"][number]> = {}) => ({
  source: "rollback" as const, recordId: sharedRecordId, revision: 2, operation: "rollbackAppend" as const, branch: "main", targetBranch: null,
  expectedSha: sha("e"), remoteUrl: "https://example.test/repo.git", startedAtEpochMs: 2_500, checkedAtEpochMs: 3_500,
  status: "rollbackCandidateObserved" as const, rollback: rollbackDetail(), ...overrides,
});
const diagnostics = (overrides: Partial<NonNullable<ReleaseLedgerSnapshot["rollbackDiagnostics"]>> = {}) => ({
  status: "available" as const, capacity: "available" as const, globalRecords: 1, payloadBytes: 12_000, remainingPayloadBytes: 4_131_104,
  localRecords: 1, localUnresolved: 0, maxRecords: 200 as const, maxPayloadBytes: 4_194_304 as const, maxRecordBytes: 65_536 as const,
  reservedObservationBytes: 51_200 as const, scopePartial: false, blockedTargets: [], checkedAtEpochMs: 4_000, ...overrides,
});
const snapshot = (entries: ReleaseLedgerSnapshot["entries"], overrides: Partial<ReleaseLedgerSnapshot> = {}): ReleaseLedgerSnapshot => ({
  sessionId: "session-1", entries, partialSources: [], warnings: [],
  summary: {
    total: entries.length,
    verifiedPushes: entries.filter((e) => e.status === "pushVerified").length,
    verifiedReviews: entries.filter((e) => e.status === "reviewVerified").length,
    needsAttention: entries.filter((e) => !["pushVerified", "reviewVerified", "rollbackCandidateObserved"].includes(e.status)).length,
    rollbackTransactions: entries.filter((e) => e.source === "rollback").length,
    historicalCandidateObservations: entries.filter((e) => e.source === "rollback" && e.rollback?.candidateObservedAtEpochMs !== null).length,
    unresolvedRollbackTransactions: entries.filter((e) => e.source === "rollback" && e.rollback?.candidateObservedAtEpochMs === null).length,
  }, rollbackDiagnostics: diagnostics({
    globalRecords: entries.filter((entry) => entry.source === "rollback").length,
    localRecords: entries.filter((entry) => entry.source === "rollback").length,
    localUnresolved: entries.filter((entry) => entry.source === "rollback" && entry.rollback?.candidateObservedAtEpochMs === null).length,
  }), ...overrides,
});
const historyRecord = (overrides: Partial<RollbackRecord> = {}): RollbackRecord => ({
  recordId: historyRecordId, planId: "33333333-3333-4333-8333-333333333333", sessionId: "session-1", revision: 1,
  source: sourceRecord(), parentSha: sha("b"), sourceTreeSha: sha("c"), targetTreeSha: sha("d"), candidateSha: sha("e"),
  changedPaths: 2, targetFiles: 4, outcome: "candidateObserved", observedRemoteSha: sha("e"), startedAtEpochMs: 1_000,
  checkedAtEpochMs: 4_000, candidateObservedAtEpochMs: 3_000, ...overrides,
});

type Gateway = ReleaseLedgerGateway & RollbackTransactionGateway & { getReleaseLedger: ReturnType<typeof vi.fn>; listRollbackRecords: ReturnType<typeof vi.fn>; verifyRollbackRecord: ReturnType<typeof vi.fn> };
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let gateway: Gateway;
function render(props: Partial<React.ComponentProps<typeof ReleaseLedgerPanel>> = {}) { act(() => root.render(createElement(ReleaseLedgerPanel, { gateway, transactionGateway: gateway, sessionId: "session-1", enabled: true, ...props }))); }
async function settle() { await act(async () => { await Promise.resolve(); }); }

describe("ReleaseLedgerPanel rollback history", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      getReleaseLedger: vi.fn(async () => snapshot([pushEntry(), rollbackEntry()])),
      planRollbackTransaction: vi.fn(), executeRollbackTransaction: vi.fn(), discardRollbackTransaction: vi.fn(),
      listRollbackRecords: vi.fn(async () => [historyRecord()]), verifyRollbackRecord: vi.fn(),
    } as unknown as Gateway;
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); });

  it("accepts the three-source shared ID namespace and retains first candidate proof after another head", async () => {
    const review = { ...pushEntry(), source: "remoteReview" as const, operation: "githubReview" as const, targetBranch: "main", status: "reviewVerified" as const, recordId: sharedRecordId, revision: 3 };
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot([pushEntry(), review, rollbackEntry({ status: "rollbackOtherHeadObserved", rollback: rollbackDetail({ latestObservation: "otherHeadObserved", observedRemoteSha: sha("f"), candidateObservedAtEpochMs: 3_000 }) })], { summary: { total: 3, verifiedPushes: 1, verifiedReviews: 1, needsAttention: 1, rollbackTransactions: 1, historicalCandidateObservations: 1, unresolvedRollbackTransactions: 0 } }));
    render(); await settle();
    expect(host.textContent).toContain(sharedRecordId);
    expect(host.textContent).toContain("首次");
    expect(host.textContent).toContain("候选");
    expect(host.textContent).toContain("其他头");
    expect(host.textContent).toContain("需关注 1");
    expect(host.textContent).toContain("历史首次观察到候选 1");
  });

  it("derives rollback status from latest outcome while retaining the first candidate timestamp", async () => {
    const candidate = rollbackEntry({ recordId: "44444444-4444-4444-8444-444444444444", status: "rollbackCandidateObserved", rollback: rollbackDetail({ latestObservation: "candidateObserved", candidateObservedAtEpochMs: 3_100 }) });
    const other = rollbackEntry({ recordId: "55555555-5555-4555-8555-555555555555", status: "rollbackOtherHeadObserved", rollback: rollbackDetail({ latestObservation: "otherHeadObserved", observedRemoteSha: sha("f"), candidateObservedAtEpochMs: 3_200 }) });
    const unknown = rollbackEntry({ recordId: "66666666-6666-4666-8666-666666666666", status: "unconfirmed", rollback: rollbackDetail({ latestObservation: "unconfirmed", observedRemoteSha: null, candidateObservedAtEpochMs: 3_300 }) });
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot([candidate, other, unknown], { summary: { total: 3, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 2, rollbackTransactions: 3, historicalCandidateObservations: 3, unresolvedRollbackTransactions: 0 } }));
    render(); await settle();
    expect(host.textContent).toContain("候选");
    expect(host.textContent).toContain("其他头");
    expect(host.textContent).toContain("未核实");
    expect(host.textContent).toContain("首次");
    expect(host.textContent).toContain("需关注 2");
  });

  it("keeps target-changed counts, shows blocked targets and partial diagnostics, and never verifies remotely on load", async () => {
    const unresolved = rollbackEntry({ recordId: "77777777-7777-4777-8777-777777777777", status: "unconfirmed", rollback: rollbackDetail({ latestObservation: "unconfirmed", observedRemoteSha: null, candidateObservedAtEpochMs: null }) });
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot([unresolved], { partialSources: ["gitPush"], warnings: ["推送来源部分不可用"], rollbackDiagnostics: diagnostics({ scopePartial: true, localRecords: 1, localUnresolved: 1, globalRecords: 1, blockedTargets: [{ remoteUrl: unresolved.remoteUrl, branch: unresolved.branch, localUnresolved: 1, pendingElsewhere: false }] }), summary: { total: 1, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 1, rollbackTransactions: 1, historicalCandidateObservations: 0, unresolvedRollbackTransactions: 1 } }));
    render(); await settle();
    expect(host.textContent).toContain("需关注 1");
    expect(host.textContent).toContain("部分来源");
    expect(host.textContent).toContain("受阻目标");
    expect(gateway.verifyRollbackRecord).not.toHaveBeenCalled();
  });

  it("retains target-changed attention counts and rejects drifted diagnostic counts", async () => {
    const changed = pushEntry({ status: "targetChanged" });
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot([changed], { summary: { total: 1, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 1, rollbackTransactions: 0, historicalCandidateObservations: 0, unresolvedRollbackTransactions: 0 } }));
    render(); await settle();
    expect(host.textContent).toContain("需关注 1");
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot([rollbackEntry()], { rollbackDiagnostics: diagnostics({ globalRecords: 201 }), summary: { total: 1, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 0, rollbackTransactions: 1, historicalCandidateObservations: 1, unresolvedRollbackTransactions: 0 } }));
    await act(async () => { render({ refreshKey: 1 }); }); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
  });

  it("locates rollback history without requiring a parent onOpenSource callback", async () => {
    const onOpenSource = vi.fn();
    render({ onOpenSource, focusRecordId: historyRecordId, focusRequest: 1 }); await settle();
    expect(host.textContent).toContain(historyRecordId);
    expect(onOpenSource).not.toHaveBeenCalled();
    expect(gateway.listRollbackRecords).toHaveBeenCalledWith("session-1");
  });

  it("focuses the matching history row when its timeline locator is clicked without any remote request", async () => {
    const onOpenSource = vi.fn();
    gateway.listRollbackRecords.mockResolvedValue([historyRecord({ recordId: sharedRecordId })]);
    const scroll = vi.fn();
    render({ onOpenSource }); await settle();
    const target = host.querySelector<HTMLElement>(`article[data-record-id="${sharedRecordId}"]`)!;
    target.scrollIntoView = scroll;
    const button = Array.from(host.querySelectorAll("button")).find((item) => item.textContent === "定位恢复历史")!;
    await act(async () => button.click());
    expect(document.activeElement).toBe(target); expect(scroll).toHaveBeenCalledOnce();
    expect(onOpenSource).not.toHaveBeenCalled(); expect(gateway.verifyRollbackRecord).not.toHaveBeenCalled();
  });

  it.each([
    ["malformed rollback counts", snapshot([rollbackEntry({ rollback: rollbackDetail({ changedPaths: -1 }) })])],
    ["malformed rollback status", snapshot([rollbackEntry({ status: "rollbackCandidateObserved", rollback: null })])],
    ["malformed rollback detail", snapshot([rollbackEntry({ rollback: rollbackDetail({ sourceRevision: 0 }) })])],
    ["candidate observed wrong SHA", snapshot([rollbackEntry({ rollback: rollbackDetail({ observedRemoteSha: sha("f") }) })])],
    ["foreign blocked target", snapshot([rollbackEntry()], { rollbackDiagnostics: diagnostics({ blockedTargets: [{ remoteUrl: "https://foreign.example/repo.git", branch: "main", localUnresolved: 1, pendingElsewhere: false }] }) })],
    ["malformed diagnostics capacity", snapshot([rollbackEntry()], { rollbackDiagnostics: diagnostics({ capacity: "broken" as never }) })],
  ])("rejects %s", async (_name, invalid) => {
    gateway.getReleaseLedger.mockResolvedValueOnce(invalid);
    render(); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
  });

  it("rejects 601 total entries and more than 200 entries from one source", async () => {
    const tooMany = Array.from({ length: 601 }, (_, i) => pushEntry({ recordId: `push-${i}`, revision: i + 1 }));
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot(tooMany, { summary: { total: 601, verifiedPushes: 601, verifiedReviews: 0, needsAttention: 0 } }));
    render(); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot(Array.from({ length: 201 }, (_, i) => pushEntry({ recordId: `push-${i}`, revision: i + 1 })), { summary: { total: 201, verifiedPushes: 201, verifiedReviews: 0, needsAttention: 0 } }));
    await act(async () => { render({ refreshKey: 1 }); }); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
  });

  it("ignores a stale response after the session changes", async () => {
    let resolveOld!: (value: ReleaseLedgerSnapshot) => void;
    gateway.getReleaseLedger.mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve; }));
    render(); await settle();
    await act(async () => { render({ sessionId: "session-2" }); });
    resolveOld(snapshot([rollbackEntry({ recordId: "stale" })])); await settle();
    expect(host.textContent).not.toContain("stale");
  });

  it("refreshes the ledger after an explicit history observation while an older ledger read is pending", async () => {
    let resolveInitial!: (value: ReleaseLedgerSnapshot) => void;
    const oldSnapshot = snapshot([rollbackEntry({ status: "rollbackCandidateObserved" })]);
    const latest = rollbackEntry({ status: "rollbackOtherHeadObserved", revision: 3, rollback: rollbackDetail({ latestObservation: "otherHeadObserved", observedRemoteSha: sha("f"), candidateObservedAtEpochMs: 3_000 }) });
    const freshSnapshot = snapshot([latest], { summary: { total: 1, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 1, rollbackTransactions: 1, historicalCandidateObservations: 1, unresolvedRollbackTransactions: 0 } });
    gateway.getReleaseLedger.mockImplementationOnce(() => new Promise((resolve) => { resolveInitial = resolve; })).mockResolvedValueOnce(freshSnapshot);
    gateway.listRollbackRecords.mockResolvedValue([historyRecord({ outcome: "candidateObserved", revision: 1 })]);
    gateway.verifyRollbackRecord.mockResolvedValueOnce(historyRecord({ outcome: "otherHeadObserved", revision: 2, observedRemoteSha: sha("f"), candidateObservedAtEpochMs: 3_000, checkedAtEpochMs: 4_500 }));
    render(); await settle(); await settle();
    const verify = [...host.querySelectorAll("button")].find((item) => /只读查询远端恢复结果/.test(item.textContent ?? ""));
    expect(verify).toBeDefined();
    await act(async () => verify!.click()); await settle(); await settle();
    expect(gateway.verifyRollbackRecord).toHaveBeenCalledTimes(1);
    expect(gateway.getReleaseLedger).toHaveBeenCalledTimes(2);
    resolveInitial(oldSnapshot); await settle(); await settle();
    expect(host.textContent).toContain("恢复后观察到其他头");
    expect(host.textContent).not.toContain("结果未明");
  });
});
