import { createRoot } from "react-dom/client";
import { act } from "react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import type { DraftComparisonSections } from "../features/writing/draftComparison";
import type { DraftVersionComparison } from "../features/writing/draftHistory";
import { DraftVersionComparisonView } from "./DraftVersionComparisonView";

const value = (lines: DraftVersionComparison["lines"], extra: Partial<DraftVersionComparison> = {}): DraftVersionComparison => ({ addedCount: 1, removedCount: 1, unchangedCount: 1, truncated: false, lines, ...extra });
const comparison: DraftComparisonSections = { full: value([{ kind: "context", text: "raw {name}", currentLine: 1, historicalLine: 1 }, { kind: "added", text: "<b>new</b>", currentLine: 2, historicalLine: null }, { kind: "removed", text: "old", currentLine: null, historicalLine: 2 }, { kind: "context", text: "", currentLine: 3, historicalLine: 3 }]), frontMatter: value([{ kind: "context", text: "raw {name}", currentLine: 1, historicalLine: 1 }, { kind: "added", text: "<b>new</b>", currentLine: 2, historicalLine: null }, { kind: "removed", text: "old", currentLine: null, historicalLine: 2 }], { addedCount: 1, removedCount: 1 }), body: value([{ kind: "context", text: "body", currentLine: 1, historicalLine: 1 }], { addedCount: 0, removedCount: 0 }), fallback: null };
let host: HTMLDivElement; let root: ReturnType<typeof createRoot>;
async function render(valueToRender: DraftComparisonSections = comparison, locale: "zh-CN" | "en-US" = "zh-CN", targetKind: "current" | "version" = "current") { await act(async () => root.render(<I18nProvider locale={locale}><DraftVersionComparisonView comparison={valueToRender} targetKind={targetKind} /></I18nProvider>)); }
beforeEach(() => { Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true }); host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); });

describe("DraftVersionComparisonView", () => {
  it("keeps exact raw lines, empty lines, no-change context, and separate metadata/body ARIA", async () => {
    await render();
    const front = host.querySelector<HTMLPreElement>('[data-label="Front Matter 原文差异"]')!;
    expect(front.textContent).toBe("--- 历史版本\n+++ 当前稿\n raw {name}\n+<b>new</b>\n-old");
    expect(host.querySelector("script, b")).toBeNull();
    expect(front.getAttribute("aria-label")).toBe("Front Matter 原文统一差异");
    expect(host.querySelector('[aria-labelledby]')?.getAttribute("aria-labelledby")).toBe(front.parentElement?.querySelector("h3")?.id);
    const body = host.querySelector<HTMLElement>('[role="table"][data-label="正文差异"]')!;
    expect(body.querySelector("code")?.textContent).toBe("body");
    expect(body.getAttribute("aria-label")).toBe("当前稿与所选版本的统一差异");
    expect(body.closest("section")?.getAttribute("aria-labelledby")).toBe(body.closest("section")?.querySelector("h3")?.id);
    const empty = { ...comparison, body: value([], { addedCount: 0, removedCount: 0, unchangedCount: 0 }) };
    await render(empty); expect(host.querySelector('[data-label="正文差异"]')?.querySelector("code")).toBeNull(); expect(host.querySelectorAll('[role="columnheader"]')).toHaveLength(3);
  });
  it("renders both target header variants and no-Front-Matter section", async () => {
    await render(comparison, "en-US", "version");
    expect(host.querySelector('[data-label="Front Matter source differences"]')?.textContent).toContain("--- Historical version\n+++ Comparison version");
    expect(host.querySelector('[data-label="Front Matter source differences"]')?.getAttribute("aria-label")).toBe("Unified diff of Front Matter source");
    await render({ ...comparison, frontMatter: null });
    expect(host.textContent).toContain("此比较没有 Front Matter。");
    expect(host.querySelector('[data-label="正文差异"]')?.getAttribute("aria-label")).toBe("当前稿与所选版本的统一差异");
  });
  it("keeps truncation text exact and puts malformed full raw diff under the full section", async () => {
    const limited = { ...comparison, full: value([], { truncated: true, addedCount: 8, removedCount: 3 }), frontMatter: null, body: null, fallback: "comparisonLimit" as const };
    await render(limited); expect(host.querySelector("pre")?.textContent).toBe("文稿超出比较上限，已仅显示统计信息。"); expect(host.textContent).toContain("+8 行 · −3 行 · 已截断");
    const malformed = { ...comparison, full: value([{ kind: "context", text: "whole {raw}", currentLine: 1, historicalLine: 1 }]), frontMatter: null, body: null, fallback: "unclosedFrontMatter" as const };
    await render(malformed); expect(host.textContent).toContain("全文差异"); expect(host.textContent).toContain("Front Matter 未闭合"); expect(host.querySelector('[role="table"] code')?.textContent).toBe("whole {raw}"); expect(host.querySelector("pre")).toBeNull();
  });
  it("retains the same nodes and focus across zh/en/zh", async () => {
    await render(); const front = host.querySelector<HTMLPreElement>('[data-label="Front Matter 原文差异"]')!; const body = host.querySelector<HTMLElement>('[data-label="正文差异"]')!; body.focus();
    await render(comparison, "en-US", "version"); expect(host.querySelector('[data-label="Front Matter source differences"]')).toBe(front); expect(host.querySelector('[data-label="Body differences"]')).toBe(body); expect(document.activeElement).toBe(body);
    await render(comparison, "zh-CN", "current"); expect(host.querySelector('[data-label="Front Matter 原文差异"]')).toBe(front); expect(host.querySelector('[data-label="正文差异"]')).toBe(body); expect(document.activeElement).toBe(body);
  });
});
