import { compareDraftVersion, type DraftVersionComparison } from "./draftHistory";

export interface DraftComparisonSections {
  full: DraftVersionComparison;
  frontMatter: DraftVersionComparison | null;
  body: DraftVersionComparison | null;
  fallback: "unclosedFrontMatter" | "comparisonLimit" | null;
}

interface DraftSections {
  frontMatter: string;
  body: string;
  unclosed: boolean;
}

/** Recognize delimiters only; offsets always refer to the untouched source. */
function splitDraftSections(text: string): DraftSections {
  let offset = 0;
  const readLine = () => {
    const start = offset;
    while (offset < text.length && text[offset] !== "\r" && text[offset] !== "\n") offset += 1;
    const content = text.slice(start, offset);
    if (text[offset] === "\r") {
      offset += 1;
      if (text[offset] === "\n") offset += 1;
    } else if (text[offset] === "\n") offset += 1;
    return content;
  };

  const opening = /^\uFEFF?[^\S\r\n]*(---|\+\+\+)[^\S\r\n]*$/.exec(readLine());
  if (!opening) return { frontMatter: "", body: text, unclosed: false };
  const closing = opening[1] === "---" ? /^[^\S\r\n]*(?:---|\.\.\.)[^\S\r\n]*$/ : /^[^\S\r\n]*\+\+\+[^\S\r\n]*$/;
  while (offset < text.length) {
    if (closing.test(readLine())) {
      return { frontMatter: text.slice(0, offset), body: text.slice(offset), unclosed: false };
    }
  }
  return { frontMatter: "", body: text, unclosed: true };
}

/** Compare target against source without editing, decoding, or omitting source text. */
export function compareDraftSections(target: string, source: string): DraftComparisonSections {
  const full = compareDraftVersion(target, source);
  if (full.truncated) return { full, frontMatter: null, body: null, fallback: "comparisonLimit" };

  const targetSections = splitDraftSections(target);
  const sourceSections = splitDraftSections(source);
  if (targetSections.unclosed || sourceSections.unclosed) {
    return { full, frontMatter: null, body: null, fallback: "unclosedFrontMatter" };
  }
  if (!targetSections.frontMatter && !sourceSections.frontMatter) {
    return { full, frontMatter: null, body: full, fallback: null };
  }
  return {
    full,
    frontMatter: compareDraftVersion(targetSections.frontMatter, sourceSections.frontMatter),
    body: compareDraftVersion(targetSections.body, sourceSections.body),
    fallback: null,
  };
}
