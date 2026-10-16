import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { resolveUiLocale, type UiLocale } from "./locale";
import { shellMessages } from "./shellMessages";
import { settingsMessages } from "./settingsMessages";
import { editorMessages } from "./editorMessages";
import { findMessages } from "./findMessages";
import { outlineMessages } from "./outlineMessages";
import { diagnosticMessages } from "./diagnosticMessages";
import { publishMessages } from "./publishMessages";
import { publishRecordMessages } from "./publishRecordMessages";
import { publishDocumentMessages } from "./publishDocumentMessages";
import { releaseMessages } from "./releaseMessages";
import { rollbackInspectionMessages } from "./rollbackInspectionMessages";
import { rollbackArchiveMessages } from "./rollbackArchiveMessages";
import { aiMessages } from "./aiMessages";
import { aiChatMessages } from "./aiChatMessages";
import { documentToolMessages } from "./documentToolMessages";

export const UI_MESSAGE_CATALOGS = [shellMessages, settingsMessages, editorMessages, findMessages, outlineMessages, diagnosticMessages, publishMessages, publishRecordMessages, publishDocumentMessages, releaseMessages, rollbackInspectionMessages, rollbackArchiveMessages, aiMessages, aiChatMessages, documentToolMessages];
export const ENGLISH_UI_MESSAGES: Record<string, string> = Object.assign({}, ...UI_MESSAGE_CATALOGS);
export type MessageParameters = Record<string, string | number>;
export type UiTranslator = (source: string, parameters?: MessageParameters) => string;

export function translateUi(locale: UiLocale, source: string, parameters?: MessageParameters): string {
  const message = locale === "en-US" && Object.prototype.hasOwnProperty.call(ENGLISH_UI_MESSAGES, source) ? ENGLISH_UI_MESSAGES[source] : source;
  return message.replace(/\{(\w+)\}/g, (token, key: string) => parameters && Object.prototype.hasOwnProperty.call(parameters, key) ? String(parameters[key]) : token);
}

export function createUiTranslator(locale: UiLocale, messages?: Record<string, string>): UiTranslator {
  return (source, parameters) => {
    if (locale !== "en-US" || !messages || !Object.prototype.hasOwnProperty.call(messages, source)) return translateUi(locale, source, parameters);
    return messages[source].replace(/\{(\w+)\}/g, (token, key: string) => parameters && Object.prototype.hasOwnProperty.call(parameters, key) ? String(parameters[key]) : token);
  };
}

const I18nContext = createContext({ locale: "zh-CN" as UiLocale, t: createUiTranslator("zh-CN") });
/** Surface catalogs stay with their lazy component while shared labels remain available. */
export function useI18n(messages?: Record<string, string>) {
  const context = useContext(I18nContext);
  return useMemo(() => messages ? { locale: context.locale, t: createUiTranslator(context.locale, messages) } : context, [context, messages]);
}

function browserLanguages(): readonly string[] {
  if (typeof navigator === "undefined") return [];
  return navigator.languages?.length ? [...navigator.languages] : navigator.language ? [navigator.language] : [];
}

export function useUiLanguage(preference: unknown) {
  const [languages, setLanguages] = useState(browserLanguages);
  useEffect(() => {
    const update = () => setLanguages(browserLanguages());
    window.addEventListener("languagechange", update);
    return () => window.removeEventListener("languagechange", update);
  }, []);
  const locale = resolveUiLocale(preference, languages);
  return useMemo(() => ({ locale, t: createUiTranslator(locale) }), [locale]);
}

export function I18nProvider({ locale, children }: { locale: UiLocale; children: ReactNode }) {
  const value = useMemo(() => ({ locale, t: createUiTranslator(locale) }), [locale]);
  useEffect(() => {
    const previous = document.documentElement.lang;
    document.documentElement.lang = locale;
    return () => { document.documentElement.lang = previous; };
  }, [locale]);
  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}
