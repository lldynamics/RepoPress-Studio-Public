import { act, createElement, StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import type { ArticleStateContext } from "../contracts/articleState";
import { ArticleStatePanel } from "./ArticleStatePanel";

const context: ArticleStateContext = { kind: "repository", repository: { sessionId: "s1", siteKind: "hugo", contentRoot: "content" }, documentId: "d1", relativePath: "content/post.md", writable: true };
const source = "---\ntitle: \"A <b>title</b>\"\ndate: 2020-01-01\ndraft: true\n---\n\nbody";
const mountPanel = (props: Record<string, unknown> = {}, locale: "zh-CN" | "en-US" = "zh-CN") => createElement(I18nProvider, { locale, children: createElement(ArticleStatePanel, { value: source, context, contextKey: "k1", onApplyChange: vi.fn(async () => true), ...props }) });

describe("ArticleStatePanel change preview", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  let host: HTMLDivElement | undefined;
  let root: ReturnType<typeof createRoot> | undefined;
  afterEach(() => { act(() => root?.unmount()); host?.remove(); host = undefined; root = undefined; vi.restoreAllMocks(); });
  const setup = (props: Record<string, unknown> = {}, locale: "zh-CN" | "en-US" = "zh-CN") => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); act(() => root!.render(mountPanel(props, locale))); };

  it("cancels without applying and confirms one exact plan", () => {
    const apply = vi.fn(async () => true); setup({ onApplyChange: apply });
    const preview = [...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement;
    act(() => preview.click());
    expect(host!.querySelector('[aria-label="文章状态变更预览"]')).not.toBeNull();
    const cancel = [...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("取消变更")) as HTMLButtonElement;
    act(() => cancel.click());
    expect(apply).not.toHaveBeenCalled();
    act(() => preview.click());
    const confirm = [...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("确认应用")) as HTMLButtonElement;
    act(() => confirm.click());
    expect(apply).toHaveBeenCalledTimes(1);
    expect((apply.mock.calls as unknown as Array<[Record<string, unknown>]>)[0]?.[0]).toMatchObject({ target: "ready", expectedText: source, contextKey: "k1" });
  });

  it("consumes a plan before a slow promise and prevents double apply", async () => {
    let resolve!: (value: boolean) => void; const apply = vi.fn(() => new Promise<boolean>((done) => { resolve = done; })); setup({ onApplyChange: apply });
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement).click());
    const confirm = [...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("确认应用")) as HTMLButtonElement;
    act(() => { confirm.click(); confirm.click(); });
    expect(apply).toHaveBeenCalledTimes(1); resolve(true); await act(async () => { await Promise.resolve(); });
  });

  it("rejects stale text, key, hidden, or disabled plans", () => {
    const apply = vi.fn(async () => true); setup({ onApplyChange: apply });
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement).click());
    act(() => root!.render(mountPanel({ onApplyChange: apply, value: `${source}\nchanged` })));
    expect(host!.querySelector('[aria-label="文章状态变更预览"]')).toBeNull();
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement).click());
    act(() => root!.render(mountPanel({ onApplyChange: apply, contextKey: "k2", disabled: true })));
    expect(host!.querySelector('[aria-label="文章状态变更预览"]')).toBeNull();
    expect(apply).not.toHaveBeenCalled();
  });

  it("has no change entry for general drafts or read-only content", () => {
    setup({ context: { kind: "generalDraft", draftId: "g", writable: true } });
    expect(host!.textContent).not.toContain("预览设为");
    act(() => root!.render(mountPanel({ context: { ...context, writable: false } })));
    expect(host!.textContent).not.toContain("预览设为");
  });

  it("keeps preview and focus across a locale change", () => {
    setup(); const trigger = [...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement;
    act(() => trigger.click()); const heading = host!.querySelector("h3") as HTMLElement; expect(document.activeElement).toBe(heading);
    act(() => root!.render(mountPanel({}, "en-US")));
    expect(host!.querySelector("h3")).toBe(heading); expect(host!.textContent).toContain("Article state change preview"); expect(document.activeElement).toBe(heading);
  });

  it("shows future warnings and escapes raw after-field text", () => {
    vi.spyOn(Date, "now").mockReturnValue(Date.parse("2020-01-01T00:00:00Z"));
    const future = source.replace("2020-01-01", "2099-01-01T00:00:00Z"); setup({ value: future });
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement).click());
    expect(host!.textContent).toContain("日期在未来"); const after = [...host!.querySelectorAll("pre")].find((item) => item.textContent?.includes("false")); expect(after?.textContent).toBe("draft: false\n"); expect(after?.innerHTML).not.toContain("<b>");
  });

  it("does not claim success when apply returns false or throws", async () => {
    for (const onApplyChange of [vi.fn(async () => false), vi.fn(async () => { throw new Error("no"); })]) {
      setup({ onApplyChange }); act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement).click());
      const confirm = [...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("确认应用")) as HTMLButtonElement;
      await act(async () => { confirm.click(); await Promise.resolve(); }); expect(host!.textContent).toContain("请重新预览"); expect(host!.textContent).not.toContain("文章状态已应用"); act(() => root!.unmount()); host!.remove(); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    }
  });

  it("can preview and confirm under StrictMode", () => {
    const apply = vi.fn(async () => true); host = document.createElement("div"); document.body.append(host); root = createRoot(host);
    act(() => root!.render(createElement(StrictMode, { children: mountPanel({ onApplyChange: apply }) })));
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement).click());
    expect(host!.querySelector('[aria-label="文章状态变更预览"]')).not.toBeNull();
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("确认应用")) as HTMLButtonElement).click());
    expect(apply).toHaveBeenCalledTimes(1);
  });

  it("returns focus to the triggering button after requestAnimationFrame cancel", () => {
    const raf = vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => { callback(0); return 0; }); setup();
    const trigger = [...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement;
    act(() => trigger.click());
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("取消变更")) as HTMLButtonElement).click());
    expect(document.activeElement).toBe(trigger); raf.mockRestore();
  });

  it("does not show stale async feedback after text/key change or unmount", async () => {
    let resolve!: (value: boolean) => void; const apply = vi.fn(() => new Promise<boolean>((done) => { resolve = done; })); setup({ onApplyChange: apply });
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement).click());
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("确认应用")) as HTMLButtonElement).click());
    act(() => root!.render(mountPanel({ onApplyChange: apply, value: `${source}\nnew`, contextKey: "k2" }))); resolve(true); await act(async () => { await Promise.resolve(); });
    expect(host!.textContent).not.toContain("文章状态已应用");
    act(() => root!.unmount()); resolve(true); await act(async () => { await Promise.resolve(); });
  });

  it("invalidates a preview while inactive and does not restore it when active", () => {
    setup();
    act(() => ([...host!.querySelectorAll("button")].find((button) => button.textContent?.includes("待发布")) as HTMLButtonElement).click());
    act(() => root!.render(mountPanel({ active: false })));
    expect(host!.textContent).toBe("");
    act(() => root!.render(mountPanel({ active: true })));
    expect(host!.querySelector('[aria-label="文章状态变更预览"]')).toBeNull();
  });
});
