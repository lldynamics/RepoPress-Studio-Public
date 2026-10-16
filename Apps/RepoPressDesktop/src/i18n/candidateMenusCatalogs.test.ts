import { describe, expect, it } from "vitest";
import { UI_MESSAGE_CATALOGS } from "./i18n";
import { contentHealthMessages } from "./contentHealthMessages";
import { knowledgeMessages } from "./knowledgeMessages";
import { rssMessages } from "./rssMessages";
import { rssTranslationMessages } from "./rssTranslationMessages";
import { backupPreflightMessages } from "./backupPreflightMessages";
import { workspaceBackupMessages } from "./workspaceBackupMessages";
import { knowledgePackageMessages } from "./knowledgePackageMessages";
import { lifecycleDialogMessages } from "./lifecycleDialogMessages";
import { siteProfileMessages } from "./siteProfileMessages";
import { knowledgeStageMessages } from "./knowledgeStageMessages";
import { knowledgeCandidateMessages } from "./knowledgeCandidateMessages";
import { editingMenuMessages } from "./editingMenuMessages";

describe("candidate and editing menu scoped catalogs", () => {
  it("keeps every shared translation and template parameter consistent without adding eager catalogs", () => {
    const seen = new Map<string, string>();
    const tokens = (value: string) => [...value.matchAll(/\{(\w+)\}/g)].map(match => match[1]).sort();
    for (const catalog of [...UI_MESSAGE_CATALOGS, contentHealthMessages, knowledgeMessages, rssMessages, rssTranslationMessages, backupPreflightMessages, workspaceBackupMessages, knowledgePackageMessages, lifecycleDialogMessages, siteProfileMessages, knowledgeStageMessages, knowledgeCandidateMessages, editingMenuMessages]) {
      for (const [source, translated] of Object.entries(catalog)) {
        expect(translated.trim(), source).not.toBe("");
        expect(tokens(translated), source).toEqual(tokens(source));
        if (seen.has(source)) expect(translated, source).toBe(seen.get(source));
        seen.set(source, translated);
      }
    }
    for (const catalog of [knowledgeStageMessages, knowledgeCandidateMessages, editingMenuMessages]) expect(UI_MESSAGE_CATALOGS).not.toContain(catalog);
  });
});
