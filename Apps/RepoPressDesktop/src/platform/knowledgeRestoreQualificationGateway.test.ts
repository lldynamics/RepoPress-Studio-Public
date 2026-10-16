import { describe, expect, it, vi } from "vitest";
import type {
  KnowledgeRestoreQualificationGateway,
  KnowledgeRestoreQualificationPlan,
  KnowledgeRestoreQualificationRecheck,
} from "../contracts/knowledgeRestoreQualification";

const open = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ open }));
import { createRepositoryGateway } from "./repositoryGateway";

const candidate = "/private/repopress-knowledge-stage-candidate";
const plan = {
  schemaVersion: 1,
  scope: "knowledgeRestoreQualification",
  planId: "33333333-3333-4333-8333-333333333333",
  targetScope: "currentAppKnowledgeLibrary",
  candidate: {} as KnowledgeRestoreQualificationPlan["candidate"],
  currentResources: {
    state: "checked",
    fileCount: 2,
    byteSize: 12,
    inventorySha256: "a".repeat(64),
    unreferencedFilesVerified: false,
    externalReferencesVerified: false,
  },
  strategy: "keepCurrentIdentities",
  qualification: {
    state: "evidenceReady",
    reason: "none",
    addItems: 1,
    retainItems: 2,
    skipCandidateItems: 0,
    addFolders: 1,
    retainFolders: 2,
    skipCandidateFolders: 0,
  },
  currentOnlyPreserved: true,
  candidatePermissionsApplied: false,
  projectedManifestValidated: false,
  consistentSnapshot: false,
  filesystemWrites: false,
  restoreReady: false,
  checkedAtEpochMs: 1_700_000_000_000,
  expiresAtEpochMs: 1_700_000_005_000,
} satisfies KnowledgeRestoreQualificationPlan;
const recheck = { plan, comparison: "unchanged" } satisfies KnowledgeRestoreQualificationRecheck;

describe("knowledge restore qualification gateway", () => {
  it("selects a private candidate and passes exact plan/recheck/discard IPC", async () => {
    open.mockResolvedValueOnce(candidate);
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      if (name === "plan_knowledge_restore_qualification") return plan as T;
      if (name === "recheck_knowledge_restore_qualification") return recheck as T;
      if (name === "discard_knowledge_restore_qualification") return undefined as T;
      throw new Error(`unexpected command ${name}`);
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgeRestoreQualificationGateway;

    await expect(gateway.selectKnowledgeCandidateDirectory()).resolves.toBe(candidate);
    await expect(gateway.planKnowledgeRestoreQualification(candidate, "keepCurrentIdentities")).resolves.toEqual(plan);
    await expect(gateway.recheckKnowledgeRestoreQualification(plan.planId)).resolves.toEqual(recheck);
    await expect(gateway.discardKnowledgeRestoreQualification(plan.planId)).resolves.toBeUndefined();
    expect(open).toHaveBeenCalledWith({ title: "选择私有资料候选目录", multiple: false, directory: true });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_knowledge_restore_qualification", { candidatePath: candidate, strategy: "keepCurrentIdentities" });
    expect(invoke).toHaveBeenNthCalledWith(2, "recheck_knowledge_restore_qualification", { planId: plan.planId });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_knowledge_restore_qualification", { planId: plan.planId });
    expect(invoke).toHaveBeenCalledTimes(3);
  });

  it("returns null when the native candidate selector is cancelled", async () => {
    open.mockReset().mockResolvedValueOnce(null);
    const invoke = vi.fn();
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgeRestoreQualificationGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).resolves.toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });

  it("fails closed for selection and all qualification actions in browser demo mode", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway() as unknown as KnowledgeRestoreQualificationGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgeRestoreQualification(candidate, "requireNoIdentityConflicts")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.recheckKnowledgeRestoreQualification(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeRestoreQualification(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
