import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { SiteProfile, SiteProfileSnapshot } from "../contracts/sites";
import { I18nProvider } from "../i18n/i18n";
import type { UiLocale } from "../i18n/locale";
import { SiteProfileCenter, type SiteProfileCenterProps } from "./SiteProfileCenter";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
const profile: SiteProfile = { profileId: "profile-original", name: "设置 {name}", rootPath: "/tmp/设置-{path}", createdAtEpochMs: 1 };
const repository: RepositorySessionSnapshot = { sessionId: "original-session", rootPath: profile.rootPath, displayName: "原始站点", siteKind: "none", contentRoot: null, isGitRepository: false, warnings: [] };
const snapshot = (profiles = [profile], revision = 7): SiteProfileSnapshot => ({ profiles, revision, persistent: true, writable: true, warning: "站点管理" });
function deferred<T>() { let resolve!: (value: T) => void; let reject!: (reason?: unknown) => void; const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; }); return { promise, resolve, reject }; }
let host: HTMLDivElement; let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); });
function props(gateway: Partial<RepositoryGateway>, extra: Partial<SiteProfileCenterProps> = {}): SiteProfileCenterProps { return { open: true, enabled: true, gateway: gateway as RepositoryGateway, repository, onClose: vi.fn(), onSnapshot: vi.fn(), onSelect: vi.fn(async () => false), ...extra }; }
async function render(locale: UiLocale, value: SiteProfileCenterProps) { await act(async () => root.render(createElement(I18nProvider, { locale, children: createElement(SiteProfileCenter, value) }))); }
async function click(label: string) { const button = [...host.querySelectorAll("button")].find(e => e.textContent === label); expect(button).toBeDefined(); await act(async () => button!.click()); }
async function selectProfile() { await act(async () => host.querySelector<HTMLButtonElement>(".site-profile-list button")!.click()); }
async function input(element: HTMLInputElement, value: string) { await act(async () => { Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(element, value); element.dispatchEvent(new Event("input", { bubbles: true })); }); }

describe("site registration live localization", () => {
  it("keeps a pending load, raw warning and profile fields, then preserves edited input and focus", async () => {
    const pending = deferred<SiteProfileSnapshot>(); const getSiteProfiles = vi.fn(() => pending.promise); const value = props({ getSiteProfiles });
    await render("zh-CN", value); await render("en-US", value); await render("zh-CN", value);
    expect(getSiteProfiles).toHaveBeenCalledTimes(1); expect(value.onSnapshot).not.toHaveBeenCalled();
    await act(async () => pending.resolve(snapshot())); await render("en-US", value);
    expect(host.querySelector(".site-profile-warning")?.textContent).toBe("站点管理");
    expect(host.querySelector(".site-profile-list strong")?.textContent).toBe(profile.name);
    expect(host.querySelector(".site-profile-list span")?.textContent).toBe(`${profile.rootPath} · Current repository`);
    await selectProfile(); const edited = host.querySelector<HTMLInputElement>(".site-profile-editor input")!;
    await input(edited, "未保存 {name}"); edited.focus();
    await render("zh-CN", value); await render("en-US", value);
    expect(host.querySelector(".site-profile-editor input")).toBe(edited); expect(edited.value).toBe("未保存 {name}"); expect(document.activeElement).toBe(edited);
    expect(getSiteProfiles).toHaveBeenCalledTimes(1); expect(value.onSnapshot).toHaveBeenCalledTimes(1); expect(value.onSelect).not.toHaveBeenCalled();
  });

  it("retains the frozen removal and cancel focus through language changes, sends once and rerenders delayed completion", async () => {
    const pending = deferred<SiteProfileSnapshot>(); const removeSiteProfile = vi.fn(() => pending.promise); const getSiteProfiles = vi.fn(async () => snapshot()); const value = props({ getSiteProfiles, removeSiteProfile });
    await render("zh-CN", value); await selectProfile(); await click("移除登记");
    const cancel = host.querySelector<HTMLButtonElement>(".site-profile-confirm button")!;
    expect(document.activeElement).toBe(cancel); await render("en-US", value); await render("zh-CN", value); await render("en-US", value);
    expect(document.activeElement).toBe(cancel); expect(host.querySelector(".site-profile-confirm p")?.textContent).toBe(`Remove the registration for “${profile.name}”? The repository and drafts will be retained.`);
    await click("Confirm removal"); await click("Confirm removal"); await render("zh-CN", value); await render("en-US", value);
    expect(removeSiteProfile).toHaveBeenCalledTimes(1); expect(removeSiteProfile).toHaveBeenCalledWith({ profileId: profile.profileId, expectedRevision: 7 });
    const next = snapshot([], 8); await act(async () => pending.resolve(next));
    expect(value.onSnapshot).toHaveBeenLastCalledWith(next); expect(host.querySelector(".site-profile-status")?.textContent).toBe("Site registration updated.");
    expect(document.activeElement?.textContent).toBe("Refresh"); await render("zh-CN", value);
    expect(host.querySelector(".site-profile-status")?.textContent).toBe("已更新站点登记。"); expect(getSiteProfiles).toHaveBeenCalledTimes(1); expect(value.onClose).not.toHaveBeenCalled();
  });

  it("separates a delayed known-code failure from an identical raw backend message without repeating a rename", async () => {
    const pending = deferred<SiteProfileSnapshot>(); const source = "站点列表已变化，请刷新后重试。";
    const renameSiteProfile = vi.fn().mockReturnValueOnce(pending.promise).mockRejectedValueOnce(new Error(source));
    const value = props({ getSiteProfiles: vi.fn(async () => snapshot()), renameSiteProfile });
    await render("zh-CN", value); await selectProfile(); const name = host.querySelector<HTMLInputElement>(".site-profile-editor input")!;
    await input(name, " 改名 {name} "); await click("保存名称"); await render("en-US", value); await render("zh-CN", value);
    expect(renameSiteProfile).toHaveBeenCalledTimes(1); expect(renameSiteProfile).toHaveBeenCalledWith({ profileId: profile.profileId, name: "改名 {name}", expectedRevision: 7 });
    await act(async () => pending.reject({ code: "site_profiles_revision_conflict" })); await render("en-US", value);
    expect(host.querySelector(".site-profile-status")?.textContent).toBe("The site list changed. Refresh and try again."); expect(name.value).toBe(" 改名 {name} ");
    await click("Save name"); expect(host.querySelector(".site-profile-status")?.textContent).toBe(source);
    await render("zh-CN", value); await render("en-US", value);
    expect(host.querySelector(".site-profile-status")?.textContent).toBe(source); expect(renameSiteProfile).toHaveBeenCalledTimes(2);
  });

  it("keeps a pending open single-shot and relocalizes its local failure while retaining the current site", async () => {
    const pending = deferred<boolean>(); const onSelect = vi.fn(() => pending.promise); const getSiteProfiles = vi.fn(async () => snapshot()); const value = props({ getSiteProfiles }, { onSelect });
    await render("zh-CN", value); await selectProfile(); await click("打开此站点"); await render("en-US", value); await render("zh-CN", value);
    expect(onSelect).toHaveBeenCalledTimes(1); expect(onSelect).toHaveBeenCalledWith(profile);
    await act(async () => pending.resolve(false)); await render("en-US", value);
    expect(host.querySelector(".site-profile-status")?.textContent).toContain("The current repository and article are retained.");
    expect(host.querySelector(".site-profile-list strong")?.textContent).toBe(profile.name); expect(getSiteProfiles).toHaveBeenCalledTimes(1); expect(value.onClose).not.toHaveBeenCalled();
  });
});
