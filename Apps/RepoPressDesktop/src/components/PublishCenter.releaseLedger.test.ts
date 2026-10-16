import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PublishCenter } from "./PublishCenter";
import { createRepositoryGateway } from "../platform/repositoryGateway";
import type { CapabilitySnapshot, RepositorySessionSnapshot } from "../contracts/repository";
import type { PublishRecord, PublishVerificationPlan } from "../contracts/publishLedger";
import type { ReleaseLedgerSnapshot } from "../contracts/releaseLedger";

const capabilities = {
  localEdit: true, remoteAuth: true, gitStatus: true, gitCommit: true, gitFetch: true, gitPush: true,
  contentHealth: false, gitIndex: false,
} as CapabilitySnapshot;
const repository = (sessionId: string): RepositorySessionSnapshot => ({ sessionId, rootPath: `/repo/${sessionId}`, displayName: sessionId, siteKind: "generic", contentRoot: null, isGitRepository: true, warnings: [] });
const emptyLedger = (sessionId: string): ReleaseLedgerSnapshot => ({ sessionId, entries: [], partialSources: [], warnings: [], summary: { total: 0, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 0 } });
const entry = {
  source: "gitPush" as const, recordId: "push-1", revision: 1, operation: "push" as const, branch: "main", targetBranch: null,
  expectedSha: "a".repeat(40), remoteUrl: "https://example.test/repo.git", startedAtEpochMs: 1_700_000_000_000, checkedAtEpochMs: null, status: "unconfirmed" as const,
};
const ledgerWithEntry = (sessionId: string): ReleaseLedgerSnapshot => ({ sessionId, entries: [entry], partialSources: [], warnings: [], summary: { total: 1, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 1 } });
const publishRecord: PublishRecord = {
  recordId: "push-1", revision: 1,
  evidence: { repositoryPath: "/repo", repositoryIdentity: "repo-id", operation: "push", remote: "origin", remoteUrl: entry.remoteUrl, branch: entry.branch, expectedSha: entry.expectedSha, observedBeforeSha: null, changedPaths: [] },
  outcome: "unconfirmed", observedRemoteSha: null, startedAtEpochMs: entry.startedAtEpochMs, checkedAtEpochMs: null,
};
const verificationPlan: PublishVerificationPlan = { planId: "verify-1", recordId: "push-1", remoteUrl: entry.remoteUrl, branch: entry.branch, expectedSha: entry.expectedSha, expiresAt: new Date(Date.now() + 60_000).toISOString() };
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
type CommandArgs = { sessionId?: string; recordId?: string; planId?: string };
type CommandCall = (name: string, args?: CommandArgs) => Promise<unknown>;
let call: ReturnType<typeof vi.fn<CommandCall>>;
let gateway: ReturnType<typeof createRepositoryGateway>;
const calls = (name: string) => call.mock.calls.filter(([command]) => command === name);
const settle = async () => act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });

function render(sessionId = "session-1", open = true) {
  act(() => root.render(createElement(PublishCenter, { open, onClose: vi.fn(), repository: repository(sessionId), capabilities, gateway, currentDocument: null })));
}

describe("PublishCenter release ledger integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    call = vi.fn<CommandCall>(async (name: string, args?: CommandArgs) => {
      if (name === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (name === "browser_protocol_status" || name === "update_readiness") return { ready: false, configured: false, summary: "" };
      if (name === "git_status") return { available: true, branch: "main", changedFiles: [], remotes: [], ahead: 0, behind: 0 };
      if (name === "get_release_ledger") return emptyLedger(args?.sessionId ?? "session-1");
      if (name === "list_publish_records") return [];
      if (name === "list_remote_review_records") return [];
      throw new Error(`unexpected command ${name}`);
    });
    gateway = createRepositoryGateway(async <T>(name: string, args?: object) => await call(name, args as { sessionId?: string }) as T);
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); });

  it("opens with the local projection and never checks deployment or executes operations", async () => {
    call.mockImplementation(async (name: string, args?: { sessionId?: string }) => {
      if (name === "get_release_ledger") return ledgerWithEntry(args?.sessionId ?? "session-1");
      if (name === "list_publish_records") return [publishRecord];
      if (name === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (name === "browser_protocol_status" || name === "update_readiness") return { ready: false, configured: false, summary: "" };
      if (name === "git_status" || name === "list_remote_review_records") return name === "git_status" ? { available: true, branch: "main", changedFiles: [], remotes: [], ahead: 0, behind: 0 } : [];
      throw new Error(`unexpected command ${name}`);
    });
    render(); await settle();
    expect(host.textContent).toContain("发布台账与手动恢复");
    expect(host.textContent).toContain("当前可见台账摘要：共 1 条");
    expect(calls("check_deployment")).toHaveLength(0);
    expect(calls("execute_git_operation")).toHaveLength(0);
    expect(calls("execute_remote_review")).toHaveLength(0);
    expect(calls("execute_publish_verification")).toHaveLength(0);
  });

  it("shows a manually queried deployment only as an unattributed observation", async () => {
    render(); await settle();
    call.mockImplementation(async (name: string, args?: { sessionId?: string }) => {
      if (name === "check_deployment") return { configured: true, provider: "pages", status: "ready", url: "https://site.test", summary: "部署已就绪", checkedAt: "2026-10-02T00:00:00Z", warning: null };
      if (name === "get_release_ledger") return ledgerWithEntry(args?.sessionId ?? "session-1");
      if (name === "list_publish_records") return [publishRecord];
      if (name === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (name === "browser_protocol_status" || name === "update_readiness") return { ready: false, configured: false, summary: "" };
      if (name === "git_status" || name === "list_remote_review_records") return name === "git_status" ? { available: true, branch: "main", changedFiles: [], remotes: [], ahead: 0, behind: 0 } : [];
      throw new Error(`unexpected command ${name}`);
    });
    await act(async () => [...host.querySelectorAll("button")].find((button) => button.textContent === "检查部署状态")!.click()); await settle();
    expect(host.textContent).toContain("该观察未关联冻结提交，不计入已部署或成功统计");
    expect(host.textContent).toContain("部署已就绪");
    expect(host.textContent).toContain("推送 · 未核实");
  });

  it("focuses the source wrapper when the ledger asks to open a record source", async () => {
    call.mockImplementation(async (name: string, args?: { sessionId?: string }) => {
      if (name === "get_release_ledger") return ledgerWithEntry(args?.sessionId ?? "session-1");
      if (name === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (name === "browser_protocol_status" || name === "update_readiness") return { ready: false, configured: false, summary: "" };
      if (name === "git_status") return { available: true, branch: "main", changedFiles: [], remotes: [], ahead: 0, behind: 0 };
      if (name === "list_publish_records") return [];
      if (name === "list_remote_review_records") return [];
      throw new Error(`unexpected command ${name}`);
    });
    render(); await settle();
    const target = host.querySelector('[aria-label="推送记录入口"]') as HTMLDivElement;
    target.scrollIntoView = vi.fn(); target.focus = vi.fn();
    const sourceButton = [...host.querySelectorAll("button")].find((button) => button.textContent === "查看推送记录")!;
    await act(async () => sourceButton.click());
    expect(target.scrollIntoView).toHaveBeenCalledWith({ block: "start", behavior: "smooth" });
    expect(target.focus).toHaveBeenCalledWith({ preventScroll: true });
  });

  it("re-reads the unified ledger after an uncertain source verification", async () => {
    let ledgerReads = 0;
    call.mockImplementation(async (name: string, args?: { sessionId?: string; recordId?: string; planId?: string }) => {
      if (name === "get_release_ledger") { ledgerReads += 1; return ledgerWithEntry(args?.sessionId ?? "session-1"); }
      if (name === "list_publish_records") return [publishRecord];
      if (name === "plan_publish_verification") return verificationPlan;
      if (name === "execute_publish_verification") throw new Error("outcome unknown");
      if (name === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (name === "browser_protocol_status" || name === "update_readiness") return { ready: false, configured: false, summary: "" };
      if (name === "git_status" || name === "list_remote_review_records") return name === "git_status" ? { available: true, branch: "main", changedFiles: [], remotes: [], ahead: 0, behind: 0 } : [];
      throw new Error(`unexpected command ${name}`);
    });
    render(); await settle();
    const before = ledgerReads;
    await act(async () => [...host.querySelectorAll("button")].find((button) => button.textContent === "核实远端结果")!.click()); await settle();
    await act(async () => [...host.querySelectorAll("button")].find((button) => button.textContent === "确认只读核实")!.click()); await settle();
    expect(ledgerReads).toBeGreaterThan(before);
  });

  it("ignores a late ledger response from a closed or replaced session", async () => {
    let resolveOld!: (snapshot: ReleaseLedgerSnapshot) => void;
    const oldResult = new Promise<ReleaseLedgerSnapshot>((resolve) => { resolveOld = resolve; });
    call.mockImplementation(async (name: string, args?: { sessionId?: string }) => {
      if (name === "get_release_ledger") return args?.sessionId === "old" ? oldResult : { ...emptyLedger("new"), warnings: ["new-session"] };
      if (name === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (name === "browser_protocol_status" || name === "update_readiness") return { ready: false, configured: false, summary: "" };
      if (name === "git_status") return { available: true, branch: "main", changedFiles: [], remotes: [], ahead: 0, behind: 0 };
      if (name === "list_publish_records" || name === "list_remote_review_records") return [];
      throw new Error(`unexpected command ${name}`);
    });
    render("old");
    render("new"); await settle();
    resolveOld({ ...ledgerWithEntry("old"), warnings: ["old-session"] }); await settle();
    expect(host.textContent).toContain("new-session");
    expect(host.textContent).not.toContain("old-session");
    render("old", false);
    resolveOld({ ...ledgerWithEntry("old"), warnings: ["late-closed"] }); await settle();
    expect(host.textContent).not.toContain("late-closed");
  });
});
