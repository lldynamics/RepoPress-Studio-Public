export interface SitePreviewDocumentBinding {
  documentId: string;
  expectedSha256: string;
  revision: number;
}
export interface SitePreviewPlanRequest {
  document: SitePreviewDocumentBinding | null;
  articlePath: string | null;
}
export interface SitePreviewPlan {
  planId: string;
  siteKind: string;
  executable: string;
  expiresAtEpochMs: number;
  configFingerprint: string;
  document: SitePreviewDocumentBinding | null;
  articlePath: string | null;
}
export type SitePreviewPageTarget = "article" | "home";
export interface SitePreviewPageSnapshot {
  previewId: string;
  requestedUrl: string;
  url: string;
  ready: boolean;
  statusCode: number | null;
  reason: string;
}
