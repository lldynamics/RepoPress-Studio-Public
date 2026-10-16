export type MetadataBatchField = "tags" | "categories";
export interface MetadataBatchOperation { kind: "add" | "remove" | "rename"; value: string; replacement: string | null }
export interface MetadataBatchPreview {
  relativePath: string;
  originalValues: string[];
  proposedValues: string[];
  status: "change" | "unchanged" | "unavailable";
  message: string | null;
}
export interface MetadataBatchPlan {
  planId: string;
  sessionId: string;
  field: MetadataBatchField;
  operation: MetadataBatchOperation;
  previews: MetadataBatchPreview[];
  expiresAt: string;
}
export interface MetadataBatchResult {
  results: { relativePath: string; status: "applied" | "unchanged" | "conflict" | "failed"; message: string | null }[];
  summary: string;
}
export interface MetadataBatchRequest { sessionId: string; paths: string[]; field: MetadataBatchField; operation: MetadataBatchOperation }
