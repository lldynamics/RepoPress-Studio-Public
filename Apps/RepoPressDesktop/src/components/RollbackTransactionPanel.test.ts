import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type { RollbackRecord, RollbackTransactionGateway, RollbackTransactionPlan } from "../contracts/rollbackTransaction";
import { RollbackHistoryPanel, RollbackTransactionPanel } from "./RollbackTransactionPanel";

const sha = (letter: string) => letter.repeat(40);
const now = 1_700_000_000_000;
const entry: ReleaseLedgerEntry = { source: "gitPush", recordId: "223e4567-e89b-12d3-a456-426614174001", revision: 4, operation: "push", branch: "main", targetBranch: null, expectedSha: sha("a"), remoteUrl: "https://example.test/repo.git", startedAtEpochMs: now - 10_000, checkedAtEpochMs: now, status: "pushVerified" };
const plan = (overrides: Partial<RollbackTransactionPlan> = {}): RollbackTransactionPlan => ({ sessionId: "session", recordId: entry.recordId, revision: 4, branch: "main", remoteUrl: entry.remoteUrl, expectedSha: entry.expectedSha, parentSha: sha("b"), status: "ready", planId: "123e4567-e89b-12d3-a456-426614174000", sourceTreeSha: sha("c"), targetTreeSha: sha("d"), changedPaths: 2, targetFiles: 1, blockers: [], checkedAtEpochMs: now + 1_000, expiresAtEpochMs: now + 61_000, candidateSha: sha("e"), observedRemoteSha: entry.expectedSha, ...overrides });
const record = (overrides: Partial<RollbackRecord> = {}): RollbackRecord => ({ sessionId: "session", planId: "123e4567-e89b-12d3-a456-426614174000", recordId: "323e4567-e89b-12d3-a456-426614174001", revision: 1, source: { recordId: entry.recordId, revision: 4, evidence: { repositoryPath: "/repo", repositoryIdentity: "repo-id", operation: "push", remote: "origin", branch: "main", remoteUrl: entry.remoteUrl, expectedSha: entry.expectedSha, observedBeforeSha: sha("b"), changedPaths: ["docs/a.md"] }, outcome: "verified", observedRemoteSha: entry.expectedSha, startedAtEpochMs: now - 10_000, checkedAtEpochMs: now }, parentSha: sha("b"), sourceTreeSha: sha("c"), targetTreeSha: sha("d"), candidateSha: sha("e"), changedPaths: 2, targetFiles: 1, outcome: "candidateObserved", observedRemoteSha: sha("e"), candidateObservedAtEpochMs: now + 3_000, startedAtEpochMs: now + 2_000, checkedAtEpochMs: now + 3_000, ...overrides });

type GatewayMocks = { [K in keyof RollbackTransactionGateway]: ReturnType<typeof vi.fn> };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: GatewayMocks;
function render(props: Partial<React.ComponentProps<typeof RollbackTransactionPanel>> = {}) { root.render(createElement(RollbackTransactionPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "session", entry, enabled: true, ...props })); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(matcher: string | RegExp) { return [...host.querySelectorAll("button")].find((item) => typeof matcher === "string" ? item.textContent === matcher : matcher.test(item.textContent ?? "")) as HTMLButtonElement | undefined; }

describe("RollbackTransactionPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(now); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { planRollbackTransaction: vi.fn(async () => plan()), executeRollbackTransaction: vi.fn(async () => record()), discardRollbackTransaction: vi.fn(async () => undefined), listRollbackRecords: vi.fn(async () => []), verifyRollbackRecord: vi.fn(async () => record()) } as unknown as typeof gateway; });
  afterEach(() => { root.unmount(); host.remove(); vi.useRealTimers(); });

  it("requires explicit preparation and never executes automatically", async () => {
    await act(async () => render());
    expect(gateway.planRollbackTransaction).not.toHaveBeenCalled(); expect(gateway.executeRollbackTransaction).not.toHaveBeenCalled();
    await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await settle();
    expect(gateway.planRollbackTransaction).toHaveBeenCalledWith("session", entry.recordId, 4); expect(gateway.executeRollbackTransaction).not.toHaveBeenCalled();
    expect(button(/确认.*回滚|执行.*回滚/)).toBeDefined();
  });

  it("never enables execution for blocked, contradictory, invalid SHA, or stale identity plans", async () => {
    for (const bad of [plan({ status: "blocked", planId: null, candidateSha: null, blockers: ["remoteDifferent"] }), plan({ observedRemoteSha: sha("f") }), plan({ targetTreeSha: "bad" }), plan({ sessionId: "other" }), plan({ recordId: "other" }), plan({ revision: 5 })]) {
      gateway.planRollbackTransaction.mockResolvedValueOnce(bad);
      await act(async () => render()); await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await settle();
      const execute = button(/确认.*回滚|执行.*回滚/); expect(execute?.disabled ?? true).toBe(true); expect(gateway.executeRollbackTransaction).not.toHaveBeenCalled();
    }
  });

  it("discards a ready plan on cancel, expiry, context change, and unmount; late responses do not write state", async () => {
    vi.setSystemTime(now);
    await act(async () => render()); await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await settle();
    await act(async () => button(/取消.*回滚|取消.*计划/)?.click()); expect(gateway.discardRollbackTransaction).toHaveBeenCalledWith("session", plan().planId);
    gateway.planRollbackTransaction.mockResolvedValueOnce(plan({ expiresAtEpochMs: Date.now() + 2_000 })); await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await settle(); await act(async () => { vi.advanceTimersByTime(2_001); }); await settle(); expect(host.textContent).toContain("过期");
    let resolve!: (value: RollbackTransactionPlan) => void; gateway.planRollbackTransaction.mockImplementationOnce(() => new Promise((r) => { resolve = r; })); await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await act(async () => render({ sessionId: "other" })); await act(async () => { resolve(plan()); }); await settle(); expect(gateway.executeRollbackTransaction).not.toHaveBeenCalled();
    await act(async () => render({ sessionId: "session" })); await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await settle(); await act(async () => root.unmount()); expect(gateway.discardRollbackTransaction).toHaveBeenCalled(); root = createRoot(host);
  });

  it("keeps an unknown execution receipt visible and does not auto-retry", async () => {
    gateway.executeRollbackTransaction.mockRejectedValueOnce({ code: "rollback_outcome_unknown", message: "receipt-unknown" });
    await act(async () => render()); await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await settle(); await act(async () => button(/确认.*回滚|执行.*回滚/)?.click()); await settle(); await settle();
    expect(gateway.executeRollbackTransaction).toHaveBeenCalledTimes(1); expect(host.textContent).toMatch(/恢复台账|不会自动重试/);
  });

  it("executes one valid plan and keeps the durable receipt identity separate from its source record", async () => {
    const receipt = record({ recordId: "323e4567-e89b-12d3-a456-426614174002", revision: 1 });
    gateway.executeRollbackTransaction.mockResolvedValueOnce(receipt);
    await act(async () => render()); await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await settle(); await act(async () => button(/确认.*回滚|执行.*回滚/)?.click()); await settle();
    expect(gateway.executeRollbackTransaction).toHaveBeenCalledWith("session", plan().planId); expect(host.textContent).toContain("已记录"); expect(host.textContent).toContain("当前观察到候选"); expect(host.textContent).not.toContain("已追加"); expect(host.textContent).not.toContain("已部署");
  });

  it("does not authorize blocked remote-different plans or trust an incorrect candidate SHA", async () => {
    for (const blocked of [plan({ status: "blocked", planId: null, parentSha: null, sourceTreeSha: null, targetTreeSha: null, candidateSha: null, observedRemoteSha: sha("f"), changedPaths: 0, targetFiles: 0, expiresAtEpochMs: null, blockers: ["remoteDifferent"] }), plan({ candidateSha: entry.expectedSha }), plan({ sourceTreeSha: sha("c"), targetTreeSha: sha("c") })]) {
      gateway.planRollbackTransaction.mockResolvedValueOnce(blocked);
      await act(async () => render()); await act(async () => button(/准备.*回滚|准备.*计划/)?.click()); await settle();
      expect(button(/确认.*回滚|执行.*回滚/)?.disabled ?? true).toBe(true); expect(gateway.executeRollbackTransaction).not.toHaveBeenCalled();
      if (blocked.status === "blocked") { expect(host.textContent).toContain("远端分支已变化"); expect(host.querySelector('[role="alert"]')).toBeNull(); }
    }
  });
});

describe("RollbackHistoryPanel", () => {
  beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(now); host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { planRollbackTransaction: vi.fn(), executeRollbackTransaction: vi.fn(), discardRollbackTransaction: vi.fn(), listRollbackRecords: vi.fn(async () => [record({ recordId: "323e4567-e89b-12d3-a456-426614174001", revision: 2, outcome: "unconfirmed", observedRemoteSha: null, candidateObservedAtEpochMs: null, checkedAtEpochMs: null }), record({ recordId: "323e4567-e89b-12d3-a456-426614174002", revision: 2, outcome: "otherHeadObserved", observedRemoteSha: sha("f"), candidateObservedAtEpochMs: null })]), verifyRollbackRecord: vi.fn(async () => record({ recordId: "323e4567-e89b-12d3-a456-426614174001", revision: 3, outcome: "candidateObserved", observedRemoteSha: sha("e"), checkedAtEpochMs: now + 4_000, candidateObservedAtEpochMs: now + 4_000 })) }; });
  afterEach(() => { root.unmount(); host.remove(); vi.useRealTimers(); });

  it("loads history without auto-verifying and verifies only the explicit record revision", async () => {
    await act(async () => root.render(createElement(RollbackHistoryPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "session", enabled: true }))); await settle(); await settle();
    expect(gateway.listRollbackRecords).toHaveBeenCalledWith("session"); expect(gateway.verifyRollbackRecord).not.toHaveBeenCalled(); expect(host.textContent).toContain("323e4567-e89b-12d3-a456-426614174001"); expect(host.textContent).toContain("323e4567-e89b-12d3-a456-426614174002");
    const verify = [...host.querySelectorAll("button")].find((item) => /核实|验证/.test(item.textContent ?? "")); await act(async () => verify?.click()); await settle(); await settle();
    expect(gateway.verifyRollbackRecord).toHaveBeenCalledWith("session", "323e4567-e89b-12d3-a456-426614174001", 2); expect((await gateway.verifyRollbackRecord.mock.results[0]?.value).candidateObservedAtEpochMs).toBe(now + 4_000); expect(host.textContent).toContain("已刷新该记录"); expect(host.querySelector('[role="alert"]')).toBeNull(); expect(host.textContent).not.toContain("已追加远端回滚提交");
  });

  it("does not write stale list results when disabled or session changes", async () => {
    let resolve!: (value: RollbackRecord[]) => void; gateway.listRollbackRecords.mockImplementationOnce(() => new Promise((r) => { resolve = r; }));
    await act(async () => root.render(createElement(RollbackHistoryPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "session", enabled: true }))); await act(async () => root.render(createElement(RollbackHistoryPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "other", enabled: false }))); await act(async () => { resolve([record()]); }); await settle();
    expect(host.textContent).not.toContain("push-1");
  });

  it("locates and focuses a requested history row without triggering a remote read", async () => {
    const scrollIntoView = vi.fn();
    HTMLElement.prototype.scrollIntoView = scrollIntoView;
    await act(async () => root.render(createElement(RollbackHistoryPanel, {
      gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "session", enabled: true,
      focusRecordId: "323e4567-e89b-12d3-a456-426614174001", focusRequest: 1,
    })));
    await settle(); await settle();
    const row = [...host.querySelectorAll("article")].find((item) => item.textContent?.includes("323e4567-e89b-12d3-a456-426614174001")) as HTMLElement | undefined;
    expect(row).toBeDefined();
    expect(scrollIntoView).toHaveBeenCalled();
    expect(document.activeElement).toBe(row);
    expect(gateway.verifyRollbackRecord).not.toHaveBeenCalled();
  });

  it("calls onObserved only for a successful verification in the current context", async () => {
    const onObserved = vi.fn();
    await act(async () => root.render(createElement(RollbackHistoryPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "session", enabled: true, onObserved })));
    await settle(); await settle();
    const verify = [...host.querySelectorAll("button")].find((item) => /核实|验证/.test(item.textContent ?? ""));
    await act(async () => verify?.click()); await settle(); await settle();
    expect(onObserved).toHaveBeenCalledTimes(1);

    let resolve!: (value: RollbackRecord) => void;
    gateway.verifyRollbackRecord.mockImplementationOnce(() => new Promise((r) => { resolve = r; }));
    await act(async () => root.render(createElement(RollbackHistoryPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "session", enabled: true, onObserved })));
    await settle(); await settle();
    const secondVerify = [...host.querySelectorAll("button")].find((item) => /核实|验证/.test(item.textContent ?? ""));
    await act(async () => secondVerify?.click());
    await act(async () => root.render(createElement(RollbackHistoryPanel, { gateway: gateway as unknown as RollbackTransactionGateway, sessionId: "other", enabled: true, onObserved })));
    resolve(record({ sessionId: "session", revision: 3 })); await settle();
    expect(onObserved).toHaveBeenCalledTimes(1);
  });
});
