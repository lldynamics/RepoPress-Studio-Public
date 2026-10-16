import { describe, expect, it, vi } from "vitest";
import type { KnowledgeBackupGateway, KnowledgeBackupPlan, KnowledgeBackupResult } from "../contracts/knowledgeBackup";

const save = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ save }));
import { createRepositoryGateway } from "./repositoryGateway";

const plan = { planId: "11111111-1111-4111-8111-111111111111", destinationPath: "/tmp/repopress-knowledge.json" } as KnowledgeBackupPlan;
const result = { planId: plan.planId, destinationPath: plan.destinationPath, byteSize: 100, sha256: "a".repeat(64) } as KnowledgeBackupResult;

describe("knowledge backup gateway", () => {
  it("uses the native JSON selector and exact IPC commands and payloads", async () => {
    save.mockResolvedValueOnce(plan.destinationPath);
    const invoke = vi.fn(async <T>(command: string): Promise<T> => command === "plan_knowledge_backup" ? plan as T : command === "execute_knowledge_backup" ? result as T : undefined as T);
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgeBackupGateway;
    await expect(gateway.selectKnowledgeBackupDestination()).resolves.toBe(plan.destinationPath);
    await expect(gateway.planKnowledgeBackup(plan.destinationPath)).resolves.toEqual(plan);
    await expect(gateway.executeKnowledgeBackup(plan.planId, true)).resolves.toEqual(result);
    await expect(gateway.discardKnowledgeBackup(plan.planId)).resolves.toBeUndefined();
    expect(save).toHaveBeenCalledWith({ title: "选择新的资料 JSON 文件路径", defaultPath: "repopress-knowledge-saved-files.json", filters: [{ name: "资料保存文件备份包", extensions: ["json"] }] });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_knowledge_backup", { destinationPath: plan.destinationPath });
    expect(invoke).toHaveBeenNthCalledWith(2, "execute_knowledge_backup", { planId: plan.planId, confirmSensitivePlaintext: true });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_knowledge_backup", { planId: plan.planId });
  });

  it("fails closed for all browser actions and does not invoke native IPC", async () => {
    const invoke = vi.fn(); const gateway = createRepositoryGateway() as unknown as KnowledgeBackupGateway;
    await expect(gateway.selectKnowledgeBackupDestination()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgeBackup(plan.destinationPath)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeKnowledgeBackup(plan.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeBackup(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
