import { describe, expect, it, vi } from "vitest";
import type { RollbackChangePreview } from "../contracts/rollbackChangePreview";
import { createRepositoryGateway } from "./repositoryGateway";

const preview: RollbackChangePreview = {
  sessionId: "session-1",
  recordId: "push-1",
  revision: 3,
  branch: "main",
  remoteUrl: "https://example.test/repo.git",
  expectedSha: "a".repeat(40),
  parentSha: "b".repeat(40),
  status: "complete",
  changes: [],
  omittedPaths: 0,
  blockers: [],
  warnings: [],
  summary: { visible: 0, deleteFiles: 0, restoreFiles: 0, replaceFiles: 0, unsupportedFiles: 0, verifiedFiles: 0 },
  checkedAtEpochMs: 1_700_000_000_000,
};

describe("rollback change preview gateway", () => {
  it("passes only the bounded local preview arguments", async () => {
    const invoke = vi.fn(async <T>(command: string, args?: object): Promise<T> => {
      expect(command).toBe("inspect_rollback_changes");
      expect(args).toEqual({ sessionId: "session-1", recordId: "push-1", revision: 3 });
      return preview as T;
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>);

    await expect(gateway.inspectRollbackChanges("session-1", "push-1", 3)).resolves.toEqual(preview);
    expect(invoke).toHaveBeenCalledTimes(1);
  });

  it("rejects the browser demo without fabricating an empty complete preview or invoking IPC", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway();

    await expect(gateway.inspectRollbackChanges("demo-session", "push-1", 3)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
