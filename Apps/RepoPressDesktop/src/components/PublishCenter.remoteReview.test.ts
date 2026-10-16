import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PublishCenter } from "./PublishCenter";
import { createRepositoryGateway } from "../platform/repositoryGateway";
import type { CapabilitySnapshot, RemoteReviewPlan, RepositorySessionSnapshot } from "../contracts/repository";

const repository: RepositorySessionSnapshot = { sessionId: "session", rootPath: "/repo", displayName: "repo", siteKind: "generic", contentRoot: null, isGitRepository: true, warnings: [] };
const capabilities = { localEdit: true, remoteAuth: true, gitStatus: true } as CapabilitySnapshot;
const plan: RemoteReviewPlan = { planId: "creation-plan", provider: "github", host: "github.com", title: "Review title", baseBranch: "main", headBranch: "feature", summary: "Create review", expiresAt: new Date(Date.now() + 60_000).toISOString(), warnings: ["说明中会包含关联标记"], sourceSha: "a".repeat(40), requestMarker: "marker-id", bodyPreview: "Frozen body\n\n<!-- repopress-review-plan:marker-id -->" };
let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
let call = vi.fn<(command: string, args?: object) => Promise<unknown>>();
const button = (label: string) => [...host.querySelectorAll("button")].find((value) => value.textContent === label)!;
async function fillTitle() {
  const input = [...host.querySelectorAll("label")].find((value) => value.textContent === "标题")!.querySelector("input")!;
  await act(async () => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "Review title");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}
describe("PublishCenter PR/MR durable records integration", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(async () => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    call = vi.fn(async (command: string) => {
      if (command === "credential_status") return { credentials: [], storage: "session_only", warning: null };
      if (command === "git_status") return { available: true, branch: "feature", changedFiles: [], remotes: [], ahead: 0, behind: 0 };
      if (command === "list_publish_records" || command === "list_remote_review_records") return [];
      if (command === "plan_remote_review") return plan;
      return { ready: false, configured: false, summary: "" };
    });
    const gateway = createRepositoryGateway(async <T>(name: string, args?: object) => await call(name, args) as T);
    await act(async () => { root.render(createElement(PublishCenter, { open: true, onClose: vi.fn(), repository, capabilities, gateway, currentDocument: null })); });
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); });

  it("shows the actual frozen body, SHA and marker without creating remotely", async () => {
    await fillTitle();
    await act(async () => button("生成 PR/MR 计划").click());
    expect(host.textContent).toContain(plan.bodyPreview);
    expect(host.textContent).toContain(plan.sourceSha);
    expect(host.textContent).toContain("marker-id");
    expect(call.mock.calls.filter(([name]) => name === "execute_remote_review")).toHaveLength(0);
    expect(host.querySelector('[aria-label="远端审查记录"]')).not.toBeNull();
  });

  it("consumes creation confirmation before awaiting and refreshes records on an uncertain result", async () => {
    const execute = vi.fn(() => Promise.reject({ code: "remote_review_outcome_unknown", message: "private raw payload" }));
    const original = call.getMockImplementation()!;
    call.mockImplementation((name: string) => name === "execute_remote_review" ? execute() : original(name));
    await fillTitle(); await act(async () => button("生成 PR/MR 计划").click());
    const before = call.mock.calls.filter(([name]) => name === "list_remote_review_records").length;
    await act(async () => { const confirm = button("确认创建"); confirm.click(); confirm.click(); });
    expect(execute).toHaveBeenCalledTimes(1);
    expect(button("确认创建")).toBeUndefined();
    expect(host.textContent).toContain("避免重复创建");
    expect(host.textContent).not.toContain("private raw payload");
    expect(call.mock.calls.filter(([name]) => name === "list_remote_review_records").length).toBeGreaterThan(before);
  });
});
