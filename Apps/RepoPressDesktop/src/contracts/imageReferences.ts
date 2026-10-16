import type { ContentHealthSourceSnapshot, RepositorySessionSnapshot } from "./repository";
import type { RepositoryImageSnapshot } from "./images";

export interface ImageReferenceOverlay { relativePath: string; text: string }
export interface ImageReferenceRepairEdit {
  documentKey: string;
  relativePath: string;
  expectedText: string;
  nextText: string;
  selection: { from: number; to: number };
}
/** An exact UTF-16 selection of an inline Markdown destination. Reference
 * definitions deliberately do not expose this because their use site is not
 * the text that would be changed. */
export interface ImageReferenceRepairTarget {
  from: number;
  to: number;
  expectedText: string;
}
export interface ImageReferenceInput {
  sources: ContentHealthSourceSnapshot;
  images: RepositoryImageSnapshot;
  repository: Pick<RepositorySessionSnapshot, "siteKind" | "contentRoot">;
  overlay?: ImageReferenceOverlay;
}
export type ImageReferenceStatus = "matched" | "unverified" | "external" | "unsafe" | "unsupported";
export interface ImageReferenceFinding {
  id: string;
  documentPath: string;
  line: number;
  offset: number;
  alt: string;
  target: string;
  resolvedPath: string | null;
  status: ImageReferenceStatus;
  source: "disk" | "editor";
  repairTarget?: ImageReferenceRepairTarget;
}
export interface ImageReferenceReport {
  references: ImageReferenceFinding[];
  scannedDocuments: number;
  omittedDocuments: number;
  imageCount: number;
  imagesWithoutReferences: string[];
  partial: boolean;
  truncated: boolean;
  warnings: string[];
}
