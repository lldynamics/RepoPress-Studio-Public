import type { UiLocale } from "../../i18n/locale";
import type { UiTranslator } from "../../i18n/i18n";
import { renderUiMessage, type UiMessage } from "../../i18n/uiMessage";

export function renderBackupExportMessage(message: UiMessage, locale: UiLocale, t: UiTranslator): string {
  const parameters = message.parameters && Object.fromEntries(Object.entries(message.parameters).map(([key, value]) =>
    [key, typeof value === "number" ? value.toLocaleString(locale) : value],
  ));
  return renderUiMessage({ ...message, parameters }, t);
}
