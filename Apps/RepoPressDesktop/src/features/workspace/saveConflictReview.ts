/** Maximum UTF-8 source bytes that may be displayed for one conflict version. */
export const SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES = 256 * 1024;
/** The three conflict versions together must stay within this UTF-8 budget. */
export const SAVE_CONFLICT_REVIEW_TOTAL_LIMIT_BYTES = 3 * SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES;

export interface SaveConflictReviewSnapshot {
  documentKey: string;
  relativePath: string;
  baselineText: string;
  localText: string;
  diskText: string;
  diskSha256: string;
}

export type SaveConflictReviewBudget =
  | { ok: true; bytes: { baseline: number; local: number; disk: number; total: number } }
  | { ok: false; message: string };

export type SaveConflictMergedTextBudget =
  | { ok: true; bytes: number }
  | { ok: false; message: string };

export function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

/**
 * Rejects an oversized review instead of truncating any version. Callers must
 * render the returned message and request a bounded re-read from the backend.
 */
export function validateSaveConflictReviewBudget(review: SaveConflictReviewSnapshot): SaveConflictReviewBudget {
  // Every UTF-8 code point uses at least one byte. This cheap check prevents
  // encoding unquestionably oversized content just to reject it.
  if (review.baselineText.length > SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES || review.localText.length > SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES || review.diskText.length > SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES) {
    return { ok: false, message: "冲突内容超过单份 256 KiB 的审阅上限，未显示或截断任何文本。请缩小文稿后重新读取。" };
  }
  const baseline = utf8ByteLength(review.baselineText);
  const local = utf8ByteLength(review.localText);
  const disk = utf8ByteLength(review.diskText);
  const total = baseline + local + disk;
  if (baseline > SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES || local > SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES || disk > SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES) {
    return { ok: false, message: "冲突内容超过单份 256 KiB 的审阅上限，未显示或截断任何文本。请缩小文稿后重新读取。" };
  }
  if (total > SAVE_CONFLICT_REVIEW_TOTAL_LIMIT_BYTES) {
    return { ok: false, message: "冲突内容超过合计 768 KiB 的审阅上限，未显示或截断任何文本。请缩小文稿后重新读取。" };
  }
  return { ok: true, bytes: { baseline, local, disk, total } };
}

/** Rejects an oversized editable merge before it can be handed to save flow. */
export function validateSaveConflictMergedTextBudget(value: string): SaveConflictMergedTextBudget {
  if (value.length > SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES) {
    return { ok: false, message: "合并稿超过 256 KiB 上限，未载入编辑缓冲区。请缩小内容后重试。" };
  }
  const bytes = utf8ByteLength(value);
  return bytes <= SAVE_CONFLICT_REVIEW_TEXT_LIMIT_BYTES
    ? { ok: true, bytes }
    : { ok: false, message: "合并稿超过 256 KiB 上限，未载入编辑缓冲区。请缩小内容后重试。" };
}

/** Includes every displayed source value so a changed review invalidates a draft. */
export function saveConflictReviewIdentity(review: SaveConflictReviewSnapshot): string {
  return JSON.stringify([
    review.documentKey,
    review.relativePath,
    review.baselineText,
    review.localText,
    review.diskText,
    review.diskSha256,
  ]);
}
