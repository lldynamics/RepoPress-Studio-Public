import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type { RollbackCandidateGateway } from "../contracts/rollbackCandidate";
import { RollbackCandidatePanel } from "./RollbackCandidatePanel";

const sha = (letter: string) => letter.repeat(40);
const entry: ReleaseLedgerEntry = { source: "gitPush", recordId: "push-1", revision: 4, operation: "push", branch: "main", targetBranch: null, expectedSha: sha("a"), remoteUrl: "https://example.test/repo.git", startedAtEpochMs: 1_000, checkedAtEpochMs: 2_000, status: "pushVerified" };
const makePlan = (overrides: Record<string, unknown> = {}) => ({ sessionId: "session", recordId: entry.recordId, revision: entry.revision, branch: entry.branch, remoteUrl: entry.remoteUrl, expectedSha: entry.expectedSha, parentSha: sha("b"), status: "ready" as const, planId: "123e4567-e89b-12d3-a456-426614174000", sourceTreeSha: sha("c"), targetTreeSha: sha("d"), changedPaths: 2, targetFiles: 1, blockers: [], checkedAtEpochMs: Date.now(), expiresAtEpochMs: Date.now() + 60_000, ...overrides });
const makeReport = (plan = makePlan(), overrides: Record<string, unknown> = {}) => ({ sessionId: plan.sessionId, recordId: plan.recordId, revision: plan.revision, branch: plan.branch, remoteUrl: plan.remoteUrl, expectedSha: plan.expectedSha, parentSha: plan.parentSha, planId: plan.planId, sourceTreeSha: plan.sourceTreeSha, targetTreeSha: plan.targetTreeSha, candidateSha: sha("e"), changedPaths: plan.changedPaths, targetFiles: plan.targetFiles, generatedAtEpochMs: Math.max(plan.checkedAtEpochMs + 1, Date.now()), temporaryObjectsRemoved: true as const, ...overrides });

let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: RollbackCandidateGateway & { planRollbackCandidate: ReturnType<typeof vi.fn>; generateRollbackCandidate: ReturnType<typeof vi.fn>; discardRollbackCandidate: ReturnType<typeof vi.fn> };
function render(props: Partial<React.ComponentProps<typeof RollbackCandidatePanel>> = {}) { root.render(createElement(RollbackCandidatePanel, { gateway, sessionId: "session", entry, enabled: true, ...props })); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement | undefined; }

describe("RollbackCandidatePanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { planRollbackCandidate: vi.fn(async () => makePlan()), generateRollbackCandidate: vi.fn(async () => makeReport()), discardRollbackCandidate: vi.fn(async () => undefined) }; });
  afterEach(() => { root.unmount(); host.remove(); vi.useRealTimers(); });

  it("does nothing automatically and requires explicit prepare then generate", async () => {
    await act(async () => render()); expect(gateway.planRollbackCandidate).not.toHaveBeenCalled(); expect(gateway.generateRollbackCandidate).not.toHaveBeenCalled();
    await act(async () => button("准备候选计划")?.click()); await settle();
    expect(gateway.planRollbackCandidate).toHaveBeenCalledWith("session", "push-1", 4); expect(host.textContent).toContain("源树 SHA"); expect(gateway.generateRollbackCandidate).not.toHaveBeenCalled();
    await act(async () => button("确认生成本地候选")?.click()); await settle();
    expect(gateway.generateRollbackCandidate).toHaveBeenCalledWith("session", "123e4567-e89b-12d3-a456-426614174000"); expect(host.textContent).toContain("候选父提交（冻结提交）"); expect(host.textContent).toContain("临时对象已清理，候选 SHA 仅供审阅");
  });

  it("shows blocked plans and rejects malformed plans and reports", async () => {
    gateway.planRollbackCandidate.mockResolvedValueOnce(makePlan({ status: "blocked", parentSha: sha("b"), sourceTreeSha: null, targetTreeSha: null, changedPaths: 0, targetFiles: 0, blockers: ["noChanges"], planId: null, expiresAtEpochMs: null }));
    await act(async () => render()); await act(async () => button("准备候选计划")?.click()); await settle(); expect(host.textContent).toContain("没有可确认的本地候选"); expect(host.textContent).toContain("没有可生成的变更"); expect(host.textContent).not.toContain("无法读取本地回滚候选条件"); expect(button("确认生成本地候选")).toBeUndefined();
    gateway.planRollbackCandidate.mockResolvedValueOnce(makePlan({ planId: null })); await act(async () => button("准备候选计划")?.click()); await settle(); expect(host.textContent).toContain("无法读取本地回滚候选条件");
    gateway.planRollbackCandidate.mockResolvedValueOnce(makePlan()); gateway.generateRollbackCandidate.mockResolvedValueOnce(makeReport(makePlan(), { candidateSha: entry.expectedSha })); await act(async () => button("准备候选计划")?.click()); await settle(); await act(async () => button("确认生成本地候选")?.click()); await settle(); expect(host.textContent).toContain("计划已消费");
  });

  it("discards on cancel and expiry, and invalidates disabled or changed context", async () => {
    vi.useFakeTimers(); vi.setSystemTime(new Date("2026-01-01T00:00:00.000Z"));
    await act(async () => render()); await act(async () => button("准备候选计划")?.click()); await settle(); await act(async () => button("取消候选计划")?.click()); expect(gateway.discardRollbackCandidate).toHaveBeenCalledWith("session", "123e4567-e89b-12d3-a456-426614174000");
    gateway.planRollbackCandidate.mockResolvedValueOnce(makePlan({ expiresAtEpochMs: Date.now() + 1_000 })); await act(async () => button("准备候选计划")?.click()); await settle(); await act(async () => { vi.advanceTimersByTime(1_001); }); await settle(); expect(host.textContent).toContain("计划已过期");
    await act(async () => render({ disabled: true })); expect(button("准备候选计划")?.disabled).toBe(true); await act(async () => render({ disabled: false, sessionId: "other" })); expect(host.textContent).not.toContain("候选计划已准备");
  });

  it("discards a stale ready response and a ready plan on unmount", async () => {
    let resolve!: (value: ReturnType<typeof makePlan>) => void; gateway.planRollbackCandidate.mockImplementationOnce(() => new Promise((r) => { resolve = r; }));
    await act(async () => render()); await act(async () => button("准备候选计划")?.click()); await act(async () => render({ sessionId: "other" })); resolve(makePlan()); await settle(); expect(gateway.discardRollbackCandidate).toHaveBeenCalledWith("session", "123e4567-e89b-12d3-a456-426614174000");
    vi.mocked(gateway.discardRollbackCandidate).mockClear();
    await act(async () => render({ sessionId: "session" })); await act(async () => button("准备候选计划")?.click()); await settle();
    expect(gateway.discardRollbackCandidate).not.toHaveBeenCalled();
    await act(async () => { root.unmount(); }); expect(gateway.discardRollbackCandidate).toHaveBeenCalledTimes(1); expect(gateway.discardRollbackCandidate).toHaveBeenCalledWith("session", "123e4567-e89b-12d3-a456-426614174000");
    root = createRoot(host);
  });
});
