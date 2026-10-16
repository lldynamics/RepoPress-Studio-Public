export interface EditorSelectionSnapshot {
  from: number;
  to: number;
  text: string;
}

export interface SelectionReplacement {
  text: string;
  selection: EditorSelectionSnapshot;
}

/** CodeMirror and JavaScript string offsets are both UTF-16 code-unit offsets. */
export function replaceUnchangedSelection(
  documentText: string,
  selection: EditorSelectionSnapshot,
  expectedText: string,
  replacementText: string,
): SelectionReplacement | null {
  if (!Number.isSafeInteger(selection.from)
    || !Number.isSafeInteger(selection.to)
    || selection.from < 0
    || selection.to < selection.from
    || selection.to > documentText.length
    || selection.text !== expectedText
    || documentText.slice(selection.from, selection.to) !== expectedText) {
    return null;
  }
  const text = `${documentText.slice(0, selection.from)}${replacementText}${documentText.slice(selection.to)}`;
  return {
    text,
    selection: {
      from: selection.from,
      to: selection.from + replacementText.length,
      text: replacementText,
    },
  };
}
