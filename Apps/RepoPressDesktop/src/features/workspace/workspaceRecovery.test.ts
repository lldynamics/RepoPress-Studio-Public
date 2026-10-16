import { describe, expect, it, vi } from "vitest";
import type { RecoveryDraftSnapshot } from "../../contracts/repository";
import { clampEditorFontSize, DEFAULT_WRITING_TOOLBAR_ITEM_IDS, normalizeWorkspacePreferences, RecoveryDraftScheduler, recoveryDraftPreview, recoveryMatch } from "./workspaceRecovery";

const draft: RecoveryDraftSnapshot = { recoveryId: "recovery-1", repositoryPath: "/repo", relativePath: "content/post.md", text: "draft", baselineSha256: "same", savedAtEpochSeconds: 1 };

describe("workspace recovery coordination", () => {
  it("uses safe defaults and clamps editor font size boundaries", () => {
    expect(normalizeWorkspacePreferences(null)).toEqual({ uiLanguage: "zh-CN", theme: "system", editorFontSize: 15, editorLineSpacing: 4, editorBodyWidth: 820, spellCheckEnabled: false, typewriterModeEnabled: false, currentParagraphHighlightEnabled: true, warmPaperBackgroundEnabled: false, automaticPairingEnabled: true, paragraphSpotlightEnabled: false, writingToolDensity: "basic", writingToolbarItemIds: DEFAULT_WRITING_TOOLBAR_ITEM_IDS, restoreLastWorkspace: true, recoveryEnabled: true });
    expect(normalizeWorkspacePreferences({ theme: "unknown", editorFontSize: 12, editorLineSpacing: 99, editorBodyWidth: 1, spellCheckEnabled: "yes", writingToolDensity: "expanded", restoreLastWorkspace: false, recoveryEnabled: false })).toEqual({ uiLanguage: "zh-CN", theme: "system", editorFontSize: 12, editorLineSpacing: 12, editorBodyWidth: 560, spellCheckEnabled: false, typewriterModeEnabled: false, currentParagraphHighlightEnabled: true, warmPaperBackgroundEnabled: false, automaticPairingEnabled: true, paragraphSpotlightEnabled: false, writingToolDensity: "basic", writingToolbarItemIds: DEFAULT_WRITING_TOOLBAR_ITEM_IDS, restoreLastWorkspace: false, recoveryEnabled: false });
    expect(clampEditorFontSize(2)).toBe(12);
    expect(clampEditorFontSize(50)).toBe(28);
    expect(clampEditorFontSize("not-a-number")).toBe(15);
  });

  it("preserves supported language choices without changing existing editor preferences", () => {
    for (const uiLanguage of ["zh-CN", "en-US", "system"]) {
      expect(normalizeWorkspacePreferences({ uiLanguage, theme: "dark", editorFontSize: 21, recoveryEnabled: false })).toMatchObject({ uiLanguage, theme: "dark", editorFontSize: 21, recoveryEnabled: false });
    }
    expect(normalizeWorkspacePreferences({ uiLanguage: "fr" }).uiLanguage).toBe("zh-CN");
  });

  it("falls back for invalid numeric preference types and non-finite values", () => {
    for (const value of [null, true, "", Number.NaN, Number.POSITIVE_INFINITY]) {
      const normalized = normalizeWorkspacePreferences({ editorFontSize: value, editorLineSpacing: value, editorBodyWidth: value });
      expect(normalized.editorFontSize).toBe(15);
      expect(normalized.editorLineSpacing).toBe(4);
      expect(normalized.editorBodyWidth).toBe(820);
    }
    expect(clampEditorFontSize(null)).toBe(15);
    expect(clampEditorFontSize(true)).toBe(15);
    expect(clampEditorFontSize("")).toBe(15);
    expect(clampEditorFontSize(Number.NaN)).toBe(15);
    expect(clampEditorFontSize(Number.POSITIVE_INFINITY)).toBe(15);
  });

  it("normalizes writing toolbar IDs without changing a deliberate empty toolbar", () => {
    expect(normalizeWorkspacePreferences({ writingToolbarItemIds: ["quote", "bold", "unknown", "bold", 3] }).writingToolbarItemIds).toEqual(["quote", "bold"]);
    expect(normalizeWorkspacePreferences({ writingToolbarItemIds: [] }).writingToolbarItemIds).toEqual([]);
  });

  it("only offers recovery for the exact document and unchanged disk baseline", () => {
    expect(recoveryMatch(draft, "/repo", { relativePath: "content/post.md", baselineSha256: "same" })).toBe("ready");
    expect(recoveryMatch(draft, "/repo", { relativePath: "content/post.md", baselineSha256: "changed" })).toBe("baseline-mismatch");
    expect(recoveryMatch(draft, "/repo", { relativePath: "content/other.md", baselineSha256: "same" })).toBe("different-document");
  });

  it("bounds a recovery preview without splitting a surrogate pair", () => {
    expect(recoveryDraftPreview("short", 10)).toEqual({ text: "short", truncated: false });
    const preview = recoveryDraftPreview("1234😀rest", 5);
    expect(preview).toEqual({ text: "1234\n…", truncated: true });
  });

  it("ignores a stale save response after cancellation", async () => {
    vi.useFakeTimers();
    let resolve!: (value: string) => void;
    const save = vi.fn(() => new Promise<string>((done) => { resolve = done; }));
    const received = vi.fn();
    const scheduler = new RecoveryDraftScheduler<string>(900);
    scheduler.schedule(save, received);
    await vi.advanceTimersByTimeAsync(900);
    scheduler.cancel();
    resolve("stale");
    await Promise.resolve();
    expect(received).not.toHaveBeenCalled();
    vi.useRealTimers();
  });
});
