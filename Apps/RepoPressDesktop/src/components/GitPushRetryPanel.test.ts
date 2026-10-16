import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { GitPushRetryPlan } from "../contracts/gitPushRetry";
import type { RepositoryGateway } from "../contracts/repository";
import { GitPushRetryPanel } from "./GitPushRetryPanel";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
const plan: GitPushRetryPlan = {
  planId: "plan-1", branch: "main", head: "a".repeat(40), remote: "origin", remoteUrl: "https://github.com/example/repo.git", observedRemoteSha: "b".repeat(40), pendingCommitCount: 2, changedPaths: ["content/a.md", "content/b.md"], summary: "review", expiresAt: "2030-01-01T00:00:00Z", warnings: ["精确确认"],
};
let root: Root | null = null;
let host: HTMLDivElement;

function render(gateway: RepositoryGateway, enabled = true, sessionId = "session-1", onCompleted?: () => Promise<void> | void, disabled = false) {
  if (!root) { host = document.createElement("div"); document.body.append(host); root = createRoot(host); }
  act(() => root!.render(createElement(GitPushRetryPanel, { gateway, sessionId, enabled, onCompleted, disabled })));
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
async function click(label: string) {
  const button = [...host.querySelectorAll("button")].find((item) => item.textContent === label);
  expect(button).toBeTruthy();
  await act(async () => { button!.click(); });
}
afterEach(() => { if (root) act(() => root!.unmount()); root = null; host?.remove(); });

describe("GitPushRetryPanel", () => {
  it("does not inspect when push is unavailable", async () => {
    const gateway = { planGitPushRetry: vi.fn() } as unknown as RepositoryGateway;
    render(gateway, false); await click("检查可重试提交");
    expect(gateway.planGitPushRetry).not.toHaveBeenCalled();
  });

  it("reviews the bound remote snapshot and only executes after explicit confirmation", async () => {
    const gateway = {
      planGitPushRetry: vi.fn().mockResolvedValue(plan),
      executeGitPushRetry: vi.fn().mockResolvedValue({ branch: "main", head: plan.head, remoteSha: plan.head, verified: true, summary: "verified" }),
    } as unknown as RepositoryGateway;
    render(gateway); await click("检查可重试提交");
    expect(gateway.planGitPushRetry).toHaveBeenCalledWith("session-1");
    expect(host.textContent).toContain("content/a.md");
    expect(gateway.executeGitPushRetry).not.toHaveBeenCalled();
    await click("确认重试推送");
    expect(gateway.executeGitPushRetry).toHaveBeenCalledWith("session-1", "plan-1");
    expect(host.textContent).toContain("精确指向");
  });

  it("does not treat an unverified or wrong-SHA response as success", async () => {
    const gateway = {
      planGitPushRetry: vi.fn().mockResolvedValue(plan),
      executeGitPushRetry: vi.fn().mockResolvedValue({ branch: "main", head: plan.head, remoteSha: "c".repeat(40), verified: true, summary: "wrong SHA" }),
    } as unknown as RepositoryGateway;
    render(gateway); await click("检查可重试提交"); await click("确认重试推送");
    expect(host.querySelector('[role="alert"]')?.textContent).toContain("未确认");
  });

  it("drops a late inspection after the session changes and ignores a double click", async () => {
    const pending = deferred<GitPushRetryPlan>();
    const gateway = { planGitPushRetry: vi.fn().mockReturnValue(pending.promise) } as unknown as RepositoryGateway;
    render(gateway);
    const button = [...host.querySelectorAll("button")].find((item) => item.textContent === "检查可重试提交")!;
    act(() => { button.click(); button.click(); });
    expect(gateway.planGitPushRetry).toHaveBeenCalledTimes(1);
    render(gateway, true, "session-2");
    await act(async () => { pending.resolve(plan); });
    expect(host.textContent).not.toContain("推送重试计划");
  });

  it("drops a late execution when permission closes", async () => {
    const pending = deferred<{ branch: string; head: string; remoteSha: string; verified: boolean; summary: string }>();
    const gateway = {
      planGitPushRetry: vi.fn().mockResolvedValue(plan),
      executeGitPushRetry: vi.fn().mockReturnValue(pending.promise),
    } as unknown as RepositoryGateway;
    render(gateway); await click("检查可重试提交"); await click("确认重试推送");
    render(gateway, false);
    await act(async () => { pending.resolve({ branch: "main", head: plan.head, remoteSha: plan.head, verified: true, summary: "verified" }); });
    expect(host.textContent).not.toContain("精确指向");
  });

  it("keeps an exactly verified push successful when the local refresh fails", async () => {
    const gateway = {
      planGitPushRetry: vi.fn().mockResolvedValue(plan),
      executeGitPushRetry: vi.fn().mockResolvedValue({ branch: "main", head: plan.head, remoteSha: plan.head, verified: true, summary: "verified" }),
    } as unknown as RepositoryGateway;
    render(gateway, true, "session-1", async () => { throw new Error("refresh unavailable"); });
    await click("检查可重试提交"); await click("确认重试推送");
    expect(host.textContent).toContain("已确认远端");
    expect(host.textContent).toContain("刷新失败");
    expect(host.querySelector('[role="alert"]')).toBeNull();
  });
});
