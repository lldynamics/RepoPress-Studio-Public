import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { DraftComparisonSections } from "../features/writing/draftComparison";
import type { DraftDiffLine, DraftVersionComparison } from "../features/writing/draftHistory";
import { I18nProvider } from "../i18n/i18n";
import { DraftVersionComparisonView } from "./DraftVersionComparisonView";

const diff = (lines: DraftDiffLine[], extra: Partial<DraftVersionComparison> = {}): DraftVersionComparison => ({
  lines,
  addedCount: lines.filter((line) => line.kind === "added").length,
  removedCount: lines.filter((line) => line.kind === "removed").length,
  unchangedCount: lines.filter((line) => line.kind === "context").length,
  truncated: false,
  ...extra,
});

const sections = (body: DraftVersionComparison): DraftComparisonSections => ({ full: body, body, frontMatter: null, fallback: null });
const context = (text: string, historicalLine: number, currentLine = historicalLine): DraftDiffLine => ({ kind: "context", text, historicalLine, currentLine });
const rawLines: DraftDiffLine[] = [
  context("raw {name} <script>alert('x')</script>", 19, 23),
  { kind: "removed", text: "当前稿行 {historicalLine} <b>old</b>", historicalLine: 20, currentLine: null },
  { kind: "added", text: "来源行 {currentLine} <img src=x onerror=alert(1)>", historicalLine: null, currentLine: 24 },
  context("", 21, 25),
];
const foldFixture = (): DraftComparisonSections => sections(diff([
  ...Array.from({ length: 10 }, (_, index) => context(`before ${index + 1}`, index + 1)),
  { kind: "added", text: "changed {count}", historicalLine: null, currentLine: 11 },
  ...Array.from({ length: 11 }, (_, index) => context(`after ${index + 1}`, index + 11, index + 12)),
]));

let host: HTMLDivElement;
let root: ReturnType<typeof createRoot>;
async function render(comparison: DraftComparisonSections, locale: "zh-CN" | "en-US" = "zh-CN", targetKind: "current" | "version" = "current") {
  await act(async () => root.render(<I18nProvider locale={locale}><DraftVersionComparisonView comparison={comparison} targetKind={targetKind} /></I18nProvider>));
}
function table(): HTMLElement {
  const result = host.querySelector<HTMLElement>('[role="table"]');
  expect(result).not.toBeNull();
  return result!;
}
function dataRows(includeHidden = false): HTMLElement[] {
  return Array.from(table().querySelectorAll<HTMLElement>('[role="row"]')).filter((row) => row.querySelector("code.draft-version-comparison__text") && (includeHidden || !row.closest('[hidden]')));
}
function contents(includeHidden = false): string[] {
  return dataRows(includeHidden).map((row) => row.querySelector(".draft-version-comparison__text")!.textContent!);
}
function button(label: string): HTMLButtonElement {
  const result = Array.from(host.querySelectorAll("button")).find((element) => element.textContent === label);
  expect(result, label).toBeDefined();
  return result!;
}
function foldButtons(): HTMLButtonElement[] {
  return Array.from(host.querySelectorAll<HTMLButtonElement>("button[aria-controls][aria-expanded]"));
}
function controlledGroup(control: HTMLButtonElement): HTMLElement {
  const id = control.getAttribute("aria-controls");
  expect(id).toBeTruthy();
  const result = document.getElementById(id!);
  expect(result).not.toBeNull();
  expect(result!.getAttribute("role")).toBe("rowgroup");
  expect(table().contains(result)).toBe(true);
  return result!;
}
async function click(control: HTMLButtonElement) { await act(async () => control.click()); }

beforeEach(() => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
});
afterEach(() => { act(() => root.unmount()); host.remove(); });

describe("DraftVersionComparisonView mounted numbered rows", () => {
  it("maps source and target numbers without filling nulls and preserves every literal line", async () => {
    const comparison = sections(diff(rawLines));
    const untouched = JSON.stringify(comparison);
    await render(comparison, "en-US");
    expect(table().tabIndex).toBe(0);
    expect(Array.from(table().querySelectorAll('[role="columnheader"]'), (header) => header.textContent)).toEqual(["Source line", "Current draft line", "Diff content"]);
    expect(contents()).toEqual(rawLines.map((line) => line.text));
    const rows = dataRows();
    rows.forEach((row, index) => {
      const cells = Array.from(row.querySelectorAll('[role="cell"]'));
      expect(cells).toHaveLength(3);
      expect(cells[0].textContent).toBe(rawLines[index].historicalLine === null ? "" : String(rawLines[index].historicalLine));
      expect(cells[1].textContent).toBe(rawLines[index].currentLine === null ? "" : String(rawLines[index].currentLine));
      expect(cells[2].querySelector('[aria-hidden="true"]')?.textContent).toBe(rawLines[index].kind === "added" ? "+" : rawLines[index].kind === "removed" ? "-" : " ");
      expect(cells[2].querySelector("code.draft-version-comparison__text")?.textContent).toBe(rawLines[index].text);
    });
    expect(rows[1].getAttribute("aria-label")).toContain("20");
    expect(rows[1].getAttribute("aria-label")).toContain(rawLines[1].text);
    expect(rows[2].getAttribute("aria-label")).toContain("24");
    expect(rows[2].getAttribute("aria-label")).toContain(rawLines[2].text);
    expect(host.querySelector("script, b, img, input, textarea, [contenteditable=true], [aria-live], [role=status], [role=alert]")).toBeNull();
    expect(JSON.stringify(comparison)).toBe(untouched);
  });

  it("keeps Front Matter escaped in its own pre and body rows in a labelled section", async () => {
    const body = diff(rawLines);
    const comparison = { ...sections(body), frontMatter: diff([context("---", 1), context("title: 当前稿行 {name} <b>literal</b>", 2), context("---", 3)]) };
    await render(comparison);
    const pre = host.querySelector("pre")!;
    expect(pre.textContent).toBe("--- 历史版本\n+++ 当前稿\n ---\n title: 当前稿行 {name} <b>literal</b>\n ---");
    expect(pre.getAttribute("aria-label")).toBe("Front Matter 原文统一差异");
    const metadataSection = pre.closest("section")!;
    expect(metadataSection.getAttribute("aria-labelledby")).toBe(metadataSection.querySelector("h3")?.id);
    expect(metadataSection.querySelector("h3")?.textContent).toBe("Front Matter 原文差异");
    const bodySection = table().closest("section")!;
    expect(bodySection.getAttribute("aria-labelledby")).toBe(bodySection.querySelector("h3")?.id);
    expect(bodySection.querySelector("h3")?.textContent).toBe("正文差异");
    expect(table().getAttribute("aria-label")).toBe("当前稿与所选版本的统一差异");
    expect(host.querySelectorAll('[role="table"]')).toHaveLength(1);
    expect(host.querySelector("b")).toBeNull();
  });

  it("renders short unchanged and empty bodies with headers and no fold controls", async () => {
    await render(sections(diff([context("unchanged {name}", 4, 9), context("", 5, 10)])));
    expect(contents()).toEqual(["unchanged {name}", ""]);
    expect(host.querySelector("button")).toBeNull();
    await render(sections(diff([])));
    expect(dataRows()).toHaveLength(0);
    expect(table().querySelectorAll('[role="columnheader"]')).toHaveLength(3);
    expect(host.querySelector("button")).toBeNull();
  });

  it("changes the target column and table label for two historical versions", async () => {
    const comparison = sections(diff(rawLines));
    await render(comparison, "en-US", "version");
    expect(Array.from(table().querySelectorAll('[role="columnheader"]'), (header) => header.textContent)).toEqual(["Source line", "Comparison version line", "Diff content"]);
    expect(table().getAttribute("aria-label")).toBe("Unified diff of two historical versions");
    expect(contents()).toEqual(rawLines.map((line) => line.text));
    await render(comparison, "zh-CN", "current");
    expect(Array.from(table().querySelectorAll('[role="columnheader"]'), (header) => header.textContent)).toEqual(["来源行", "当前稿行", "差异内容"]);
    expect(table().getAttribute("aria-label")).toBe("当前稿与所选版本的统一差异");
  });

  it("retains three lines nearest a change and reversibly reveals original hidden rows", async () => {
    const comparison = foldFixture();
    const untouched = JSON.stringify(comparison);
    await render(comparison, "en-US");
    expect(contents()).toEqual(["before 8", "before 9", "before 10", "changed {count}", "after 1", "after 2", "after 3"]);
    const controls = foldButtons();
    expect(controls).toHaveLength(2);
    expect(controls.map((control) => control.textContent)).toEqual(["Show 7 unchanged lines", "Show 8 unchanged lines"]);
    const groups = controls.map(controlledGroup);
    expect(groups[0]).not.toBe(groups[1]);
    expect(groups.every((group) => group.hidden)).toBe(true);
    expect(controls.every((control) => control.getAttribute("aria-expanded") === "false")).toBe(true);
    await click(controls[0]);
    expect(controls[0].getAttribute("aria-expanded")).toBe("true");
    expect(controls[0].textContent).toBe("Hide 7 unchanged lines");
    expect(groups[0].hidden).toBe(false);
    expect(groups[1].hidden).toBe(true);
    expect(contents()).toEqual([...Array.from({ length: 10 }, (_, index) => `before ${index + 1}`), "changed {count}", "after 1", "after 2", "after 3"]);
    expect(dataRows()[0].querySelectorAll('[role="cell"]')[0].textContent).toBe("1");
    expect(dataRows()[0].querySelectorAll('[role="cell"]')[1].textContent).toBe("1");
    await click(controls[0]);
    expect(groups[0].hidden).toBe(true);
    expect(contents()).toHaveLength(7);
    expect(JSON.stringify(comparison)).toBe(untouched);
  });

  it("does not offer a fold for fewer than four hidden context lines", async () => {
    const body = diff([
      ...Array.from({ length: 6 }, (_, index) => context(`before ${index}`, index + 1)),
      { kind: "added", text: "new", historicalLine: null, currentLine: 7 },
      ...Array.from({ length: 6 }, (_, index) => context(`after ${index}`, index + 7, index + 8)),
    ]);
    await render(sections(body));
    expect(contents()).toEqual(body.lines.map((line) => line.text));
    expect(foldButtons()).toHaveLength(0);
    expect(host.querySelector("button")).toBeNull();
  });

  it("offers a fold at the four hidden context line boundary", async () => {
    await render(sections(diff([
      ...Array.from({ length: 7 }, (_, index) => context(`before ${index}`, index + 1)),
      { kind: "added", text: "new", historicalLine: null, currentLine: 8 },
    ])), "en-US");
    expect(foldButtons()).toHaveLength(1);
    expect(foldButtons()[0].textContent).toBe("Show 4 unchanged lines");
    expect(contents()).toEqual(["before 4", "before 5", "before 6", "new"]);
  });

  it("shows and hides both folds globally and disables hide-all when already collapsed", async () => {
    const comparison = foldFixture();
    await render(comparison, "en-US");
    const showAll = button("Show all unchanged lines");
    const hideAll = button("Hide all unchanged lines");
    expect(hideAll.disabled).toBe(true);
    await click(showAll);
    expect(hideAll.disabled).toBe(false);
    expect(foldButtons().every((control) => control.getAttribute("aria-expanded") === "true")).toBe(true);
    expect(contents()).toEqual(comparison.body!.lines.map((line) => line.text));
    const allRows = dataRows();
    const lastCells = allRows[allRows.length - 1].querySelectorAll('[role="cell"]');
    expect(lastCells[0].textContent).toBe("21");
    expect(lastCells[1].textContent).toBe("22");
    await click(hideAll);
    expect(hideAll.disabled).toBe(true);
    expect(foldButtons().every((control) => control.getAttribute("aria-expanded") === "false")).toBe(true);
    expect(contents()).toHaveLength(7);
    await click(foldButtons()[1]);
    expect(hideAll.disabled).toBe(false);
    await click(hideAll);
    expect(hideAll.disabled).toBe(true);
    expect(contents()).toHaveLength(7);
  });

  it("preserves fold controls, focus, expansion, table, and raw text through zh/en/zh", async () => {
    const comparison = foldFixture();
    await render(comparison);
    const initialTable = table();
    const controls = foldButtons();
    const group = controlledGroup(controls[0]);
    const globalControl = button("展开全部未变化内容");
    await click(controls[0]); controls[0].focus();
    await render(comparison, "en-US");
    expect(table()).toBe(initialTable);
    foldButtons().forEach((control, index) => expect(control).toBe(controls[index]));
    expect(button("Show all unchanged lines")).toBe(globalControl);
    expect(controls[0].textContent).toBe("Hide 7 unchanged lines");
    expect(document.activeElement).toBe(controls[0]);
    expect(controlledGroup(controls[0])).toBe(group);
    expect(group.hidden).toBe(false);
    expect(contents()).toContain("changed {count}");
    await render(comparison);
    expect(table()).toBe(initialTable);
    foldButtons().forEach((control, index) => expect(control).toBe(controls[index]));
    expect(button("展开全部未变化内容")).toBe(globalControl);
    expect(controls[0].textContent).toBe("收起 7 行未变化内容");
    expect(controls[0].getAttribute("aria-expanded")).toBe("true");
    expect(document.activeElement).toBe(controls[0]);
    expect(group.hidden).toBe(false);
  });

  it("collapses folds when a new comparison object arrives even with identical diff references", async () => {
    const comparison = foldFixture();
    await render(comparison, "en-US");
    await click(button("Show all unchanged lines"));
    expect(contents()).toHaveLength(22);
    const nextComparison = { ...comparison };
    expect(nextComparison.body).toBe(comparison.body);
    await render(nextComparison, "en-US");
    expect(foldButtons().every((control) => control.getAttribute("aria-expanded") === "false")).toBe(true);
    expect(foldButtons().map(controlledGroup).every((group) => group.hidden)).toBe(true);
    expect(button("Hide all unchanged lines").disabled).toBe(true);
    expect(contents()).toHaveLength(7);
  });

  it("does not revive an old expansion when switching from owner A to B and back to A", async () => {
    const ownerA = foldFixture();
    const ownerB = { ...ownerA };
    await render(ownerA, "en-US");
    await click(button("Show all unchanged lines"));
    expect(contents()).toHaveLength(22);
    await render(ownerB, "en-US");
    expect(contents()).toHaveLength(7);
    await render(ownerA, "en-US");
    expect(foldButtons().every((control) => control.getAttribute("aria-expanded") === "false")).toBe(true);
    expect(foldButtons().map(controlledGroup).every((group) => group.hidden)).toBe(true);
    expect(button("Hide all unchanged lines").disabled).toBe(true);
    expect(contents()).toHaveLength(7);
  });

  it("uses numbered full-document fallback rows for an unclosed preamble", async () => {
    const comparison: DraftComparisonSections = { ...sections(diff(rawLines)), body: null, frontMatter: null, fallback: "unclosedFrontMatter" };
    await render(comparison, "en-US", "version");
    expect(host.querySelector("h3")?.textContent).toBe("Full document differences");
    expect(host.textContent).toContain("Front Matter is unclosed");
    expect(contents()).toEqual(rawLines.map((line) => line.text));
    expect(table().getAttribute("aria-label")).toBe("Unified diff of two historical versions");
    expect(host.querySelector("pre")).toBeNull();
    expect(host.querySelectorAll("section")).toHaveLength(1);
  });

  it("renders only the controlled truncated pre even when a capped fixture contains raw rows", async () => {
    const comparison: DraftComparisonSections = { full: diff(foldFixture().full.lines, { truncated: true, addedCount: 80, removedCount: 40 }), body: null, frontMatter: null, fallback: "comparisonLimit" };
    await render(comparison);
    const pre = host.querySelector("pre")!;
    expect(pre.textContent).toBe("文稿超出比较上限，已仅显示统计信息。");
    expect(pre.getAttribute("aria-label")).toBe("当前稿与所选版本的统一差异");
    expect(host.textContent).toContain("+80 行 · −40 行 · 已截断");
    expect(host.querySelector('[role="table"], [role="row"], button, code')).toBeNull();
    await render(comparison, "en-US", "version");
    expect(host.querySelector("pre")).toBe(pre);
    expect(pre.textContent).toBe("The document exceeds the comparison limit. Only statistics are shown.");
    expect(pre.getAttribute("aria-label")).toBe("Unified diff of two historical versions");
    expect(host.querySelector('[role="table"], button')).toBeNull();
  });
});
