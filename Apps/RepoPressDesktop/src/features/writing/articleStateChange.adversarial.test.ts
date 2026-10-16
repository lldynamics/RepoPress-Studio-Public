import { describe, expect, it } from "vitest";
import type { ArticleStateContext } from "../../contracts/articleState";
import type {
  ArticleStateChangeInput,
  ArticleStateChangeResult,
  EditableArticleState,
} from "../../contracts/articleStateChange";
import { MAX_ARTICLE_STATE_BYTES, projectArticleState } from "./articleState";
import { planArticleStateChange } from "./articleStateChange";

const NOW = Date.parse("2026-10-15T00:00:00Z");
const repositoryContext: Extract<ArticleStateContext, { kind: "repository" }> = {
  kind: "repository",
  repository: { sessionId: "session-1", siteKind: "hugo", contentRoot: "content" },
  documentId: "document-1",
  relativePath: "content/posts/article.md",
  writable: true,
};

function input(
  text: string,
  context: ArticleStateContext = repositoryContext,
  contextKey = "session-1:document-1:7",
): ArticleStateChangeInput {
  return { text, context, contextKey, nowEpochMs: NOW };
}

function requirePlan(result: ArticleStateChangeResult) {
  expect(result.ok).toBe(true);
  if (!result.ok) throw new Error(`expected a change plan, received ${result.reason}`);
  return result.plan;
}

function applyPlannedEdit(source: string, edit: { from: number; to: number; insert: string }) {
  return source.slice(0, edit.from) + edit.insert + source.slice(edit.to);
}

function expectFailure(result: ArticleStateChangeResult, reason: Extract<ArticleStateChangeResult, { ok: false }>["reason"]) {
  expect(result).toEqual({ ok: false, reason });
}

function assertPlanIntegrity(source: string, target: EditableArticleState, result: ArticleStateChangeResult) {
  const plan = requirePlan(result);
  expect(plan.target).toBe(target);
  expect(plan.expectedText).toBe(source);
  expect(plan.contextKey).toBe("session-1:document-1:7");
  expect(plan.edit.from).toBeGreaterThanOrEqual(0);
  expect(plan.edit.to).toBeGreaterThanOrEqual(plan.edit.from);
  expect(plan.edit.to).toBeLessThanOrEqual(source.length);
  expect(applyPlannedEdit(source, plan.edit)).toBe(plan.nextText);
  expect(plan.selection.from).toBeGreaterThanOrEqual(plan.edit.from);
  expect(plan.selection.to).toBeGreaterThanOrEqual(plan.selection.from);
  expect(plan.selection.to).toBeLessThanOrEqual(plan.edit.from + plan.edit.insert.length);
  expect(projectArticleState({ text: plan.nextText, context: repositoryContext, nowEpochMs: NOW })).toMatchObject({
    state: target,
    scope: "site",
    online: "unverified",
  });
  return plan;
}

function utf8Length(value: string) {
  return new TextEncoder().encode(value).byteLength;
}

describe("article state change adversarial boundaries", () => {
  it("changes only the existing YAML boolean token in a BOM and mixed-line-ending document", () => {
    const source = "\uFEFF---\r\ntitle: \"Article\"\ndate: 2026-10-14T00:00:00Z\r\nowner: \"alice\"\ndraft: false\r\n---\n正文 😀\r\n";
    const plan = assertPlanIntegrity(source, "draft", planArticleStateChange(input(source), "draft"));

    expect(source.slice(plan.edit.from, plan.edit.to)).toBe("false");
    expect(plan.edit.insert).toBe("true");
    expect(plan.nextText.slice(0, plan.edit.from)).toBe(source.slice(0, plan.edit.from));
    expect(plan.nextText.slice(plan.edit.from + plan.edit.insert.length)).toBe(source.slice(plan.edit.to));
    expect(plan.nextText).toContain("owner: \"alice\"\ndraft: true\r\n---\n正文 😀\r\n");
  });

  it("changes only the existing TOML boolean token and leaves extension metadata opaque", () => {
    const source = [
      "+++",
      'title = "Article"',
      'date = "2026-10-14T00:00:00Z"',
      'owner = "alice"',
      'params = { theme = "paper", weight = 2 }',
      "draft = true",
      "+++",
      "Body",
    ].join("\n");
    const plan = assertPlanIntegrity(source, "ready", planArticleStateChange(input(source), "ready"));

    expect(source.slice(plan.edit.from, plan.edit.to)).toBe("true");
    expect(plan.edit.insert).toBe("false");
    expect(plan.nextText.replace("draft = false", "draft = true")).toBe(source);
    expect(plan.nextText).toContain('params = { theme = "paper", weight = 2 }');
  });

  it("inserts one YAML draft line into existing CRLF front matter without normalizing any existing byte", () => {
    const source = "\uFEFF---\r\ntitle: \"Article\"\r\ndate: 2026-10-14T00:00:00Z\r\nprivate: true\r\n---\r\nBody\r\n";
    const plan = assertPlanIntegrity(source, "draft", planArticleStateChange(input(source), "draft"));

    expect(plan.beforeField).toBeNull();
    expect(plan.edit.from).toBe(plan.edit.to);
    expect(plan.nextText).toBe(source.replace("\r\n---\r\nBody", "\r\ndraft: true\r\n---\r\nBody"));
    expect(plan.nextText.match(/^draft:/gm)).toHaveLength(1);
  });

  it("inserts one TOML draft line without creating or rewriting other front matter", () => {
    const source = '+++\ntitle = "Article"\ndate = "2026-10-14T00:00:00Z"\nprivate = true\n+++\nBody';
    const plan = assertPlanIntegrity(source, "ready", planArticleStateChange(input(source), "ready"));

    expect(plan.beforeField).toBeNull();
    expect(plan.edit.from).toBe(plan.edit.to);
    expect(plan.nextText).toBe(source.replace("\n+++\nBody", "\ndraft = false\n+++\nBody"));
    expect(plan.nextText.match(/^draft\s*=/gm)).toHaveLength(1);
  });

  it("does not create front matter for a body that merely looks like metadata", () => {
    const source = "title: Article\ndraft: true\n\nBody";
    expectFailure(planArticleStateChange(input(source), "ready"), "frontMatterMissing");
    expect(source).toBe("title: Article\ndraft: true\n\nBody");
  });

  it.each([
    ["duplicate draft", "---\ntitle: Article\ndraft: true\ndraft: false\n---\nBody"],
    ["quoted YAML draft key", '---\ntitle: Article\n"draft": false\n---\nBody'],
    ["quoted YAML boolean", '---\ntitle: Article\ndraft: "false"\n---\nBody'],
    ["nested YAML draft", "---\ntitle: Article\nparams:\n  draft: false\n---\nBody"],
    ["TOML section", '+++\ntitle = "Article"\n[params]\ndraft = false\n+++\nBody'],
    ["malformed unknown metadata", '---\ntitle: Article\nauthor: "alice" trailing\ndraft: false\n---\nBody'],
  ])("rejects unsupported front matter instead of finding a convenient token: %s", (_name, source) => {
    expectFailure(planArticleStateChange(input(source), "draft"), "frontMatterInvalid");
  });

  it("does not treat unknown publication, privacy, date, or ownership metadata as edit authority", () => {
    const source = [
      "---",
      "title: Article",
      "date: 2099-01-01T00:00:00Z",
      "publishDate: 2000-01-01T00:00:00Z",
      "published: true",
      "private: true",
      "owner: alice",
      "draft: true",
      "---",
      "Body",
    ].join("\n");
    const plan = assertPlanIntegrity(source, "ready", planArticleStateChange(input(source), "ready"));

    expect(plan.nextText).toBe(source.replace("draft: true", "draft: false"));
    const projection = projectArticleState({ text: plan.nextText, context: repositoryContext, nowEpochMs: NOW });
    expect(projection.state).toBe("ready");
    expect(projection.state).not.toBe("published");
    expect(projection.online).toBe("unverified");
  });

  it.each([
    ["general draft", { kind: "generalDraft", draftId: "draft-1", writable: true } satisfies ArticleStateContext],
    ["outside the content root", { ...repositoryContext, relativePath: "notes/article.md" } satisfies ArticleStateContext],
    ["unsafe relative path", { ...repositoryContext, relativePath: "content/../private/article.md" } satisfies ArticleStateContext],
    ["unknown site", { ...repositoryContext, repository: { ...repositoryContext.repository, siteKind: "custom" } } satisfies ArticleStateContext],
  ])("refuses a writable document without verified site scope: %s", (_name, context) => {
    const source = "---\ntitle: Article\ndraft: true\n---\nBody";
    expectFailure(planArticleStateChange(input(source, context), "ready"), "notSiteArticle");
  });

  it("refuses a structurally valid site article when the current context is read-only", () => {
    const source = "---\ntitle: Article\ndraft: true\n---\nBody";
    expectFailure(planArticleStateChange(input(source, { ...repositoryContext, writable: false }), "ready"), "readOnly");
  });

  it.each(["published", "localOnly", "", "READY", undefined])("rejects a forged target before producing a plan: %s", (target) => {
    const source = "---\ntitle: Article\ndraft: true\n---\nBody";
    expectFailure(
      planArticleStateChange(input(source), target as unknown as EditableArticleState),
      "invalidTarget",
    );
  });

  it.each([
    ["draft", "---\ntitle: Article\ndraft: true\n---\nBody"],
    ["ready", "---\ntitle: Article\ndraft: false\n---\nBody"],
  ] as const)("returns unchanged rather than manufacturing a %s edit", (target, source) => {
    expectFailure(planArticleStateChange(input(source), target), "unchanged");
  });

  it("rejects a missing-field insertion whose result would cross the UTF-8 byte cap", () => {
    const prefix = "---\ntitle: Article\n---\n";
    const source = prefix + "x".repeat(MAX_ARTICLE_STATE_BYTES - utf8Length(prefix));
    expect(utf8Length(source)).toBe(MAX_ARTICLE_STATE_BYTES);

    expectFailure(planArticleStateChange(input(source), "ready"), "sizeLimit");
  });

  it("checks the post-edit size when replacing true with the longer false token", () => {
    const prefix = "---\ntitle: Article\ndraft: true\n---\n";
    const source = prefix + "x".repeat(MAX_ARTICLE_STATE_BYTES - utf8Length(prefix));
    expect(utf8Length(source)).toBe(MAX_ARTICLE_STATE_BYTES);

    expectFailure(planArticleStateChange(input(source), "ready"), "sizeLimit");
  });

  it("accepts a byte-cap boundary edit when the replacement makes the document smaller", () => {
    const prefix = "---\ntitle: Article\ndraft: false\n---\n";
    const source = prefix + "界".repeat(Math.floor((MAX_ARTICLE_STATE_BYTES - utf8Length(prefix)) / 3));
    const remainder = MAX_ARTICLE_STATE_BYTES - utf8Length(source);
    const exactSource = source + "x".repeat(remainder);
    expect(utf8Length(exactSource)).toBe(MAX_ARTICLE_STATE_BYTES);

    const plan = assertPlanIntegrity(exactSource, "draft", planArticleStateChange(input(exactSource), "draft"));
    expect(utf8Length(plan.nextText)).toBe(MAX_ARTICLE_STATE_BYTES - 1);
  });
});
