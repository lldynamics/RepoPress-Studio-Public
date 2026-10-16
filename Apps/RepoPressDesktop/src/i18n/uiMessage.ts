import type { MessageParameters, UiTranslator } from "./i18n";

export interface UiTemplate { source: string; parameters?: MessageParameters }
/** Explicit local labels may be translated; literal user parameters are interpolated once. */
export interface UiMessage extends UiTemplate { labels?: Record<string, UiTemplate> }
export interface DiagnosticPresentation { title: UiTemplate; message: UiMessage }

export function renderUiMessage(message: UiMessage, t: UiTranslator): string {
  const labels = Object.fromEntries(Object.entries(message.labels ?? {}).map(([key, label]) => [key, t(label.source, label.parameters)]));
  return t(message.source, { ...message.parameters, ...labels });
}

export function presentDiagnostic(item: { title: string; message: string; presentation?: DiagnosticPresentation }, t: UiTranslator) {
  if (!item.presentation) return { title: item.title, message: item.message };
  return {
    title: t(item.presentation.title.source, item.presentation.title.parameters),
    message: renderUiMessage(item.presentation.message, t),
  };
}
