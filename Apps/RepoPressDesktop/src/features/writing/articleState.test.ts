import { describe, expect, it } from "vitest";
import type { ArticleStateInput } from "../../contracts/articleState";
import { MAX_ARTICLE_STATE_BYTES, projectArticleState } from "./articleState";

const NOW = Date.UTC(2026, 9, 15, 12, 0, 0);

function repositoryInput(text: string, overrides: Partial<Extract<ArticleStateInput["context"], { kind: "repository" }>> = {}): ArticleStateInput {
  return {
    text,
    nowEpochMs: NOW,
    context: {
      kind: "repository",
      repository: { sessionId: "session", siteKind: "hugo", contentRoot: "content" },
      documentId: "document",
      relativePath: "content/posts/article.md",
      writable: true,
      ...overrides,
    },
  };
}

function codes(projection: ReturnType<typeof projectArticleState>) {
  return projection.issues.map((item) => item.code);
}

describe("projectArticleState", () => {
  it("projects explicit YAML and TOML draft intent without claiming publication", () => {
    const yaml = projectArticleState(repositoryInput('---\ntitle: "Draft"\ndate: 2026-10-15T11:00:00Z\ndraft: true\n---\nBody'));
    const toml = projectArticleState(repositoryInput('+++\ntitle = "Ready"\ndate = "2026-10-15T13:00:00+01:00"\ndraft = false\n+++\nBody'));

    expect(yaml).toMatchObject({ state: "draft", scope: "site", online: "unverified", date: { kind: "elapsed", epochMs: NOW - 60 * 60_000 } });
    expect(toml).toMatchObject({ state: "ready", scope: "site", online: "unverified", date: { kind: "elapsed", epochMs: NOW } });
    expect(codes(yaml)).toContain("publicationUnverified");
    expect(codes(toml)).toContain("publicationUnverified");
    expect(yaml.state).not.toBe("published");
  });

  it("requires explicit title, date, and draft fields instead of parser defaults", () => {
    const projection = projectArticleState(repositoryInput("---\nslug: article\n---\nBody"));
    expect(projection.state).toBeNull();
    expect(projection.date).toEqual({ kind: "absent", value: "", epochMs: null });
    expect(projection.issues).toEqual(expect.arrayContaining([
      expect.objectContaining({ code: "titleMissing", location: { kind: "field", field: "title" } }),
      expect.objectContaining({ code: "dateMissing", location: { kind: "field", field: "date" } }),
      expect.objectContaining({ code: "draftMissing", location: { kind: "field", field: "draft" } }),
    ]));
  });

  it("locates explicit empty fields by their full UTF-16 ranges", () => {
    const text = '\ufeff---\r\ntitle: \r\ndate: "2026-10-15T21:00:00+08:00"\r\ndraft: false\r\n---\r\n中文😀';
    const projection = projectArticleState(repositoryInput(text));
    const title = projection.issues.find((item) => item.code === "titleMissing");
    const date = projection.issues.find((item) => item.code === "dateFuture");
    expect(title?.location?.kind).toBe("range");
    expect(date?.location?.kind).toBe("range");
    const titleLocation = title?.location;
    const dateLocation = date?.location;
    if (titleLocation?.kind === "range") expect(text.slice(titleLocation.from, titleLocation.to)).toBe("title: \r\n");
    if (dateLocation?.kind === "range") expect(text.slice(dateLocation.from, dateLocation.to)).toBe('date: "2026-10-15T21:00:00+08:00"\r\n');
  });

  it.each([
    ["missing", "Body"],
    ["duplicate", "---\ntitle: one\ntitle: two\ndraft: false\n---\nBody"],
    ["complex", "---\ntitle: { nested: value }\ndraft: false\n---\nBody"],
    ["unclosed", "---\ntitle: one\ndraft: false\nBody"],
  ])("fails closed for %s front matter", (kind, text) => {
    const projection = projectArticleState(repositoryInput(text));
    expect(projection.state).toBeNull();
    const structural = projection.issues.find((item) => item.code === (kind === "missing" ? "frontMatterMissing" : "frontMatterInvalid"));
    expect(structural).toBeDefined();
    if (kind !== "missing") expect(structural?.location).toEqual({ kind: "range", from: 0, to: 3 });
  });

  it.each([
    ["TOML table", '+++\ntitle = "Top"\n[params]\ndate = "2026-10-15T12:00:00Z"\ndraft = false\n+++'],
    ["TOML quoted duplicate", '+++\ntitle = "Top"\ndate = "2026-10-15T12:00:00Z"\n"draft" = true\ndraft = false\n+++'],
    ["YAML quoted duplicate", '---\ntitle: Top\ndate: 2026-10-15T12:00:00Z\n"draft": true\ndraft: false\n---'],
  ])("fails closed for unsupported %s status structure", (_name, text) => {
    const projection = projectArticleState(repositoryInput(text));
    expect(projection.state).toBeNull();
    expect(codes(projection)).toContain("frontMatterInvalid");
  });

  it.each([
    ["spaced opening delimiter", ' ---\ntitle: T\ndate: 2026-10-15T12:00:00Z\ndraft: false\n---'],
    ["nested YAML", '---\ntitle: T\ndate: 2026-10-15T12:00:00Z\nparams:\n  draft: false\n---'],
    ["multiline unknown field", '---\ntitle: T\ndate: 2026-10-15T12:00:00Z\nextra: {\ndraft: false\n}\n---'],
  ])("does not project ready from ambiguous %s", (_name, text) => {
    const projection = projectArticleState(repositoryInput(text));
    expect(projection.state).toBeNull();
    expect(codes(projection)).toContain("frontMatterInvalid");
  });

  it("allows strict flat scalar extension metadata without letting it define article state", () => {
    const projection = projectArticleState(repositoryInput('---\ntitle: T\ndate: 2026-10-15T12:00:00Z\nauthor: "作者"\nsummary: "Line 1\\nLine 2"\nlayout: post\nrevision: 3\ndraft: false\n---'));
    expect(projection.state).toBe("ready");
    expect(codes(projection)).not.toContain("frontMatterInvalid");
  });

  it.each([
    ["bare TOML extension", '+++\ntitle = "T"\ndate = 2026-10-15T12:00:00Z\nauthor = person\ndraft = false\n+++'],
    ["YAML double quote tail", '---\ntitle: T\ndate: 2026-10-15T12:00:00Z\nauthor: "name" trailing\ndraft: false\n---'],
    ["YAML single quote tail", "---\ntitle: T\ndate: 2026-10-15T12:00:00Z\nauthor: 'name' trailing '\ndraft: false\n---"],
    ["TOML single quote tail", "+++\ntitle = \"T\"\ndate = 2026-10-15T12:00:00Z\nauthor = 'name' trailing '\ndraft = false\n+++"],
    ["known title single quote tail", "---\ntitle: 'name' trailing '\ndate: 2026-10-15T12:00:00Z\ndraft: false\n---"],
    ["duplicate TOML extension", '+++\ntitle = "T"\ndate = 2026-10-15T12:00:00Z\nauthor = "one"\nauthor = "two"\ndraft = false\n+++'],
  ])("fails closed for invalid %s scalar syntax", (_name, text) => {
    const projection = projectArticleState(repositoryInput(text));
    expect(projection.state).toBeNull();
    expect(codes(projection)).toContain("frontMatterInvalid");
  });

  it("marks read-only documents without changing their semantic state", () => {
    const projection = projectArticleState(repositoryInput("---\ntitle: T\ndate: 2026-10-15T12:00:00Z\ndraft: false\n---", { writable: false }));
    expect(projection).toMatchObject({ state: "ready", readOnly: true });
    expect(projection.issues).toContainEqual({ code: "readOnly", severity: "information", location: null });
  });

  it("keeps general drafts local-only independently of metadata and repository checks", () => {
    const text = "---\ndraft: false\n---\nLocal";
    const projection = projectArticleState({ text, nowEpochMs: NOW, context: { kind: "generalDraft", draftId: "draft", writable: true } });
    expect(projection).toMatchObject({ state: "localOnly", scope: "generalDraft", online: "unverified", date: { kind: "absent" } });
    expect(projection.issues).toEqual([]);
  });

  it("does not apply site clock or metadata checks to a general draft", () => {
    const projection = projectArticleState({ text: "---\ndraft: nonsense\n---", nowEpochMs: Number.NaN, context: { kind: "generalDraft", draftId: "draft", writable: false } });
    expect(projection).toMatchObject({ state: "localOnly", scope: "generalDraft", checkedAtEpochMs: null, readOnly: true });
    expect(codes(projection)).toEqual(["readOnly"]);
  });

  it.each([
    ["sibling prefix", "content-old/article.md", "outsideSite", "outsideContentRoot"],
    ["root itself", "content", "outsideSite", "outsideContentRoot"],
    ["outside", "posts/article.md", "outsideSite", "outsideContentRoot"],
    ["parent", "content/../secret.md", "unknown", "invalidPath"],
    ["dot", "content/./article.md", "unknown", "invalidPath"],
    ["empty segment", "content//article.md", "unknown", "invalidPath"],
    ["backslash", "content\\article.md", "unknown", "invalidPath"],
    ["absolute", "/content/article.md", "unknown", "invalidPath"],
  ])("does not infer state for %s paths", (_name, relativePath, scope, expectedIssue) => {
    const projection = projectArticleState(repositoryInput("---\ndraft: false\n---", { relativePath }));
    expect(projection).toMatchObject({ state: null, scope });
    expect(codes(projection)).toContain(expectedIssue);
  });

  it("requires a known site and a safe non-empty content root", () => {
    const unknownSite = projectArticleState(repositoryInput("---\ndraft: false\n---", { repository: { sessionId: "s", siteKind: "custom", contentRoot: "content" } }));
    const badRoot = projectArticleState(repositoryInput("---\ndraft: false\n---", { repository: { sessionId: "s", siteKind: "astro", contentRoot: "" } }));
    expect(unknownSite).toMatchObject({ state: null, scope: "unknown" });
    expect(codes(unknownSite)).toContain("siteUnknown");
    expect(badRoot).toMatchObject({ state: null, scope: "unknown" });
    expect(codes(badRoot)).toContain("invalidPath");
  });

  it.each(["hugo", "zola", "astro", "jekyll", "nextjs", "vitepress", "quartz", "hexo", "foam"])("recognizes repository detector site kind %s", (siteKind) => {
    const projection = projectArticleState(repositoryInput("---\ntitle: T\ndate: 2026-10-15T12:00:00Z\ndraft: true\n---", {
      repository: { sessionId: "s", siteKind, contentRoot: "content" },
    }));
    expect(projection).toMatchObject({ scope: "site", state: "draft" });
  });

  it.each([
    ["invalid calendar", "2026-02-30T00:00:00Z", "invalid", "dateInvalid"],
    ["invalid hour", "2026-10-15T24:00:00Z", "invalid", "dateInvalid"],
    ["invalid offset", "2026-10-15T12:00:00+14:01", "invalid", "dateInvalid"],
    ["date only", "2026-10-15", "timezoneUnknown", "dateTimezoneUnknown"],
    ["local datetime", "2026-10-15T12:00:00", "timezoneUnknown", "dateTimezoneUnknown"],
    ["unknown negative-zero offset", "2026-10-15T12:00:00-00:00", "timezoneUnknown", "dateTimezoneUnknown"],
    ["future", "2026-10-15T12:00:00.001Z", "future", "dateFuture"],
  ])("classifies %s dates without host-timezone parsing", (_name, value, kind, expectedIssue) => {
    const projection = projectArticleState(repositoryInput(`---\ntitle: T\ndate: ${value}\ndraft: false\n---`));
    expect(projection.date.kind).toBe(kind);
    expect(codes(projection)).toContain(expectedIssue);
    expect(projection.state).toBe("ready");
  });

  it.each([
    ["TOML case-sensitive key", '+++\ntitle = "T"\ndate = "2026-10-15T12:00:00Z"\nDraft = false\n+++'],
    ["YAML case-sensitive key", '---\ntitle: T\ndate: 2026-10-15T12:00:00Z\nDraft: false\n---'],
    ["noncanonical boolean", '+++\ntitle = "T"\ndate = "2026-10-15T12:00:00Z"\ndraft = False\n+++'],
  ])("does not accept %s as explicit draft intent", (_name, text) => {
    const projection = projectArticleState(repositoryInput(text));
    expect(projection.state).toBeNull();
    expect(codes(projection)).toContain("frontMatterInvalid");
  });

  it("treats an exact or elapsed zoned timestamp as elapsed, never published", () => {
    for (const value of ["2026-10-15T12:00:00Z", "2026-10-15T11:59:59Z", "2026-10-15T20:00:00+08:00"]) {
      const projection = projectArticleState(repositoryInput(`---\ntitle: T\ndate: ${value}\ndraft: false\n---`));
      expect(projection).toMatchObject({ state: "ready", date: { kind: "elapsed" } });
      expect(projection.date.epochMs).toBeLessThanOrEqual(NOW);
    }
  });

  it("reports an invalid injected clock and does not create a future claim", () => {
    const input = repositoryInput("---\ntitle: T\ndate: 2026-10-15T12:00:00Z\ndraft: false\n---");
    input.nowEpochMs = Number.NaN;
    const projection = projectArticleState(input);
    expect(projection.checkedAtEpochMs).toBeNull();
    expect(codes(projection)).toContain("clockInvalid");
    expect(projection.issues.find((item) => item.code === "clockInvalid")?.location).toBeNull();
    expect(codes(projection)).not.toContain("dateFuture");
    expect(projection.state).toBe("ready");
  });

  it("uses actual UTF-8 bytes for the bounded check and never inspects oversized text", () => {
    const raw = `---\ntitle: T\ndate: 2026-10-15T12:00:00Z\ndraft: false\n---\n${"界".repeat(Math.ceil(MAX_ARTICLE_STATE_BYTES / 3))}`;
    const repository = projectArticleState(repositoryInput(raw));
    const general = projectArticleState({ text: raw, nowEpochMs: NOW, context: { kind: "generalDraft", draftId: "d", writable: true } });
    expect(repository).toMatchObject({ state: null, limited: true, date: { kind: "absent" } });
    expect(general).toMatchObject({ state: "localOnly", limited: true, date: { kind: "absent" } });
    expect(codes(repository)).toEqual(expect.arrayContaining(["sizeLimit", "publicationUnverified"]));
    expect(codes(repository)).not.toEqual(expect.arrayContaining(["titleMissing", "draftMissing", "dateMissing"]));
    expect(raw.endsWith("界")).toBe(true);
  });

  it("does not modify frozen input or raw text", () => {
    const text = "---\ntitle: 原文 😀\ndate: 2026-10-15T12:00:00Z\ndraft: false\n---\r\n正文";
    const input = Object.freeze(repositoryInput(text));
    const before = input.text;
    projectArticleState(input);
    expect(input.text).toBe(before);
  });
});
