import { describe, expect, it } from "vitest";
import { insertMarkdownImage, insertMarkdownImages } from "./imageInsertion";

describe("insertMarkdownImage", () => {
  it("inserts an imported image and selects its fallback alt text", () => {
    const result = insertMarkdownImage("开头\n", { from: 3, to: 3 }, "/images/2026/示例 图.png", "示例图");

    expect(result.text).toBe("开头\n![示例图](/images/2026/示例%20图.png)");
    expect(result.text.slice(result.selection.from, result.selection.to)).toBe("示例图");
  });

  it("uses the current selection as alt text and replaces only that range", () => {
    const result = insertMarkdownImage("前文 封面图 后文", { from: 3, to: 6 }, "/images/cover.png", "cover");

    expect(result.text).toBe("前文 ![封面图](/images/cover.png) 后文");
    expect(result.text.slice(result.selection.from, result.selection.to)).toBe("封面图");
  });

  it("normalizes a reverse selection before replacing it", () => {
    const result = insertMarkdownImage("前封面后", { from: 3, to: 1 }, "/cover.png", "cover");

    expect(result.text).toBe("前![封面](/cover.png)后");
    expect(result.text.slice(result.selection.from, result.selection.to)).toBe("封面");
  });

  it("escapes alt delimiters and unsafe path punctuation", () => {
    const result = insertMarkdownImage("", { from: -3, to: 99 }, "images/a (1).png", "图]片\\说明");

    expect(result.markdown).toBe("![图\\]片\\\\说明](images/a%20%281%29.png)");
    expect(result.selection).toEqual({ from: 2, to: 10 });
  });
});

describe("insertMarkdownImages", () => {
  const images = [
    { markdownPath: "/images/第一张 图 (1).png", fallbackAlt: "第一张" },
    { markdownPath: "/images/第二张图.png", fallbackAlt: "第二张" },
  ];

  it("returns a no-op for an empty list with a normalized selection", () => {
    const result = insertMarkdownImages("正文", { from: 99, to: -2 }, []);

    expect(result).toEqual({
      text: "正文",
      markdown: "",
      selection: { from: 0, to: 2 },
    });
  });

  it("inserts multiple images on separate lines and selects the first fallback alt", () => {
    const result = insertMarkdownImages("开头\n结尾", { from: 3, to: 3 }, images);

    expect(result.markdown).toBe(
      "![第一张](/images/第一张%20图%20%281%29.png)\n![第二张](/images/第二张图.png)",
    );
    expect(result.text).toBe(`开头\n${result.markdown}结尾`);
    expect(result.text.slice(result.selection.from, result.selection.to)).toBe("第一张");
  });

  it("reuses one non-empty selected alt for every image", () => {
    const result = insertMarkdownImages("前文 封面组 后文", { from: 3, to: 6 }, images);

    expect(result.text).toBe(
      "前文 ![封面组](/images/第一张%20图%20%281%29.png)\n![封面组](/images/第二张图.png) 后文",
    );
    expect(result.markdown.match(/封面组/g)).toHaveLength(2);
    expect(result.text.slice(result.selection.from, result.selection.to)).toBe("封面组");
  });

  it("handles clamped reverse ranges and unsafe alt delimiters", () => {
    const result = insertMarkdownImages(
      "",
      { from: 99, to: -99 },
      [
        { markdownPath: "assets/图 (一)\\封面.png", fallbackAlt: "图]一\\说明" },
        { markdownPath: "assets/第二 图.png", fallbackAlt: "第二" },
      ],
    );

    expect(result.markdown).toBe(
      "![图\\]一\\\\说明](assets/图%20%28一%29/封面.png)\n![第二](assets/第二%20图.png)",
    );
    expect(result.selection).toEqual({ from: 2, to: 10 });
  });
});
