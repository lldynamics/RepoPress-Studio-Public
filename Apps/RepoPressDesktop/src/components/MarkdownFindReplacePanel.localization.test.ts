import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createUiTranslator, I18nProvider } from "../i18n/i18n";
import { MarkdownFindReplacePanel, type MarkdownFindReplacePanelProps } from "./MarkdownFindReplacePanel";
import { localizeFindError } from "./findPresentation";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

class LocalizationWorker {
  static mode: "respond" | "never" = "respond";
  static terminated = 0;
  static posted = 0;
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null;
  onerror: (() => void) | null = null;
  onmessageerror: (() => void) | null = null;

  terminate() { LocalizationWorker.terminated += 1; }

  postMessage(request: { requestId: number; kind: string; text: string; query: string; replacement?: string }) {
    LocalizationWorker.posted += 1;
    if (LocalizationWorker.mode === "never") return;
    const matches: Array<{ from: number; to: number }> = [];
    let at = request.text.indexOf(request.query);
    while (request.query && at >= 0) {
      matches.push({ from: at, to: at + request.query.length });
      at = request.text.indexOf(request.query, at + request.query.length);
    }
    queueMicrotask(() => this.onmessage?.({ data: request.kind === "preview"
      ? { requestId: request.requestId, error: null, matches, proposedText: request.text.split(request.query).join(request.replacement ?? ""), replacementCount: matches.length }
      : { requestId: request.requestId, error: null, matches } } as MessageEvent));
  }
}

let root: Root | null = null;
let host: HTMLDivElement | null = null;

afterEach(() => {
  if (root) act(() => root?.unmount());
  root = null;
  host?.remove();
  host = null;
  LocalizationWorker.mode = "respond";
  LocalizationWorker.terminated = 0;
  LocalizationWorker.posted = 0;
  vi.unstubAllGlobals();
});

function render(locale: "zh-CN" | "en-US", props: MarkdownFindReplacePanelProps) {
  if (!host) {
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
  }
  act(() => root?.render(createElement(I18nProvider, {
    locale,
    children: createElement(MarkdownFindReplacePanel, props),
  })));
}

async function setInput(element: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
  await act(async () => {
    setter?.call(element, value);
    element.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

async function setSelect(element: HTMLSelectElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value")?.set;
  await act(async () => {
    setter?.call(element, value);
    element.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

function button(label: string) {
  const found = [...host!.querySelectorAll<HTMLButtonElement>("button")].find((node) => node.textContent === label);
  if (!found) throw new Error(`Missing button ${label}`);
  return found;
}

describe("MarkdownFindReplacePanel localization", () => {
  it("translates a controlled Front Matter issue without allowing a body operation", async () => {
    vi.stubGlobal("Worker", LocalizationWorker);
    const value = "---\ntitle: one\ntitle: two\n---\n标题";
    const props: MarkdownFindReplacePanelProps = {
      value,
      selection: { from: value.length, to: value.length },
      documentKey: "doc:invalid-front-matter",
      onChange: vi.fn(),
    };
    render("zh-CN", props);
    const inputs = host!.querySelectorAll<HTMLInputElement>("input");
    await setInput(inputs[0], "标题");
    await setInput(inputs[1], "设置");
    act(() => button("预览全部替换").click());
    expect(host!.querySelector(".markdown-writing-find-status")?.textContent)
      .toBe("无法确认正文范围：Front Matter 字段 title 重复，已保留原始文本");
    expect(host!.querySelector("[role='dialog']")).toBeNull();
    expect(LocalizationWorker.posted).toBe(0);
    expect(props.onChange).not.toHaveBeenCalled();

    render("en-US", props);
    expect(host!.querySelector(".markdown-writing-find-status")?.textContent)
      .toBe("Body scope could not be confirmed: Front Matter Field title is duplicated; the original text was preserved");
    act(() => button("Replace").click());
    expect(LocalizationWorker.posted).toBe(0);
    expect(props.onChange).not.toHaveBeenCalled();

    render("zh-CN", props);
    expect(host!.querySelector(".markdown-writing-find-status")?.textContent)
      .toBe("无法确认正文范围：Front Matter 字段 title 重复，已保留原始文本");
  });

  it("renders stored match scope from its source template after a locale switch", async () => {
    vi.stubGlobal("Worker", LocalizationWorker);
    const value = "标题 标题";
    const props: MarkdownFindReplacePanelProps = {
      value,
      selection: { from: 0, to: value.length },
      documentKey: "doc:scope-locale",
      onChange: vi.fn(),
      onLocate: vi.fn(),
    };
    render("zh-CN", props);
    await setInput(host!.querySelectorAll<HTMLInputElement>("input")[0], "标题");
    await setSelect(host!.querySelector("select")!, "selection");
    await act(async () => { button("下一处").click(); await Promise.resolve(); });
    expect(host!.querySelector(".markdown-writing-find-status")?.textContent).toBe("已回绕，1/2 处 · 仅选区");

    render("en-US", props);
    expect(host!.querySelector(".markdown-writing-find-status")?.textContent).toBe("Wrapped, 1/2 · Selection only");
  });

  it("preserves inputs, options, frozen scope, in-flight work, and a valid preview across locale changes", async () => {
    vi.stubGlobal("Worker", LocalizationWorker);
    LocalizationWorker.mode = "never";
    const value = "外部 标题 标题 外部";
    const selected = value.indexOf("标题");
    const props: MarkdownFindReplacePanelProps = {
      value,
      selection: { from: selected, to: selected + "标题 标题".length },
      documentKey: "doc:locale",
      onChange: vi.fn(),
    };
    render("zh-CN", props);
    const inputs = host!.querySelectorAll<HTMLInputElement>("input");
    await setInput(inputs[0], "标题");
    await setInput(inputs[1], "设置");
    act(() => { inputs[2].click(); inputs[3].click(); });
    await setSelect(host!.querySelector("select")!, "selection");
    act(() => button("下一处").click());
    expect(host!.querySelector(".markdown-writing-find-status")?.textContent).toBe("正在查找…");

    render("en-US", props);
    expect(LocalizationWorker.terminated).toBe(0);
    expect((host!.querySelectorAll("input")[0] as HTMLInputElement).value).toBe("标题");
    expect((host!.querySelectorAll("input")[1] as HTMLInputElement).value).toBe("设置");
    expect((host!.querySelectorAll("input")[2] as HTMLInputElement).checked).toBe(true);
    expect((host!.querySelectorAll("input")[3] as HTMLInputElement).checked).toBe(true);
    expect((host!.querySelector("select") as HTMLSelectElement).value).toBe("selection");
    expect(host!.querySelector(".markdown-writing-find-status")?.textContent).toBe("Finding…");

    LocalizationWorker.mode = "respond";
    await act(async () => { button("Preview all replacements").click(); await Promise.resolve(); });
    const dialog = host!.querySelector<HTMLElement>("[role='dialog']")!;
    expect(dialog.getAttribute("aria-label")).toBe("Replace all preview");
    const previewText = dialog.querySelectorAll("pre");
    expect(previewText[0].textContent).toBe("标题 标题");
    expect(previewText[1].textContent).toBe("设置 设置");

    render("zh-CN", props);
    expect(host!.querySelector("[role='dialog']")).toBe(dialog);
    expect(dialog.getAttribute("aria-label")).toBe("全部替换预览");
    expect(dialog.querySelectorAll("pre")[0].textContent).toBe("标题 标题");
    expect(dialog.querySelectorAll("pre")[1].textContent).toBe("设置 设置");

    render("en-US", { ...props, value: `${value} changed` });
    expect(host!.querySelector("[role='dialog']")).toBeNull();
    expect(props.onChange).not.toHaveBeenCalled();
  });

  it("localizes only explicit known errors and preserves unknown text", () => {
    const t = createUiTranslator("en-US");
    expect(localizeFindError("范围超过 262,144 个 UTF-16 字符，无法安全预览。", t))
      .toBe("The scope exceeds 262,144 UTF-16 code units and cannot be previewed safely.");
    expect(localizeFindError("查找工作线程不可用，已拒绝本次操作。", t))
      .toBe("The find worker is unavailable, so this operation was refused.");
    expect(localizeFindError("来自未知来源的原始错误", t)).toBe("来自未知来源的原始错误");
  });

  it("keeps read-only replacement controls disabled in English", async () => {
    vi.stubGlobal("Worker", LocalizationWorker);
    render("en-US", { value: "标题", selection: { from: 0, to: 0 }, readOnly: true, onChange: vi.fn() });
    const inputs = host!.querySelectorAll<HTMLInputElement>("input");
    await setInput(inputs[0], "标题");
    expect(inputs[1].disabled).toBe(true);
    expect(inputs[1].placeholder).toBe("This read-only document cannot be changed");
    expect(button("Replace").disabled).toBe(true);
    expect(button("Preview all replacements").disabled).toBe(true);
  });
});
