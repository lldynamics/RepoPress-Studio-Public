import type { WorkspaceUiLanguage } from "../contracts/repository";

export type UiLocale = "zh-CN" | "en-US";
// Existing installations keep their Chinese UI until the user selects otherwise.
export const DEFAULT_UI_LANGUAGE: WorkspaceUiLanguage = "zh-CN";

export function normalizeUiLanguage(value: unknown): WorkspaceUiLanguage {
  return value === "system" || value === "zh-CN" || value === "en-US" ? value : DEFAULT_UI_LANGUAGE;
}

export function resolveUiLocale(preference: unknown, languages: readonly string[] = []): UiLocale {
  const normalized = normalizeUiLanguage(preference);
  if (normalized !== "system") return normalized;
  for (const language of languages.slice(0, 32)) {
    if (typeof language !== "string") continue;
    if (/^zh(?:-|$)/i.test(language)) return "zh-CN";
    if (/^en(?:-|$)/i.test(language)) return "en-US";
  }
  return "en-US";
}
