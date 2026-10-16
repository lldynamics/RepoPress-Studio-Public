import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { PublishCenter } from "./PublishCenter";
import { I18nProvider } from "../i18n/i18n";
import { createRepositoryGateway } from "../platform/repositoryGateway";
import type { AppUpdatePlan, CapabilitySnapshot, GitIndexUpdatePlan, GitOperationPlan, RemoteReviewPlan, RepositorySessionSnapshot } from "../contracts/repository";

vi.mock("./ReleaseLedgerPanel", () => ({ ReleaseLedgerPanel: () => null }));
vi.mock("./UnpublishImpactPanel", () => ({ UnpublishImpactPanel: () => null }));
const repository: RepositorySessionSnapshot = { sessionId: "s", rootPath: "/repo", displayName: "标题", siteKind: "generic", contentRoot: null, isGitRepository: true, warnings: [] };
const capabilities = { localEdit: true, gitStatus: true, gitPush: true, gitFetch: true, gitCommit: true, gitIndex: true, remoteAuth: true } as CapabilitySnapshot;
const future = () => new Date(Date.now() + 60_000).toISOString();
let push: GitOperationPlan, review: RemoteReviewPlan, index: GitIndexUpdatePlan, update: AppUpdatePlan;
let host: HTMLDivElement, root: ReturnType<typeof createRoot>, call: ReturnType<typeof vi.fn<(name: string, args?: object) => Promise<unknown>>>, gateway: ReturnType<typeof createRepositoryGateway>;
const props = () => ({ open: true, onClose: vi.fn(), repository, capabilities, gateway, currentDocument: null });
async function render(locale: "zh-CN" | "en-US", overrides = {}) {
  await act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(PublishCenter, { ...props(), ...overrides }) })));
}
function button(label: string) {
  const node = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label);
  if (!node) throw new Error(`Missing button ${label}`);
  return node;
}
async function click(label: string) { await act(async () => button(label).click()); }
function field(label: string) {
  const node = [...host.querySelectorAll("label")].find((item) => item.firstChild?.textContent === label)?.querySelector<HTMLInputElement | HTMLTextAreaElement>("input,textarea");
  if (!node) throw new Error(`Missing field ${label}`);
  return node;
}
async function fill(label: string, text: string) {
  const node = field(label), prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  await act(async () => { Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, text); node.dispatchEvent(new Event("input", { bubbles: true })); });
  return node;
}
const executions = () => call.mock.calls.filter(([name]) => ["execute_git_operation", "execute_git_index_update", "execute_remote_review", "install_app_update", "store_repository_credential", "delete_repository_credential"].includes(name));

describe("PublishCenter live localization", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  beforeEach(() => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    push = { planId: "push-frozen", operation: "push", branch: "标题", head: "a".repeat(40), stagedFiles: ["设置.md"], remote: "origin", remoteUrl: "https://example.test/标题.git", summary: "设置", expiresAt: future(), warnings: ["标题"] };
    review = { planId: "review-frozen", provider: "github", host: "example.test", title: "标题", baseBranch: "设置", headBranch: "标题", summary: "设置", expiresAt: future(), warnings: ["标题"], sourceSha: "b".repeat(40), requestMarker: "marker", bodyPreview: "<b>设置 {source}</b>" };
    index = { planId: "index-frozen", action: "stage", paths: ["标题.md"], summary: "设置", expiresAt: future(), warnings: ["标题"] };
    update = { planId: "update-frozen", currentVersion: "1.0", version: "1.1", publishedAt: null, notes: "设置", downloadHost: "example.test", artifactName: "标题.AppImage", expiresAt: future(), warnings: ["标题"] };
    call = vi.fn(async (name: string) => {
      if (name === "credential_status") return { credentials: [{ credentialId: "credential", provider: "github", host: "example.test", account: "标题", storage: "session_only" }], storage: "session_only", warning: "设置" };
      if (name === "git_status") return { available: true, branch: "标题", upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [{ status: "??", relativePath: "标题.md", sourcePath: null }], warnings: [] };
      if (name.startsWith("list_")) return [];
      if (name === "plan_git_operation") return push;
      if (name === "plan_remote_review") return review;
      if (name === "plan_git_index_update") return index;
      if (name === "check_app_update") return { supported: true, configured: true, available: true, summary: "标题", plan: update };
      if (name === "execute_git_operation") return { operation: "push", summary: "设置", remote: "origin" };
      if (name === "check_deployment") return { configured: true, provider: "custom", status: "unknown", url: null, summary: "设置", checkedAt: null, warning: "标题" };
      return { configured: true, ready: true, summary: "标题", warning: "设置" };
    });
    gateway = createRepositoryGateway(async <T>(name: string, args?: object) => await call(name, args) as T);
  });
  afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); });

  it("preserves inputs, selected paths, and all frozen plans without extra calls across locales", async () => {
    await render("zh-CN");
    const commitInput = await fill("提交说明", "标题 {count}");
    const tokenInput = await fill("访问令牌", "LOCAL_TEST_TOKEN");
    const titleInput = await fill("标题", "标题");
    const bodyInput = await fill("说明（可选）", "<b>设置</b>");
    await click("生成 Push 计划"); await click("生成 PR/MR 计划");
    await act(async () => host.querySelector<HTMLInputElement>(".index-file input")!.click());
    await click("生成暂存计划"); await click("检查 AppImage 更新");
    const calls = call.mock.calls.length;
    await render("en-US");
    expect(call).toHaveBeenCalledTimes(calls); expect(executions()).toHaveLength(0);
    expect(field("Commit message")).toBe(commitInput); expect(commitInput.value).toBe("标题 {count}");
    expect(field("Access token")).toBe(tokenInput); expect(tokenInput.value).toBe("LOCAL_TEST_TOKEN");
    expect(field("Title")).toBe(titleInput); expect(titleInput.value).toBe("标题");
    expect(field("Description (optional)")).toBe(bodyInput); expect(bodyInput.value).toBe("<b>设置</b>");
    expect(host.textContent).not.toContain("LOCAL_TEST_TOKEN");
    expect(host.querySelector<HTMLInputElement>(".index-file input")!.checked).toBe(true);
    expect(button("Confirm Push").disabled).toBe(false); expect(button("Confirm creation").disabled).toBe(false);
    expect(button("Confirm execution").disabled).toBe(false); expect(button("Confirm update installation").disabled).toBe(false);
    expect(host.querySelector(".operation-plan pre")?.textContent).toBe(review.bodyPreview);
    expect(host.textContent).toContain(push.remoteUrl); expect(host.textContent).toContain("设置.md");
    expect(host.textContent).toContain("标题.AppImage"); expect(host.querySelector(".operation-plan b")).toBeNull();
    await render("zh-CN"); expect(call).toHaveBeenCalledTimes(calls);
    expect(button("确认执行 Push").disabled).toBe(false); expect(tokenInput.value).toBe("LOCAL_TEST_TOKEN");
  });

  it("confirms the same push once after a locale switch and keeps backend summaries literal", async () => {
    await render("zh-CN"); await click("生成 Push 计划"); await render("en-US");
    await act(async () => { const confirm = button("Confirm Push"); confirm.click(); confirm.click(); });
    const executed = executions(); expect(executed).toHaveLength(1);
    expect(executed[0]).toEqual(["execute_git_operation", { sessionId: "s", planId: "push-frozen" }]);
    expect(host.querySelector(".publish-state")?.textContent).toBe("Push completed: 设置");
    await render("zh-CN"); expect(host.querySelector(".publish-state")?.textContent).toBe("Push已完成：设置");
  });

  it("keeps missing-destination and expired plans disabled in both languages", async () => {
    await render("zh-CN"); push.remoteUrl = null;
    await click("生成 Push 计划"); await render("en-US"); expect(button("Confirm Push").disabled).toBe(true);
    push.remoteUrl = "https://example.test/标题.git"; push.expiresAt = "2000-01-01T00:00:00Z";
    await click("Create Push plan"); expect(button("Confirm Push").disabled).toBe(true);
    expect(host.textContent).toContain("The plan expired. Create a new plan.");
    await render("zh-CN"); expect(button("确认执行 Push").disabled).toBe(true); expect(executions()).toHaveLength(0);
  });

  it("localizes credential deletion confirmation and preserves cancellation", async () => {
    await render("en-US"); const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    await click("Delete"); expect(confirm).toHaveBeenCalledWith("Delete this credential? This does not affect the remote repository.");
    expect(executions()).toHaveLength(0);
  });

  it("keeps actual deployment summaries literal and demo writes disabled", async () => {
    await render("en-US"); await click("Check deployment status");
    const section = [...host.querySelectorAll(".publish-section")].find((node) => node.querySelector("h2")?.textContent === "Deployment (read-only)")!;
    expect(section.querySelector("p")?.textContent).toBe("设置");
    await render("zh-CN"); expect(section.querySelector("p")?.textContent).toBe("设置");
    await render("en-US", { capabilities: { ...capabilities, localEdit: false } });
    for (const label of ["Create Push plan", "Create Commit plan", "Create PR/MR plan", "Save credentials", "In-app updates disabled"]) expect(button(label).disabled).toBe(true);
    expect(executions()).toHaveLength(0);
  });
});
