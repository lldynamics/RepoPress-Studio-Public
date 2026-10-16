import type { AiProviderKind } from "./repository";

export type AiConnectionOperation = "models" | "probe";
export interface AiConnectionRequest {
  operation: AiConnectionOperation;
  provider: AiProviderKind;
  endpoint: string;
  model: string;
}
export interface ExecuteAiConnectionRequest extends AiConnectionRequest { planId: string; }
export interface AiConnectionPlan {
  planId: string;
  operation: AiConnectionOperation;
  provider: AiProviderKind;
  endpoint: string;
  requestUrl: string;
  model: string | null;
  expiresAt: number;
  requestSummary: string;
}
export interface AiConnectionResult {
  planId: string;
  operation: AiConnectionOperation;
  provider: AiProviderKind;
  endpoint: string;
  model: string | null;
  models: string[];
  checkedAt: number;
  status: "models_available" | "probe_succeeded";
  warnings: string[];
  elapsedMs: number;
}
