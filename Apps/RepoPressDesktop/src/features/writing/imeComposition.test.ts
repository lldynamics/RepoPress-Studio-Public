import { describe, expect, it } from "vitest";
import { isImeCompositionBeforeInput, isImeCompositionKeyboardEvent } from "./imeComposition";

describe("IME composition guards", () => {
  it("bypasses every browser representation of an in-progress IME key", () => {
    expect(isImeCompositionKeyboardEvent({ isComposing: true, key: "Enter" })).toBe(true);
    expect(isImeCompositionKeyboardEvent({ isComposing: false, key: "Process" })).toBe(true);
    expect(isImeCompositionKeyboardEvent({ isComposing: false, key: "Tab", keyCode: 229 })).toBe(true);
  });

  it("bypasses composition beforeinput events, including the committed input", () => {
    expect(isImeCompositionBeforeInput({ isComposing: true, inputType: "insertText" })).toBe(true);
    expect(isImeCompositionBeforeInput({ isComposing: false, inputType: "insertCompositionText" })).toBe(true);
    expect(isImeCompositionBeforeInput({ isComposing: false, inputType: "insertFromComposition" })).toBe(true);
  });

  it("leaves ordinary shortcuts and insertText available to the existing editor workflows", () => {
    expect(isImeCompositionKeyboardEvent({ isComposing: false, key: "Enter", keyCode: 13 })).toBe(false);
    expect(isImeCompositionKeyboardEvent({ isComposing: false, key: "Tab", keyCode: 9 })).toBe(false);
    expect(isImeCompositionKeyboardEvent({ isComposing: false, key: "(" })).toBe(false);
    expect(isImeCompositionBeforeInput({ isComposing: false, inputType: "insertText" })).toBe(false);
  });
});
