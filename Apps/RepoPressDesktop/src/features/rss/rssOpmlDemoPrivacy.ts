import type { RssOpmlDirection, RssOpmlReview } from "./contracts";

export interface DemoOpmlEntry {
  feedUrl: string;
  siteUrl: string | null;
  title: string;
}

interface UrlRisk {
  displayUrl: string;
  parameterNames: string[];
  containsUserInfo: boolean;
  blocked: boolean;
}

interface EntryAssessment {
  affected: boolean;
  blocked: boolean;
  titleAffected: boolean;
  findings: RssOpmlReview["findings"];
}

const MAX_OPML_BYTES = 4 * 1024 * 1024;
const MAX_OUTLINES = 10_000;
const MAX_DEPTH = 256;
const MAX_TITLE_BYTES = 4 * 1024;
const MAX_TITLE_URL_CHARS = 8_192;

export function parseDemoOpml(value: string): DemoOpmlEntry[] {
  if (new TextEncoder().encode(value).byteLength > MAX_OPML_BYTES || /<\s*!(?:DOCTYPE|ENTITY)\b/i.test(value)) throw new Error("OPML XML 无法安全解析。");
  const document = new DOMParser().parseFromString(value, "application/xml");
  if (document.querySelector("parsererror") || document.documentElement.localName.toLowerCase() !== "opml") throw new Error("OPML XML 无法解析。");
  const rootChildren = [...document.documentElement.children];
  const bodies = rootChildren.filter((element) => element.localName.toLowerCase() === "body");
  if (bodies.length !== 1 || rootChildren.some((element) => !["head", "body"].includes(element.localName.toLowerCase())) || rootChildren.filter((element) => element.localName.toLowerCase() === "head").length > 1) throw new Error("OPML 必须包含单一 body，且只能包含标准 head/body 根元素。");
  let outlineCount = 0;
  const entries: DemoOpmlEntry[] = [];
  const visit = (element: Element, depth: number) => {
    if (element.localName.toLowerCase() !== "outline") throw new Error("OPML body 只能包含 outline 元素。");
    outlineCount += 1;
    if (outlineCount > MAX_OUTLINES || depth > MAX_DEPTH) throw new Error("OPML 超出安全的节点数或嵌套深度限制。");
    const feedUrl = element.getAttribute("xmlUrl");
    if (feedUrl !== null) entries.push({ feedUrl, siteUrl: element.getAttribute("htmlUrl"), title: (element.getAttribute("title") ?? element.getAttribute("text") ?? "").trim() });
    for (const child of [...element.children]) visit(child, depth + 1);
  };
  for (const child of [...bodies[0].children]) visit(child, 1);
  return entries;
}

export function reviewDemoOpml(direction: RssOpmlDirection, entries: ReadonlyArray<DemoOpmlEntry>): RssOpmlReview {
  const findings: RssOpmlReview["findings"] = [];
  let affectedCount = 0;
  let blockedCount = 0;
  entries.forEach((entry, index) => {
    const assessment = assessEntry(entry, index);
    if (assessment.affected) affectedCount += 1;
    if (assessment.blocked) blockedCount += 1;
    findings.push(...assessment.findings);
  });
  return { direction, fingerprint: `browser-demo-${crypto.randomUUID()}`, totalCount: entries.length, affectedCount, blockedCount, findings };
}

export function transformDemoOpml(entries: ReadonlyArray<DemoOpmlEntry>, action: "redact" | "exclude") {
  const transformed: DemoOpmlEntry[] = [];
  let excludedCount = 0;
  entries.forEach((entry, index) => {
    const assessment = assessEntry(entry, index);
    if (assessment.affected && action === "exclude") { excludedCount += 1; return; }
    if (assessment.blocked) throw new Error("OPML 含无法安全脱敏的内容，请改为排除风险订阅。");
    const feedUrl = redactUrl(entry.feedUrl);
    const siteUrl = entry.siteUrl ? redactUrl(entry.siteUrl) : null;
    const title = assessment.titleAffected ? new URL(feedUrl).hostname || "RSS feed" : entry.title;
    transformed.push({ feedUrl, siteUrl, title });
  });
  return { opml: serializeDemoOpml(transformed), entries: transformed, excludedCount };
}

function assessEntry(entry: DemoOpmlEntry, index: number): EntryAssessment {
  const findings: RssOpmlReview["findings"] = [];
  let affected = false;
  let blocked = false;
  for (const [location, value] of [["feed", entry.feedUrl], ["site", entry.siteUrl]] as const) {
    if (!value) continue;
    const risk = inspectUrl(value);
    if (!risk) continue;
    affected = true;
    blocked ||= risk.blocked;
    findings.push({ index, location, displayUrl: risk.displayUrl, parameterNames: risk.parameterNames, containsUserInfo: risk.containsUserInfo });
  }
  const title = inspectTitle(entry.title);
  if (title.blocked) {
    affected = true;
    blocked = true;
    findings.push({ index, location: "title", displayUrl: "Title URL (cannot be safely displayed)", parameterNames: [], containsUserInfo: false });
  } else {
    for (const risk of title.risks) {
      affected = true;
      findings.push({ index, location: "title", displayUrl: risk.displayUrl, parameterNames: risk.parameterNames, containsUserInfo: risk.containsUserInfo });
    }
  }
  return { affected, blocked, titleAffected: title.blocked || title.risks.length > 0, findings };
}

function inspectTitle(title: string): { blocked: boolean; risks: UrlRisk[] } {
  if (new TextEncoder().encode(title).byteLength > MAX_TITLE_BYTES) return { blocked: true, risks: [] };
  const starts = [...title.matchAll(/https?:\/\//gi)].map((match) => match.index);
  const risks: UrlRisk[] = [];
  for (let index = 0; index < starts.length; index += 1) {
    const start = starts[index];
    let delimiterEnd = title.length;
    for (let cursor = start + 1; cursor < title.length; cursor += 1) {
      if (titleUrlDelimiter(title[cursor])) { delimiterEnd = cursor; break; }
    }
    const end = Math.min(delimiterEnd, starts[index + 1] ?? title.length);
    const raw = title.slice(start, end);
    if ([...raw].length > MAX_TITLE_URL_CHARS) return { blocked: true, risks: [] };
    let parsed: URL;
    try { parsed = new URL(raw); } catch { return { blocked: true, risks: [] }; }
    if (!/^https?:$/.test(parsed.protocol) || !parsed.hostname) return { blocked: true, risks: [] };
    const risk = inspectUrl(raw, false);
    if (risk) risks.push(risk);
  }
  return { blocked: false, risks };
}

function inspectUrl(value: string, blockUserInfo = true): UrlRisk | null {
  try {
    const url = new URL(value);
    const parameterNames = [...new Set([...url.searchParams.keys()].filter(credentialParameter))];
    const containsUserInfo = Boolean(url.username || url.password);
    const invalid = !/^https?:$/.test(url.protocol) || !url.hostname;
    if (!parameterNames.length && !containsUserInfo && !invalid) return null;
    const display = new URL(url.toString());
    if (display.username || display.password) { display.username = "redacted"; display.password = ""; }
    for (const name of [...display.searchParams.keys()]) display.searchParams.set(name, "REDACTED");
    display.hash = "";
    return { displayUrl: display.toString(), parameterNames, containsUserInfo, blocked: invalid || (blockUserInfo && containsUserInfo) };
  } catch {
    return { displayUrl: "Subscription URL (cannot be safely displayed)", parameterNames: [], containsUserInfo: false, blocked: true };
  }
}

function redactUrl(value: string) {
  const url = new URL(value);
  for (const name of [...url.searchParams.keys()].filter(credentialParameter)) url.searchParams.set(name, "REDACTED");
  return url.toString();
}

function credentialParameter(name: string) {
  const normalized = [...name].filter((character) => /[\p{L}\p{N}]/u.test(character)).join("").toLocaleLowerCase();
  return normalized.includes("token") || normalized.includes("signature") || normalized.includes("credential") || normalized.includes("authorization") || normalized.includes("authentication") || normalized.includes("password") || normalized.includes("passwd") || normalized.includes("secret") || normalized.includes("apikey") || normalized.includes("accesskey") || normalized.includes("privatekey") || normalized.includes("clientkey") || normalized.includes("consumerkey") || normalized.includes("subscriptionkey") || normalized.startsWith("oauth") || (normalized.startsWith("auth") && !normalized.startsWith("author")) || ["key", "sig", "jwt"].includes(normalized);
}

function titleUrlDelimiter(character: string) {
  return /\s/u.test(character) || "<>\"'()[]{}，。；：！？【】《》「」『』".includes(character);
}

function serializeDemoOpml(entries: ReadonlyArray<DemoOpmlEntry>) {
  const document = new DOMParser().parseFromString('<opml version="2.0"><head><title>RSS Subscriptions</title></head><body/></opml>', "application/xml");
  const body = document.querySelector("body")!;
  for (const entry of entries) {
    const outline = document.createElement("outline");
    outline.setAttribute("text", entry.title);
    outline.setAttribute("title", entry.title);
    outline.setAttribute("type", "rss");
    outline.setAttribute("xmlUrl", entry.feedUrl);
    if (entry.siteUrl) outline.setAttribute("htmlUrl", entry.siteUrl);
    body.append(outline);
  }
  return new XMLSerializer().serializeToString(document);
}
