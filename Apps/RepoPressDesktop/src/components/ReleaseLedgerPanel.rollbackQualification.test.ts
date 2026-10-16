import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RollbackQualificationGateway, RollbackQualificationPlan, RollbackQualificationReport } from "../contracts/rollbackQualification";
import type { ReleaseLedgerGateway, ReleaseLedgerSnapshot } from "../contracts/releaseLedger";
import { ReleaseLedgerPanel } from "./ReleaseLedgerPanel";

const pushEntry = (overrides: Partial<ReleaseLedgerSnapshot["entries"][number]> = {}) => ({
  source: "gitPush" as const,
  recordId: "push-1",
  revision: 3,
  operation: "push" as const,
  branch: "main",
  targetBranch: null,
  expectedSha: "a".repeat(40),
  remoteUrl: "https://example.test/repo.git",
  startedAtEpochMs: 1_700_000_000_000,
  checkedAtEpochMs: 1_700_000_100_000,
  status: "pushVerified" as const,
  ...overrides,
});

const snapshot = (sessionId = "session-1", entry = pushEntry()): ReleaseLedgerSnapshot => ({
  sessionId,
  entries: [entry],
  partialSources: [],
  warnings: [],
  summary: { total: 1, verifiedPushes: 1, verifiedReviews: 0, needsAttention: 0 },
});

const qualificationPlan: RollbackQualificationPlan = {
  sessionId: "session-1",
  recordId: "push-1",
  revision: 3,
  branch: "main",
  remoteUrl: "https://example.test/repo.git",
  expectedSha: "a".repeat(40),
  parentSha: "b".repeat(40),
  localStatus: "candidate",
  blockers: [],
  planId: "rollback-plan-1",
  expiresAtEpochMs: Date.now() + 60_000,
};

const qualificationReport: RollbackQualificationReport = {
  sessionId: "session-1",
  recordId: "push-1",
  revision: 3,
  branch: "main",
  remoteUrl: "https://example.test/repo.git",
  expectedSha: "a".repeat(40),
  parentSha: "b".repeat(40),
  status: "qualified",
  blockers: [],
  remoteSha: "a".repeat(40),
  checkedAtEpochMs: 1_700_000_000_000,
};

type Gateway = ReleaseLedgerGateway & RollbackQualificationGateway & {
  getReleaseLedger: ReturnType<typeof vi.fn>;
  planRollbackQualification: ReturnType<typeof vi.fn>;
  checkRollbackQualification: ReturnType<typeof vi.fn>;
};

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let gateway: Gateway;

function render(props: Partial<React.ComponentProps<typeof ReleaseLedgerPanel>> = {}) {
  root.render(createElement(ReleaseLedgerPanel, {
    gateway,
    rollbackGateway: gateway,
    sessionId: "session-1",
    enabled: true,
    ...props,
  }));
}

async function settle() {
  await act(async () => { await Promise.resolve(); });
}

function clickText(text: string | RegExp) {
  const button = [...host.querySelectorAll("button")].find((item) => typeof text === "string" ? item.textContent === text : text.test(item.textContent ?? ""));
  expect(button).toBeTruthy();
  return act(async () => { (button as HTMLButtonElement).click(); await Promise.resolve(); });
}

describe("ReleaseLedgerPanel rollback qualification integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    gateway = {
      getReleaseLedger: vi.fn(async () => snapshot()),
      planRollbackQualification: vi.fn(async () => qualificationPlan),
      checkRollbackQualification: vi.fn(async () => qualificationReport),
    };
  });
  afterEach(() => { root.unmount(); host.remove(); });

  it("does not plan or check on load, and only exposes qualification for git pushes", async () => {
    render(); await settle();
    expect(gateway.getReleaseLedger).toHaveBeenCalledWith("session-1");
    expect(gateway.planRollbackQualification).not.toHaveBeenCalled();
    expect(gateway.checkRollbackQualification).not.toHaveBeenCalled();
    expect(host.textContent).toContain("审阅回滚条件");

    await act(async () => {
      render({ gateway: { ...gateway, getReleaseLedger: vi.fn(async () => ({
        ...snapshot(),
        entries: [pushEntry({ source: "remoteReview", targetBranch: "main", operation: "githubReview", status: "reviewVerified" })],
        summary: { total: 1, verifiedPushes: 0, verifiedReviews: 1, needsAttention: 0 },
      })) } as Gateway, rollbackGateway: gateway });
    });
    await settle();
    expect(host.textContent).not.toContain("审阅回滚条件");
  });

  it("requires explicit read-only confirmation before checking and keeps the sequence bounded", async () => {
    render(); await settle();
    await clickText("审阅回滚条件");
    expect(gateway.planRollbackQualification).toHaveBeenCalledWith("session-1", "push-1", 3);
    expect(gateway.checkRollbackQualification).not.toHaveBeenCalled();
    expect(host.textContent).toContain("确认只读查询远端头");

    await clickText("确认只读查询远端头");
    expect(gateway.checkRollbackQualification).toHaveBeenCalledWith("session-1", "rollback-plan-1");
    expect(gateway.planRollbackQualification).toHaveBeenCalledTimes(1);
    expect(gateway.checkRollbackQualification).toHaveBeenCalledTimes(1);
    expect(host.textContent).toContain("查询时基础条件满足");
  });

  it("invalidates a planned qualification when the ledger source refreshes", async () => {
    render(); await settle();
    await clickText("审阅回滚条件");
    expect(host.textContent).toContain("确认只读查询远端头");
    await act(async () => { render({ refreshKey: 1 }); });
    await settle();
    expect(host.textContent).not.toContain("确认只读查询远端头");
    expect(gateway.checkRollbackQualification).not.toHaveBeenCalled();
  });

  it("clears an open qualification when the session changes and ignores the late result", async () => {
    let resolvePlan!: (value: RollbackQualificationPlan) => void;
    gateway.planRollbackQualification.mockImplementationOnce(() => new Promise<RollbackQualificationPlan>((resolve) => { resolvePlan = resolve; }));
    gateway.getReleaseLedger.mockImplementation(async (sessionId: string) => snapshot(sessionId));
    render(); await settle();
    await clickText("审阅回滚条件");
    await act(async () => { render({ sessionId: "session-2" }); });
    expect(host.textContent).not.toContain("确认只读查询远端头");
    resolvePlan(qualificationPlan);
    await settle();
    expect(gateway.checkRollbackQualification).not.toHaveBeenCalled();
    expect(host.textContent).not.toContain("rollback-plan-1");
  });
});
