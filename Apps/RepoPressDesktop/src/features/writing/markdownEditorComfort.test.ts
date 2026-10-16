import { describe, expect, it } from "vitest";
import {
  DEFAULT_MARKDOWN_EDITOR_COMFORT,
  findMarkdownParagraphLineStarts,
  findMarkdownParagraphRange,
  normalizeMarkdownEditorComfort,
  planMarkdownEditorComfortClass,
} from "./markdownEditorComfort";

describe("Markdown editor comfort", () => {
  it("normalizes bounded layout preferences and safe defaults", () => {
    expect(normalizeMarkdownEditorComfort()).toEqual(DEFAULT_MARKDOWN_EDITOR_COMFORT);
    expect(normalizeMarkdownEditorComfort()).toMatchObject({ lineSpacing: 4, bodyWidth: 820 });
    expect(normalizeMarkdownEditorComfort({ lineSpacing: -2, bodyWidth: 300 })).toMatchObject({ lineSpacing: 0, bodyWidth: 560 });
    expect(normalizeMarkdownEditorComfort({ lineSpacing: 20, bodyWidth: 1400 })).toMatchObject({ lineSpacing: 12, bodyWidth: 1200 });
    expect(normalizeMarkdownEditorComfort({ lineSpacing: Number.NaN, bodyWidth: Number.POSITIVE_INFINITY })).toEqual(DEFAULT_MARKDOWN_EDITOR_COMFORT);
  });

  it("rounds numeric workspace preferences and rejects malformed flags", () => {
    const malformed = {
      lineSpacing: 4.6,
      bodyWidth: 819.5,
      spellCheckEnabled: "true",
      typewriterModeEnabled: 1,
      currentParagraphHighlightEnabled: null,
      warmPaperBackgroundEnabled: "false",
      paragraphSpotlightEnabled: {},
    } as unknown as Partial<typeof DEFAULT_MARKDOWN_EDITOR_COMFORT>;
    expect(normalizeMarkdownEditorComfort(malformed)).toEqual({
      ...DEFAULT_MARKDOWN_EDITOR_COMFORT,
      lineSpacing: 5,
      bodyWidth: 820,
    });
  });

  it("plans no DOM changes unless comfort settings are supplied", () => {
    expect(planMarkdownEditorComfortClass()).toEqual({});
    expect(planMarkdownEditorComfortClass({ lineSpacing: 8, bodyWidth: 720 })).toEqual({
      className: "rp-markdown-editor-comfort",
      style: { "--rp-editor-line-spacing": "8px", "--rp-editor-body-width": "720px" },
    });
    expect(planMarkdownEditorComfortClass({ warmPaperBackgroundEnabled: true })).toMatchObject({
      className: "rp-markdown-editor-comfort rp-markdown-editor-warm-paper",
      style: { "--rp-editor-line-spacing": "4px", "--rp-editor-body-width": "820px" },
    });
    expect(planMarkdownEditorComfortClass({ paragraphSpotlightEnabled: true })).toMatchObject({
      className: "rp-markdown-editor-comfort rp-markdown-editor-paragraph-spotlight",
    });
    expect(planMarkdownEditorComfortClass({ typewriterModeEnabled: true })).toMatchObject({
      className: "rp-markdown-editor-comfort rp-markdown-editor-typewriter",
    });
  });

  it("finds UTF-16 paragraph ranges bounded by blank lines", () => {
    const document = "first line\nsecond 😀 line\n\n第三段\n\n   \nfinal";
    expect(findMarkdownParagraphRange(document, document.indexOf("😀") + 1)).toEqual({ from: 0, to: 25 });
    expect(findMarkdownParagraphRange(document, document.indexOf("第三"))).toEqual({ from: 27, to: 30 });
    expect(findMarkdownParagraphRange(document, document.indexOf("   "))).toBeNull();
    expect(findMarkdownParagraphRange(document, -10)).toEqual({ from: 0, to: 25 });
    expect(findMarkdownParagraphRange(document, document.length + 10)).toEqual({ from: 36, to: 41 });
    expect(findMarkdownParagraphLineStarts(document, { from: 0, to: 25 })).toEqual([0, 11]);
    expect(findMarkdownParagraphLineStarts(document, { from: 27, to: 30 })).toEqual([27]);
  });
});
