import { describe, expect, it } from "vitest";
import type { ArticleStateContext, ArticleStateIssueCode } from "../../contracts/articleState";
import { MAX_ARTICLE_STATE_BYTES, projectArticleState } from "./articleState";

const NOW = Date.parse("2026-10-15T00:00:00Z");
const repositoryContext: ArticleStateContext = {
  kind: "repository",
  repository: { sessionId: "session-1", siteKind: "hugo", contentRoot: "content" },
  documentId: "document-1",
  relativePath: "content/posts/article.md",
  writable: true,
};

function project(text: string, context: ArticleStateContext = repositoryContext, nowEpochMs = NOW) {
  return projectArticleState({ text, context, nowEpochMs });
}

function issueCodes(text: string, context: ArticleStateContext = repositoryContext, nowEpochMs = NOW): ArticleStateIssueCode[] {
  return project(text, context, nowEpochMs).issues.map((issue) => issue.code);
}

function yaml(fields: string, body = "Body") {
  return `---\n${fields}\n---\n\n${body}`;
}

describe("article state adversarial boundaries", () => {
  it("keeps publication unverified for the strongest locally-ready metadata", () => {
    const result = project(yaml([
      'title: "Article"',
      'date: "2026-10-14T23:59:59Z"',
      "draft: false",
    ].join("\n")));

    expect(result).toMatchObject({
      state: "ready",
      scope: "site",
      online: "unverified",
      readOnly: false,
      limited: false,
      checkedAtEpochMs: NOW,
      date: { kind: "elapsed", value: "2026-10-14T23:59:59Z", epochMs: Date.parse("2026-10-14T23:59:59Z") },
    });
    expect(result.issues).toContainEqual({ code: "publicationUnverified", severity: "information", location: { kind: "publishing" } });
    expect(result.state).not.toBe("published");
  });

  it("does not turn a missing or malformed draft field into an implicit draft or ready state", () => {
    const missing = project(yaml('title: "Article"\ndate: "2026-10-14T00:00:00Z"'));
    expect(missing.state).toBeNull();
    expect(missing.issues).toContainEqual(expect.objectContaining({ code: "draftMissing", location: { kind: "field", field: "draft" } }));

    for (const source of [
      yaml('title: "Article"\ndate: "2026-10-14T00:00:00Z"\ndraft: yes'),
      yaml('title: "Article"\ndate: "2026-10-14T00:00:00Z"\ndraft: true\ndraft: false'),
      "---\ntitle: Article\ndraft: false",
    ]) {
      const result = project(source);
      expect(result.state).toBeNull();
      expect(result.online).toBe("unverified");
      expect(issueCodes(source)).toContain("frontMatterInvalid");
    }
  });

  it("does not infer fields from TOML tables or nested YAML mappings", () => {
    const tomlTable = [
      "+++",
      "[params]",
      'title = "Section title"',
      'date = "2026-10-14T00:00:00Z"',
      "draft = false",
      "+++",
    ].join("\n");
    const nestedYaml = yaml([
      "article:",
      '  title: "Nested title"',
      '  date: "2026-10-14T00:00:00Z"',
      "  draft: false",
    ].join("\n"));

    for (const source of [tomlTable, nestedYaml]) {
      const result = project(source);
      expect(result.state).toBeNull();
      expect(result.state).not.toBe("ready");
      expect(result.online).toBe("unverified");
    }
  });

  it("fails closed for ambiguous headers, quoted draft keys, BOMs, and case variants", () => {
    const sources = [
      " ---\ntitle: Article\ndate: 2026-10-14T00:00:00Z\ndraft: false\n---",
      yaml('title: "Article"\ndate: "2026-10-14T00:00:00Z"\n"draft": true'),
      `\uFEFF${yaml('title: "Article"\ndate: "2026-10-14T00:00:00Z"\ndraft: true')}`,
      yaml('title: "Article"\ndate: "2026-10-14T00:00:00Z"\nDRAFT: true'),
    ];

    for (const source of sources) {
      const result = project(source);
      expect(result.state).not.toBe("ready");
      expect(result.state).not.toBe("published");
      expect(result.online).toBe("unverified");
    }
  });

  it("keeps duplicate unknown metadata irrelevant to publication evidence", () => {
    const result = project(yaml([
      'title: "Article"',
      'date: "2026-10-14T00:00:00Z"',
      "draft: false",
      "extension: one",
      "extension: two",
    ].join("\n")));

    expect(result.state).toBe("ready");
    expect(result.online).toBe("unverified");
    expect(result.state).not.toBe("published");
  });

  it.each([
    ["YAML quoted scalar with trailing garbage", yaml('title: Article\ndate: 2026-10-14T00:00:00Z\nauthor: "name" trailing\ndraft: false')],
    ["YAML inline array with trailing garbage", yaml('title: Article\ndate: 2026-10-14T00:00:00Z\nauthors: [one] trailing\ndraft: false')],
    ["TOML bare string", '+++\ntitle = "Article"\ndate = "2026-10-14T00:00:00Z"\nauthor = person\ndraft = false\n+++'],
    ["TOML quoted scalar with trailing garbage", '+++\ntitle = "Article"\ndate = "2026-10-14T00:00:00Z"\nauthor = "name" trailing\ndraft = false\n+++'],
  ])("does not project ready through invalid unknown metadata: %s", (_name, source) => {
    const result = project(source);
    expect(result.state).toBeNull();
    expect(result.issues.map((issue) => issue.code)).toContain("frontMatterInvalid");
    expect(result.online).toBe("unverified");
  });

  it("accepts a bounded set of valid one-line TOML extension values without letting them define state", () => {
    const source = [
      "+++",
      'title = "Article"',
      'date = "2026-10-14T00:00:00Z"',
      'author = "name"',
      "weight = 10",
      "featured = true",
      'authors = ["one", "two"]',
      'extra = { image = "cover.jpg" }',
      "draft = false",
      "+++",
    ].join("\n");
    const result = project(source);

    expect(result).toMatchObject({ state: "ready", scope: "site", online: "unverified" });
    expect(result.issues.map((issue) => issue.code)).not.toContain("frontMatterInvalid");
  });

  it("requires explicit general-draft provenance before reporting local-only", () => {
    const generalDraft: ArticleStateContext = { kind: "generalDraft", draftId: "general-1", writable: false };
    const unboundRepository: ArticleStateContext = {
      ...repositoryContext,
      repository: { ...repositoryContext.repository, siteKind: "unknown", contentRoot: null },
      relativePath: "notes/article.md",
    };

    expect(project("Body", generalDraft)).toMatchObject({ state: "localOnly", scope: "generalDraft", online: "unverified", readOnly: true });
    const repositoryResult = project("Body", unboundRepository);
    expect(repositoryResult.state).toBeNull();
    expect(repositoryResult.state).not.toBe("localOnly");
    expect(repositoryResult.scope).toBe("unknown");
    expect(issueCodes("Body", unboundRepository)).toContain("siteUnknown");
  });

  it("requires a known site and a lexical descendant of its safe content root", () => {
    const cases: Array<{ context: ArticleStateContext; code: ArticleStateIssueCode; scope: "outsideSite" | "unknown" }> = [
      {
        context: { ...repositoryContext, relativePath: "content-other/article.md" },
        code: "outsideContentRoot",
        scope: "outsideSite",
      },
      {
        context: { ...repositoryContext, relativePath: "content/../private/article.md" },
        code: "invalidPath",
        scope: "unknown",
      },
      {
        context: { ...repositoryContext, relativePath: "/content/article.md" },
        code: "invalidPath",
        scope: "unknown",
      },
      {
        context: { ...repositoryContext, repository: { ...repositoryContext.repository, siteKind: "wordpress" } },
        code: "siteUnknown",
        scope: "unknown",
      },
    ];
    const source = yaml('title: "Article"\ndate: "2026-10-14T00:00:00Z"\ndraft: false');

    for (const entry of cases) {
      const result = project(source, entry.context);
      expect(result).toMatchObject({ state: null, scope: entry.scope, online: "unverified" });
      expect(result.issues).toContainEqual(expect.objectContaining({ code: entry.code, location: { kind: "site" } }));
      expect(result.state).not.toBe("localOnly");
    }
  });

  it.each(["hugo", "zola", "astro", "nextjs", "vitepress", "quartz", "hexo", "jekyll", "foam"])(
    "recognizes the %s site kind emitted by repository detection",
    (siteKind) => {
      const context: ArticleStateContext = {
        ...repositoryContext,
        repository: { ...repositoryContext.repository, siteKind },
      };
      const result = project(yaml('title: Article\ndate: 2026-10-14T00:00:00Z\ndraft: false'), context);

      expect(result).toMatchObject({ state: "ready", scope: "site", online: "unverified" });
      expect(result.issues.map((issue) => issue.code)).not.toContain("siteUnknown");
    },
  );

  it("reports read-only separately without changing ownership or inventing publication", () => {
    const context: ArticleStateContext = { ...repositoryContext, writable: false };
    const result = project(yaml('title: Article\ndate: 2026-10-14T00:00:00Z\ndraft: false'), context);

    expect(result).toMatchObject({ state: "ready", scope: "site", readOnly: true, online: "unverified" });
    expect(result.issues).toContainEqual(expect.objectContaining({ code: "readOnly" }));
    expect(result.state).not.toBe("published");
  });

  it("compares only strict ISO timestamps with an explicit timezone", () => {
    const dateOnlySource = yaml('title: Article\ndate: 2026-10-14\ndraft: false');
    const dateOnly = project(dateOnlySource);
    expect(dateOnly.date).toEqual({ kind: "timezoneUnknown", value: "2026-10-14", epochMs: null });
    const timezoneIssue = dateOnly.issues.find((issue) => issue.code === "dateTimezoneUnknown");
    expect(timezoneIssue?.location).toMatchObject({ kind: "range" });
    if (timezoneIssue?.location?.kind === "range") {
      expect(dateOnlySource.slice(timezoneIssue.location.from, timezoneIssue.location.to)).toMatch(/^date: 2026-10-14/);
    }

    const localTimestamp = project(yaml('title: Article\ndate: 2026-10-14T12:00:00\ndraft: false'));
    expect(localTimestamp.date).toEqual({ kind: "timezoneUnknown", value: "2026-10-14T12:00:00", epochMs: null });

    const impossibleSource = yaml('title: Article\ndate: 2026-02-30T00:00:00Z\ndraft: false');
    const impossibleDate = project(impossibleSource);
    expect(impossibleDate.date).toEqual({ kind: "invalid", value: "2026-02-30T00:00:00Z", epochMs: null });
    const invalidIssue = impossibleDate.issues.find((issue) => issue.code === "dateInvalid");
    expect(invalidIssue?.location).toMatchObject({ kind: "range" });
    if (invalidIssue?.location?.kind === "range") {
      expect(impossibleSource.slice(invalidIssue.location.from, invalidIssue.location.to)).toMatch(/^date: 2026-02-30/);
    }
  });

  it("keeps issue ranges aligned to the original BOM and CRLF buffer", () => {
    const source = "\uFEFF---\r\ntitle: Article\r\ndate: 2026-10-15T08:00:01+08:00\r\ndraft: false\r\n---\r\n\r\nBody";
    const result = project(source);
    const dateIssue = result.issues.find((issue) => issue.code === "dateFuture");

    expect(result.state).toBe("ready");
    expect(dateIssue?.location).toMatchObject({ kind: "range", from: source.indexOf("date:") });
    if (dateIssue?.location?.kind === "range") {
      expect(source.slice(dateIssue.location.from, dateIssue.location.to)).toMatch(/^date: 2026-10-15T08:00:01\+08:00\r?\n/);
    }
  });

  it("treats elapsed and future dates as timing evidence, never publication evidence", () => {
    const elapsed = project(yaml('title: Article\ndate: 2026-10-15T07:59:59+08:00\ndraft: false'));
    expect(elapsed.date).toEqual({ kind: "elapsed", value: "2026-10-15T07:59:59+08:00", epochMs: NOW - 1_000 });
    expect(elapsed.state).toBe("ready");

    const futureSource = yaml('title: Article\ndate: 2026-10-15T08:00:01+08:00\ndraft: false');
    const future = project(futureSource);
    expect(future.date).toEqual({ kind: "future", value: "2026-10-15T08:00:01+08:00", epochMs: NOW + 1_000 });
    const futureIssue = future.issues.find((issue) => issue.code === "dateFuture");
    expect(futureIssue?.location).toMatchObject({ kind: "range" });
    if (futureIssue?.location?.kind === "range") {
      expect(futureSource.slice(futureIssue.location.from, futureIssue.location.to)).toMatch(/^date: 2026-10-15/);
    }
    expect(future.state).toBe("ready");
    expect(future.state).not.toBe("published");
  });

  it("fails closed when the supplied clock is invalid", () => {
    const source = yaml('title: Article\ndate: 2026-10-14T00:00:00Z\ndraft: false');
    for (const clock of [Number.NaN, Number.POSITIVE_INFINITY]) {
      const result = project(source, repositoryContext, clock);
      expect(result.checkedAtEpochMs).toBeNull();
      expect(result.issues).toContainEqual(expect.objectContaining({ code: "clockInvalid", location: null }));
      expect(result.state).not.toBe("published");
    }
  });

  it("enforces the byte cap at the boundary without partially interpreting oversized text", () => {
    const prefix = yaml('title: Article\ndate: 2026-10-14T00:00:00Z\ndraft: false', "");
    expect(prefix.length).toBeLessThan(MAX_ARTICLE_STATE_BYTES);
    const atLimit = prefix + "a".repeat(MAX_ARTICLE_STATE_BYTES - prefix.length);
    const overLimit = `${atLimit}a`;

    expect(project(atLimit)).toMatchObject({ state: "ready", limited: false, online: "unverified" });
    const limited = project(overLimit);
    expect(limited).toMatchObject({ state: null, limited: true, online: "unverified" });
    expect(limited.issues).toContainEqual(expect.objectContaining({ code: "sizeLimit" }));
  });
});
