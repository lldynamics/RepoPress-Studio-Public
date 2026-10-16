/**
 * Browser IME implementations do not expose composition state consistently.
 * In particular, Linux WebKit and Chromium can report an IME key as either
 * `Process` or legacy keyCode 229 after `isComposing` is no longer reliable.
 */
export interface EditorKeyboardEventLike {
  isComposing?: boolean;
  key?: string;
  keyCode?: number;
}

export interface EditorBeforeInputEventLike {
  isComposing?: boolean;
  inputType?: string;
}

/** True when a key event must bypass editor-owned keyboard workflows. */
export function isImeCompositionKeyboardEvent(event: EditorKeyboardEventLike): boolean {
  return event.isComposing === true || event.key === "Process" || event.keyCode === 229;
}

/** True when beforeinput belongs to an in-progress or committed IME composition. */
export function isImeCompositionBeforeInput(event: EditorBeforeInputEventLike): boolean {
  return event.isComposing === true || event.inputType?.toLowerCase().includes("composition") === true;
}
