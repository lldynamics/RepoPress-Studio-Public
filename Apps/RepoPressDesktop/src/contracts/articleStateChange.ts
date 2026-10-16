import type { ArticleStateInput, ArticleStateIssueCode } from "./articleState";

export type EditableArticleState = "draft" | "ready";
export interface ArticleStateChangePlan {
  target: EditableArticleState;
  contextKey: string;
  expectedText: string;
  nextText: string;
  beforeField: string | null;
  afterField: string;
  edit: { from: number; to: number; insert: string };
  selection: { from: number; to: number };
  warnings: ArticleStateIssueCode[];
}
export type ArticleStateChangeFailure = "invalidTarget" | "readOnly" | "notSiteArticle" | "sizeLimit"
  | "frontMatterMissing" | "frontMatterInvalid" | "unchanged";
export type ArticleStateChangeResult = { ok: true; plan: ArticleStateChangePlan }
  | { ok: false; reason: ArticleStateChangeFailure };
export type ArticleStateChangeInput = ArticleStateInput & { contextKey: string };
