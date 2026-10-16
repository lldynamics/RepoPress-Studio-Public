import type { MessageParameters, UiTranslator } from "../i18n/i18n";
import { renderUiMessage, type UiTemplate } from "../i18n/uiMessage";

export type FindStatus =
  | { kind: "message"; source: string; parameters?: MessageParameters; labels?: Record<string, UiTemplate> }
  | { kind: "error"; value: string }
  | null;

export function findMessage(source: string, parameters?: MessageParameters, labels?: Record<string, UiTemplate>): FindStatus {
  return { kind: "message", source, ...(parameters ? { parameters } : {}), ...(labels ? { labels } : {}) };
}

export function findError(value: string): FindStatus {
  return { kind: "error", value };
}

const SCOPE_LIMIT = 256 * 1024;
const DOCUMENT_LIMIT = 512 * 1024;
const QUERY_LIMIT = 512;
const REPLACEMENT_LIMIT = 4 * 1024;
const MATCH_LIMIT = 2_000;
const number = (value: number) => value.toLocaleString();

const knownBudgetMessages = new Map<string, { source: string; parameters: MessageParameters }>([
  [`范围超过 ${number(SCOPE_LIMIT)} 个 UTF-16 字符，无法安全预览。`, { source: "范围超过 {count} 个 UTF-16 字符，无法安全预览。", parameters: { count: number(SCOPE_LIMIT) } }],
  [`文稿超过 ${number(DOCUMENT_LIMIT)} 个 UTF-16 字符，无法安全查找替换。`, { source: "文稿超过 {count} 个 UTF-16 字符，无法安全查找替换。", parameters: { count: number(DOCUMENT_LIMIT) } }],
  [`查找内容超过 ${QUERY_LIMIT} 个字符。`, { source: "查找内容超过 {count} 个字符。", parameters: { count: QUERY_LIMIT } }],
  [`查找内容超过 ${QUERY_LIMIT} 个 UTF-16 字符。`, { source: "查找内容超过 {count} 个 UTF-16 字符。", parameters: { count: QUERY_LIMIT } }],
  [`替换内容超过 ${number(REPLACEMENT_LIMIT)} 个字符。`, { source: "替换内容超过 {count} 个字符。", parameters: { count: number(REPLACEMENT_LIMIT) } }],
  [`替换内容超过 ${number(REPLACEMENT_LIMIT)} 个 UTF-16 字符。`, { source: "替换内容超过 {count} 个 UTF-16 字符。", parameters: { count: number(REPLACEMENT_LIMIT) } }],
  [`匹配超过 ${number(MATCH_LIMIT)} 处，无法安全预览。`, { source: "匹配超过 {count} 处，无法安全预览。", parameters: { count: number(MATCH_LIMIT) } }],
  [`替换后的范围超过 ${number(SCOPE_LIMIT)} 个 UTF-16 字符，无法安全预览。`, { source: "替换后的范围超过 {count} 个 UTF-16 字符，无法安全预览。", parameters: { count: number(SCOPE_LIMIT) } }],
  [`替换后的范围超过 ${number(SCOPE_LIMIT)} 个 UTF-16 字符，无法安全替换。`, { source: "替换后的范围超过 {count} 个 UTF-16 字符，无法安全替换。", parameters: { count: number(SCOPE_LIMIT) } }],
  [`替换后的范围超过 ${number(SCOPE_LIMIT)} 个字符，无法安全预览。`, { source: "替换后的范围超过 {count} 个字符，无法安全预览。", parameters: { count: number(SCOPE_LIMIT) } }],
]);

export function localizeFindError(value: string, t: UiTranslator): string {
  const knownBudget = knownBudgetMessages.get(value);
  return knownBudget ? t(knownBudget.source, knownBudget.parameters) : t(value);
}

export function renderFindStatus(status: FindStatus, t: UiTranslator): string {
  if (!status) return "";
  return status.kind === "message" ? renderUiMessage(status, t) : localizeFindError(status.value, t);
}
