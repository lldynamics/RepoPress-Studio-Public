import type { KnowledgeMergeProjectionPlan } from "./knowledgeMergeProjection";
import type { KnowledgeRestoreStrategy } from "./knowledgeRestoreQualification";
export type KnowledgeRestoreRecoveryAction = "finalize" | "rollback" | "cancel";
export interface KnowledgeRestoreInstallPlan {
  schemaVersion: 1; scope: "knowledgeRestoreInstall"; planId: string;
  projection: KnowledgeMergeProjectionPlan;
  requiresAcknowledgement: true; writesCurrentLibrary: true; preservesRollbackSnapshot: true;
  importedPermissionsDisabled: true; currentOnlyPreserved: true; completedOperationsExcluded: true;
  transactionLimit: 1; checkedAtEpochMs: number; expiresAtEpochMs: number;
}
export interface KnowledgeRestoreDiagnosis {
  schemaVersion: 1; scope: "knowledgeRestoreDiagnosis";
  state: "none" | "preparing" | "prepared" | "installed" | "committed" | "rolledBack" | "cancelled" | "changed" | "invalid" | "unavailable";
  transactionId: string | null; phase: "preparing" | "intent" | "committed" | "rolledBack" | "cancelled" | null;
  previousManifestSha256: string | null; projectedManifestSha256: string | null;
  canFinalize: boolean; canRollback: boolean; canCancel: boolean;
  libraryAccessBlocked: boolean; snapshotRetained: boolean; filesystemWrites: false;
}
export interface KnowledgeRestoreRecoveryPlan {
  schemaVersion: 1; scope: "knowledgeRestoreRecovery"; planId: string;
  transactionId: string; action: KnowledgeRestoreRecoveryAction; diagnosis: KnowledgeRestoreDiagnosis;
  requiresAcknowledgement: true; preservesSnapshot: true; checkedAtEpochMs: number; expiresAtEpochMs: number;
}
export interface KnowledgeRestoreReceipt {
  schemaVersion: 1; scope: "knowledgeRestoreReceipt"; planId: string; transactionId: string;
  state: "committed" | "rolledBack" | "cancelled"; action: "install" | KnowledgeRestoreRecoveryAction;
  previousManifestSha256: string; projectedManifestSha256: string;
  importedPermissionsDisabled: true; snapshotRetained: boolean; journalPersisted: true;
  libraryAccessBlocked: false; completedAtEpochMs: number;
}
export interface KnowledgeRestoreInstallGateway {
  selectKnowledgeCandidateDirectory(): Promise<string | null>;
  planKnowledgeRestoreInstall(candidatePath: string, strategy: KnowledgeRestoreStrategy): Promise<KnowledgeRestoreInstallPlan>;
  executeKnowledgeRestoreInstall(planId: string, acknowledgeInstall: boolean): Promise<KnowledgeRestoreReceipt>;
  inspectKnowledgeRestore(): Promise<KnowledgeRestoreDiagnosis>;
  planKnowledgeRestoreRecovery(transactionId: string, action: KnowledgeRestoreRecoveryAction): Promise<KnowledgeRestoreRecoveryPlan>;
  executeKnowledgeRestoreRecovery(planId: string, acknowledgeRecovery: boolean): Promise<KnowledgeRestoreReceipt>;
  discardKnowledgeRestoreInstall(planId: string): Promise<void>;
}
