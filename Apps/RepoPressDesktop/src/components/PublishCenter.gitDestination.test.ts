import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PublishCenter } from "./PublishCenter";
import { createRepositoryGateway } from "../platform/repositoryGateway";
import type { CapabilitySnapshot, GitOperationPlan, RepositorySessionSnapshot } from "../contracts/repository";

const repository: RepositorySessionSnapshot = { sessionId: "session", rootPath: "/repo", displayName: "repo", siteKind: "generic", contentRoot: null, isGitRepository: true, warnings: [] };
const capabilities = { localEdit: true, gitStatus: true, gitPush: true, gitFetch: true, gitCommit: true } as CapabilitySnapshot;
const destination = "https://github.com/other-owner/private-project.git";
let plan: GitOperationPlan;
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let call = vi.fn<(command: string, args?: object) => Promise<unknown>>();
const button = (label: string) => [...host.querySelectorAll("button")].find((value) => value.textContent === label)!;

describe("Push destination confirmation", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(async () => {
    plan = { planId: "push-plan", operation: "push", branch: "main", head: "a".repeat(40), stagedFiles: [], remote: "origin", remoteUrl: destination, summary: "Push current branch", expiresAt: new Date(Date.now() + 60_000).toISOString(), warnings: [] };
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    call = vi.fn(async (command: string) => {
      if (command === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (command === "git_status") return { available: true, branch: "main", changedFiles: [], remotes: [], ahead: 0, behind: 0 };
      if (command === "list_publish_records" || command === "list_remote_review_records") return [];
      if (command === "plan_git_operation") return plan;
      return { ready: false, configured: false, summary: "" };
    });
    const gateway = createRepositoryGateway(async <T>(name: string, args?: object) => await call(name, args) as T);
    await act(async () => root.render(createElement(PublishCenter, { open: true, onClose: vi.fn(), repository, capabilities, gateway, currentDocument: null })));
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); });

  it("shows the frozen destination as text before any execution", async () => {
    await act(async () => button("生成 Push 计划").click());
    expect(host.textContent).toContain("实际推送地址");
    expect(host.textContent).toContain(destination);
    expect(host.querySelector(`a[href="${destination}"]`)).toBeNull();
    expect(button("确认执行 Push").disabled).toBe(false);
    expect(call.mock.calls.filter(([name]) => name === "execute_git_operation")).toHaveLength(0);
  });
  it("blocks a push confirmation whose destination is absent", async () => {
    plan.remoteUrl = null;
    await act(async () => button("生成 Push 计划").click());
    expect(button("确认执行 Push").disabled).toBe(true);
    expect(host.textContent).toContain("缺少地址");
  });
  it("does not mislabel a push URL as the fetch destination", async () => {
    plan.operation = "fetch";
    await act(async () => button("生成 Fetch 计划").click());
    expect(host.textContent).not.toContain("实际推送地址");
    expect(button("确认执行 Fetch").disabled).toBe(false);
  });
});
