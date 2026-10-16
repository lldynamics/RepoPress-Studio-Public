import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_WORKSPACE_PREFERENCES } from "../features/workspace/workspaceRecovery";
import { I18nProvider } from "../i18n/i18n";
import { SettingsCenter } from "./SettingsCenter";

describe("SettingsCenter language preference", () => {
  let host: HTMLDivElement | undefined;
  let root: ReturnType<typeof createRoot> | undefined;
  const preferences = { ...DEFAULT_WORKSPACE_PREFERENCES, theme: "dark" as const, uiLanguage: "zh-CN" as const };
  const base = { open: true, preferences, recentRepositories: [], canOpenRecent: false, onClose: vi.fn(), onOpenRecent: vi.fn(async () => false) };
  afterEach(() => { act(() => root?.unmount()); host?.remove(); root = undefined; host = undefined; });
  function render(locale: "zh-CN" | "en-US" = "zh-CN", onSave = vi.fn(async () => undefined)) {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => { root?.render(createElement(I18nProvider, { locale, children: createElement(SettingsCenter, { ...base, onSave }) })); });
    return { onSave, drawer: host.querySelector<HTMLElement>(".settings-center")! };
  }
  function languageSelect(drawer: HTMLElement) { return drawer.querySelectorAll<HTMLSelectElement>("select")[2]; }

  it("does not save an English selection until Save is pressed", () => {
    const { drawer, onSave } = render();
    act(() => { languageSelect(drawer).value = "en-US"; languageSelect(drawer).dispatchEvent(new Event("change", { bubbles: true })); });
    expect(onSave).not.toHaveBeenCalled();
    expect(languageSelect(drawer).value).toBe("en-US");
  });
  it("saves en-US while preserving the other preferences", async () => {
    const { drawer, onSave } = render();
    act(() => { languageSelect(drawer).value = "en-US"; languageSelect(drawer).dispatchEvent(new Event("change", { bubbles: true })); });
    await act(async () => { drawer.querySelector<HTMLButtonElement>(".settings-actions button")!.click(); });
    expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ uiLanguage: "en-US", theme: "dark" }));
  });
  it("keeps the selected language when restoring editor defaults", async () => {
    const { drawer, onSave } = render();
    act(() => { languageSelect(drawer).value = "en-US"; languageSelect(drawer).dispatchEvent(new Event("change", { bubbles: true })); });
    act(() => { Array.from(drawer.querySelectorAll("button")).find((button) => button.textContent?.includes("恢复编辑器默认设置"))?.click(); });
    await act(async () => { drawer.querySelector<HTMLButtonElement>(".settings-actions button")!.click(); });
    expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ uiLanguage: "en-US" }));
  });
  it("switches labels without remounting the draft", () => {
    const { drawer } = render();
    act(() => { languageSelect(drawer).value = "en-US"; languageSelect(drawer).dispatchEvent(new Event("change", { bubbles: true })); });
    act(() => { root?.render(createElement(I18nProvider, { locale: "en-US", children: createElement(SettingsCenter, { ...base, onSave: vi.fn(async () => undefined) }) })); });
    expect(drawer.querySelector("h1")?.textContent).toBe("Settings Center");
    expect(languageSelect(drawer).value).toBe("en-US");
  });
});
