import type { RepositorySessionSnapshot } from "./repository";

/** User-facing vocabulary; published requires document-bound deployment evidence. */
export type ArticleState = "draft" | "ready" | "published" | "localOnly";
export type ArticleStateContext =
  | { kind: "repository"; repository: Pick<RepositorySessionSnapshot, "sessionId" | "siteKind" | "contentRoot">;
      documentId: string; relativePath: string; writable: boolean }
  | { kind: "generalDraft"; draftId: string; writable: boolean };

export type ArticleStateLocation =
  | { kind: "field"; field: "title" | "draft" | "date" }
  | { kind: "range"; from: number; to: number }
  | { kind: "site" }
  | { kind: "publishing" };

export type ArticleStateIssueCode = "frontMatterMissing" | "frontMatterInvalid" | "draftMissing" | "titleMissing"
  | "dateMissing" | "dateInvalid" | "dateTimezoneUnknown" | "dateFuture" | "outsideContentRoot"
  | "siteUnknown" | "invalidPath" | "readOnly" | "sizeLimit" | "publicationUnverified" | "clockInvalid";

export interface ArticleStateIssue {
  code: ArticleStateIssueCode;
  severity: "warning" | "information";
  location: ArticleStateLocation | null;
}

export interface ArticleStateProjection {
  state: ArticleState | null;
  scope: "site" | "generalDraft" | "outsideSite" | "unknown";
  /** Existing Git/deployment contracts cannot establish article publication. */
  online: "unverified";
  readOnly: boolean;
  limited: boolean;
  date: { kind: "absent" | "invalid" | "timezoneUnknown" | "future" | "elapsed"; value: string; epochMs: number | null };
  checkedAtEpochMs: number | null;
  issues: ArticleStateIssue[];
}

export interface ArticleStateInput {
  text: string;
  context: ArticleStateContext;
  nowEpochMs: number;
}
