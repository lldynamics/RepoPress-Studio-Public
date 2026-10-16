import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { I18nProvider, UI_MESSAGE_CATALOGS } from "../i18n/i18n";
import { articleStateMessages } from "../i18n/articleStateMessages";
import type { ArticleStateContext, ArticleStateProjection } from "../contracts/articleState";
import { ArticleStatePanel } from "./ArticleStatePanel";

const context = { kind: "generalDraft", draftId: "draft-1", writable: true } as ArticleStateContext;
const projection: ArticleStateProjection = { state: "draft", scope: "generalDraft", online: "unverified", readOnly: false, limited: false, date: { kind: "absent", value: "", epochMs: null }, checkedAtEpochMs: 1_700_000_000_000, issues: [{ code: "titleMissing", severity: "warning", location: { kind: "field", field: "title" } }] };
const projector = vi.hoisted(() => vi.fn(() => projection));

vi.mock("../features/writing/articleState", () => ({ projectArticleState: projector }));

describe("ArticleStatePanel", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  let host: HTMLDivElement | undefined;
  let root: ReturnType<typeof createRoot> | undefined;
  afterEach(() => { act(() => root?.unmount()); host?.remove(); host = undefined; root = undefined; projector.mockClear(); vi.restoreAllMocks(); });

  it("is read-only and binds locate to the current value and context key", () => {
    const onLocate = vi.fn(); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => root!.render(createElement(ArticleStatePanel, { value: "title: x", context, contextKey: "k1", onLocate })));
    expect(host.querySelector("input, textarea, select")).toBeNull();
    const button = host.querySelector("button[aria-label^='定位问题']") as HTMLButtonElement;
    act(() => button.click());
    expect(onLocate).toHaveBeenCalledWith({ kind: "field", field: "title" }, "title: x", "k1");
  });

  it("hides while inactive and renders compact general-draft ownership", () => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => root!.render(createElement(ArticleStatePanel, { value: "x", context, contextKey: "k", active: false })));
    expect(host.textContent).toBe("");
    act(() => root!.render(createElement(ArticleStatePanel, { value: "x", context, contextKey: "k", compact: true })));
    expect(host.textContent).toContain("本机通用草稿");
    expect(host.textContent).not.toContain("查看站点");
  });

  it("keeps the mounted DOM node through a language change", () => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => root!.render(createElement(I18nProvider, { locale: "zh-CN", children: createElement(ArticleStatePanel, { value: "x", context, contextKey: "k" }) })));
    const section = host.querySelector("section"); const refresh = host.querySelector<HTMLButtonElement>("button"); refresh?.focus();
    act(() => root!.render(createElement(I18nProvider, { locale: "en-US", children: createElement(ArticleStatePanel, { value: "x", context, contextKey: "k" }) })));
    expect(host.querySelector("section")).toBe(section);
    expect(document.activeElement).toBe(refresh);
    expect(host.textContent).toContain("Article state");
  });

  it("only samples the clock on projection inputs or an explicit refresh", () => {
    host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    let clock = 0; vi.spyOn(Date, "now").mockImplementation(() => ++clock);
    act(() => root!.render(createElement(ArticleStatePanel, { value: "x", context, contextKey: "k", onLocate: vi.fn() })));
    expect(projector).toHaveBeenCalledTimes(1);
    act(() => root!.render(createElement(ArticleStatePanel, { value: "x", context, contextKey: "k", onLocate: vi.fn() })));
    expect(projector).toHaveBeenCalledTimes(1);
    act(() => host!.querySelector<HTMLButtonElement>("button")!.click());
    const calls = projector.mock.calls as unknown as unknown[][];
    const firstInput = calls[0]?.[0] as { nowEpochMs: number } | undefined;
    const secondInput = calls[1]?.[0] as { nowEpochMs: number } | undefined;
    expect(projector).toHaveBeenCalledTimes(2); expect(secondInput!.nowEpochMs).toBeGreaterThan(firstInput!.nowEpochMs);
  });

  it("reprojects on value or context key changes and blocks disabled location", () => {
    const onLocate = vi.fn(); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => root!.render(createElement(ArticleStatePanel, { value: "a", context, contextKey: "k", disabled: true, onLocate })));
    act(() => host!.querySelector<HTMLButtonElement>("button[aria-label^='定位问题']")!.click());
    expect(onLocate).not.toHaveBeenCalled(); expect(projector).toHaveBeenCalledTimes(1);
    act(() => root!.render(createElement(ArticleStatePanel, { value: "b", context, contextKey: "k2", onLocate })));
    expect(projector).toHaveBeenCalledTimes(2);
  });

  it("does not diverge from shared translations when a message key is reused", () => {
    const tokens = (value: string) => [...value.matchAll(/\{(\w+)\}/g)].map((match) => match[1]).sort();
    for (const catalog of UI_MESSAGE_CATALOGS) {
      for (const [source, translated] of Object.entries(catalog)) {
        if (!(source in articleStateMessages)) continue;
        expect(articleStateMessages[source], source).toBe(translated);
        expect(tokens(articleStateMessages[source]), source).toEqual(tokens(translated));
      }
    }
  });
});
