import type { KnowledgeArchiveExportPlan, KnowledgeArchiveFormat, KnowledgeArchiveMetadata, KnowledgeItem, KnowledgeItemSummary, KnowledgeExportPlan, KnowledgeRevisionSummary } from "../../contracts/repository";
export function clampProgress(value: number): number { return Math.max(0, Math.min(100, Math.round(Number.isFinite(value) ? value : 0))); }
export function safeSourceUrl(value: string | null | undefined): string | null {
  try {
    const url = new URL(value ?? "");
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || !url.hostname) return null;
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}
export function slugForExport(title: string): string { const slug = title.trim().toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, "-").replace(/^-+|-+$/g, "").slice(0, 70); return slug || "knowledge-item"; }
export function defaultExportPath(item: Pick<KnowledgeItemSummary, "title">): string { return `knowledge/${slugForExport(item.title)}.md`; }
export function defaultArchivePath(item: Pick<KnowledgeItemSummary, "title">, format: KnowledgeArchiveFormat = "html"): string { return `knowledge/${slugForExport(item.title)}.${format}`; }
function normalizeArchive(value: unknown): KnowledgeArchiveMetadata | null {
  if (!value || typeof value !== "object") return null;
  const archive = value as Partial<KnowledgeArchiveMetadata>;
  if (archive.format !== "html" && archive.format !== "mhtml") return null;
  return { format: archive.format, byteSize: Number.isFinite(archive.byteSize) ? Number(archive.byteSize) : 0, embeddedResourceCount: typeof archive.embeddedResourceCount === "number" ? archive.embeddedResourceCount : null, missingResourceCount: typeof archive.missingResourceCount === "number" ? archive.missingResourceCount : null, wasTruncated: archive.wasTruncated === true };
}
export function normalizeKnowledgeItem(value: KnowledgeItem | { summary?: KnowledgeItemSummary; text?: string } & Partial<KnowledgeItemSummary>): KnowledgeItem {
  const source = "summary" in value && value.summary ? value.summary : value as KnowledgeItemSummary;
  return { ...source, folderId: typeof source.folderId === "string" ? source.folderId : null, revisionNumber: Number.isFinite(source.revisionNumber) ? source.revisionNumber : 1, revisionCount: Number.isFinite(source.revisionCount) ? source.revisionCount : 1, archive: normalizeArchive((source as Partial<KnowledgeItemSummary>).archive), text: "text" in value && typeof value.text === "string" ? value.text : "" } as KnowledgeItem;
}
export function normalizeKnowledgeSummary(value: Partial<KnowledgeItemSummary> & Pick<KnowledgeItemSummary, "itemId" | "title" | "sourceKind" | "sourceName">): KnowledgeItemSummary {
  const { text: _text, ...summary } = normalizeKnowledgeItem(value as KnowledgeItemSummary);
  return summary;
}
export function filterKnowledgeItems(items: KnowledgeItemSummary[], folderId: string | null | "all"): KnowledgeItemSummary[] { return folderId === "all" ? items : items.filter((item) => item.folderId === folderId); }
export function revisionLabel(revision: Pick<KnowledgeRevisionSummary, "revisionNumber" | "createdAtEpochSeconds">): string { return `版本 ${revision.revisionNumber} · ${new Date(revision.createdAtEpochSeconds * 1000).toLocaleString()}`; }
export function isExportPlanExpired(plan: Pick<KnowledgeExportPlan | KnowledgeArchiveExportPlan, "expiresAtEpochSeconds">, now = Date.now()): boolean { return plan.expiresAtEpochSeconds * 1000 <= now; }
