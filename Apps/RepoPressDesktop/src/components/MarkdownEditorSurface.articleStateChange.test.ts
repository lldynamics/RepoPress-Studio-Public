import { describe, expect, it, vi } from "vitest";
import { EditorState, type EditorView } from "@uiw/react-codemirror";
import { history, redo, undo, undoDepth } from "@codemirror/commands";
import { applyArticleStateChangeToEditor, sourceLineSeparator } from "./MarkdownEditorSurface";
import { planArticleStateChange } from "../features/writing/articleStateChange";

function editor(text: string) {
  let state = EditorState.create({ doc: text, extensions: [sourceLineSeparator, history()] });
  const dispatch = vi.fn((transaction) => { state = transaction.state ?? state.update(transaction).state; });
  const focus = vi.fn();
  const view = { get state() { return state; }, dispatch, focus } as unknown as EditorView;
  return { view, dispatch, focus };
}
function plan(text: string) {
  const result = planArticleStateChange({ text, contextKey: "bound-context", nowEpochMs: Date.now(), context: {
    kind: "repository", repository: { sessionId: "repo", siteKind: "hugo", contentRoot: "content" },
    documentId: "doc", relativePath: "content/a.md", writable: true,
  } }, "ready");
  if (!result.ok) throw new Error(result.reason);
  return result.plan;
}

describe("confirmed article state editor transaction", () => {
  it.each(["\uFEFF---\r\ntitle: 中文\r\ndraft: true\r\n---\r\nBody 😀\r\n", "---\r\ntitle: 中文\ndraft: true\r\n---\nBody\r\n"])("preserves CRLF/BOM and mixed source in real CodeMirror through apply, undo and redo", (initial) => {
    const { view } = editor(initial); const change = plan(initial);
    expect(view.state.doc.toString()).toBe(initial);
    expect(applyArticleStateChangeToEditor(view, change)).toBe(true);
    expect(view.state.doc.toString()).toBe(initial.replace("draft: true", "draft: false"));
    expect(undo(view)).toBe(true); expect(view.state.doc.toString()).toBe(initial);
    expect(redo(view)).toBe(true); expect(view.state.doc.toString()).toBe(change.nextText);
  });
  it("isolates the flag change from typing on both sides in real CodeMirror history", () => {
    const initial = "---\ntitle: 中文\ndraft: true\n---\nBody";
    const { view } = editor(initial);
    view.dispatch({ changes: { from: initial.length, insert: " before" }, userEvent: "input.type" });
    const prior = view.state.doc.toString();
    const change = plan(prior);
    expect(applyArticleStateChangeToEditor(view, change)).toBe(true);
    view.dispatch({ changes: { from: view.state.doc.length, insert: " after" }, userEvent: "input.type" });
    expect(undoDepth(view.state)).toBe(3);
    expect(undo(view)).toBe(true); expect(view.state.doc.toString()).toBe(change.nextText);
    expect(undo(view)).toBe(true); expect(view.state.doc.toString()).toBe(prior);
    expect(undo(view)).toBe(true); expect(view.state.doc.toString()).toBe(initial);
    expect(redo(view)).toBe(true); expect(view.state.doc.toString()).toBe(prior);
    expect(redo(view)).toBe(true); expect(view.state.doc.toString()).toBe(change.nextText);
    expect(redo(view)).toBe(true); expect(view.state.doc.toString()).toBe(change.nextText + " after");
  });
  it("rejects a stale live document before dispatch or focus", () => {
    const initial = "---\ndraft: true\n---\nBody";
    const change = plan(initial); const { view, dispatch, focus } = editor(initial + " new");
    expect(applyArticleStateChangeToEditor(view, change)).toBe(false);
    expect(dispatch).not.toHaveBeenCalled(); expect(focus).not.toHaveBeenCalled();
  });
  it("rejects a next-text mismatch without touching the document", () => {
    const initial = "---\ndraft: true\n---\nBody";
    const change = plan(initial); const { view, dispatch } = editor(initial);
    expect(applyArticleStateChangeToEditor(view, { ...change, nextText: "overwrite" })).toBe(false);
    expect(dispatch).not.toHaveBeenCalled();
  });
});
