import type { UiLocale } from "./locale";
import type { UiMessage } from "./uiMessage";
import type { UiTemplate } from "./uiMessage";
import { renderUiMessage } from "./uiMessage";
import type { UiTranslator } from "./i18n";
import { isPlanExpired } from "../features/publish/publishPlan";

/** Display-only expiry; operation guards continue using their existing plan helpers. */
export function publishExpiryMessage(expiresAt: string, locale: UiLocale, now = new Date()): UiMessage {
  if (isPlanExpired({ expiresAt }, now)) return { source: "计划已过期，请重新生成。" };
  return { source: "计划将在 {time} 过期。", parameters: { time: new Date(expiresAt).toLocaleString(locale) } };
}

export interface PublishNotice extends UiMessage { errorParts?: (string | UiTemplate)[] }

/** Redact before storing; only placeholders created here are localizable. */
export function publishErrorNotice(source: string, error: unknown): PublishNotice {
  const raw = error instanceof Error ? error.message : typeof error === "object" && error !== null && "message" in error && typeof error.message === "string" ? error.message : typeof error === "string" ? error : null;
  if (raw === null) return { source, errorParts: [{ source: "未知错误" }] };
  const errorParts: (string | UiTemplate)[] = [];
  let offset = 0;
  for (const match of raw.matchAll(/(?:[A-Za-z]:[\\/]|\/)[^\s，。；：:]+/g)) {
    errorParts.push(raw.slice(offset, match.index), { source: "[本地文件]" });
    offset = match.index! + match[0].length;
  }
  errorParts.push(raw.slice(offset));
  return { source, errorParts };
}

export function renderPublishNotice(message: PublishNotice, t: UiTranslator): string {
  if (!message.errorParts) return renderUiMessage(message, t);
  const error = message.errorParts.map((part) => typeof part === "string" ? part : t(part.source, part.parameters)).join("");
  return renderUiMessage({ ...message, parameters: { ...message.parameters, error } }, t);
}
