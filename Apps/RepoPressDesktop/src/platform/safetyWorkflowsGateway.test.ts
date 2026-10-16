import { describe, expect, it, vi } from "vitest";
import { createRepositoryGateway } from "./repositoryGateway";

describe("safety workflow gateway contracts", () => {
  it("P32 sends only scoped identifiers for read-only reconciliation and local cleanup", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.listRemoteReviewRecords("session");
    await gateway.planRemoteReviewVerification("session", "record");
    await gateway.executeRemoteReviewVerification("session", "plan");
    await gateway.removeRemoteReviewRecord("session", "record", 2);
    expect(call.mock.calls).toEqual([
      ["list_remote_review_records", { sessionId: "session" }],
      ["plan_remote_review_verification", { sessionId: "session", recordId: "record" }],
      ["execute_remote_review_verification", { sessionId: "session", planId: "plan" }],
      ["remove_remote_review_record", { sessionId: "session", recordId: "record", revision: 2 }],
    ]);
  });
  it("P32 browser demo has no stored results, network checks, or local writes", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.listRemoteReviewRecords("session")).resolves.toEqual([]);
    await expect(gateway.planRemoteReviewVerification("session", "record")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeRemoteReviewVerification("session", "plan")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.removeRemoteReviewRecord("session", "record", 2)).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("creates an app-private original backup without inventing a draft ID", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    const request = { draftId: null, text: "unsaved original", expectedRevision: null, expectedSha256: null } as const;
    await gateway.saveGeneralDraft(request);
    expect(call).toHaveBeenCalledWith("save_general_draft", request);
  });
  it("sends only session and approved retry plan identifiers", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    await gateway.planGitPushRetry("session"); await gateway.executeGitPushRetry("session", "plan");
    expect(call.mock.calls).toEqual([["plan_git_push_retry", { sessionId: "session" }], ["execute_git_push_retry", { sessionId: "session", planId: "plan" }]]);
  });
  it("sends only ledger identifiers and revision for publish verification", async () => {
    const call = vi.fn()
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce({ planId: "verification-plan" })
      .mockResolvedValueOnce({})
      .mockResolvedValueOnce([]);
    const gateway = createRepositoryGateway(call);
    await gateway.listPublishRecords("session");
    await gateway.planPublishVerification("session", "record");
    await gateway.executePublishVerification("session", "verification-plan");
    await gateway.removePublishRecord("session", "record", 7);
    expect(call.mock.calls).toEqual([
      ["list_publish_records", { sessionId: "session" }],
      ["plan_publish_verification", { sessionId: "session", recordId: "record" }],
      ["execute_publish_verification", { sessionId: "session", planId: "verification-plan" }],
      ["remove_publish_record", { sessionId: "session", recordId: "record", revision: 7 }],
    ]);
  });
  it("does not contact a remote or create a backup in browser demo", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.planGitPushRetry("session")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeGitPushRetry("session", "plan")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.saveGeneralDraft({ draftId: null, text: "draft", expectedRevision: null, expectedSha256: null })).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("keeps publish ledger read-only in browser demo", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.listPublishRecords("session")).resolves.toEqual([]);
    await expect(gateway.planPublishVerification("session", "record")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executePublishVerification("session", "plan")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.removePublishRecord("session", "record", 1)).rejects.toMatchObject({ code: "read_only_demo" });
  });
});
