import type { DocumentSnapshot, RecoveryDraftSnapshot, WorkspacePreferences, WorkspaceStateSnapshot, WritingToolbarItemId } from "../../contracts/repository";
import { DEFAULT_UI_LANGUAGE, normalizeUiLanguage } from "../../i18n/locale";

export const DEFAULT_WRITING_TOOLBAR_ITEM_IDS: readonly WritingToolbarItemId[] = [
  "bold", "italic", "strike", "code", "link", "heading", "quote", "unorderedList", "orderedList", "taskList", "codeBlock", "horizontalRule",
];

export const DEFAULT_WORKSPACE_PREFERENCES: WorkspacePreferences = {
  uiLanguage: DEFAULT_UI_LANGUAGE,
  theme: "system",
  editorFontSize: 15,
  editorLineSpacing: 4,
  editorBodyWidth: 820,
  spellCheckEnabled: false,
  typewriterModeEnabled: false,
  currentParagraphHighlightEnabled: true,
  warmPaperBackgroundEnabled: false,
  automaticPairingEnabled: true,
  paragraphSpotlightEnabled: false,
  writingToolDensity: "basic",
  writingToolbarItemIds: [...DEFAULT_WRITING_TOOLBAR_ITEM_IDS],
  restoreLastWorkspace: true,
  recoveryEnabled: true,
};

export function clampEditorFontSize(value: unknown): number {
  const numeric = numericPreference(value);
  if (numeric === null) return DEFAULT_WORKSPACE_PREFERENCES.editorFontSize;
  return Math.max(12, Math.min(28, Math.round(numeric)));
}

function clampEditorLineSpacing(value: unknown): number {
  return clampInteger(value, 0, 12, DEFAULT_WORKSPACE_PREFERENCES.editorLineSpacing);
}

function clampEditorBodyWidth(value: unknown): number {
  return clampInteger(value, 560, 1200, DEFAULT_WORKSPACE_PREFERENCES.editorBodyWidth);
}

function clampInteger(value: unknown, minimum: number, maximum: number, fallback: number): number {
  const numeric = numericPreference(value);
  if (numeric === null) return fallback;
  return Math.max(minimum, Math.min(maximum, Math.round(numeric)));
}

function numericPreference(value: unknown): number | null {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value !== "string" || value.trim() === "") return null;
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function normalizeWritingToolbarItemIds(value: unknown): WritingToolbarItemId[] {
  if (!Array.isArray(value)) return [...DEFAULT_WRITING_TOOLBAR_ITEM_IDS];
  const known = new Set<string>(DEFAULT_WRITING_TOOLBAR_ITEM_IDS);
  const seen = new Set<WritingToolbarItemId>();
  return value.filter((item): item is WritingToolbarItemId => {
    if (typeof item !== "string" || !known.has(item) || seen.has(item as WritingToolbarItemId)) return false;
    seen.add(item as WritingToolbarItemId);
    return true;
  });
}

export function normalizeWorkspacePreferences(value: unknown): WorkspacePreferences {
  const candidate = isRecord(value) ? value : {};
  return {
    uiLanguage: normalizeUiLanguage(candidate.uiLanguage),
    theme: candidate.theme === "light" || candidate.theme === "dark" || candidate.theme === "system" ? candidate.theme : DEFAULT_WORKSPACE_PREFERENCES.theme,
    editorFontSize: clampEditorFontSize(candidate.editorFontSize),
    editorLineSpacing: clampEditorLineSpacing(candidate.editorLineSpacing),
    editorBodyWidth: clampEditorBodyWidth(candidate.editorBodyWidth),
    spellCheckEnabled: typeof candidate.spellCheckEnabled === "boolean" ? candidate.spellCheckEnabled : DEFAULT_WORKSPACE_PREFERENCES.spellCheckEnabled,
    typewriterModeEnabled: typeof candidate.typewriterModeEnabled === "boolean" ? candidate.typewriterModeEnabled : DEFAULT_WORKSPACE_PREFERENCES.typewriterModeEnabled,
    currentParagraphHighlightEnabled: typeof candidate.currentParagraphHighlightEnabled === "boolean" ? candidate.currentParagraphHighlightEnabled : DEFAULT_WORKSPACE_PREFERENCES.currentParagraphHighlightEnabled,
    warmPaperBackgroundEnabled: typeof candidate.warmPaperBackgroundEnabled === "boolean" ? candidate.warmPaperBackgroundEnabled : DEFAULT_WORKSPACE_PREFERENCES.warmPaperBackgroundEnabled,
    automaticPairingEnabled: typeof candidate.automaticPairingEnabled === "boolean" ? candidate.automaticPairingEnabled : DEFAULT_WORKSPACE_PREFERENCES.automaticPairingEnabled,
    paragraphSpotlightEnabled: typeof candidate.paragraphSpotlightEnabled === "boolean" ? candidate.paragraphSpotlightEnabled : DEFAULT_WORKSPACE_PREFERENCES.paragraphSpotlightEnabled,
    writingToolDensity: candidate.writingToolDensity === "professional" || candidate.writingToolDensity === "basic" ? candidate.writingToolDensity : DEFAULT_WORKSPACE_PREFERENCES.writingToolDensity,
    writingToolbarItemIds: normalizeWritingToolbarItemIds(candidate.writingToolbarItemIds),
    restoreLastWorkspace: typeof candidate.restoreLastWorkspace === "boolean" ? candidate.restoreLastWorkspace : DEFAULT_WORKSPACE_PREFERENCES.restoreLastWorkspace,
    recoveryEnabled: typeof candidate.recoveryEnabled === "boolean" ? candidate.recoveryEnabled : DEFAULT_WORKSPACE_PREFERENCES.recoveryEnabled,
  };
}

export function normalizeWorkspaceState(value: Partial<WorkspaceStateSnapshot> | null | undefined): WorkspaceStateSnapshot {
  return {
    schemaVersion: 1,
    preferences: normalizeWorkspacePreferences(value?.preferences),
    recentRepositories: Array.isArray(value?.recentRepositories) ? value.recentRepositories : [],
    lastRepositoryPath: typeof value?.lastRepositoryPath === "string" ? value.lastRepositoryPath : null,
    lastDocumentPath: typeof value?.lastDocumentPath === "string" ? value.lastDocumentPath : null,
    recoveryDraft: value?.recoveryDraft ?? null,
    warning: typeof value?.warning === "string" ? value.warning : null,
  };
}

export type RecoveryMatch = "none" | "different-document" | "baseline-mismatch" | "ready";

export function recoveryMatch(draft: RecoveryDraftSnapshot | null, repositoryPath: string | null | undefined, document: Pick<DocumentSnapshot, "relativePath" | "baselineSha256"> | null): RecoveryMatch {
  if (!draft) return "none";
  if (!repositoryPath || !document || draft.repositoryPath !== repositoryPath || draft.relativePath !== document.relativePath) return "different-document";
  return draft.baselineSha256 === document.baselineSha256 ? "ready" : "baseline-mismatch";
}

export function recoveryDraftPreview(text: string, maximumCharacters = 16_000): { text: string; truncated: boolean } {
  if (text.length <= maximumCharacters) return { text, truncated: false };
  let end = maximumCharacters;
  const last = text.charCodeAt(end - 1);
  const next = text.charCodeAt(end);
  if (last >= 0xd800 && last <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) end -= 1;
  return { text: `${text.slice(0, end)}\n…`, truncated: true };
}

export class RecoveryDraftScheduler<T> {
  private timer: ReturnType<typeof setTimeout> | null = null;
  private generation = 0;

  constructor(private readonly delayMs = 1000) {}

  schedule(save: () => Promise<T>, onSaved: (value: T) => void, onError?: (error: unknown) => void): void {
    this.cancel();
    const generation = ++this.generation;
    this.timer = setTimeout(() => {
      this.timer = null;
      void save().then((value) => {
        if (generation === this.generation) onSaved(value);
      }).catch((error: unknown) => {
        if (generation === this.generation) onError?.(error);
      });
    }, this.delayMs);
  }

  cancel(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.generation += 1;
  }
}
