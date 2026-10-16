import { useI18n } from "../i18n/i18n";
import { forwardRef, useCallback, useEffect, useMemo, useRef, type ClipboardEvent, type CSSProperties, type FormEvent, type KeyboardEvent } from "react";
import CodeMirror, { Decoration, EditorState, EditorView, ViewPlugin, type Extension, type ReactCodeMirrorRef, type Text, type ViewUpdate } from "@uiw/react-codemirror";
import { markdown } from "@codemirror/lang-markdown";
import { oneDark } from "@codemirror/theme-one-dark";
import { isolateHistory } from "@codemirror/commands";
import type { ArticleStateChangePlan } from "../contracts/articleStateChange";
import {
  normalizeMarkdownEditorComfort,
  planMarkdownEditorComfortClass,
  type MarkdownEditorComfortOptions,
} from "../features/writing/markdownEditorComfort";
import "./MarkdownEditorComfort.css";

export type { MarkdownEditorComfortOptions } from "../features/writing/markdownEditorComfort";

export interface MarkdownEditorSurfaceProps {
  value: string;
  darkMode: boolean;
  onChange: (value: string) => void;
  onPasteCapture: (event: ClipboardEvent) => void;
  onBeforeInputCapture: (event: FormEvent<HTMLDivElement>) => void;
  onKeyDownCapture: (event: KeyboardEvent<HTMLDivElement>) => void;
  onSelectionChange: (selection: { from: number; to: number; text: string }) => void;
  onReady?: () => void;
  editable: boolean;
  /** Optional so standalone and legacy callers retain the unmodified editor surface. */
  comfort?: Partial<MarkdownEditorComfortOptions>;
}

const EDITOR_BASIC_SETUP = {
  lineNumbers: true,
  foldGutter: false,
  highlightActiveLine: true,
  closeBrackets: false,
  closeBracketsKeymap: false,
} as const;

// Preserve literal CR characters in CRLF/mixed source. CodeMirror's default
// splitting otherwise drops them and makes source-bound UTF-16 edits stale.
export const sourceLineSeparator = EditorState.lineSeparator.of("\n");

/** Apply the confirmed local field edit as its own reversible history event. */
export function applyArticleStateChangeToEditor(view: EditorView, plan: ArticleStateChangePlan): boolean {
  if (view.state.doc.toString() !== plan.expectedText
    || plan.expectedText.slice(0, plan.edit.from) + plan.edit.insert + plan.expectedText.slice(plan.edit.to) !== plan.nextText) return false;
  view.dispatch({ changes: plan.edit, selection: { anchor: plan.selection.from, head: plan.selection.to },
    annotations: isolateHistory.of("full"), userEvent: "input.article-state", scrollIntoView: true });
  view.focus();
  return true;
}

function useLatestValue<T>(value: T) {
  const valueRef = useRef(value);
  valueRef.current = value;
  return valueRef;
}

interface EditorParagraph {
  from: number;
  to: number;
  lineStarts: number[];
}

/**
 * Uses CodeMirror's persistent Text tree directly. Cursor movement therefore
 * visits only the current blank-line-bounded paragraph, never copies or scans
 * the entire document.
 */
function findEditorParagraph(document: Text, position: number): EditorParagraph | null {
  const cursor = Math.min(document.length, Math.max(0, position));
  const current = document.lineAt(cursor);
  if (current.text.trim().length === 0) return null;

  let firstLineNumber = current.number;
  while (firstLineNumber > 1 && document.line(firstLineNumber - 1).text.trim().length > 0) {
    firstLineNumber -= 1;
  }

  let lastLineNumber = current.number;
  while (lastLineNumber < document.lines && document.line(lastLineNumber + 1).text.trim().length > 0) {
    lastLineNumber += 1;
  }

  const first = document.line(firstLineNumber);
  const last = document.line(lastLineNumber);
  const lineStarts: number[] = [];
  for (let lineNumber = firstLineNumber; lineNumber <= lastLineNumber; lineNumber += 1) {
    lineStarts.push(document.line(lineNumber).from);
  }
  return { from: first.from, to: last.to, lineStarts };
}

function createParagraphDecorationExtension(comfort: MarkdownEditorComfortOptions): Extension {
  return ViewPlugin.fromClass(class {
    decorations = Decoration.none;
    private view: EditorView;

    constructor(view: EditorView) {
      this.view = view;
      this.decorations = this.buildDecorations(view);
    }

    update(update: { docChanged: boolean; selectionSet: boolean; focusChanged: boolean; view: EditorView }) {
      if (update.docChanged || update.selectionSet || update.focusChanged) {
        this.decorations = this.buildDecorations(update.view);
      }
    }

    destroy() {
      // The plugin can be reconfigured while its CodeMirror view survives.
      // Always return the root to its non-spotlight state in that case.
      this.view.dom.classList.remove("cm-rp-editor-paragraph-spotlight-active");
    }

    private syncSpotlightClass(view: EditorView, hasActiveParagraph: boolean) {
      if (comfort.paragraphSpotlightEnabled) {
        view.dom.classList.toggle("cm-rp-editor-paragraph-spotlight-active", view.hasFocus && hasActiveParagraph);
      }
    }

    private buildDecorations(view: EditorView) {
      if (!view.hasFocus) {
        this.syncSpotlightClass(view, false);
        return Decoration.none;
      }

      const active = findEditorParagraph(view.state.doc, view.state.selection.main.head);
      if (!active) {
        this.syncSpotlightClass(view, false);
        return Decoration.none;
      }
      this.syncSpotlightClass(view, true);

      const decorations = [];
      if (comfort.paragraphSpotlightEnabled) {
        for (const lineStart of active.lineStarts) {
          decorations.push(Decoration.line({ class: "cm-rp-editor-paragraph-spotlight-active" }).range(lineStart));
        }
      }
      if (comfort.currentParagraphHighlightEnabled) {
        decorations.push(Decoration.mark({ class: "cm-rp-editor-active-paragraph" }).range(active.from, active.to));
      }
      return Decoration.set(decorations, true);
    }
  }, { decorations: (plugin) => plugin.decorations });
}

function prefersReducedMotion(): boolean {
  return typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches === true;
}

function createTypewriterExtension(): Extension {
  return ViewPlugin.fromClass(class {
    update(update: { docChanged: boolean; selectionSet: boolean; view: EditorView }) {
      // Composition transactions update the document and selection while an IME
      // candidate window is open. Scrolling then would displace that window.
      if (!update.view.hasFocus || update.view.composing || (!update.docChanged && !update.selectionSet)) return;

      update.view.requestMeasure({
        read(view) {
          const cursor = view.coordsAtPos(view.state.selection.main.head);
          if (!cursor) return null;
          return { cursorTop: cursor.top, cursorBottom: cursor.bottom };
        },
        write(measure, view) {
          if (!measure || view.composing || !view.hasFocus) return;
          const scroller = view.scrollDOM;
          const scrollerRect = scroller.getBoundingClientRect();
          const cursorCenter = (measure.cursorTop + measure.cursorBottom) / 2;
          const target = Math.max(0, scroller.scrollTop + cursorCenter - scrollerRect.top - scroller.clientHeight / 2);
          const behavior: ScrollBehavior = prefersReducedMotion() ? "auto" : "smooth";
          if (typeof scroller.scrollTo === "function") scroller.scrollTo({ top: target, behavior });
          else scroller.scrollTop = target;
        },
      });
    }
  });
}

const MarkdownEditorSurface = forwardRef<ReactCodeMirrorRef, MarkdownEditorSurfaceProps>(function MarkdownEditorSurface({
  value,
  darkMode,
  onChange,
  onPasteCapture,
  onBeforeInputCapture,
  onKeyDownCapture,
  onSelectionChange,
  onReady,
  editable,
  comfort,
}, ref) {
  const { t } = useI18n();
  // Parent state changes on every document edit. Keep the callbacks current
  // without making CodeMirror receive a fresh callback or extension setup.
  const callbacksRef = useLatestValue({ onChange, onPasteCapture, onBeforeInputCapture, onKeyDownCapture, onSelectionChange, onReady });
  const handleChange = useCallback((nextValue: string) => callbacksRef.current.onChange(nextValue), [callbacksRef]);
  const handlePasteCapture = useCallback((event: ClipboardEvent<HTMLDivElement>) => callbacksRef.current.onPasteCapture(event), [callbacksRef]);
  const handleBeforeInputCapture = useCallback((event: FormEvent<HTMLDivElement>) => callbacksRef.current.onBeforeInputCapture(event), [callbacksRef]);
  const handleKeyDownCapture = useCallback((event: KeyboardEvent<HTMLDivElement>) => callbacksRef.current.onKeyDownCapture(event), [callbacksRef]);
  const handleUpdate = useCallback((update: ViewUpdate) => {
    const selection = update.state.selection.main;
    callbacksRef.current.onSelectionChange({ from: selection.from, to: selection.to, text: update.state.sliceDoc(selection.from, selection.to) });
    if (update.docChanged) callbacksRef.current.onReady?.();
  }, [callbacksRef]);
  useEffect(() => { callbacksRef.current.onReady?.(); }, [callbacksRef]);

  const hasComfortSettings = comfort !== undefined;
  const normalizedComfort = useMemo(() => normalizeMarkdownEditorComfort(comfort), [
    comfort?.lineSpacing,
    comfort?.bodyWidth,
    comfort?.spellCheckEnabled,
    comfort?.typewriterModeEnabled,
    comfort?.currentParagraphHighlightEnabled,
    comfort?.warmPaperBackgroundEnabled,
    comfort?.paragraphSpotlightEnabled,
  ]);
  const comfortClassPlan = useMemo(() => planMarkdownEditorComfortClass(comfort), [
    comfort?.lineSpacing,
    comfort?.bodyWidth,
    comfort?.warmPaperBackgroundEnabled,
    comfort?.typewriterModeEnabled,
    comfort?.paragraphSpotlightEnabled,
  ]);
  const comfortExtensions = useMemo(() => {
    if (!hasComfortSettings) return [] as Extension[];

    const extensions: Extension[] = [
      EditorView.contentAttributes.of({ spellcheck: normalizedComfort.spellCheckEnabled ? "true" : "false" }),
    ];
    if (normalizedComfort.currentParagraphHighlightEnabled || normalizedComfort.paragraphSpotlightEnabled) {
      extensions.push(createParagraphDecorationExtension(normalizedComfort));
    }
    if (normalizedComfort.typewriterModeEnabled) extensions.push(createTypewriterExtension());
    return extensions;
  }, [
    hasComfortSettings,
    normalizedComfort.spellCheckEnabled,
    normalizedComfort.typewriterModeEnabled,
    normalizedComfort.currentParagraphHighlightEnabled,
    normalizedComfort.paragraphSpotlightEnabled,
  ]);
  const markdownExtension = useMemo(() => markdown(), []);
  const extensions = useMemo<Extension[]>(
    () => [sourceLineSeparator, markdownExtension, ...comfortExtensions],
    [markdownExtension, comfortExtensions],
  );
  return <CodeMirror
    ref={ref}
    onCreateEditor={() => callbacksRef.current.onReady?.()}
    value={value}
    height="100%"
    theme={darkMode ? oneDark : "light"}
    extensions={extensions}
    className={comfortClassPlan.className}
    style={comfortClassPlan.style as CSSProperties | undefined}
    onChange={handleChange}
    onPasteCapture={handlePasteCapture}
    onBeforeInputCapture={handleBeforeInputCapture}
    onKeyDownCapture={handleKeyDownCapture}
    onUpdate={handleUpdate}
    editable={editable}
    aria-label={t("Markdown 编辑器")}
    basicSetup={EDITOR_BASIC_SETUP}
  />;
});

export default MarkdownEditorSurface;
