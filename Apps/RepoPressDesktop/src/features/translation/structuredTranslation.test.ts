import { describe, expect, it } from "vitest";
import { buildStructuredTranslation, splitTranslationParagraphs, structuredTranslationText } from "./structuredTranslation";

describe("RSS structured translation", () => {
  it("normalizes CRLF and splits Unicode paragraphs", () => {
    expect(splitTranslationParagraphs("  第一段\r\n\r\n第二段 🌏  ")).toEqual(["第一段", "第二段 🌏"]);
    expect(splitTranslationParagraphs("第一行\r第二行")).toEqual(["第一行", "第二行"]);
  });

  it("aligns exact paragraphs with stable IDs", () => {
    const first = buildStructuredTranslation("第一段\n\n第二段", "译一\n\n译二");
    const second = buildStructuredTranslation("第一段\n\n第二段", "译一\n\n译二");
    expect(first.exactAlignment).toBe(true);
    expect(first.paragraphs.map((item) => item.translatedText)).toEqual(["译一", "译二"]);
    expect(first.paragraphs.map((item) => item.id)).toEqual(second.paragraphs.map((item) => item.id));
  });

  it("conservatively handles missing, extra, and overridden translations", () => {
    const initial = buildStructuredTranslation("one\n\ntwo", "一\n\n二\n\n三");
    const result = buildStructuredTranslation("one\n\ntwo", "一\n\n二\n\n三", { [initial.paragraphs[0].id]: "覆盖" });
    expect(result.exactAlignment).toBe(false);
    expect(result.paragraphs[0].translatedText).toBe("覆盖");
    expect(result.unmatchedTranslations).toEqual(["三"]);
    expect(structuredTranslationText({ ...result, paragraphs: result.paragraphs.map((paragraph, index) => index === 1 ? { ...paragraph, translatedText: null } : paragraph) })).toBe("覆盖\n\ntwo\n\n三");

    const missing = buildStructuredTranslation("one\n\ntwo", "一");
    expect(missing.exactAlignment).toBe(false);
    expect(missing.paragraphs[1].translatedText).toBeNull();
    expect(missing.unmatchedTranslations).toEqual([]);
  });
});
