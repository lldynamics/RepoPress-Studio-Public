import type { ContentHealthSourceSnapshot } from "./repository";
import type { UiTemplate } from "../i18n/uiMessage";

export interface UnpublishImpactTarget { relativePath: string; text: string }
export interface UnpublishImpactInput {
  sources: ContentHealthSourceSnapshot;
  target: UnpublishImpactTarget;
}
export interface UnpublishImpactFinding {
  id: string;
  documentPath: string;
  line: number;
  range: { from: number; to: number };
  target: string;
  status: "confirmed" | "possible" | "unresolved";
  reason: string;
  /** Present only for controlled explanations produced by the local analyzer. */
  reasonPresentation?: UiTemplate;
}
export interface UnpublishImpactReport {
  targetPath: string;
  targetAvailable: boolean;
  targetEdited: boolean;
  findings: UnpublishImpactFinding[];
  scannedDocuments: number;
  omittedDocuments: number;
  externalLinks: number;
  partial: boolean;
  truncated: boolean;
  warnings: string[];
  warningPresentations?: UiTemplate[];
}
