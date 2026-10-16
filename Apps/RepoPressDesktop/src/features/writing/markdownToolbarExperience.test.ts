import { describe, expect, it } from "vitest";
import { DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS, filterMarkdownShortcuts, MARKDOWN_FORMAT_COMMANDS, MARKDOWN_SHORTCUT_CATALOG, moveMarkdownToolbarItem, normalizeMarkdownToolbarItemIds, planMarkdownToolbarCustomizationItems, planMarkdownToolbarFormatLayout, planMarkdownToolbarFormats, planMarkdownToolbarResponsiveLayout, toggleMarkdownToolbarItem } from "./markdownToolbarExperience";
import type { MarkdownFormat } from "./markdownWriting";

describe("markdown shortcut catalog", () => {
  it("contains only the shortcuts currently wired by the editor", () => {
    expect(MARKDOWN_SHORTCUT_CATALOG.map((item) => item.id)).toEqual([
      "save", "open-repository", "new-draft", "find", "repository-search", "editor-focus", "go-to-line", "publish", "command-palette", "bold", "italic", "slash-menu", "table-forward", "table-backward",
    ]);
  });

  it("filters labels, details, shortcut notation, and alternate keywords", () => {
    expect(filterMarkdownShortcuts("  TAB ").map((item) => item.id)).toEqual(["table-forward", "table-backward"]);
    expect(filterMarkdownShortcuts("仓库").map((item) => item.id)).toEqual(["open-repository", "repository-search"]);
    expect(filterMarkdownShortcuts("")).toHaveLength(MARKDOWN_SHORTCUT_CATALOG.length);
    expect(filterMarkdownShortcuts("not a shortcut")).toEqual([]);
  });
});

describe("markdown toolbar density planner", () => {
  it("keeps basic mode compact and frequent", () => {
    expect(planMarkdownToolbarFormats("basic")).toEqual(["heading", "bold", "italic", "unorderedList", "link"]);
    expect(planMarkdownToolbarFormats("basic", DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS)).toEqual(["heading", "bold", "italic", "unorderedList", "link"]);
  });
  it("makes every MarkdownFormat reachable in professional mode", () => {
    const allFormats = MARKDOWN_FORMAT_COMMANDS.map((command) => command.format);
    const professional = planMarkdownToolbarFormats("professional");
    expect(new Set(professional)).toEqual(new Set<MarkdownFormat>(allFormats));
    expect(professional).toHaveLength(allFormats.length);
  });
  it("keeps high frequency commands direct and routes overflow to reachable menus", () => {
    const plan = planMarkdownToolbarResponsiveLayout("basic", DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS, 360);
    expect(plan.direct).toEqual(["heading"]);
    expect(new Set([...plan.direct, ...plan.insert, ...plan.format])).toEqual(new Set(DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS));
    expect(plan.insert).toContain("codeBlock");
  });
  it("uses a safe width when ResizeObserver has not measured yet", () => {
    const plan = planMarkdownToolbarResponsiveLayout("basic", DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS);
    expect(plan.direct).toEqual(["heading", "bold", "italic", "unorderedList", "link"]);
  });
});

describe("markdown toolbar customization", () => {
  it("uses defaults only for a missing preference and preserves explicit empty preferences", () => {
    expect(normalizeMarkdownToolbarItemIds()).toEqual(DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS);
    expect(normalizeMarkdownToolbarItemIds([])).toEqual([]);
  });

  it("removes unknown and duplicate persisted values without filling hidden commands back in", () => {
    expect(normalizeMarkdownToolbarItemIds(["bold", "unknown", "bold", "link"])).toEqual(["bold", "link"]);
  });

  it("toggles hidden items by removing and appending them", () => {
    expect(toggleMarkdownToolbarItem(["bold", "link"], "bold")).toEqual(["link"]);
    expect(toggleMarkdownToolbarItem(["bold", "link"], "italic")).toEqual(["bold", "link", "italic"]);
  });

  it("moves only enabled items and leaves boundary moves unchanged", () => {
    expect(moveMarkdownToolbarItem(["bold", "link", "italic"], "link", "up")).toEqual(["link", "bold", "italic"]);
    expect(moveMarkdownToolbarItem(["bold", "link"], "bold", "up")).toEqual(["bold", "link"]);
    expect(moveMarkdownToolbarItem(["bold", "link"], "link", "down")).toEqual(["bold", "link"]);
    expect(moveMarkdownToolbarItem(["bold"], "italic", "down")).toEqual(["bold"]);
  });

  it("keeps only enabled frequent formats direct in basic mode, and all enabled formats ordered in professional mode", () => {
    const itemIds: MarkdownFormat[] = ["codeBlock", "bold", "heading", "quote", "link"];
    expect(planMarkdownToolbarFormatLayout("basic", itemIds)).toEqual({ direct: ["bold", "heading", "link"], more: ["codeBlock", "quote"] });
    expect(planMarkdownToolbarFormatLayout("professional", itemIds)).toEqual({ direct: itemIds, more: [] });
  });

  it("never makes hidden items reachable through the basic more menu", () => {
    const plan = planMarkdownToolbarFormatLayout("basic", ["bold", "quote"]);
    expect([...plan.direct, ...plan.more]).toEqual(["bold", "quote"]);
    expect(planMarkdownToolbarFormats("basic", [])).toEqual([]);
  });

  it("places enabled customization rows in draft order before catalog-ordered hidden rows", () => {
    const planned = planMarkdownToolbarCustomizationItems(["quote", "bold"]);
    expect(planned.slice(0, 2)).toEqual(["quote", "bold"]);
    expect(planned.slice(2)).toEqual(DEFAULT_MARKDOWN_TOOLBAR_ITEM_IDS.filter((item) => item !== "quote" && item !== "bold"));
  });
});
