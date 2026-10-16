import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReleaseLedgerGateway, ReleaseLedgerSnapshot } from "../contracts/releaseLedger";
import { ReleaseLedgerPanel } from "./ReleaseLedgerPanel";

const entry = (overrides: Partial<ReleaseLedgerSnapshot["entries"][number]> = {}) => ({ source: "gitPush" as const, recordId: "push-1", revision: 1, operation: "push" as const, branch: "main", targetBranch: null, expectedSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", remoteUrl: "https://secret.example/repo.git", startedAtEpochMs: 1_000, checkedAtEpochMs: 2_000, status: "pushVerified" as const, ...overrides });
const snapshot = (overrides: Partial<ReleaseLedgerSnapshot> = {}): ReleaseLedgerSnapshot => ({ sessionId: "session", entries: [entry()], partialSources: [], warnings: [], summary: { total: 1, verifiedPushes: 1, verifiedReviews: 0, needsAttention: 0 }, ...overrides });

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let gateway: ReleaseLedgerGateway & { getReleaseLedger: ReturnType<typeof vi.fn> };
function render(props: Partial<React.ComponentProps<typeof ReleaseLedgerPanel>> = {}) { root.render(createElement(ReleaseLedgerPanel, { gateway, sessionId: "session", enabled: true, ...props })); }
async function settle() { await act(async () => { await Promise.resolve(); }); }
function button(label: string) { return [...host.querySelectorAll("button")].find((item) => item.textContent === label) as HTMLButtonElement; }

describe("ReleaseLedgerPanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); gateway = { getReleaseLedger: vi.fn(async () => snapshot()) }; });
  afterEach(() => { root.unmount(); host.remove(); });

  it("only reads locally on open and exposes safe source navigation", async () => {
    const onOpenSource = vi.fn();
    render({ onOpenSource }); await settle();
    expect(gateway.getReleaseLedger).toHaveBeenCalledWith("session");
    expect(host.textContent).toContain("推送已核实（不代表合并或部署）");
    expect(host.textContent).not.toContain("https://secret.example");
    await act(async () => button("查看推送记录").click());
    expect(onOpenSource).toHaveBeenCalledWith("gitPush");
  });

  it("warns for partial sources and does not claim an empty partial ledger is complete", async () => {
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot({ entries: [], partialSources: ["remoteReview"], summary: { total: 0, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 0 } }));
    render(); await settle();
    expect(host.textContent).toContain("部分来源未能读取");
    expect(host.textContent).toContain("不能据此判断全部无记录");
  });

  it("rejects invalid responses and keeps errors generic", async () => {
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot({ sessionId: "other" }));
    render(); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
    expect(host.textContent).not.toContain("other");
  });

  it("rejects forged summaries and partial sources that contain records", async () => {
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot({ summary: { total: 9, verifiedPushes: 1, verifiedReviews: 0, needsAttention: 0 } }));
    render(); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
    await act(async () => { render({ refreshKey: 1 }); }); await settle();
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot({ partialSources: ["gitPush"], summary: { total: 1, verifiedPushes: 1, verifiedReviews: 0, needsAttention: 0 } }));
    await act(async () => { render({ refreshKey: 2 }); }); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
  });

  it("rejects cross-source status and operation combinations", async () => {
    const review = entry({ source: "remoteReview", operation: "push", targetBranch: "main", status: "pushVerified" });
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot({ entries: [review], summary: { total: 1, verifiedPushes: 1, verifiedReviews: 0, needsAttention: 0 } }));
    render(); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
    await act(async () => { render({ refreshKey: 1 }); }); await settle();
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot({ entries: [entry({ status: "pushVerified", checkedAtEpochMs: null })], summary: { total: 1, verifiedPushes: 1, verifiedReviews: 0, needsAttention: 0 } }));
    await act(async () => { render({ refreshKey: 2 }); }); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
  });

  it("rejects repeated partial sources", async () => {
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot({ entries: [], partialSources: ["gitPush", "gitPush"], summary: { total: 0, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 0 } }));
    render(); await settle();
    expect(host.textContent).toContain("无法读取发布台账");
  });

  it("hides loaded content immediately when session or refresh context changes", async () => {
    render(); await settle();
    expect(host.textContent).toContain("push-1");
    await act(async () => { render({ sessionId: "new-session" }); });
    expect(host.textContent).not.toContain("push-1");
    await settle();
    gateway.getReleaseLedger.mockImplementationOnce(() => new Promise(() => undefined));
    await act(async () => { render({ sessionId: "session", refreshKey: 9 }); });
    expect(host.textContent).not.toContain("push-1");
  });

  it("guards refresh concurrency and ignores stale session results", async () => {
    let resolveOld!: (value: ReleaseLedgerSnapshot) => void;
    let resolveNew!: (value: ReleaseLedgerSnapshot) => void;
    gateway.getReleaseLedger.mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve; }));
    gateway.getReleaseLedger.mockImplementationOnce(() => new Promise((resolve) => { resolveNew = resolve; }));
    render({ sessionId: "old" }); await settle();
    render({ sessionId: "new" }); await settle();
    expect(gateway.getReleaseLedger).toHaveBeenCalledTimes(2);
    resolveOld(snapshot({ sessionId: "old", entries: [entry({ recordId: "stale" })] })); await settle();
    expect(host.textContent).not.toContain("stale");
    resolveNew(snapshot({ sessionId: "new", entries: [entry({ recordId: "fresh" })] })); await settle();
    expect(host.textContent).toContain("fresh");
    gateway.getReleaseLedger.mockClear();
    await act(async () => { button("刷新台账").click(); button("刷新台账").click(); });
    expect(gateway.getReleaseLedger).toHaveBeenCalledTimes(1);
  });

  it("does not read in disabled browser state and handles deployment as unattributed", async () => {
    await act(async () => { render({ enabled: false, disabled: true, deployment: { sessionId: "session", snapshot: { configured: true, provider: "ci", status: "success", url: null, summary: "部署完成", checkedAt: null, warning: null } } }); }); await settle();
    expect(gateway.getReleaseLedger).not.toHaveBeenCalled();
    expect(host.textContent).toContain("当前环境不可用");
    expect(host.textContent).not.toContain("部署完成");
    await act(async () => { render({ deployment: { sessionId: "session", snapshot: { configured: true, provider: "ci", status: "success", url: null, summary: "部署完成", checkedAt: "2026-10-02T11:00:00Z", warning: null } } }); }); await settle();
    expect(host.textContent).toContain("未关联冻结提交");
    expect(host.textContent).toContain("不计入已部署或成功统计");
  });

  it("cleans up on unmount and supports bounded pagination", async () => {
    const entries = Array.from({ length: 51 }, (_, index) => entry({ recordId: `id-${index}` }));
    gateway.getReleaseLedger.mockResolvedValueOnce(snapshot({ entries, summary: { total: 51, verifiedPushes: 51, verifiedReviews: 0, needsAttention: 0 } }));
    render(); await settle();
    expect(host.querySelectorAll("article")).toHaveLength(50);
    await act(async () => button("下一页").click());
    expect(host.querySelectorAll("article")).toHaveLength(1);
    root.unmount();
  });
});
