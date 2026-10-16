import { describe, expect, it } from "vitest";
import type { ArticleStateChangeInput, EditableArticleState } from "../../contracts/articleStateChange";
import type { ArticleStateContext } from "../../contracts/articleState";
import { MAX_ARTICLE_STATE_BYTES, projectArticleState } from "./articleState";
import { planArticleStateChange } from "./articleStateChange";

const NOW = Date.parse("2026-10-15T00:00:00Z");
const context: ArticleStateContext = {
  kind: "repository",
  repository: { sessionId: "session-1", siteKind: "hugo", contentRoot: "content" },
  documentId: "document-1",
  relativePath: "content/posts/article.md",
  writable: true,
};

function input(text: string, overrides: Partial<ArticleStateChangeInput> = {}): ArticleStateChangeInput {
  return { text, context, nowEpochMs: NOW, contextKey: "document-1:revision-7", ...overrides };
}

function plan(text: string, target: EditableArticleState, overrides: Partial<ArticleStateChangeInput> = {}) {
  return planArticleStateChange(input(text, overrides), target);
}

function expectPlan(text: string, target: EditableArticleState, overrides: Partial<ArticleStateChangeInput> = {}) {
  const result = plan(text, target, overrides);
  expect(result.ok).toBe(true);
  if (!result.ok) throw new Error(result.reason);
  expect(result.plan.nextText).toBe(
    text.slice(0, result.plan.edit.from) + result.plan.edit.insert + text.slice(result.plan.edit.to),
  );
  expect(projectArticleState({
    text: result.plan.nextText,
    context: (overrides.context ?? context),
    nowEpochMs: overrides.nowEpochMs ?? NOW,
  }).state).toBe(target);
  return result.plan;
}

describe("planArticleStateChange", () => {
  it.each([
    ["YAML draft to ready", "---\ntitle: T\ndate: 2026-10-14T00:00:00Z\ndraft: true\n---\nBody", "ready" as const, "false"],
    ["YAML ready to draft", "---\ntitle: T\ndate: 2026-10-14T00:00:00Z\ndraft: false\n---\nBody", "draft" as const, "true"],
    ["TOML draft to ready", '+++\ntitle = "T"\ndate = "2026-10-14T00:00:00Z"\ndraft = true\n+++\nBody', "ready" as const, "false"],
    ["TOML ready to draft", '+++\ntitle = "T"\ndate = "2026-10-14T00:00:00Z"\ndraft = false\n+++\nBody', "draft" as const, "true"],
  ])("changes only the boolean token for %s", (_name, text, target, expected) => {
    const result = expectPlan(text, target);
    expect(result.edit.insert).toBe(expected);
    expect(result.beforeField).toBe(text.includes("draft:") ? `${text.match(/draft:.*\n/)![0]}` : `${text.match(/draft = .*\n/)![0]}`);
    expect(result.afterField).toBe(result.beforeField!.replace(/true|false/, expected));
    expect(result.selection).toEqual({ from: result.edit.from, to: result.edit.from + expected.length });
    expect(result.expectedText).toBe(text);
    expect(result.contextKey).toBe("document-1:revision-7");
  });

  it.each([
    ["YAML", "---\ntitle: T\ndate: 2026-10-14T00:00:00Z\n---\nBody", "draft: true\n"],
    ["TOML", '+++\ntitle = "T"\ndate = "2026-10-14T00:00:00Z"\n+++\nBody', "draft = true\n"],
  ])("inserts an explicit draft field before the %s delimiter", (_name, text, inserted) => {
    const result = expectPlan(text, "draft");
    expect(result.beforeField).toBeNull();
    expect(result.afterField).toBe(inserted);
    expect(result.edit).toEqual({ from: text.lastIndexOf(text.startsWith("---") ? "---" : "+++"), to: text.lastIndexOf(text.startsWith("---") ? "---" : "+++"), insert: inserted });
    expect(result.selection).toEqual({ from: result.edit.from, to: result.edit.from + inserted.length - 1 });
  });

  it("preserves BOM, CRLF, emoji, spacing, body, and a missing final newline byte-for-byte outside the token", () => {
    const text = '\uFEFF---\r\ntitle: "😀 标题"\r\ndate: 2026-10-14T00:00:00Z\r\ndraft  :  false  \r\n---\r\n正文😀';
    const result = expectPlan(text, "draft");
    expect(result.beforeField).toBe("draft  :  false  \r\n");
    expect(result.afterField).toBe("draft  :  true  \r\n");
    expect(result.nextText.slice(0, result.edit.from)).toBe(text.slice(0, result.edit.from));
    expect(result.nextText.slice(result.edit.from + result.edit.insert.length)).toBe(text.slice(result.edit.to));
    expect(result.nextText.endsWith("正文😀")).toBe(true);
  });

  it("uses the original CRLF convention when inserting and leaves every existing character untouched", () => {
    const text = "\uFEFF---\r\ntitle: \"😀\"\r\ndate: 2026-10-14T00:00:00Z\r\n---";
    const result = expectPlan(text, "ready");
    expect(result.afterField).toBe("draft: false\r\n");
    expect(result.nextText).toBe("\uFEFF---\r\ntitle: \"😀\"\r\ndate: 2026-10-14T00:00:00Z\r\ndraft: false\r\n---");
  });

  it("returns unchanged when the explicit state already equals the target", () => {
    expect(plan("---\ndraft: true\n---", "draft")).toEqual({ ok: false, reason: "unchanged" });
    expect(plan("---\ndraft: false\n---", "ready")).toEqual({ ok: false, reason: "unchanged" });
  });

  it.each([
    ["missing front matter", "Body", "frontMatterMissing"],
    ["unterminated front matter", "---\ndraft: true", "frontMatterInvalid"],
    ["nested YAML", "---\narticle:\n  draft: false\n---", "frontMatterInvalid"],
    ["TOML table", "+++\n[params]\ndraft = false\n+++", "frontMatterInvalid"],
    ["malformed draft", "---\ndraft: yes\n---", "frontMatterInvalid"],
    ["duplicate draft", "---\ndraft: true\ndraft: false\n---", "frontMatterInvalid"],
  ])("fails closed for %s", (_name, text, reason) => {
    expect(plan(text, "ready")).toEqual({ ok: false, reason });
  });

  it("rejects non-site, read-only, general-draft, and unsupported target requests", () => {
    const text = "---\ndraft: true\n---";
    expect(plan(text, "ready", { context: { ...context, relativePath: "notes/article.md" } })).toEqual({ ok: false, reason: "notSiteArticle" });
    expect(plan(text, "ready", { context: { ...context, repository: { ...context.repository, siteKind: "custom" } } })).toEqual({ ok: false, reason: "notSiteArticle" });
    expect(plan(text, "ready", { context: { ...context, writable: false } })).toEqual({ ok: false, reason: "readOnly" });
    expect(plan(text, "ready", { context: { kind: "generalDraft", draftId: "draft-1", writable: true } })).toEqual({ ok: false, reason: "notSiteArticle" });
    expect(planArticleStateChange(input(text), "published" as EditableArticleState)).toEqual({ ok: false, reason: "invalidTarget" });
    expect(planArticleStateChange(input(text), "localOnly" as EditableArticleState)).toEqual({ ok: false, reason: "invalidTarget" });
  });

  it("rejects source text over 256 KiB", () => {
    const text = `---\ndraft: true\n---\n${"界".repeat(MAX_ARTICLE_STATE_BYTES)}`;
    expect(plan(text, "ready")).toEqual({ ok: false, reason: "sizeLimit" });
  });

  it("rejects an insertion or longer replacement that would cross the 256 KiB boundary", () => {
    const insertionPrefix = "---\n---\n";
    const insertionText = insertionPrefix + "x".repeat(MAX_ARTICLE_STATE_BYTES - insertionPrefix.length);
    expect(new TextEncoder().encode(insertionText)).toHaveLength(MAX_ARTICLE_STATE_BYTES);
    expect(plan(insertionText, "draft")).toEqual({ ok: false, reason: "sizeLimit" });

    const replacementPrefix = "---\ndraft: true\n---\n";
    const replacementText = replacementPrefix + "x".repeat(MAX_ARTICLE_STATE_BYTES - replacementPrefix.length);
    expect(plan(replacementText, "ready")).toEqual({ ok: false, reason: "sizeLimit" });
  });

  it("carries title, date, clock, and publication warnings without inventing publication", () => {
    const text = "---\ndate: 2026-10-16\ndraft: true\n---";
    const result = expectPlan(text, "ready", { nowEpochMs: Number.NaN });
    expect(result.warnings).toEqual([
      "clockInvalid",
      "titleMissing",
      "dateTimezoneUnknown",
      "publicationUnverified",
    ]);
    expect(projectArticleState({ text: result.nextText, context, nowEpochMs: Number.NaN }).state).toBe("ready");
  });

  it("keeps a future date as a warning and never turns ready into published", () => {
    const text = "---\ntitle: T\ndate: 2026-10-15T00:00:00.001Z\ndraft: true\n---";
    const result = expectPlan(text, "ready");
    expect(result.warnings).toEqual(["dateFuture", "publicationUnverified"]);
    const projected = projectArticleState({ text: result.nextText, context, nowEpochMs: NOW });
    expect(projected.state).toBe("ready");
    expect(projected.state).not.toBe("published");
  });

  it("retains an invalid-date warning in the plan", () => {
    const text = "---\ntitle: T\ndate: 2026-02-30T00:00:00Z\ndraft: true\n---";
    const result = expectPlan(text, "ready");
    expect(result.warnings).toEqual(["dateInvalid", "publicationUnverified"]);
  });

  it("does not mutate frozen input and produces deterministic plans", () => {
    const frozen = Object.freeze(input("---\ndraft: true\n---"));
    const first = planArticleStateChange(frozen, "ready");
    const second = planArticleStateChange(frozen, "ready");
    expect(second).toEqual(first);
    expect(frozen.text).toBe("---\ndraft: true\n---");
  });
});
