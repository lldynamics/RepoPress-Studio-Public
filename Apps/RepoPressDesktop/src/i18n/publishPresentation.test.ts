import { describe, expect, it } from "vitest";
import { createUiTranslator } from "./i18n";
import { publishErrorNotice, publishExpiryMessage, renderPublishNotice } from "./publishPresentation";

describe("local publishing notices", () => {
  const en = createUiTranslator("en-US"), zh = createUiTranslator("zh-CN");
  it("redacts paths before storage and translates only locally created placeholders", () => {
    const notice = publishErrorNotice("无法生成计划：{error}", new Error("标题 /private/article.md，设置 C:\\private\\draft.md"));
    expect(JSON.stringify(notice)).not.toContain("private");
    expect(renderPublishNotice(notice, zh)).toBe("无法生成计划：标题 [本地文件]，设置 [本地文件]");
    expect(renderPublishNotice(notice, en)).toBe("Unable to create a plan: 标题 [Local file]，设置 [Local file]");
    expect(renderPublishNotice(notice, zh)).toBe("无法生成计划：标题 [本地文件]，设置 [本地文件]");
  });
  it("distinguishes the local fallback from identical backend text", () => {
    expect(renderPublishNotice(publishErrorNotice("无法生成计划：{error}", {}), en)).toBe("Unable to create a plan: Unknown error");
    for (const raw of ["未知错误", "设置 {error}", "[本地文件]"]) {
      expect(renderPublishNotice(publishErrorNotice("无法生成计划：{error}", raw), en)).toBe(`Unable to create a plan: ${raw}`);
    }
  });
  it("uses the existing expiry predicate and renders dates for the selected locale", () => {
    const now = new Date("2030-01-01T00:00:00Z");
    for (const expiresAt of ["bad", now.toISOString(), "2029-01-01T00:00:00Z"]) {
      expect(renderPublishNotice(publishExpiryMessage(expiresAt, "en-US", now), en)).toBe("The plan expired. Create a new plan.");
    }
    const expiry = "2030-01-01T01:00:00Z";
    expect(renderPublishNotice(publishExpiryMessage(expiry, "en-US", now), en)).toBe(`Plan expires at ${new Date(expiry).toLocaleString("en-US")}.`);
  });
});
