import { act, createElement, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { GitPushRetryPlan } from "../contracts/gitPushRetry";
import type { PublishRecord, PublishVerificationPlan } from "../contracts/publishLedger";
import type { RemoteReviewRecord, RemoteReviewRecordsGateway, RemoteReviewVerificationPlan } from "../contracts/remoteReviewLedger";
import type { RepositoryGateway } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { GitPushRetryPanel } from "./GitPushRetryPanel";
import { PublishRecordsPanel } from "./PublishRecordsPanel";
import { RemoteReviewRecordsPanel } from "./RemoteReviewRecordsPanel";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

let host: HTMLDivElement;
let root: Root;

beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  host.remove();
  vi.useRealTimers();
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

function render(locale: "zh-CN" | "en-US", child: ReactElement) {
  act(() => root.render(createElement(I18nProvider, { locale, children: child })));
}

async function settle() {
  await act(async () => { await Promise.resolve(); });
}

function button(label: string): HTMLButtonElement {
  const found = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label);
  if (!found) throw new Error(`Missing button: ${label}`);
  return found;
}

const publishEvidence = {
  repositoryPath: "/repo/发布结果记录",
  repositoryIdentity: "repo-id",
  operation: "push" as const,
  remote: "origin",
  remoteUrl: "远端",
  branch: "推送",
  expectedSha: "未知",
  observedBeforeSha: "old",
  changedPaths: ["刷新记录"],
};
const publishRecord: PublishRecord = {
  recordId: "publish-record",
  revision: 1,
  evidence: publishEvidence,
  outcome: "unconfirmed",
  observedRemoteSha: null,
  startedAtEpochMs: 1_000,
  checkedAtEpochMs: null,
};

const reviewEvidence = {
  repositoryPath: "/repo/远端审查记录",
  repositoryIdentity: "repo-id",
  remote: "origin",
  remoteUrl: "远端",
  provider: "github" as const,
  owner: "所有者 / 项目",
  project: "目标",
  remoteProjectId: 42,
  sourceBranch: "来源 → 目标",
  targetBranch: "分支",
  sourceSha: "冻结 SHA",
  titleSha256: "title",
  bodySha256: "body",
  marker: "请求关联标记",
};
const reviewRecord: RemoteReviewRecord = {
  recordId: "review-record",
  revision: 1,
  evidence: reviewEvidence,
  outcome: "unconfirmed",
  verification: "notChecked",
  reviewNumber: null,
  webUrl: null,
  startedAtEpochMs: 1_000,
  checkedAtEpochMs: null,
};

describe("publish and remote record localization", () => {
  it("keeps a pending publish plan request and frozen evidence across locale changes", async () => {
    const recordsRequest = deferred<PublishRecord[]>();
    const planRequest = deferred<PublishVerificationPlan>();
    const gateway = {
      listPublishRecords: vi.fn(() => recordsRequest.promise),
      planPublishVerification: vi.fn(() => planRequest.promise),
      executePublishVerification: vi.fn(),
      removePublishRecord: vi.fn(),
    };
    const view = () => createElement(PublishRecordsPanel, { gateway, sessionId: "session", enabled: true });

    render("zh-CN", view());
    await settle();
    render("en-US", view());
    expect(gateway.listPublishRecords).toHaveBeenCalledTimes(1);
    await act(async () => recordsRequest.resolve([publishRecord]));
    expect(host.querySelector("section")?.getAttribute("aria-label")).toBe("Publish result records");
    expect(host.textContent).toContain("Push · Unverified");
    expect(host.textContent).toContain("推送");
    expect(host.textContent).toContain("远端");
    expect(host.textContent).toContain("未知");
    expect(host.textContent).toContain("刷新记录");

    await act(async () => button("Verify remote result").click());
    render("zh-CN", view());
    render("en-US", view());
    expect(gateway.planPublishVerification).toHaveBeenCalledTimes(1);
    await act(async () => planRequest.resolve({
      planId: "publish-plan",
      recordId: publishRecord.recordId,
      remoteUrl: publishEvidence.remoteUrl,
      branch: publishEvidence.branch,
      expectedSha: publishEvidence.expectedSha,
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
    }));
    expect(host.querySelector("[aria-label='Publish result verification plan']")).not.toBeNull();
    expect(host.textContent).toContain("远端 · 推送");
    expect(gateway.executePublishVerification).not.toHaveBeenCalled();
    expect(gateway.listPublishRecords).toHaveBeenCalledTimes(1);
  });

  it("keeps a remote review plan and literal evidence while translating controls", async () => {
    const planRequest = deferred<RemoteReviewVerificationPlan>();
    const gateway: RemoteReviewRecordsGateway = {
      listRemoteReviewRecords: vi.fn(async () => [reviewRecord]),
      planRemoteReviewVerification: vi.fn(() => planRequest.promise),
      executeRemoteReviewVerification: vi.fn(),
      removeRemoteReviewRecord: vi.fn(),
    };
    const view = () => createElement(RemoteReviewRecordsPanel, { gateway, sessionId: "session", enabled: true });

    render("zh-CN", view());
    await settle();
    await act(async () => button("核实远端结果").click());
    render("en-US", view());
    expect(gateway.listRemoteReviewRecords).toHaveBeenCalledTimes(1);
    expect(gateway.planRemoteReviewVerification).toHaveBeenCalledTimes(1);
    await act(async () => planRequest.resolve({
      planId: "review-plan",
      recordId: reviewRecord.recordId,
      remoteUrl: reviewEvidence.remoteUrl,
      provider: reviewEvidence.provider,
      owner: reviewEvidence.owner,
      project: reviewEvidence.project,
      sourceBranch: reviewEvidence.sourceBranch,
      targetBranch: reviewEvidence.targetBranch,
      sourceSha: reviewEvidence.sourceSha,
      expiresAt: new Date(Date.now() + 60_000).toISOString(),
    }));
    expect(host.querySelector("[aria-label='Remote review verification plan']")).not.toBeNull();
    expect(host.textContent).toContain("Unverified");
    expect(host.textContent).toContain("所有者 / 项目");
    expect(host.textContent).toContain("来源 → 目标");
    expect(host.textContent).toContain("冻结 SHA");
    expect(host.textContent).toContain("请求关联标记");
    expect(gateway.executeRemoteReviewVerification).not.toHaveBeenCalled();

    render("zh-CN", view());
    expect(host.querySelector("[aria-label='远端审查核实计划']")).not.toBeNull();
    expect(gateway.listRemoteReviewRecords).toHaveBeenCalledTimes(1);
  });
});

describe("GitPushRetryPanel localization", () => {
  const retryPlan: GitPushRetryPlan = {
    planId: "retry-plan",
    branch: "推送",
    head: "a".repeat(40),
    remote: "origin",
    remoteUrl: "远端",
    observedRemoteSha: "b".repeat(40),
    pendingCommitCount: 2,
    changedPaths: ["刷新记录"],
    summary: "推送重试计划",
    expiresAt: "2030-01-01T00:00:00Z",
    warnings: ["未知错误"],
  };

  it("preserves pending work and consumes the frozen plan only once across locale changes", async () => {
    const inspectRequest = deferred<GitPushRetryPlan>();
    const executeRequest = deferred<{ branch: string; head: string; remoteSha: string; verified: boolean; summary: string }>();
    const gateway = {
      planGitPushRetry: vi.fn(() => inspectRequest.promise),
      executeGitPushRetry: vi.fn(() => executeRequest.promise),
    } as unknown as RepositoryGateway;
    const view = () => createElement(GitPushRetryPanel, { gateway, sessionId: "session", enabled: true });

    render("zh-CN", view());
    await act(async () => button("检查可重试提交").click());
    render("en-US", view());
    expect(gateway.planGitPushRetry).toHaveBeenCalledTimes(1);
    await act(async () => inspectRequest.resolve(retryPlan));
    expect(host.textContent).toContain("Push retry plan");
    expect(host.textContent).toContain("推送重试计划");
    expect(host.textContent).toContain("未知错误");
    expect(host.textContent).toContain("刷新记录");
    expect(host.textContent).toContain("Plan valid until 2030-01-01T00:00:00Z");

    let confirm = button("Confirm push retry");
    await act(async () => { confirm.click(); confirm.click(); });
    render("zh-CN", view());
    render("en-US", view());
    expect(gateway.executeGitPushRetry).toHaveBeenCalledTimes(1);
    expect(gateway.executeGitPushRetry).toHaveBeenCalledWith("session", "retry-plan");
    await act(async () => executeRequest.resolve({ branch: retryPlan.branch, head: retryPlan.head, remoteSha: retryPlan.head, verified: true, summary: "发布结果记录" }));
    expect(host.textContent).toContain(`Confirmed that remote 推送 points exactly to ${retryPlan.head}.`);
    expect(gateway.planGitPushRetry).toHaveBeenCalledTimes(1);
  });

  it("keeps an unknown catalog-key error literal and lets an expired plan be discarded", async () => {
    const gateway = {
      planGitPushRetry: vi.fn()
        .mockRejectedValueOnce(new Error("推送重试计划"))
        .mockResolvedValueOnce({ ...retryPlan, expiresAt: "invalid" }),
      executeGitPushRetry: vi.fn(),
    } as unknown as RepositoryGateway;
    const view = () => createElement(GitPushRetryPanel, { gateway, sessionId: "session", enabled: true });

    render("en-US", view());
    await act(async () => button("Check retryable commits").click());
    expect(host.querySelector("[role='alert']")?.textContent).toBe("Unable to generate a push retry plan: 推送重试计划");
    await act(async () => button("Check retryable commits").click());
    expect(host.textContent).toContain("This retry plan expired. Check the remote again.");
    expect(button("Confirm push retry").disabled).toBe(true);
    await act(async () => button("Discard plan").click());
    expect(host.textContent).not.toContain("This retry plan expired");
    expect(gateway.executeGitPushRetry).not.toHaveBeenCalled();
  });

  it("translates the controlled frozen-plan mismatch without translating response fields", async () => {
    const unexpectedSha = "远端不同";
    const gateway = {
      planGitPushRetry: vi.fn(async () => retryPlan),
      executeGitPushRetry: vi.fn(async () => ({ branch: retryPlan.branch, head: retryPlan.head, remoteSha: unexpectedSha, verified: true, summary: "已核实" })),
    } as unknown as RepositoryGateway;
    render("en-US", createElement(GitPushRetryPanel, { gateway, sessionId: "session", enabled: true }));
    await act(async () => button("Check retryable commits").click());
    await act(async () => button("Confirm push retry").click());
    expect(host.querySelector("[role='alert']")?.textContent)
      .toBe("The push result was not confirmed: The remote result was not confirmed exactly as this plan's frozen commit. Check the remote again before deciding what to do next.");
    expect(gateway.executeGitPushRetry).toHaveBeenCalledWith("session", "retry-plan");
  });
});
