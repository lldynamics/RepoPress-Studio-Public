import { createRoot } from "react-dom/client";
import { act, Fragment } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { OperationLogSnapshot } from "../contracts/activity";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import OperationLogCenter from "./OperationLogCenter";
import { createElement } from "react";

const snapshot: OperationLogSnapshot = { entries: [{ sequence: 3, occurredAtEpochMs: 1_700_000_000_000, durationMs: 12, kind: "saveDocument", outcome: "succeeded", repositoryKey: "repo" }], latestSequence: 3, persistent: true, warning: null, currentRepositoryKey: "repo" };
const gateway = { getOperationLog: vi.fn().mockResolvedValue(snapshot), clearOperationLog: vi.fn().mockResolvedValue({ ...snapshot, entries: [] }) } as unknown as RepositoryGateway;
const repo = (sessionId: string): RepositorySessionSnapshot => ({ sessionId, rootPath: `/${sessionId}`, displayName: sessionId, siteKind: "none", contentRoot: null, isGitRepository: false, warnings: [] });
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

describe("OperationLogCenter", () => {
  afterEach(() => { vi.restoreAllMocks(); document.body.innerHTML = ""; });
  it("does not call gateway while disabled and reads without a repository", async () => {
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    await act(async () => { root.render(createElement(OperationLogCenter, { open: true, enabled: false, gateway, repository: null, onClose: vi.fn() })); });
    expect(gateway.getOperationLog).not.toHaveBeenCalled();
    await act(async () => { root.render(createElement(OperationLogCenter, { open: true, enabled: true, gateway, repository: null, onClose: vi.fn() })); });
    expect(gateway.getOperationLog).toHaveBeenCalledWith(undefined);
    expect(host.textContent).toContain("保存文稿");
    root.unmount();
  });
  it("starts a new session load while the previous session is pending", async () => {
    const first = deferred<OperationLogSnapshot>();
    const second = deferred<OperationLogSnapshot>();
    const getOperationLog = vi.fn().mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
    const localGateway = { getOperationLog, clearOperationLog: vi.fn() } as unknown as RepositoryGateway;
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    await act(async () => { root.render(createElement(OperationLogCenter, { open: true, enabled: true, gateway: localGateway, repository: repo("one"), onClose: vi.fn() })); });
    await act(async () => { root.render(createElement(OperationLogCenter, { open: true, enabled: true, gateway: localGateway, repository: repo("two"), onClose: vi.fn() })); });
    expect(getOperationLog).toHaveBeenCalledTimes(2);
    await act(async () => { second.resolve({ ...snapshot, currentRepositoryKey: "two", entries: [{ ...snapshot.entries[0], sequence: 22, repositoryKey: "two" }] }); });
    expect(host.textContent).toContain("22");
    await act(async () => { first.resolve({ ...snapshot, entries: [{ ...snapshot.entries[0], sequence: 11, repositoryKey: "one" }] }); });
    expect(host.textContent).not.toContain("#11");
    root.unmount();
  });
  it("allows closing a pending clear and reading again after reopening", async () => {
    const clearPending = deferred<OperationLogSnapshot>();
    const getOperationLog = vi.fn().mockResolvedValue(snapshot);
    const clearOperationLog = vi.fn().mockReturnValue(clearPending.promise);
    const onClose = vi.fn();
    const localGateway = { getOperationLog, clearOperationLog } as unknown as RepositoryGateway;
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    await act(async () => { root.render(createElement(OperationLogCenter, { open: true, enabled: true, gateway: localGateway, repository: repo("one"), onClose })); });
    const clearButton = Array.from(host.querySelectorAll("button")).find((button) => button.textContent === "清空已加载记录")!;
    await act(async () => { clearButton.click(); });
    const confirm = Array.from(host.querySelectorAll("button")).find((button) => button.textContent === "确认清空")!;
    await act(async () => { confirm.click(); });
    const closeButton = host.querySelector("button[aria-label='关闭操作日志']") as HTMLButtonElement;
    await act(async () => { closeButton.click(); });
    expect(onClose).toHaveBeenCalledTimes(1);
    await act(async () => { root.render(createElement(OperationLogCenter, { open: false, enabled: true, gateway: localGateway, repository: repo("one"), onClose })); });
    await act(async () => { root.render(createElement(OperationLogCenter, { open: true, enabled: true, gateway: localGateway, repository: repo("two"), onClose })); });
    expect(getOperationLog).toHaveBeenCalledTimes(2);
    await act(async () => { clearPending.resolve({ ...snapshot, entries: [] }); });
    expect(host.querySelector(".operation-log-list")?.textContent).toContain("#3");
    expect((Array.from(host.querySelectorAll("button")).find((button) => button.textContent === "刷新") as HTMLButtonElement).disabled).toBe(false);
    root.unmount();
  });
  it("freezes the clear cutoff and keeps records when clear fails", async () => {
    const clearOperationLog = vi.fn().mockRejectedValue(new Error("暂时不可用"));
    const localGateway = { getOperationLog: vi.fn().mockResolvedValue(snapshot), clearOperationLog } as unknown as RepositoryGateway;
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    await act(async () => { root.render(createElement(OperationLogCenter, { open: true, enabled: true, gateway: localGateway, repository: repo("one"), onClose: vi.fn() })); });
    await act(async () => { (Array.from(host.querySelectorAll("button")).find((button) => button.textContent === "清空已加载记录") as HTMLButtonElement).click(); });
    await act(async () => { (Array.from(host.querySelectorAll("button")).find((button) => button.textContent === "确认清空") as HTMLButtonElement).click(); });
    expect(clearOperationLog).toHaveBeenCalledWith(3, "one");
    expect(host.textContent).toContain("#3");
    expect(host.textContent).toContain("暂时不可用");
    root.unmount();
  });
  it("inerts the background and closes on Escape, restoring focus", async () => {
    const onClose = vi.fn(); const host = document.createElement("div"); document.body.append(host);
    const outside = createElement("button", { id: "background" }, "背景"); const root = createRoot(host);
    await act(async () => { root.render(createElement(Fragment, null, outside, createElement(OperationLogCenter, { open: false, enabled: false, gateway, repository: null, onClose }))); });
    const background = host.querySelector("#background") as HTMLButtonElement;
    background.focus();
    await act(async () => { root.render(createElement(Fragment, null, outside, createElement(OperationLogCenter, { open: true, enabled: false, gateway, repository: null, onClose }))); });
    expect(background.inert).toBe(true);
    const scrim = host.querySelector(".operation-log-scrim")!;
    scrim.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(onClose).toHaveBeenCalledTimes(1);
    await act(async () => { root.render(createElement(Fragment, null, outside, createElement(OperationLogCenter, { open: false, enabled: false, gateway, repository: null, onClose }))); });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
    expect(background.inert).toBe(false);
    expect(document.activeElement).toBe(background);
    root.unmount();
  });

  it("retains the confirmation cutoff across refresh and restores focus after clearing", async () => {
    const newer = { ...snapshot.entries[0], sequence: 4, kind: "createDocument" as const };
    const refreshed = { ...snapshot, latestSequence: 4, entries: [newer, ...snapshot.entries] };
    const getOperationLog = vi.fn().mockResolvedValueOnce(snapshot).mockResolvedValue(refreshed);
    const clearOperationLog = vi.fn().mockResolvedValue({ ...refreshed, entries: [newer] });
    const localGateway = { getOperationLog, clearOperationLog } as unknown as RepositoryGateway;
    const onClose = vi.fn();
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    const button = (label: string) => Array.from(host.querySelectorAll("button"))
      .find((entry) => entry.textContent === label)!;
    await act(async () => {
      root.render(createElement(OperationLogCenter, { open: true, enabled: true, gateway: localGateway, repository: repo("one"), onClose }));
    });
    await act(async () => { button("清空已加载记录").click(); });
    expect(document.activeElement).toBe(button("取消"));
    expect(button("清空已加载记录").disabled).toBe(true);
    await act(async () => { button("刷新").click(); });
    expect(host.querySelector(".operation-log-list")?.textContent).toContain("#4");
    expect(host.querySelector(".operation-log-confirm")?.textContent).toContain("截至序号 #3");
    await act(async () => { button("确认清空").click(); });
    expect(clearOperationLog).toHaveBeenCalledWith(3, "one");
    expect(host.querySelector(".operation-log-list")?.textContent).toContain("#4");
    expect(host.querySelector(".operation-log-list")?.textContent).not.toContain("#3");
    expect(document.activeElement).toBe(button("清空已加载记录"));
    document.activeElement?.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(onClose).toHaveBeenCalledTimes(1);
    await act(async () => { root.unmount(); });
  });

  it("restores focus after cancellation and falls back to refresh when clearing empties the list", async () => {
    const clearOperationLog = vi.fn().mockResolvedValue({ ...snapshot, entries: [] });
    const localGateway = { getOperationLog: vi.fn().mockResolvedValue(snapshot), clearOperationLog } as unknown as RepositoryGateway;
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    const button = (label: string) => Array.from(host.querySelectorAll("button"))
      .find((entry) => entry.textContent === label)!;
    await act(async () => {
      root.render(createElement(OperationLogCenter, { open: true, enabled: true, gateway: localGateway, repository: null, onClose: vi.fn() }));
    });
    await act(async () => { button("清空已加载记录").click(); });
    await act(async () => { button("取消").click(); });
    expect(document.activeElement).toBe(button("清空已加载记录"));
    expect(clearOperationLog).not.toHaveBeenCalled();
    await act(async () => { button("清空已加载记录").click(); });
    await act(async () => { button("确认清空").click(); });
    expect(button("清空已加载记录").disabled).toBe(true);
    expect(document.activeElement).toBe(button("刷新"));
    await act(async () => { root.unmount(); });
  });
});
