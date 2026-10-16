import type { GeneralDraftSummary } from "../../contracts/repository";

/**
 * Creates a display-safe filename stem. The Rust command remains authoritative
 * for path validation; this only keeps the default suggestions predictable.
 */
export function generalDraftFilenameStem(title: string): string {
  const normalized = title.normalize("NFKC").trim()
    .replace(/[\\/\\\\<>:"|?*\u0000-\u001f]+/g, " ")
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/^\.+/, "")
    .slice(0, 72);
  return normalized || "untitled-draft";
}

function safePrefix(contentRoot: string | null): string {
  const segments = (contentRoot ?? "").replace(/\\\\/g, "/").split("/")
    .map((segment) => segment.trim())
    .filter((segment) => segment && segment !== "." && segment !== "..")
    .map((segment) => segment.replace(/[\\/\\\\<>:"|?*\u0000-\u001f]+/g, "").replace(/^\.+/, ""))
    .filter(Boolean);
  return [...segments, "drafts"].join("/");
}

/** Turns an edited suggestion back into a Markdown filename without inventing a site-specific layout. */
export function withMarkdownExtension(path: string): string {
  const trimmed = path.trim().replace(/\\\\/g, "/").replace(/^\/+/, "");
  return /\.md$/i.test(trimmed) ? trimmed : `${trimmed || "drafts/untitled-draft"}.md`;
}

/**
 * The output is independent of the selection order and resolves collisions in
 * the batch itself. Existing repository files are deliberately not inspected
 * here: the transfer plan performs that authoritative no-clobber check.
 */
export function suggestedGeneralDraftPaths(entries: readonly Pick<GeneralDraftSummary, "draftId" | "title">[], contentRoot: string | null): Record<string, string> {
  const prefix = safePrefix(contentRoot);
  const used = new Set<string>();
  const output: Record<string, string> = {};
  const ordered = [...entries].sort((left, right) => left.title.localeCompare(right.title, "zh-Hans-CN") || left.draftId.localeCompare(right.draftId));
  for (const entry of ordered) {
    const stem = generalDraftFilenameStem(entry.title);
    let index = 1;
    let candidate = `${prefix}/${stem}.md`;
    while (used.has(candidate.toLocaleLowerCase())) {
      index += 1;
      candidate = `${prefix}/${stem}-${index}.md`;
    }
    used.add(candidate.toLocaleLowerCase());
    output[entry.draftId] = candidate;
  }
  return output;
}
