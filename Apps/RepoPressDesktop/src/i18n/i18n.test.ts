import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { normalizeUiLanguage, resolveUiLocale } from "./locale";
import { I18nProvider, translateUi, UI_MESSAGE_CATALOGS, useI18n, useUiLanguage } from "./i18n";

describe("UI locale resolution and messages", () => {
  it("keeps legacy and invalid preferences Chinese and honors explicit choices", () => {
    for (const value of [undefined, null, "fr", {}, 3]) expect(normalizeUiLanguage(value)).toBe("zh-CN");
    expect(resolveUiLocale("zh-CN", ["en-US"])).toBe("zh-CN");
    expect(resolveUiLocale("en-US", ["zh-CN"])).toBe("en-US");
  });
  it("follows the first supported system language and uses English when none are supported", () => {
    expect(resolveUiLocale("system", ["fr-FR", "zh-TW", "en-US"])).toBe("zh-CN");
    expect(resolveUiLocale("system", ["en-GB", "zh-CN"])).toBe("en-US");
    expect(resolveUiLocale("system", ["ja-JP"])).toBe("en-US");
    expect(resolveUiLocale("system", [])).toBe("en-US");
  });
  it("preserves every template parameter and rejects conflicting catalog entries", () => {
    const seen = new Map<string, string>();
    const tokens = (value: string) => [...value.matchAll(/\{(\w+)\}/g)].map((match) => match[1]).sort();
    for (const catalog of UI_MESSAGE_CATALOGS) for (const [source, translated] of Object.entries(catalog)) {
      expect(translated.trim(), source).not.toBe("");
      expect(tokens(translated), source).toEqual(tokens(source));
      if (seen.has(source)) expect(translated, source).toBe(seen.get(source));
      seen.set(source, translated);
    }
  });
  it("keeps unknown content and parameter values literal without recursive interpolation", () => {
    for (const source of ["用户原文 / 私人文章.md", "constructor", "__proto__"]) expect(translateUi("en-US", source)).toBe(source);
    const name = "<b>私人文章</b>{name}";
    expect(translateUi("en-US", "已打开：{name}", { name })).toBe(`Opened: ${name}`);
    expect(translateUi("zh-CN", "已打开：{name}", { name })).toBe(`已打开：${name}`);
    expect(translateUi("en-US", "Missing {value}")).toBe("Missing {value}");
  });
});

describe("live locale context", () => {
  let host: HTMLDivElement | undefined;
  let root: ReturnType<typeof createRoot> | undefined;
  afterEach(() => { act(() => root?.unmount()); host?.remove(); root = undefined; host = undefined; vi.restoreAllMocks(); });
  it("updates system language and HTML lang while keeping children mounted", () => {
    let languages = ["zh-CN"];
    vi.spyOn(navigator, "languages", "get").mockImplementation(() => languages);
    function Label() { const { t } = useI18n(); return createElement("input", { "aria-label": t("标题"), defaultValue: "中文原稿" }); }
    function Harness({ preference }: { preference: string }) {
      const { locale } = useUiLanguage(preference);
      return createElement(I18nProvider, { locale, children: createElement(Label) });
    }
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => root!.render(createElement(Harness, { preference: "system" })));
    const input = host.querySelector("input")!;
    input.value = "未保存输入";
    expect(document.documentElement.lang).toBe("zh-CN");
    languages = ["en-US"];
    act(() => window.dispatchEvent(new Event("languagechange")));
    expect(document.documentElement.lang).toBe("en-US");
    expect(host.querySelector("input")).toBe(input);
    expect(input.getAttribute("aria-label")).toBe("Title");
    expect(input.value).toBe("未保存输入");
    act(() => root!.render(createElement(Harness, { preference: "zh-CN" })));
    expect(document.documentElement.lang).toBe("zh-CN");
    expect(host.querySelector("input")).toBe(input);
  });
});
