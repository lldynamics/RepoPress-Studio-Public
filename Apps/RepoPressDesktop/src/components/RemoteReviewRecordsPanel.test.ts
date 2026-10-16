import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RemoteReviewRecord, RemoteReviewRecordsGateway } from "../contracts/remoteReviewLedger";
import { RemoteReviewRecordsPanel } from "./RemoteReviewRecordsPanel";

const evidence = { repositoryPath: "/repo", repositoryIdentity: "repo-id", remote: "origin", remoteUrl: "https://github.com/acme/project.git", provider: "github" as const, owner: "acme", project: "project", remoteProjectId: 42, sourceBranch: "feature", targetBranch: "main", sourceSha: "abc123", titleSha256: "title", bodySha256: "body", marker: "marker" };
const record = (overrides: Partial<RemoteReviewRecord> = {}): RemoteReviewRecord => ({ recordId: "record-1", revision: 1, evidence, outcome: "unconfirmed", verification: "notChecked", reviewNumber: null, webUrl: null, startedAtEpochMs: 1_000, checkedAtEpochMs: null, ...overrides });
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let currentRecords: RemoteReviewRecord[];
type TestGateway = { [K in keyof RemoteReviewRecordsGateway]: ReturnType<typeof vi.fn> };
let gateway: TestGateway;

function render(props: Partial<React.ComponentProps<typeof RemoteReviewRecordsPanel>> = {}) { root.render(createElement(RemoteReviewRecordsPanel, { gateway: gateway as unknown as RemoteReviewRecordsGateway, sessionId: "session", enabled: true, ...props })); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement; }
function plan() { return { planId: "plan-1", recordId: "record-1", remoteUrl: evidence.remoteUrl, provider: evidence.provider, owner: evidence.owner, project: evidence.project, sourceBranch: evidence.sourceBranch, targetBranch: evidence.targetBranch, sourceSha: evidence.sourceSha, expiresAt: new Date(Date.now() + 10_000).toISOString() }; }

describe("RemoteReviewRecordsPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host); currentRecords = [record()];
    gateway = { listRemoteReviewRecords: vi.fn(async () => currentRecords), planRemoteReviewVerification: vi.fn(async () => plan()), executeRemoteReviewVerification: vi.fn(async () => record({ revision: 2, outcome: "verified", verification: "matched", reviewNumber: 12, checkedAtEpochMs: Date.now() })), removeRemoteReviewRecord: vi.fn(async () => []) };
  });
  afterEach(() => { root.unmount(); host.remove(); vi.useRealTimers(); });

  it("loads local records without verification calls and explains unknown states", async () => {
    currentRecords = [record({ verification: "noMatch" }), record({ recordId: "ambiguous", verification: "ambiguous" })]; render(); await settle();
    expect(gateway.listRemoteReviewRecords).toHaveBeenCalledWith("session"); expect(gateway.planRemoteReviewVerification).not.toHaveBeenCalled(); expect(gateway.executeRemoteReviewVerification).not.toHaveBeenCalled();
    expect(host.textContent).toContain("未匹配（不代表未创建）"); expect(host.textContent).toContain("结果不明确");
  });

  it("requires explicit confirmation, rejects mismatched targets, and consumes failed plans", async () => {
    render(); await settle(); await act(async () => button("核实远端结果").click()); await settle();
    expect(gateway.executeRemoteReviewVerification).not.toHaveBeenCalled(); expect(host.textContent).toContain("确认只读核实");
    gateway.executeRemoteReviewVerification.mockRejectedValueOnce(new Error("raw secret")); await act(async () => button("确认只读核实").click()); await settle();
    expect(gateway.executeRemoteReviewVerification).toHaveBeenCalledWith("session", "plan-1"); expect(host.textContent).not.toContain("确认只读核实"); expect(host.textContent).not.toContain("raw secret");
    gateway.planRemoteReviewVerification.mockResolvedValueOnce({ ...plan(), sourceSha: "wrong" }); await act(async () => button("核实远端结果").click()); await settle();
    expect(host.textContent).toContain("无法读取远端审查记录或核实结果");
  });

  it("allows only one execute call for duplicate confirmation clicks and rejects inconsistent verified results", async () => {
    let resolveExecute!: (value: RemoteReviewRecord) => void;
    gateway.executeRemoteReviewVerification.mockImplementationOnce(() => new Promise((resolve) => { resolveExecute = resolve; }));
    render(); await settle(); await act(async () => button("核实远端结果").click()); await settle();
    await act(async () => { button("确认只读核实").click(); button("确认只读核实").click(); });
    expect(gateway.executeRemoteReviewVerification).toHaveBeenCalledTimes(1);
    resolveExecute(record({ outcome: "verified", verification: "noMatch", reviewNumber: null })); await settle();
    expect(host.textContent).toContain("无法读取远端审查记录或核实结果"); expect(host.textContent).toContain("未核实");
  });

  it("does not let an old session finally unlock a newer plan request", async () => {
    let resolveOld!: (value: unknown) => void; let resolveNew!: (value: unknown) => void;
    gateway.planRemoteReviewVerification
      .mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveNew = resolve; }));
    render({ sessionId: "old-session" }); await settle(); await act(async () => button("核实远端结果").click());
    render({ sessionId: "new-session" }); await settle(); await act(async () => button("核实远端结果").click());
    resolveOld(plan()); await settle();
    expect(button("核实远端结果").disabled).toBe(true);
    resolveNew({ ...plan(), planId: "new-plan" }); await settle();
    expect(button("核实远端结果").disabled).toBe(false);
  });

  it("invalidates stale session results and expired plans", async () => {
    let resolveList!: (value: RemoteReviewRecord[]) => void; gateway.listRemoteReviewRecords.mockImplementationOnce(() => new Promise((resolve) => { resolveList = resolve; }));
    render({ sessionId: "old" }); await settle(); render({ sessionId: "new" }); await settle(); resolveList([record({ recordId: "stale" })]); await settle(); expect(host.textContent).not.toContain("stale");
    gateway.planRemoteReviewVerification.mockResolvedValueOnce({ ...plan(), expiresAt: "invalid" }); await act(async () => button("核实远端结果").click()); await settle(); expect(host.textContent).toContain("已过期"); expect(gateway.executeRemoteReviewVerification).not.toHaveBeenCalled();
  });

  it("only allows confirmed local deletion with explicit ID and revision", async () => {
    currentRecords = [record({ outcome: "verified", verification: "matched" }), record({ recordId: "unknown" })]; render(); await settle();
    expect([...host.querySelectorAll("button")].filter((item) => item.textContent === "删除本地记录")).toHaveLength(1);
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true); await act(async () => button("删除本地记录").click()); await settle();
    expect(confirm.mock.calls[0][0]).toContain("记录 ID：record-1"); expect(confirm.mock.calls[0][0]).toContain("记录版本：1"); expect(gateway.removeRemoteReviewRecord).toHaveBeenCalledWith("session", "record-1", 1); confirm.mockRestore();
  });

  it("shows success only after the frozen evidence and a newer record are returned", async () => {
    render(); await settle(); await act(async () => button("核实远端结果").click()); await settle();
    await act(async () => button("确认只读核实").click()); await settle();
    expect(host.textContent).toContain("已核实");
    expect(host.textContent).toContain("12");
    expect(button("删除本地记录")).toBeDefined();
  });

  it.each(["bodySha256", "marker"] as const)("rejects a verification response with changed %s", async (key) => {
    gateway.executeRemoteReviewVerification.mockResolvedValueOnce(record({ revision: 2, evidence: { ...evidence, [key]: "changed" }, outcome: "verified", verification: "matched", reviewNumber: 12 }));
    render(); await settle(); await act(async () => button("核实远端结果").click()); await settle();
    await act(async () => button("确认只读核实").click()); await settle();
    expect(host.textContent).toContain("无法读取远端审查记录或核实结果");
    expect(button("删除本地记录")).toBeUndefined();
  });

  it("keeps disabled demo state inert", async () => { render({ enabled: false, disabled: true }); await settle(); expect(gateway.listRemoteReviewRecords).not.toHaveBeenCalled(); expect(host.textContent).toContain("当前环境不可用"); });
});
