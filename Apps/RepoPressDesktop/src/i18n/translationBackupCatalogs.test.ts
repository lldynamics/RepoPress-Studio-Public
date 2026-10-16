import { describe, expect, it } from "vitest";
import { createUiTranslator, UI_MESSAGE_CATALOGS } from "./i18n";
import { contentHealthMessages } from "./contentHealthMessages";
import { knowledgeMessages } from "./knowledgeMessages";
import { rssMessages } from "./rssMessages";
import { rssTranslationMessages } from "./rssTranslationMessages";
import { backupPreflightMessages } from "./backupPreflightMessages";
import { workspaceBackupMessages } from "./workspaceBackupMessages";

describe("translation and backup surface catalogs", () => {
  it("preserves canonical shared translations and every template parameter", () => {
    const seen = new Map<string, string>();
    const tokens = (value: string) => [...value.matchAll(/\{(\w+)\}/g)].map(match => match[1]).sort();
    for (const catalog of [...UI_MESSAGE_CATALOGS, contentHealthMessages, knowledgeMessages, rssMessages, rssTranslationMessages, backupPreflightMessages, workspaceBackupMessages]) {
      for (const [source, translated] of Object.entries(catalog)) {
        expect(translated.trim(), source).not.toBe("");
        expect(tokens(translated), source).toEqual(tokens(source));
        if (seen.has(source)) expect(translated, source).toBe(seen.get(source));
        seen.set(source, translated);
      }
    }
    for (const catalog of [rssTranslationMessages, backupPreflightMessages, workspaceBackupMessages]) expect(UI_MESSAGE_CATALOGS).not.toContain(catalog);
  });

  it("substitutes raw parameters once while using a scoped English catalog", () => {
    const t = createUiTranslator("en-US", workspaceBackupMessages);
    expect(t("已导出并核验本地资料 JSON 文件：{path}；大小：{bytes} 字节；SHA-256：{sha}。", { path: "/tmp/设置-{bytes}.json", bytes: "1,234", sha: "报告 {path}" }))
      .toBe("Exported and verified the local knowledge JSON file: /tmp/设置-{bytes}.json; size: 1,234 bytes; SHA-256: 报告 {path}.");
  });
});
