import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { PublishRecord } from "../contracts/publishLedger";
import type { RepositoryGateway } from "../contracts/repository";
import { PublishRecordsPanel } from "./PublishRecordsPanel";

const evidence = { repositoryPath: "/repo", repositoryIdentity: "repo-id", operation: "push" as const, remote: "origin", remoteUrl: "https://example.test/repo.git", branch: "main", expectedSha: "abc123", observedBeforeSha: "old", changedPaths: ["article.md"] };
const record = (overrides: Partial<PublishRecord> = {}): PublishRecord => ({ recordId: "record-1", revision: 1, evidence, outcome: "unconfirmed", observedRemoteSha: null, startedAtEpochMs: 1_000, checkedAtEpochMs: null, ...overrides });

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
type TestGateway = Pick<RepositoryGateway, "listPublishRecords" | "planPublishVerification" | "executePublishVerification" | "removePublishRecord">;
let gateway: TestGateway & { listPublishRecords: ReturnType<typeof vi.fn>; planPublishVerification: ReturnType<typeof vi.fn>; executePublishVerification: ReturnType<typeof vi.fn> };
let currentRecords: PublishRecord[];

function render(props: Partial<React.ComponentProps<typeof PublishRecordsPanel>> = {}) {
  root.render(createElement(PublishRecordsPanel, { gateway: gateway as TestGateway, sessionId: "session", enabled: true, ...props }));
}
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement; }

describe("PublishRecordsPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    currentRecords = [record()];
    gateway = {
      listPublishRecords: vi.fn(async (_sessionId: string): Promise<PublishRecord[]> => currentRecords),
      planPublishVerification: vi.fn(async (_sessionId: string, _recordId: string) => ({ planId: "plan-1", recordId: "record-1", remoteUrl: evidence.remoteUrl, branch: evidence.branch, expectedSha: evidence.expectedSha, expiresAt: new Date(Date.now() + 10_000).toISOString() })),
      executePublishVerification: vi.fn(async (_sessionId: string, _planId: string) => record({ outcome: "verified", observedRemoteSha: evidence.expectedSha, checkedAtEpochMs: Date.now() })),
      removePublishRecord: vi.fn(async (_sessionId: string, _recordId: string, _revision: number) => []),
    };
  });
  afterEach(() => { root.unmount(); host.remove(); vi.useRealTimers(); });

  it("lists records newest first and makes no verification call before confirmation", async () => {
    currentRecords = [record({ recordId: "new", revision: 2, evidence: { ...evidence, branch: "new" } }), record({ recordId: "old", revision: 1, evidence: { ...evidence, branch: "old" } })];
    render(); await settle();
    expect(gateway.listPublishRecords).toHaveBeenCalledWith("session");
    expect([...host.querySelectorAll("article")][0].textContent).toContain("new");
    expect(gateway.planPublishVerification).not.toHaveBeenCalled();
    expect(gateway.executePublishVerification).not.toHaveBeenCalled();
  });

  it("shows a review plan and updates verified, different, and unknown outcomes", async () => {
    render(); await settle(); await act(async () => button("核实远端结果").click()); await settle();
    expect(host.textContent).toContain("预期 SHA"); expect(host.textContent).toContain("确认只读核实");
    await act(async () => button("确认只读核实").click()); await settle();
    expect(gateway.executePublishVerification).toHaveBeenCalledWith("session", "plan-1");
    expect(host.textContent).toContain("已核实");
    currentRecords = [record({ outcome: "different", observedRemoteSha: "other" }), record({ outcome: "unconfirmed", observedRemoteSha: null })];
    render({ refreshKey: 1 }); await settle();
    expect(host.textContent).toContain("远端不同"); expect(host.textContent).toContain("未知");
    expect(host.textContent).toContain("不证明之前推送失败");
  });

  it("rejects stale session results and invalidates plans on refresh", async () => {
    let resolveList!: (value: PublishRecord[]) => void;
    gateway.listPublishRecords.mockImplementationOnce(() => new Promise((resolve) => { resolveList = resolve; }));
    render(); await settle(); render({ sessionId: "new-session" }); await settle();
    resolveList([record({ recordId: "stale" })]); await settle();
    expect(host.textContent).not.toContain("stale");

    await act(async () => button("核实远端结果").click()); await settle();
    expect(host.textContent).toContain("确认只读核实");
    currentRecords = [record({ recordId: "fresh" })];
    render({ sessionId: "new-session", refreshKey: 2 }); await settle();
    expect(host.textContent).not.toContain("确认只读核实");
  });

  it("guards duplicate clicks and expired plans", async () => {
    let resolvePlan!: (value: unknown) => void;
    gateway.planPublishVerification.mockImplementationOnce(() => new Promise((resolve) => { resolvePlan = resolve; }));
    render(); await settle();
    await act(async () => { button("核实远端结果").click(); button("核实远端结果").click(); });
    expect(gateway.planPublishVerification).toHaveBeenCalledTimes(1);
    resolvePlan({ planId: "plan-1", recordId: "record-1", remoteUrl: evidence.remoteUrl, branch: evidence.branch, expectedSha: evidence.expectedSha, expiresAt: "not-a-date" }); await settle();
    expect(host.textContent).toContain("已过期");
    expect(gateway.executePublishVerification).not.toHaveBeenCalled();
  });

  it("consumes a plan before a failed execute so it cannot be replayed", async () => {
    gateway.executePublishVerification.mockRejectedValueOnce(new Error("remote unavailable"));
    render(); await settle(); await act(async () => button("核实远端结果").click()); await settle();
    await act(async () => button("确认只读核实").click()); await settle();
    expect(gateway.executePublishVerification).toHaveBeenCalledTimes(1);
    expect(host.textContent).not.toContain("确认只读核实");
    expect(host.textContent).toContain("无法读取发布记录或核实结果");
  });

  it("does not let an old plan request finally clear busy for a newer session", async () => {
    let resolveOld!: (value: unknown) => void;
    let resolveNew!: (value: unknown) => void;
    gateway.planPublishVerification
      .mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve; }))
      .mockImplementationOnce(() => new Promise((resolve) => { resolveNew = resolve; }));
    render({ sessionId: "old-session" }); await settle();
    await act(async () => button("核实远端结果").click());
    render({ sessionId: "new-session" }); await settle();
    await act(async () => button("核实远端结果").click());
    resolveOld({ planId: "old", recordId: "record-1", remoteUrl: evidence.remoteUrl, branch: evidence.branch, expectedSha: evidence.expectedSha, expiresAt: new Date(Date.now() + 10_000).toISOString() }); await settle();
    expect(button("核实远端结果").disabled).toBe(true);
    resolveNew({ planId: "new", recordId: "record-1", remoteUrl: evidence.remoteUrl, branch: evidence.branch, expectedSha: evidence.expectedSha, expiresAt: new Date(Date.now() + 10_000).toISOString() }); await settle();
    expect(button("核实远端结果").disabled).toBe(false);
  });

  it("does not accept mismatched verification evidence and has no raw error payload", async () => {
    gateway.executePublishVerification.mockResolvedValueOnce(record({ recordId: "other" }));
    render(); await settle(); await act(async () => button("核实远端结果").click()); await settle(); await act(async () => button("确认只读核实").click()); await settle();
    expect(host.textContent).toContain("无法读取发布记录或核实结果");
    expect(host.textContent).not.toContain("other");
  });

  it("makes disabled demo state inert", async () => {
    render({ enabled: false, disabled: true }); await settle();
    expect(gateway.listPublishRecords).not.toHaveBeenCalled();
    expect(host.textContent).toContain("当前环境不可用");
  });

  it("only offers explicit local deletion for inspected records and honors confirmation", async () => {
    currentRecords = [record({ outcome: "verified", observedRemoteSha: evidence.expectedSha, checkedAtEpochMs: 2_000 }), record({ recordId: "unknown", outcome: "unconfirmed" })];
    render(); await settle();
    expect(host.querySelectorAll("button")).toHaveLength(4);
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    await act(async () => button("删除本地记录").click());
    expect(gateway.removePublishRecord).not.toHaveBeenCalled();
    confirm.mockReturnValue(true);
    await act(async () => button("删除本地记录").click()); await settle();
    expect(confirm.mock.calls[1][0]).toContain("分支：main");
    expect(confirm.mock.calls[1][0]).toContain("冻结 SHA：abc123");
    expect(confirm.mock.calls[1][0]).toContain("远端内容不会更改");
    expect(gateway.removePublishRecord).toHaveBeenCalledWith("session", "record-1", 1);
    expect(host.textContent).not.toContain("推送 · 已核实");
    confirm.mockRestore();
  });
});
