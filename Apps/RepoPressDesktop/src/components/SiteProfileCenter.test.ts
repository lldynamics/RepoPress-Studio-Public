import { act, createElement, Fragment } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { SiteProfile, SiteProfileSnapshot } from "../contracts/sites";
import SiteProfileCenter from "./SiteProfileCenter";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const repo = (sessionId = "session-a", rootPath = "/site-a"): RepositorySessionSnapshot => ({ sessionId, rootPath, displayName: sessionId, siteKind: "none", contentRoot: null, isGitRepository: false, warnings: [] });
const profile: SiteProfile = { profileId: "p1", name: "博客", rootPath: "/site-a", createdAtEpochMs: 1 };
const secondProfile: SiteProfile = { profileId: "p2", name: "文档", rootPath: "/site-b", createdAtEpochMs: 2 };
const profiles = (items: SiteProfile[] = [profile], revision = 4): SiteProfileSnapshot => ({ profiles: items, revision, persistent: true, writable: true, warning: null });

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => { resolve = resolvePromise; reject = rejectPromise; });
  return { promise, resolve, reject };
}

function mount(gateway: Partial<RepositoryGateway>, extra: Record<string, unknown> = {}) {
  const host = document.createElement("div"); document.body.append(host);
  const root = createRoot(host);
  const props = { open: true, enabled: true, gateway: gateway as RepositoryGateway, repository: repo(), onClose: vi.fn(), onSnapshot: vi.fn(), onSelect: vi.fn().mockResolvedValue(false), ...extra };
  return { host, root, props };
}

function button(host: HTMLElement, label: string) {
  const match = Array.from(host.querySelectorAll("button")).find((entry) => entry.textContent === label);
  if (!match) throw new Error(`Missing button: ${label}`);
  return match as HTMLButtonElement;
}

function profileButton(host: HTMLElement, name: string) {
  const match = Array.from(host.querySelectorAll<HTMLButtonElement>(".site-profile-list button"))
    .find((entry) => entry.querySelector("strong")?.textContent === name);
  if (!match) throw new Error(`Missing profile: ${name}`);
  return match;
}

function setInput(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" }));
  input.dispatchEvent(new Event("change", { bubbles: true }));
  input.dispatchEvent(new Event("blur", { bubbles: true }));
}

async function settle() {
  await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
}

describe("SiteProfileCenter", () => {
  afterEach(() => { document.body.innerHTML = ""; vi.restoreAllMocks(); });

  it("selects a list profile without opening it, then sends the real renamed input", async () => {
    const renamed = profiles([{ ...profile, name: "新名称" }], 5);
    const gateway = { getSiteProfiles: vi.fn().mockResolvedValue(profiles()), renameSiteProfile: vi.fn().mockResolvedValue(renamed) };
    const m = mount(gateway);
    await act(async () => { m.root.render(createElement(SiteProfileCenter, m.props)); });
    await settle();
    await act(async () => { profileButton(m.host, "博客").click(); });
    expect(m.props.onSelect).not.toHaveBeenCalled();
    const input = m.host.querySelector(".site-profile-editor input") as HTMLInputElement;
    await act(async () => { setInput(input, "新名称"); });
    await act(async () => { button(m.host, "保存名称").click(); });
    expect(gateway.renameSiteProfile).toHaveBeenCalledWith({ profileId: "p1", name: "新名称", expectedRevision: 4 });
    expect(m.props.onSnapshot).toHaveBeenLastCalledWith(renamed);
    m.root.unmount();
  });

  it("registers an unregistered current session with the entered name", async () => {
    const registered = profiles([profile], 1);
    const gateway = { getSiteProfiles: vi.fn().mockResolvedValue(profiles([], 0)), registerSiteProfile: vi.fn().mockResolvedValue(registered) };
    const m = mount(gateway);
    await act(async () => { m.root.render(createElement(SiteProfileCenter, m.props)); });
    await settle();
    const input = m.host.querySelector(".site-profile-register input") as HTMLInputElement;
    await act(async () => { setInput(input, "  我的站点  "); button(m.host, "登记").click(); });
    expect(gateway.registerSiteProfile).toHaveBeenCalledWith({ sessionId: "session-a", name: "我的站点", expectedRevision: 0 });
    expect(m.props.onSnapshot).toHaveBeenLastCalledWith(registered);
    m.root.unmount();
  });

  it("cancels removal without mutation and freezes selected id, name, and revision", async () => {
    const gateway = { getSiteProfiles: vi.fn().mockResolvedValue(profiles()), removeSiteProfile: vi.fn() };
    const m = mount(gateway);
    await act(async () => { m.root.render(createElement(SiteProfileCenter, m.props)); });
    await settle();
    await act(async () => { profileButton(m.host, "博客").click(); });
    await act(async () => { button(m.host, "移除登记").click(); });
    expect(m.host.querySelector(".site-profile-confirm")?.textContent).toContain("博客");
    expect(document.activeElement).toBe(button(m.host, "取消"));
    await act(async () => { button(m.host, "取消").click(); });
    expect(gateway.removeSiteProfile).not.toHaveBeenCalled();
    expect(m.host.textContent).toContain("博客");
    m.root.unmount();
  });

  it("executes confirmed removal, keeps records on failure, and restores enabled focus on success", async () => {
    const removeSiteProfile = vi.fn().mockRejectedValueOnce(new Error("暂时不可用")).mockResolvedValueOnce(profiles([secondProfile], 5));
    const gateway = { getSiteProfiles: vi.fn().mockResolvedValue(profiles()), removeSiteProfile };
    const m = mount(gateway);
    await act(async () => { m.root.render(createElement(SiteProfileCenter, m.props)); });
    await settle();
    await act(async () => { profileButton(m.host, "博客").click(); });
    await act(async () => { button(m.host, "移除登记").click(); });
    await act(async () => { button(m.host, "确认移除").click(); });
    expect(removeSiteProfile).toHaveBeenCalledWith({ profileId: "p1", expectedRevision: 4 });
    expect(m.host.textContent).toContain("博客");
    expect(m.host.textContent).toContain("暂时不可用");
    await act(async () => { button(m.host, "确认移除").click(); });
    expect(removeSiteProfile).toHaveBeenCalledTimes(2);
    expect(m.host.textContent).toContain("文档");
    expect(m.host.textContent).not.toContain("博客");
    await act(async () => { await Promise.resolve(); });
    expect(document.activeElement).toBe(button(m.host, "刷新"));
    m.root.unmount();
  });

  it("starts a new load when the session changes while an older load is pending", async () => {
    const first = deferred<SiteProfileSnapshot>(); const second = deferred<SiteProfileSnapshot>();
    const getSiteProfiles = vi.fn().mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
    const m = mount({ getSiteProfiles });
    await act(async () => { m.root.render(createElement(SiteProfileCenter, m.props)); });
    await settle();
    await act(async () => { m.root.render(createElement(SiteProfileCenter, { ...m.props, repository: repo("session-b", "/site-b") })); });
    expect(getSiteProfiles).toHaveBeenCalledTimes(2);
    const current = profiles([secondProfile], 8);
    await act(async () => { second.resolve(current); });
    expect(m.host.textContent).toContain("文档");
    await act(async () => { first.resolve(profiles([profile], 4)); });
    expect(m.host.textContent).not.toContain("博客");
    expect(m.props.onSnapshot).toHaveBeenLastCalledWith(current);
    m.root.unmount();
  });

  it("does not let an old pending open close a reopened panel", async () => {
    const opening = deferred<boolean>(); const onClose = vi.fn();
    const m = mount({ getSiteProfiles: vi.fn().mockResolvedValue(profiles()) }, { onClose, onSelect: vi.fn().mockReturnValue(opening.promise) });
    await act(async () => { m.root.render(createElement(SiteProfileCenter, m.props)); });
    await settle();
    await act(async () => { profileButton(m.host, "博客").click(); });
    await act(async () => { button(m.host, "打开此站点").click(); });
    await act(async () => { m.root.render(createElement(SiteProfileCenter, { ...m.props, open: false })); });
    await act(async () => { m.root.render(createElement(SiteProfileCenter, { ...m.props, open: true, repository: repo("session-b", "/site-b") })); });
    await act(async () => { opening.resolve(true); });
    expect(onClose).not.toHaveBeenCalled();
    expect(m.host.querySelector(".site-profile-scrim")).not.toBeNull();
    m.root.unmount();
  });

  it("keeps the panel open when opening a selected profile returns false", async () => {
    const onClose = vi.fn();
    const m = mount({ getSiteProfiles: vi.fn().mockResolvedValue(profiles()) }, { onClose, onSelect: vi.fn().mockResolvedValue(false) });
    await act(async () => { m.root.render(createElement(SiteProfileCenter, m.props)); });
    await settle();
    await act(async () => { profileButton(m.host, "博客").click(); });
    await act(async () => { button(m.host, "打开此站点").click(); });
    expect(onClose).not.toHaveBeenCalled();
    expect(m.host.textContent).toContain("未切换站点");
    m.root.unmount();
  });

  it("publishes a completed CRUD snapshot after closing without filling the closed panel", async () => {
    const registration = deferred<SiteProfileSnapshot>();
    const gateway = { getSiteProfiles: vi.fn().mockResolvedValue(profiles([], 0)), registerSiteProfile: vi.fn().mockReturnValue(registration.promise) };
    const m = mount(gateway);
    await act(async () => { m.root.render(createElement(SiteProfileCenter, m.props)); });
    await settle();
    const input = m.host.querySelector(".site-profile-register input") as HTMLInputElement;
    await act(async () => { setInput(input, "新站点"); button(m.host, "登记").click(); });
    await act(async () => { m.root.render(createElement(SiteProfileCenter, { ...m.props, open: false })); });
    const registered = profiles([profile], 1);
    await act(async () => { registration.resolve(registered); });
    expect(m.props.onSnapshot).toHaveBeenLastCalledWith(registered);
    expect(m.host.querySelector(".site-profile-scrim")).toBeNull();
    m.root.unmount();
  });

  it("does not access data while disabled and restores inert background focus after escape", async () => {
    const getSiteProfiles = vi.fn(); const onClose = vi.fn(); const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    const outside = createElement("button", { id: "background" }, "背景");
    const props = { enabled: false, gateway: { getSiteProfiles } as unknown as RepositoryGateway, repository: repo(), onClose, onSnapshot: vi.fn(), onSelect: vi.fn() };
    await act(async () => { root.render(createElement(Fragment, null, outside, createElement(SiteProfileCenter, { ...props, open: false }))); });
    const background = host.querySelector("#background") as HTMLButtonElement; background.focus();
    await act(async () => { root.render(createElement(Fragment, null, outside, createElement(SiteProfileCenter, { ...props, open: true }))); });
    expect(getSiteProfiles).not.toHaveBeenCalled(); expect(background.inert).toBe(true);
    host.querySelector(".site-profile-scrim")!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    expect(onClose).toHaveBeenCalledTimes(1);
    await act(async () => { root.render(createElement(Fragment, null, outside, createElement(SiteProfileCenter, { ...props, open: false }))); });
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
    expect(background.inert).toBe(false); expect(document.activeElement).toBe(background);
    root.unmount();
  });
});
