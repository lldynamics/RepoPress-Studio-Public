import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { describe, expect, it } from "vitest";
import { createUiTranslator, I18nProvider, UI_MESSAGE_CATALOGS, useI18n } from "./i18n";
import { contentHealthMessages } from "./contentHealthMessages";
import { knowledgeMessages } from "./knowledgeMessages";
import { rssMessages } from "./rssMessages";
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

describe("lazy surface catalogs", () => {
  it("keeps shared and surface catalog values and tokens consistent", () => {
    const seen = new Map<string, string>();
    const tokens = (value: string) => [...value.matchAll(/\{(\w+)\}/g)].map(match => match[1]).sort();
    for (const catalog of [...UI_MESSAGE_CATALOGS, contentHealthMessages, knowledgeMessages, rssMessages]) for (const [source, translated] of Object.entries(catalog)) {
      expect(translated.trim(), source).not.toBe(""); expect(tokens(translated), source).toEqual(tokens(source));
      if (seen.has(source)) expect(translated, source).toBe(seen.get(source)); seen.set(source, translated);
    }
    expect(UI_MESSAGE_CATALOGS).not.toContain(contentHealthMessages); expect(UI_MESSAGE_CATALOGS).not.toContain(knowledgeMessages); expect(UI_MESSAGE_CATALOGS).not.toContain(rssMessages);
  });

  it("memoizes scoped translators and retains mounted inputs while using shared fallback and literal parameters", () => {
    const inherited = Object.assign(Object.create({ constructor: "bad", inherited: "bad" }) as Record<string, string>, { "本地 {value}": "Local {value}" });
    const host = document.createElement("div"); document.body.append(host); const root = createRoot(host);
    const translators: ReturnType<typeof createUiTranslator>[] = [];
    function Input() { const { t } = useI18n(inherited); translators.push(t); return createElement("input", { "aria-label": t("本地 {value}", { value: "标题 {value}" }), defaultValue: "原始值" }); }
    const render = (locale: "zh-CN" | "en-US") => act(() => root.render(createElement(I18nProvider, { locale, children: createElement(Input) })));
    try {
      render("zh-CN"); const input = host.querySelector("input")!; input.value = "未保存 {value}";
      render("zh-CN"); expect(translators[0]).toBe(translators[1]); render("en-US");
      expect(host.querySelector("input")).toBe(input); expect(input.value).toBe("未保存 {value}"); expect(input.getAttribute("aria-label")).toBe("Local 标题 {value}");
      const t = translators[translators.length - 1]; expect(t("标题")).toBe("Title"); expect(t("constructor")).toBe("constructor"); expect(t("__proto__")).toBe("__proto__"); expect(t("inherited")).toBe("inherited");
      render("en-US"); expect(translators[translators.length - 1]).toBe(t); render("zh-CN"); expect(input.value).toBe("未保存 {value}");
    } finally { act(() => root.unmount()); host.remove(); }
  });
});
