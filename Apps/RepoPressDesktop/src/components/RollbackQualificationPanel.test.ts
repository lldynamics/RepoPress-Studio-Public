import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerEntry } from "../contracts/releaseLedger";
import type { RollbackQualificationGateway } from "../contracts/rollbackQualification";
import { RollbackQualificationPanel } from "./RollbackQualificationPanel";

const target = "a".repeat(40);
const parent = "b".repeat(40);
const entry: ReleaseLedgerEntry = { source: "gitPush", recordId: "push-1", revision: 4, operation: "push", branch: "main", targetBranch: null, expectedSha: target, remoteUrl: "https://example.test/repo.git", startedAtEpochMs: 1_000, checkedAtEpochMs: 2_000, status: "pushVerified" };
const plan = (overrides: Record<string, unknown> = {}) => ({ sessionId: "session", recordId: "push-1", revision: 4, branch: "main", remoteUrl: entry.remoteUrl, expectedSha: target, parentSha: parent, localStatus: "candidate" as const, blockers: [], planId: "plan-1", expiresAtEpochMs: Date.now() + 60_000, ...overrides });
const report = (overrides: Record<string, unknown> = {}) => ({ ...plan(), status: "qualified" as const, remoteSha: target, checkedAtEpochMs: Date.now(), ...overrides });

let host: HTMLDivElement; let root: ReturnType<typeof createRoot>; let gateway: RollbackQualificationGateway & { planRollbackQualification: ReturnType<typeof vi.fn>; checkRollbackQualification: ReturnType<typeof vi.fn> };
function render(props: Partial<React.ComponentProps<typeof RollbackQualificationPanel>> = {}) { root.render(createElement(RollbackQualificationPanel, { gateway, sessionId: "session", entry, enabled: true, ...props })); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement; }

describe("RollbackQualificationPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { planRollbackQualification: vi.fn(async () => plan()), checkRollbackQualification: vi.fn(async () => report()) }; });
  afterEach(() => { root.unmount(); host.remove(); });

  it("uses local selection only and requires explicit remote confirmation", async () => {
    await act(async () => { render(); }); expect(gateway.planRollbackQualification).not.toHaveBeenCalled();
    await act(async () => button("审阅回滚条件").click()); await settle();
    expect(gateway.planRollbackQualification).toHaveBeenCalledWith("session", "push-1", 4);
    expect(host.textContent).toContain("冻结 SHA"); expect(gateway.checkRollbackQualification).not.toHaveBeenCalled();
    await act(async () => button("确认只读查询远端头").click()); await settle();
    expect(gateway.checkRollbackQualification).toHaveBeenCalledWith("session", "plan-1"); expect(host.textContent).toContain("查询时基础条件满足");
  });

  it("shows typed blockers and keeps blocked plans unconfirmable", async () => {
    gateway.planRollbackQualification.mockResolvedValueOnce(plan({ localStatus: "blocked", parentSha: null, blockers: ["mergeCommit"], planId: null, expiresAtEpochMs: null }));
    await act(async () => { render(); }); await act(async () => button("审阅回滚条件").click()); await settle();
    expect(host.textContent).toContain("目标是合并提交"); expect(host.textContent).not.toContain("确认只读查询远端头");
  });

  it("rejects unknown or mismatched responses without fabricating success", async () => {
    gateway.planRollbackQualification.mockResolvedValueOnce(plan({ recordId: "other" })); await act(async () => { render(); }); await act(async () => button("审阅回滚条件").click()); await settle();
    expect(host.textContent).toContain("无法读取回滚条件"); expect(host.textContent).not.toContain("候选");
    gateway.planRollbackQualification.mockResolvedValueOnce(plan()); gateway.checkRollbackQualification.mockResolvedValueOnce(report({ status: "unknown", blockers: ["remoteUnavailable"], remoteSha: null }));
    await act(async () => button("审阅回滚条件").click()); await settle(); await act(async () => button("确认只读查询远端头").click()); await settle(); expect(host.textContent).toContain("查询结果未知"); expect(host.textContent).not.toContain("基础条件满足");
  });

  it("expires and consumes a plan, and prevents replay", async () => {
    gateway.planRollbackQualification.mockResolvedValueOnce(plan({ expiresAtEpochMs: Date.now() - 1 })); await act(async () => { render(); }); await act(async () => button("审阅回滚条件").click()); await settle();
    expect(host.textContent).toContain("无法读取回滚条件"); expect(button("确认只读查询远端头")).toBeUndefined();
    gateway.planRollbackQualification.mockResolvedValueOnce(plan()); await act(async () => button("审阅回滚条件").click()); await settle(); await act(async () => button("确认只读查询远端头").click()); await settle();
    expect(gateway.checkRollbackQualification).toHaveBeenCalledTimes(1); expect(button("确认只读查询远端头")).toBeUndefined();
  });

  it("rejects contradictory candidate and blocked plan fields", async () => {
    gateway.planRollbackQualification.mockResolvedValueOnce(plan({ planId: null }));
    await act(async () => { render(); }); await act(async () => button("审阅回滚条件").click()); await settle();
    expect(host.textContent).toContain("无法读取回滚条件"); expect(host.textContent).not.toContain("只读查询候选");
    gateway.planRollbackQualification.mockResolvedValueOnce(plan({ localStatus: "blocked", blockers: [], planId: "plan-1", expiresAtEpochMs: Date.now() + 60_000 }));
    await act(async () => { render({ sessionId: "other" }); }); await act(async () => { render({ sessionId: "session" }); }); await act(async () => button("审阅回滚条件").click()); await settle();
    expect(host.textContent).toContain("无法读取回滚条件");
  });

  it("rejects a candidate for an unconfirmed ledger entry", async () => {
    gateway.planRollbackQualification.mockResolvedValueOnce(plan());
    await act(async () => { render({ entry: { ...entry, status: "unconfirmed" } }); });
    await act(async () => button("审阅回滚条件").click()); await settle();
    expect(host.textContent).toContain("无法读取回滚条件"); expect(host.textContent).not.toContain("只读查询候选");
  });

  it("rejects qualified reports without exact remote head or parent", async () => {
    gateway.checkRollbackQualification.mockResolvedValueOnce(report({ remoteSha: "c".repeat(40) }));
    await act(async () => { render(); }); await act(async () => button("审阅回滚条件").click()); await settle(); await act(async () => button("确认只读查询远端头").click()); await settle();
    expect(host.textContent).toContain("只读远端头查询失败"); expect(host.textContent).not.toContain("查询时基础条件满足");
  });

  it("invalidates state on identity, disabled, and stale response changes", async () => {
    let resolve!: (value: ReturnType<typeof plan>) => void; gateway.planRollbackQualification.mockImplementationOnce(() => new Promise((r) => { resolve = r; }));
    await act(async () => { render(); }); await act(async () => button("审阅回滚条件").click()); await act(async () => { render({ sessionId: "other" }); }); resolve(plan()); await settle(); expect(host.textContent).not.toContain("冻结 SHA");
    await act(async () => { render({ sessionId: "session", disabled: true }); }); expect(button("审阅回滚条件").disabled).toBe(true);
  });
});
