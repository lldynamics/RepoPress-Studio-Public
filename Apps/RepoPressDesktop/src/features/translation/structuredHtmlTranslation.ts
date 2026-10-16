import type {
  StructuredTextTranslationSegment,
  StructuredTextTranslationResult,
} from "../../contracts/repository";

/** The maximum reviewed source payload accepted by the structured endpoint. */
export const MAX_STRUCTURED_HTML_TRANSLATION_BYTES = 64 * 1024;
export const MAX_STRUCTURED_HTML_TRANSLATION_TITLE_CHARACTERS = 500;
export const MAX_STRUCTURED_HTML_TRANSLATION_SEGMENTS = 256;

const ENVELOPE_PREFIX = "repopress-structured-translation:v1:";
const EXCLUDED_ANCESTOR_TAGS = new Set([
  "script", "style", "noscript", "pre", "code", "textarea", "svg", "math",
]);
const BLOCK_TEXT_TAGS = new Set([
  "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figcaption",
  "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
  "hr", "li", "main", "nav", "ol", "p", "section", "table", "tbody", "td", "tfoot",
  "th", "thead", "tr", "ul",
]);

export interface StructuredHtmlTranslationPlan {
  /** The only serializable source material: reviewed text sent to the provider. */
  segments: StructuredTextTranslationSegment[];
  sourceTextBytes: number;
  wasTruncated: boolean;
}

export interface StructuredHtmlTranslationOutput {
  translatedTitle: string;
  translatedHtml: string;
  /** Visible body text, excluding executable/non-reader content. */
  translatedPlainText: string;
}

interface PlanBacking {
  title: string;
  template: HTMLTemplateElement;
  bodyPaths: ReadonlyMap<string, readonly number[]>;
}

// Source HTML and the DOM template stay in memory only. In particular, they
// are neither enumerable on the plan nor included in cache envelopes.
const planBacking = new WeakMap<StructuredHtmlTranslationPlan, PlanBacking>();

export function buildStructuredHtmlTranslationPlan({
  title,
  html,
  maxTextBytes = MAX_STRUCTURED_HTML_TRANSLATION_BYTES,
}: {
  title: string;
  html: string;
  maxTextBytes?: number;
}): StructuredHtmlTranslationPlan {
  const byteLimit = normalizedByteLimit(maxTextBytes);
  const template = document.createElement("template");
  template.innerHTML = html;

  const segments: StructuredTextTranslationSegment[] = [];
  let sourceTextBytes = 0;
  let wasTruncated = false;
  const limitedTitle = truncateByCharactersAndBytes(
    title,
    MAX_STRUCTURED_HTML_TRANSLATION_TITLE_CHARACTERS,
    byteLimit,
  );
  if (limitedTitle.value !== title) wasTruncated = true;
  if (limitedTitle.value.trim()) {
    segments.push({ id: "title", text: limitedTitle.value });
    sourceTextBytes = utf8ByteLength(limitedTitle.value);
  }

  const bodyPaths = new Map<string, readonly number[]>();
  const visibleNodes = visibleTextNodes(template.content);
  for (const node of visibleNodes) {
    if (segments.length >= MAX_STRUCTURED_HTML_TRANSLATION_SEGMENTS) {
      wasTruncated = true;
      break;
    }
    const bytes = utf8ByteLength(node.data);
    if (sourceTextBytes + bytes > byteLimit) {
      // Do not partially translate a DOM text node: it would create an
      // incoherent sentence and makes safe reconstruction ambiguous.
      wasTruncated = true;
      break;
    }
    const id = `body.${bodyPaths.size}`;
    segments.push({ id, text: node.data });
    bodyPaths.set(id, pathToNode(node, template.content));
    sourceTextBytes += bytes;
  }

  const plan: StructuredHtmlTranslationPlan = {
    segments,
    sourceTextBytes,
    wasTruncated,
  };
  planBacking.set(plan, { title, template, bodyPaths });
  return plan;
}

/**
 * Applies an exactly matching structured response to an in-memory plan.
 * Translation strings are always assigned to Text.data, never parsed as HTML.
 */
export function reconstructStructuredHtmlTranslation(
  plan: StructuredHtmlTranslationPlan,
  result: StructuredTextTranslationResult,
): StructuredHtmlTranslationOutput {
  const backing = planBacking.get(plan);
  if (!backing) throw new Error("Structured HTML translation plan is unavailable.");
  const translations = exactTranslations(plan.segments, result);
  const content = backing.template.content.cloneNode(true) as DocumentFragment;

  for (const [id, path] of backing.bodyPaths) {
    const node = nodeAtPath(content, path);
    if (!node || node.nodeType !== Node.TEXT_NODE) {
      throw new Error("Structured HTML translation plan no longer matches its document.");
    }
    node.textContent = translations.get(id)!;
  }

  const translatedTitle = (translations.get("title") ?? backing.title).trim();
  const container = document.createElement("div");
  container.append(content);
  return {
    translatedTitle,
    translatedHtml: container.innerHTML,
    translatedPlainText: readablePlainText(container),
  };
}

export interface StructuredTextTranslationEnvelope {
  translations: StructuredTextTranslationResult["translations"];
}

/** Stores only result translations; source title and source HTML never enter this envelope. */
export function encodeStructuredTextTranslationResult(
  result: Pick<StructuredTextTranslationResult, "translations">,
): string {
  return `${ENVELOPE_PREFIX}${JSON.stringify({
    translations: result.translations.map(({ id, translatedText }) => ({ id, translatedText })),
  } satisfies StructuredTextTranslationEnvelope)}`;
}

/** Returns null for legacy plain-text cache values and malformed envelopes. */
export function decodeStructuredTextTranslationResult(
  value: string,
): StructuredTextTranslationEnvelope | null {
  if (!value.startsWith(ENVELOPE_PREFIX)) return null;
  try {
    const parsed: unknown = JSON.parse(value.slice(ENVELOPE_PREFIX.length));
    if (!isEnvelope(parsed)) return null;
    return {
      translations: parsed.translations.map(({ id, translatedText }) => ({ id, translatedText })),
    };
  } catch {
    return null;
  }
}

// HTML-specific aliases make the cache helper discoverable at its use site.
export const encodeStructuredHtmlTranslationResult = encodeStructuredTextTranslationResult;
export const decodeStructuredHtmlTranslationResult = decodeStructuredTextTranslationResult;

function exactTranslations(
  segments: readonly StructuredTextTranslationSegment[],
  result: StructuredTextTranslationResult,
): Map<string, string> {
  if (!Array.isArray(result?.translations)) {
    throw new Error("Structured translation response is missing translations.");
  }
  const expected = new Set(segments.map(({ id }) => id));
  const output = new Map<string, string>();
  for (const translation of result.translations) {
    if (!translation || typeof translation.id !== "string" || typeof translation.translatedText !== "string") {
      throw new Error("Structured translation response is invalid.");
    }
    if (!expected.has(translation.id) || output.has(translation.id)
      || !translation.translatedText.trim()) {
      throw new Error("Structured translation response does not exactly match its plan.");
    }
    output.set(translation.id, translation.translatedText);
  }
  if (output.size !== expected.size) {
    throw new Error("Structured translation response does not exactly match its plan.");
  }
  return output;
}

function visibleTextNodes(root: Node): Text[] {
  const documentForRoot = root.ownerDocument ?? document;
  const filter = documentForRoot.defaultView?.NodeFilter.SHOW_TEXT ?? 4;
  const walker = documentForRoot.createTreeWalker(root, filter);
  const output: Text[] = [];
  let current: Node | null;
  while ((current = walker.nextNode())) {
    if (current.nodeType !== Node.TEXT_NODE || !current.textContent?.trim() || hasExcludedAncestor(current, root)) continue;
    output.push(current as Text);
  }
  return output;
}

function readablePlainText(root: Node): string {
  const chunks: string[] = [];
  const appendBreak = () => {
    if (chunks.length && !chunks[chunks.length - 1].endsWith("\n")) chunks.push("\n\n");
  };
  const visit = (node: Node) => {
    if (node.nodeType === Node.TEXT_NODE) {
      if (node.textContent?.trim()) chunks.push(node.textContent);
      return;
    }
    if (node instanceof Element && EXCLUDED_ANCESTOR_TAGS.has(node.localName)) return;
    if (node instanceof HTMLBRElement) {
      chunks.push("\n");
      return;
    }
    for (const child of node.childNodes) visit(child);
    if (node instanceof Element && BLOCK_TEXT_TAGS.has(node.localName)) appendBreak();
  };
  visit(root);
  return chunks.join("")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n[ \t]+/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function hasExcludedAncestor(node: Node, boundary: Node): boolean {
  let current = node.parentElement;
  while (current) {
    if (EXCLUDED_ANCESTOR_TAGS.has(current.localName)) return true;
    if (current === boundary) return false;
    current = current.parentElement;
  }
  return false;
}

function pathToNode(node: Node, root: Node): number[] {
  const path: number[] = [];
  let current: Node | null = node;
  while (current && current !== root) {
    const parent: ParentNode | null = current.parentNode;
    if (!parent) throw new Error("Cannot locate structured HTML text node.");
    const index = Array.prototype.indexOf.call(parent.childNodes, current) as number;
    if (index < 0) throw new Error("Cannot locate structured HTML text node.");
    path.unshift(index);
    current = parent;
  }
  if (current !== root) throw new Error("Cannot locate structured HTML text node.");
  return path;
}

function nodeAtPath(root: Node, path: readonly number[]): Node | null {
  let current: Node | null = root;
  for (const index of path) current = current?.childNodes.item(index) ?? null;
  return current;
}

function normalizedByteLimit(value: number): number {
  if (!Number.isInteger(value) || value < 0) throw new Error("Structured translation byte limit is invalid.");
  return Math.min(value, MAX_STRUCTURED_HTML_TRANSLATION_BYTES);
}

function truncateByCharactersAndBytes(value: string, characterLimit: number, byteLimit: number): { value: string } {
  let output = "";
  let characters = 0;
  let bytes = 0;
  for (const character of value) {
    const characterBytes = utf8ByteLength(character);
    if (characters >= characterLimit || bytes + characterBytes > byteLimit) break;
    output += character;
    characters += 1;
    bytes += characterBytes;
  }
  return { value: output };
}

function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function isEnvelope(value: unknown): value is StructuredTextTranslationEnvelope {
  if (!value || typeof value !== "object" || !Array.isArray((value as { translations?: unknown }).translations)) return false;
  return (value as { translations: unknown[] }).translations.every((translation) =>
    Boolean(translation)
    && typeof (translation as { id?: unknown }).id === "string"
    && typeof (translation as { translatedText?: unknown }).translatedText === "string",
  );
}
