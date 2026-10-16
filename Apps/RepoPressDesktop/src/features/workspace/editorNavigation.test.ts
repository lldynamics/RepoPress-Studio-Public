import { describe, expect, it } from "vitest";
import { resolveEditorLocation } from "./editorNavigation";

describe("editor navigation resolution", () => {
  it("requires a complete document snapshot for stored ranges", () => {
    expect(resolveEditorLocation("hello world", { kind: "range", range: { from: 6, to: 11 }, expectedText: "hello world" })).toEqual({ from: 6, to: 11 });
    expect(resolveEditorLocation("hello brave world", { kind: "range", range: { from: 6, to: 11 }, expectedText: "hello world" })).toBeNull();
    expect(resolveEditorLocation("hello world", { kind: "range", range: { from: 6, to: 11 }, expectedText: "world" })).toBeNull();
  });

  it("rejects invalid or unsafe range bounds instead of clamping them", () => {
    expect(resolveEditorLocation("text", { kind: "range", range: { from: -1, to: 2 }, expectedText: "te" })).toBeNull();
    expect(resolveEditorLocation("text", { kind: "range", range: { from: 0, to: 99 }, expectedText: "text" })).toBeNull();
    expect(resolveEditorLocation("text", { kind: "range", range: { from: 2.5, to: 3 }, expectedText: "" })).toBeNull();
  });

  it("resolves a query after the 240-scalar snippet prefix without truncating the match", () => {
    const text = `${"a".repeat(240)} needle`;
    expect(resolveEditorLocation(text, { kind: "search", lineNumber: 1, snippet: "a".repeat(240), query: "NEEDLE" })).toEqual({ from: 241, to: 247 });
  });

  it("matches the Rust search line convention across BOM and CRLF", () => {
    const text = "\uFEFFfirst\r\nSecond Needle\r\nthird";
    expect(resolveEditorLocation(text, { kind: "search", lineNumber: 2, snippet: "Second Needle", query: "needle" })).toEqual({ from: 15, to: 21 });
  });

  it("rejects a changed snippet, an absent exact-line query, and an invalid line without fallback", () => {
    const text = "first needle\nsecond needle";
    expect(resolveEditorLocation(text, { kind: "search", lineNumber: 1, snippet: "changed", query: "needle" })).toBeNull();
    expect(resolveEditorLocation(text, { kind: "search", lineNumber: 1, snippet: "first needle", query: "second" })).toBeNull();
    expect(resolveEditorLocation(text, { kind: "search", lineNumber: 3, snippet: "", query: "needle" })).toBeNull();
  });

  it("keeps UTF-16 offsets correct for astral characters and complete case expansions", () => {
    const text = "\uFEFF😀 İSTANBUL";
    expect(resolveEditorLocation(text, { kind: "search", lineNumber: 1, snippet: "😀 İSTANBUL", query: "i\u0307stan" })).toEqual({ from: 4, to: 9 });
  });

  it("refuses matches that start or end within an expanded lower-case scalar", () => {
    const text = "İstanbul";
    expect(resolveEditorLocation(text, { kind: "search", lineNumber: 1, snippet: text, query: "i" })).toBeNull();
  });
});
