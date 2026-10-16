export interface MarkdownPasteSelection {
  from: number;
  to: number;
}

export interface MarkdownSmartPastePayload {
  plainText: string;
  html?: string | null;
  baseUrl?: string | null;
}

export interface MarkdownSmartPastePlan {
  text: string;
  selection: MarkdownPasteSelection;
  kind: "link" | "richText";
  removedTrackingParameterCount: number;
  status: "applied";
}

export interface SanitizedMarkdownPasteUrl {
  value: string;
  scheme: "http" | "https" | "mailto" | null;
  removedTrackingParameterCount: number;
}

export interface MarkdownRichTextPasteConversion {
  markdown: string;
  removedTrackingParameterCount: number;
}

export const MARKDOWN_SMART_PASTE_MAX_SIZE = 512 * 1024;

const trackingParameterNames = new Set([
  "dclid", "fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "msclkid",
  "vero_conv", "vero_id", "_hsenc", "_hsmi",
]);

const skippedElements = new Set([
  "applet", "button", "canvas", "form", "head", "iframe", "input", "link",
  "meta", "noscript", "object", "script", "select", "style", "svg", "textarea",
]);

const blockElements = new Set([
  "address", "article", "aside", "blockquote", "body", "dd", "div", "dl", "dt",
  "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header",
  "hr", "html", "main", "nav", "ol", "p", "pre", "section", "table", "ul",
]);

const controlCharacters = /[\u0000-\u001f\u007f-\u009f]/;

function finiteInteger(value: number): number {
  return Number.isFinite(value) ? Math.trunc(value) : 0;
}

function clampSelection(source: string, selection: MarkdownPasteSelection): MarkdownPasteSelection {
  const clamp = (value: number) => Math.max(0, Math.min(source.length, finiteInteger(value)));
  const from = clamp(selection.from);
  const to = clamp(selection.to);
  return { from: Math.min(from, to), to: Math.max(from, to) };
}

function normalizeUrlCandidate(value: string): string | null {
  const candidate = value.replace(/&amp;/gi, "&").trim();
  return candidate && !controlCharacters.test(candidate) ? candidate : null;
}

function safeBaseUrl(value: string | null | undefined): URL | null {
  if (!value || controlCharacters.test(value)) return null;
  try {
    return new URL(value);
  } catch {
    return null;
  }
}

/** Sanitizes a destination used by rich-text paste. Relative URLs require a base URL. */
export function sanitizeMarkdownPasteUrl(value: string, baseUrl?: string | null): SanitizedMarkdownPasteUrl | null {
  const candidate = normalizeUrlCandidate(value);
  if (!candidate) return null;
  if (candidate.startsWith("#")) {
    return { value: candidate, scheme: null, removedTrackingParameterCount: 0 };
  }

  let url: URL;
  try {
    url = new URL(candidate);
  } catch {
    const base = safeBaseUrl(baseUrl);
    if (!base) return null;
    try {
      url = new URL(candidate, base);
    } catch {
      return null;
    }
  }

  const scheme = url.protocol.slice(0, -1).toLowerCase();
  if (scheme !== "http" && scheme !== "https" && scheme !== "mailto") return null;
  if ((scheme === "http" || scheme === "https") && (!url.hostname || url.username || url.password)) return null;

  const originalParameters = Array.from(url.searchParams.entries());
  const keptParameters = originalParameters.filter(([name]) => {
    const normalized = name.toLowerCase();
    return !normalized.startsWith("utm_") && !trackingParameterNames.has(normalized);
  });
  if (keptParameters.length !== originalParameters.length) {
    url.search = "";
    for (const [name, parameterValue] of keptParameters) url.searchParams.append(name, parameterValue);
  }

  return {
    value: url.href,
    scheme: scheme as "http" | "https" | "mailto",
    removedTrackingParameterCount: originalParameters.length - keptParameters.length,
  };
}

function markdownDestination(value: string, forceAngleBrackets = false): string {
  return forceAngleBrackets || /\s/.test(value) || value.includes("(") || value.includes(")")
    ? `<${value.replace(/>/g, "%3E")}>`
    : value;
}

function escapeText(value: string): string {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/`/g, "\\`")
    .replace(/\*/g, "\\*")
    .replace(/_/g, "\\_")
    .replace(/\[/g, "\\[")
    .replace(/\]/g, "\\]");
}

function escapeLabel(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/\]/g, "\\]");
}

function sourceNeedsMarkdownAngleBrackets(value: string): boolean {
  const candidate = value.replace(/&amp;/gi, "&").trim();
  return /\s/.test(candidate);
}

function normalizedInline(value: string): string {
  return value.replace(/[ \t]+\n/g, "\n").replace(/\n[ \t]+/g, "\n").trim();
}

function normalizedDocument(value: string): string {
  return value
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((line) => line.replace(/[ \t]+$/g, ""))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function collapsedWhitespace(value: string): string {
  return value.replace(/\u00a0/g, " ").replace(/\s+/g, " ");
}

function longestBacktickRun(value: string): number {
  let longest = 0;
  let current = 0;
  for (const character of value) {
    current = character === "`" ? current + 1 : 0;
    longest = Math.max(longest, current);
  }
  return longest;
}

function elementName(element: Element): string {
  return element.localName.toLowerCase();
}

function childElements(element: Element): Element[] {
  return Array.from(element.children);
}

function directChildren(element: Element): Node[] {
  return Array.from(element.childNodes);
}

class HtmlToMarkdownRenderer {
  removedTrackingParameterCount = 0;

  constructor(private readonly baseUrl?: string | null) {}

  renderDocument(root: Element): string {
    const body = root.querySelector("body");
    return normalizedDocument(this.renderContainer(directChildren(body ?? root)));
  }

  private renderContainer(nodes: Node[]): string {
    const blocks: string[] = [];
    let inlineNodes: Node[] = [];
    const flushInline = () => {
      const inline = normalizedInline(this.renderInline(inlineNodes));
      if (inline) blocks.push(inline);
      inlineNodes = [];
    };
    for (const node of nodes) {
      if (node.nodeType === Node.ELEMENT_NODE && blockElements.has(elementName(node as Element))) {
        flushInline();
        const block = this.renderBlock(node as Element).trim();
        if (block) blocks.push(block);
      } else {
        inlineNodes.push(node);
      }
    }
    flushInline();
    return blocks.join("\n\n");
  }

  private renderBlock(element: Element): string {
    const name = elementName(element);
    if (skippedElements.has(name)) return "";
    if (/^h[1-6]$/.test(name)) {
      const title = normalizedInline(this.renderInline(directChildren(element))).replace(/\s+/g, " ");
      return title ? `${"#".repeat(Number(name.slice(1)))} ${title}` : "";
    }
    switch (name) {
      case "p": case "address": case "figcaption":
        return normalizedInline(this.renderInline(directChildren(element)));
      case "ul": case "ol": return this.renderList(element, 0);
      case "blockquote": {
        const quoted = normalizedDocument(this.renderContainer(directChildren(element)));
        return quoted ? quoted.split("\n").map((line) => line ? `> ${line}` : ">").join("\n") : "";
      }
      case "pre": return this.renderCodeBlock(element);
      case "table": return this.renderTable(element);
      case "hr": return "---";
      case "dt": {
        const term = normalizedInline(this.renderInline(directChildren(element)));
        return term ? `**${term}**` : "";
      }
      case "dd": {
        const definition = normalizedDocument(this.renderContainer(directChildren(element)));
        return definition ? definition.split("\n").map((line) => `  ${line}`).join("\n") : "";
      }
      default: return this.renderContainer(directChildren(element));
    }
  }

  private renderInline(nodes: Node[]): string {
    return nodes.map((node) => this.renderInlineNode(node)).join("");
  }

  private renderInlineNode(node: Node): string {
    if (node.nodeType === Node.TEXT_NODE) return escapeText(collapsedWhitespace(node.textContent ?? ""));
    if (node.nodeType !== Node.ELEMENT_NODE) return "";
    const element = node as Element;
    const name = elementName(element);
    if (skippedElements.has(name)) return "";
    const content = this.renderInline(directChildren(element));
    switch (name) {
      case "br": return "\n";
      case "strong": case "b": {
        const text = normalizedInline(content); return text ? `**${text}**` : "";
      }
      case "em": case "i": {
        const text = normalizedInline(content); return text ? `*${text}*` : "";
      }
      case "del": case "s": case "strike": {
        const text = normalizedInline(content); return text ? `~~${text}~~` : "";
      }
      case "code": case "tt": case "kbd": case "samp": return this.inlineCode(element.textContent ?? "");
      case "a": return this.renderLink(element, normalizedInline(content));
      case "img": return this.renderImage(element);
      case "sub": { const text = normalizedInline(content); return text ? `~${text}~` : ""; }
      case "sup": { const text = normalizedInline(content); return text ? `^${text}^` : ""; }
      default: return blockElements.has(name) ? this.renderBlock(element) : content;
    }
  }

  private destination(value: string | null): string | null {
    if (!value) return null;
    const sanitized = sanitizeMarkdownPasteUrl(value, this.baseUrl);
    if (!sanitized) return null;
    this.removedTrackingParameterCount += sanitized.removedTrackingParameterCount;
    return sanitized.value;
  }

  private renderLink(element: Element, label: string): string {
    const rawDestination = element.getAttribute("href");
    const destination = this.destination(rawDestination);
    if (!destination) return label;
    return `[${label || destination}](${markdownDestination(destination, sourceNeedsMarkdownAngleBrackets(rawDestination ?? ""))})`;
  }

  private renderImage(element: Element): string {
    const alt = escapeLabel((element.getAttribute("alt") ?? "").trim());
    const rawDestination = element.getAttribute("src");
    const destination = this.destination(rawDestination);
    return destination ? `![${alt}](${markdownDestination(destination, sourceNeedsMarkdownAngleBrackets(rawDestination ?? ""))})` : alt;
  }

  private renderList(list: Element, depth: number): string {
    const ordered = elementName(list) === "ol";
    const start = Number.parseInt(list.getAttribute("start") ?? "", 10) || 1;
    const items = childElements(list).filter((element) => elementName(element) === "li");
    const lines: string[] = [];
    items.forEach((item, index) => {
      const nested = childElements(item).filter((element) => ["ul", "ol"].includes(elementName(element)));
      const contentNodes = directChildren(item).filter((node) => node.nodeType !== Node.ELEMENT_NODE || !["ul", "ol"].includes(elementName(node as Element)));
      const content = normalizedDocument(this.renderContainer(contentNodes));
      const marker = ordered ? `${start + index}. ` : "- ";
      const indent = "  ".repeat(depth);
      const contentLines = content.split("\n");
      if (contentLines[0]) {
        lines.push(indent + marker + contentLines[0]);
        const continuation = indent + " ".repeat(marker.length);
        lines.push(...contentLines.slice(1).map((line) => line ? continuation + line : continuation));
      } else {
        lines.push(indent + marker.trimEnd());
      }
      for (const child of nested) {
        const rendered = this.renderList(child, depth + 1);
        if (rendered) lines.push(rendered);
      }
    });
    return lines.join("\n");
  }

  private renderTable(table: Element): string {
    const rows: Array<{ cells: string[]; alignments: string[] }> = [];
    const visit = (element: Element) => {
      for (const child of childElements(element)) {
        const name = elementName(child);
        if (name === "table" && child !== table) continue;
        if (name === "tr") {
          const cells = childElements(child).filter((cell) => ["th", "td"].includes(elementName(cell)));
          if (cells.length) rows.push({
            cells: cells.map((cell) => normalizedDocument(this.renderContainer(directChildren(cell))).replace(/\n/g, "<br>").replace(/\|/g, "\\|")),
            alignments: cells.map((cell) => this.tableAlignment(cell)),
          });
        } else {
          visit(child);
        }
      }
    };
    visit(table);
    if (!rows.length) return "";
    const columns = Math.max(...rows.map((row) => row.cells.length));
    const pad = (values: string[], fill = "") => values.concat(Array(Math.max(0, columns - values.length)).fill(fill));
    const line = (cells: string[]) => `| ${cells.join(" | ")} |`;
    const alignment = (value: string) => value === "left" ? ":---" : value === "center" ? ":---:" : value === "right" ? "---:" : "---";
    return [line(pad(rows[0].cells)), line(pad(rows[0].alignments, "").map(alignment)), ...rows.slice(1).map((row) => line(pad(row.cells)))].join("\n");
  }

  private tableAlignment(cell: Element): string {
    const direct = cell.getAttribute("align")?.toLowerCase();
    const styled = cell.getAttribute("style")?.match(/text-align\s*:\s*(left|center|right)/i)?.[1]?.toLowerCase();
    return direct === "left" || direct === "center" || direct === "right" ? direct : styled ?? "";
  }

  private renderCodeBlock(pre: Element): string {
    const source = (pre.textContent ?? "").replace(/\r\n?/g, "\n").replace(/^\n+|\n+$/g, "");
    const fence = "`".repeat(Math.max(3, longestBacktickRun(source) + 1));
    const code = pre.querySelector("code");
    const language = this.codeLanguage(code, pre);
    return `${fence}${language}\n${source}\n${fence}`;
  }

  private codeLanguage(code: Element | null, pre: Element): string {
    const candidates = [
      code?.getAttribute("data-language"), code?.getAttribute("class"),
      pre.getAttribute("data-language"), pre.getAttribute("class"),
    ].filter((value): value is string => Boolean(value));
    for (const candidate of candidates) {
      for (const token of candidate.split(/\s+/)) {
        const language = token.startsWith("language-") ? token.slice(9) : token.startsWith("lang-") ? token.slice(5) : (code?.getAttribute("data-language") === candidate || pre.getAttribute("data-language") === candidate) ? token : "";
        if (language && /^[A-Za-z0-9_+-]+$/.test(language)) return language;
      }
    }
    return "";
  }

  private inlineCode(value: string): string {
    const source = value.replace(/\r?\n/g, " ");
    if (!source) return "";
    const fence = "`".repeat(Math.max(1, longestBacktickRun(source) + 1));
    return /^`|`$|^\s|\s$/.test(source) ? `${fence} ${source} ${fence}` : `${fence}${source}${fence}`;
  }
}

function hasRichTextSemantics(root: Element): boolean {
  let paragraphCount = 0;
  let blockCount = 0;
  let meaningful = false;
  const visit = (element: Element) => {
    const name = elementName(element);
    if (skippedElements.has(name)) return;
    if (["h1", "h2", "h3", "h4", "h5", "h6", "strong", "b", "em", "i", "del", "s", "strike", "a", "img", "ul", "ol", "blockquote", "pre", "code", "hr", "table", "br"].includes(name)) meaningful = true;
    if (name === "p") paragraphCount += 1;
    if (["div", "article", "section", "li"].includes(name)) blockCount += 1;
    childElements(element).forEach(visit);
  };
  visit(root);
  return meaningful || paragraphCount > 0 || blockCount > 1;
}

/** Converts safe, semantically rich HTML into Markdown. Plain text-only HTML returns null. */
export function convertRichTextPasteHtml(html: string, baseUrl?: string | null): MarkdownRichTextPasteConversion | null {
  if (!html || html.length > MARKDOWN_SMART_PASTE_MAX_SIZE || typeof DOMParser === "undefined") return null;
  try {
    const document = new DOMParser().parseFromString(html, "text/html");
    if (!document.body || document.querySelector("parsererror") || !hasRichTextSemantics(document.body)) return null;
    const renderer = new HtmlToMarkdownRenderer(baseUrl);
    const markdown = renderer.renderDocument(document.body);
    if (!markdown || markdown.length > MARKDOWN_SMART_PASTE_MAX_SIZE) return null;
    return { markdown, removedTrackingParameterCount: renderer.removedTrackingParameterCount };
  } catch {
    return null;
  }
}

/** Returns a replacement plan only when paste content has an intentional Markdown transformation. */
export function planMarkdownSmartPaste(source: string, selection: MarkdownPasteSelection, payload: MarkdownSmartPastePayload): MarkdownSmartPastePlan | null {
  if (typeof source !== "string" || typeof payload?.plainText !== "string" || payload.plainText.length > MARKDOWN_SMART_PASTE_MAX_SIZE) return null;
  const range = clampSelection(source, selection);
  const replacement = (text: string, kind: "link" | "richText", removedTrackingParameterCount: number): MarkdownSmartPastePlan | null => {
    if (!text || text.length > MARKDOWN_SMART_PASTE_MAX_SIZE) return null;
    const next = source.slice(0, range.from) + text + source.slice(range.to);
    if (next.length > source.length - (range.to - range.from) + MARKDOWN_SMART_PASTE_MAX_SIZE) return null;
    const cursor = range.from + text.length;
    return { text: next, selection: { from: cursor, to: cursor }, kind, removedTrackingParameterCount, status: "applied" };
  };

  if (range.from !== range.to) {
    const url = sanitizeMarkdownPasteUrl(payload.plainText);
    if (url && (url.scheme === "http" || url.scheme === "https")) {
      const label = source.slice(range.from, range.to);
      if (label.trim()) {
        return replacement(`[${escapeLabel(label)}](${markdownDestination(url.value, sourceNeedsMarkdownAngleBrackets(payload.plainText))})`, "link", url.removedTrackingParameterCount);
      }
    }
  }

  if (typeof payload.html === "string") {
    const conversion = convertRichTextPasteHtml(payload.html, payload.baseUrl);
    if (conversion) return replacement(conversion.markdown, "richText", conversion.removedTrackingParameterCount);
  }
  return null;
}
