import { describe, expect, it, vi } from "vitest";
import type { RollbackArchivePlan, RollbackArchiveResult } from "../contracts/rollbackArchive";

const save = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ save }));

import { createRepositoryGateway } from "./repositoryGateway";

const plan: RollbackArchivePlan = {
  planId: "11111111-1111-4111-8111-111111111111", sessionId: "session-1", repositoryPath: "/repo",
  destinationPath: "/tmp/repopress-rollback-evidence.json", schemaVersion: 1, recordCount: 2,
  unresolvedCount: 1, historicalObservationCount: 1, byteSize: 4096, sha256: "a".repeat(64),
  createdAtEpochMs: 1_700_000_000_000, expiresAtEpochMs: 1_700_000_300_000,
};
const result: RollbackArchiveResult = {
  planId: plan.planId, sessionId: plan.sessionId, destinationPath: plan.destinationPath,
  recordCount: plan.recordCount, byteSize: plan.byteSize, sha256: plan.sha256,
};

describe("rollback archive gateway", () => {
  it("selects a destination through the native save dialog and maps all archive IPC calls", async () => {
    save.mockResolvedValueOnce(plan.destinationPath);
    const invoke = vi.fn(async <T>(command: string): Promise<T> => {
      if (command === "plan_rollback_archive") return plan as T;
      if (command === "execute_rollback_archive") return result as T;
      return undefined as T;
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>);

    await expect(gateway.selectRollbackArchiveDestination()).resolves.toBe(plan.destinationPath);
    await expect(gateway.planRollbackArchive(plan.sessionId, plan.destinationPath)).resolves.toEqual(plan);
    await expect(gateway.executeRollbackArchive(plan.sessionId, plan.planId)).resolves.toEqual(result);
    await expect(gateway.discardRollbackArchive(plan.sessionId, plan.planId)).resolves.toBeUndefined();
    expect(save).toHaveBeenCalledWith({ title: "导出恢复证据", defaultPath: "repopress-rollback-evidence.json", filters: [{ name: "JSON", extensions: ["json"] }] });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_rollback_archive", { sessionId: plan.sessionId, destinationPath: plan.destinationPath });
    expect(invoke).toHaveBeenNthCalledWith(2, "execute_rollback_archive", { sessionId: plan.sessionId, planId: plan.planId });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_rollback_archive", { sessionId: plan.sessionId, planId: plan.planId });
    expect(invoke).toHaveBeenCalledTimes(3);
  });

  it("keeps destination selection local and fails closed for all four browser-demo actions", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway();
    await expect(gateway.selectRollbackArchiveDestination()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planRollbackArchive("demo-session", "/tmp/archive.json")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeRollbackArchive("demo-session", plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardRollbackArchive("demo-session", plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
