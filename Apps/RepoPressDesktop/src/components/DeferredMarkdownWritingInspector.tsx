import { useEffect } from "react";
import { MarkdownWritingInspector, type MarkdownWritingInspectorProps } from "./MarkdownWritingInspector";

export interface DeferredMarkdownWritingInspectorProps extends MarkdownWritingInspectorProps {
  focusFindRequestKey: number;
  onFindFocusHandled: (requestKey: number) => void;
}

export default function DeferredMarkdownWritingInspector({ focusFindRequestKey, onFindFocusHandled, ...props }: DeferredMarkdownWritingInspectorProps) {
  useEffect(() => {
    if (!focusFindRequestKey) return;
    const frame = window.requestAnimationFrame(() => {
      window.document.querySelector<HTMLInputElement>("#markdown-document-find")?.focus();
      onFindFocusHandled(focusFindRequestKey);
    });
    return () => window.cancelAnimationFrame(frame);
  }, [focusFindRequestKey, onFindFocusHandled]);

  return <MarkdownWritingInspector {...props} />;
}
