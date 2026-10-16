import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerGateway, ReleaseLedgerSnapshot } from "../contracts/releaseLedger";
import type { RollbackCandidateGateway, RollbackCandidatePlan, RollbackCandidateReport } from "../contracts/rollbackCandidate";
import { ReleaseLedgerPanel } from "./ReleaseLedgerPanel";

const pushEntry: ReleaseLedgerSnapshot["entries"][number] = {
  source: "gitPush", recordId: "push-1", revision: 3, operation: "push", branch: "main", targetBranch: null,
  expectedSha: "a".repeat(40), remoteUrl: "https://example.test/repo.git", startedAtEpochMs: 1_700_000_000_000,
  checkedAtEpochMs: 1_700_000_100_000, status: "pushVerified",
};
const snapshot = (sessionId = "session-1", entry = pushEntry): ReleaseLedgerSnapshot => ({
  sessionId, entries: [entry], partialSources: [], warnings: [],
  summary: { total: 1, verifiedPushes: entry.source === "gitPush" ? 1 : 0, verifiedReviews: entry.source === "remoteReview" ? 1 : 0, needsAttention: 0 },
});
const checkedAtEpochMs = Date.now();
const plan: RollbackCandidatePlan = {
  sessionId: "session-1", recordId: "push-1", revision: 3, branch: "main", remoteUrl: pushEntry.remoteUrl,
  expectedSha: pushEntry.expectedSha, parentSha: "b".repeat(40), status: "ready", planId: "11111111-1111-4111-8111-111111111111",
  sourceTreeSha: "c".repeat(40), targetTreeSha: "d".repeat(40), changedPaths: 1, targetFiles: 1, blockers: [],
  checkedAtEpochMs, expiresAtEpochMs: checkedAtEpochMs + 300_000,
};
const report: RollbackCandidateReport = {
  sessionId: plan.sessionId, recordId: plan.recordId, revision: plan.revision, branch: plan.branch,
  remoteUrl: plan.remoteUrl, expectedSha: plan.expectedSha, parentSha: plan.parentSha, planId: plan.planId!,
  sourceTreeSha: plan.sourceTreeSha!, targetTreeSha: plan.targetTreeSha!, candidateSha: "e".repeat(40),
  changedPaths: plan.changedPaths, targetFiles: plan.targetFiles, generatedAtEpochMs: checkedAtEpochMs + 10_000,
  temporaryObjectsRemoved: true,
};

type Gateway = ReleaseLedgerGateway & RollbackCandidateGateway & {
  getReleaseLedger: ReturnType<typeof vi.fn<(sessionId: string) => Promise<ReleaseLedgerSnapshot>>>;
  planRollbackCandidate: ReturnType<typeof vi.fn<(sessionId: string, recordId: string, revision: number) => Promise<RollbackCandidatePlan>>>;
  generateRollbackCandidate: ReturnType<typeof vi.fn<(sessionId: string, planId: string) => Promise<RollbackCandidateReport>>>;
  discardRollbackCandidate: ReturnType<typeof vi.fn<(sessionId: string, planId: string) => Promise<void>>>;
};
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let gateway: Gateway;

function render(props: Partial<React.ComponentProps<typeof ReleaseLedgerPanel>> = {}) {
  root.render(createElement(ReleaseLedgerPanel, { gateway, candidateGateway: gateway, sessionId: "session-1", enabled: true, ...props }));
}
async function settle() { await act(async () => { await Promise.resolve(); }); }
function candidateButton() {
  return [...host.querySelectorAll("button")].find((item) => /候选/.test(item.textContent ?? "")) as HTMLButtonElement | undefined;
}
function buttonMatching(pattern: RegExp) {
  return [...host.querySelectorAll("button")].find((item) => pattern.test(item.textContent ?? "")) as HTMLButtonElement | undefined;
}

describe("ReleaseLedgerPanel rollback candidate integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      getReleaseLedger: vi.fn(async (sessionId: string) => snapshot(sessionId)),
      planRollbackCandidate: vi.fn(async () => plan),
      generateRollbackCandidate: vi.fn(async () => report),
      discardRollbackCandidate: vi.fn(async () => undefined),
    };
  });
  afterEach(() => { act(() => { root.unmount(); }); host.remove(); });

  it("requires explicit planning and confirmation, generates and then cleans up a local candidate", async () => {
    await act(async () => { render(); }); await settle();
    expect(gateway.planRollbackCandidate).not.toHaveBeenCalled();
    expect(gateway.generateRollbackCandidate).not.toHaveBeenCalled();
    expect(candidateButton()).toBeTruthy();

    await act(async () => { candidateButton()!.click(); await Promise.resolve(); });
    expect(gateway.planRollbackCandidate).toHaveBeenCalledWith("session-1", "push-1", 3);
    expect(gateway.generateRollbackCandidate).not.toHaveBeenCalled();
    const confirm = buttonMatching(/生成|确认.*候选/);
    expect(confirm).toBeTruthy();
    await act(async () => { confirm!.click(); await Promise.resolve(); });
    expect(gateway.generateRollbackCandidate).toHaveBeenCalledWith("session-1", "11111111-1111-4111-8111-111111111111");
    expect(host.textContent).toContain(report.candidateSha);
    expect(host.textContent).toContain("临时对象已清理，候选 SHA 仅供审阅，不是持久对象或执行授权");
    expect(gateway.discardRollbackCandidate).not.toHaveBeenCalled();
  });

  it("embeds candidates only for git pushes and clears plans/results across refresh or session changes", async () => {
    await act(async () => { render(); }); await settle();
    expect(candidateButton()).toBeTruthy();
    await act(async () => { candidateButton()!.click(); await Promise.resolve(); });
    const confirm = buttonMatching(/确认生成本地候选/);
    expect(confirm).toBeTruthy();
    await act(async () => { confirm!.click(); await Promise.resolve(); });
    expect(host.textContent).toContain(report.candidateSha);
    await act(async () => { render({ refreshKey: 1 }); }); await settle();
    expect(host.textContent).not.toContain(report.candidateSha);

    const review = { ...pushEntry, source: "remoteReview" as const, targetBranch: "main", operation: "githubReview" as const, status: "reviewVerified" as const };
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot("session-1", review));
    await act(async () => { render({ refreshKey: 2 }); }); await settle();
    expect(candidateButton()).toBeUndefined();
    expect(gateway.planRollbackCandidate).toHaveBeenCalledTimes(1);
  });

  it("drops a late plan response after the session changes", async () => {
    let resolvePlan!: (value: RollbackCandidatePlan) => void;
    gateway.planRollbackCandidate.mockImplementationOnce(() => new Promise<RollbackCandidatePlan>((resolve) => { resolvePlan = resolve; }));
    await act(async () => { render(); }); await settle();
    await act(async () => { candidateButton()!.click(); await Promise.resolve(); });
    await act(async () => { render({ sessionId: "session-2" }); });
    resolvePlan(plan); await settle();
    expect(host.textContent).not.toContain(report.candidateSha);
    expect(gateway.generateRollbackCandidate).not.toHaveBeenCalled();
  });
});
