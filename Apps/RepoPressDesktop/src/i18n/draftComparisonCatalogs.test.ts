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
import { writingBuiltinSnippetMessages } from "./writingBuiltinSnippetMessages";
import { slashMenuMessages } from "./slashMenuMessages";
import { snippetLibraryMessages } from "./snippetLibraryMessages";
import { writingDialogsMessages } from "./writingDialogsMessages";

import { internalLinkMessages } from "./internalLinkMessages";
import { ssgComponentMessages } from "./ssgComponentMessages";

import { draftHistoryMessages } from "./draftHistoryMessages";
import { generalDraftMessages } from "./generalDraftMessages";
import { chineseTypographyMessages } from "./chineseTypographyMessages";

import { draftComparisonMessages } from "./draftComparisonMessages";

describe("draft comparison scoped catalogs", () => {
  it("keeps shared translations and parameters consistent without eager global registration", () => {
    const seen = new Map<string, string>();
    const tokens = (value: string) => [...value.matchAll(/\{(\w+)\}/g)].map(match => match[1]).sort();
    const previous = [writingBuiltinSnippetMessages, slashMenuMessages, snippetLibraryMessages, writingDialogsMessages, internalLinkMessages, ssgComponentMessages];
    const added = [draftHistoryMessages, generalDraftMessages, chineseTypographyMessages, draftComparisonMessages];
    for (const catalog of [...UI_MESSAGE_CATALOGS, contentHealthMessages, knowledgeMessages, rssMessages, rssTranslationMessages, backupPreflightMessages, workspaceBackupMessages, knowledgePackageMessages, lifecycleDialogMessages, siteProfileMessages, knowledgeStageMessages, knowledgeCandidateMessages, editingMenuMessages, ...previous, ...added]) {
      for (const [source, translated] of Object.entries(catalog)) {
        expect(translated.trim(), source).not.toBe("");
        expect(tokens(translated), source).toEqual(tokens(source));
        if (seen.has(source)) expect(translated, source).toBe(seen.get(source));
        seen.set(source, translated);
      }
    }
    for (const catalog of added) expect(UI_MESSAGE_CATALOGS).not.toContain(catalog);
  });
});
