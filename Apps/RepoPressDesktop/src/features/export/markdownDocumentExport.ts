import { parseFrontMatter } from "../frontmatter/frontMatter";
import { renderMarkdownPreview } from "../../preview/renderMarkdownPreview";

export type MarkdownDocumentExportFormat = "markdown" | "html";

export interface MarkdownDocumentExportInput {
  /** The current editor buffer. It is never read from disk. */
  markdown: string;
  /** Current document path or file name, used only as a filename fallback. */
  fileName?: string | null;
  /** An optional editor title, used in the HTML document title when needed. */
  title?: string | null;
}

export interface MarkdownDocumentExportPlan {
  format: MarkdownDocumentExportFormat;
  /** JavaScript text which a desktop save implementation must write as UTF-8. */
  text: string;
  encoding: "utf-8";
  mimeType: "text/markdown" | "text/html";
  extension: "md" | "html";
  suggestedFileName: string;
  /** A safe, human-readable document title for save UI and the HTML <title>. */
  title: string;
}

const FALLBACK_DOCUMENT_NAME = "未命名文稿";
const WINDOWS_RESERVED_BASENAMES = new Set([
  "CON", "PRN", "AUX", "NUL",
  "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
  "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
]);
const MAXIMUM_BASENAME_LENGTH = 96;

function nonEmpty(value: string | null | undefined): string | null {
  const trimmed = value?.trim();
  return trimmed ? trimmed : null;
}

function basename(fileName: string | null | undefined): string | null {
  const normalized = nonEmpty(fileName)?.replace(/\\/g, "/");
  if (!normalized) return null;
  const parts = normalized.split("/").filter(Boolean);
  const leaf = parts[parts.length - 1] ?? "";
  // A source filename has one extension of its own. Further cleanup happens
  // in safeSuggestedFileName so a misleading extension can never survive.
  return nonEmpty(leaf.replace(/\.[^.\s]+$/u, ""));
}

function frontMatterTitle(markdown: string): string | null {
  return nonEmpty(parseFrontMatter(markdown)?.values.title);
}

function htmlEscape(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Removes path syntax, control characters, Windows-reserved names, and any
 * extension supplied by content. The caller controls the final extension.
 */
export function safeSuggestedFileName(proposedName: string | null | undefined, extension: "md" | "html"): string {
  let name = (proposedName ?? "")
    .replace(/[<>:"/\\|?*\p{Cc}]/gu, "-")
    .replace(/-{2,}/gu, "-")
    .replace(/\s+/gu, " ")
    .trim()
    .replace(/[. ]+$/u, "");

  // Do not preserve an arbitrary supplied suffix such as .exe or .html. This
  // also prevents a user-provided title from producing a misleading double
  // extension once the format's fixed suffix is appended below.
  name = name.replace(/(?:\.[A-Za-z0-9]{1,16})+$/u, "").replace(/[. ]+$/u, "");
  if (!name || name === "." || name === "..") name = FALLBACK_DOCUMENT_NAME;
  if (WINDOWS_RESERVED_BASENAMES.has(name.toLocaleUpperCase())) name += "-document";

  const characters = Array.from(name);
  if (characters.length > MAXIMUM_BASENAME_LENGTH) {
    name = characters.slice(0, MAXIMUM_BASENAME_LENGTH).join("").replace(/[. ]+$/u, "");
  }
  if (!name) name = FALLBACK_DOCUMENT_NAME;
  return `${name}.${extension}`;
}

function completeHTMLDocument(title: string, markdown: string): string {
  // renderMarkdownPreview deliberately omits all href/src/style values and
  // sanitizes raw HTML. Keeping the exported document style-free means it has
  // no style injection surface and needs no remote resources to render.
  const body = renderMarkdownPreview(markdown);
  return [
    "<!doctype html>",
    '<html lang="zh-Hans">',
    "<head>",
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; base-uri \'none\'; connect-src \'none\'; font-src \'none\'; form-action \'none\'; frame-src \'none\'; img-src \'none\'; media-src \'none\'; object-src \'none\'; script-src \'none\'; style-src \'none\';">',
    `<title>${htmlEscape(title)}</title>`,
    "</head>",
    "<body>",
    body,
    "</body>",
    "</html>",
  ].join("\n");
}

/** Builds a deterministic, side-effect-free export payload for the current buffer. */
export function createMarkdownDocumentExportPlan(
  input: MarkdownDocumentExportInput,
  format: MarkdownDocumentExportFormat,
): MarkdownDocumentExportPlan {
  const metadataTitle = frontMatterTitle(input.markdown);
  const sourceBasename = basename(input.fileName);
  // Filename priority is intentionally independent from the optional editor
  // title: front matter, then the actual current filename, then the fallback.
  const filenameStem = metadataTitle ?? sourceBasename ?? FALLBACK_DOCUMENT_NAME;
  const documentTitle = metadataTitle ?? nonEmpty(input.title) ?? sourceBasename ?? FALLBACK_DOCUMENT_NAME;
  const extension = format === "markdown" ? "md" : "html";

  return {
    format,
    text: format === "markdown" ? input.markdown : completeHTMLDocument(documentTitle, input.markdown),
    encoding: "utf-8",
    mimeType: format === "markdown" ? "text/markdown" : "text/html",
    extension,
    suggestedFileName: safeSuggestedFileName(filenameStem, extension),
    title: documentTitle,
  };
}
