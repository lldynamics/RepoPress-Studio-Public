import { describe, expect, it } from "vitest";
import { aiChatCancelSnapshotText, aiChatPassphraseIsLongEnough, aiChatPlanExpired, aiChatPlanMatchesStreaming, aiChatStreamShowsUnpersistedPreview, aiChatStreamTerminal, aiChatUtf8Bytes, appendAiChatStreamDelta, MAX_AI_CHAT_KNOWLEDGE_ITEMS, toggleAiChatKnowledgeSelection } from "./aiChat";

describe("AI chat confirmation helpers", () => {
  it("counts outbound text as UTF-8 bytes", () => {
    expect(aiChatUtf8Bytes("A中😀")).toBe(8);
  });

  it("keeps material selection at the explicit eight-item limit", () => {
    const selected = Array.from({ length: MAX_AI_CHAT_KNOWLEDGE_ITEMS }, (_, index) => `item-${index}`);
    expect(toggleAiChatKnowledgeSelection(selected, "item-9")).toEqual(selected);
    expect(toggleAiChatKnowledgeSelection(selected, "item-2")).not.toContain("item-2");
  });

  it("recognizes expired and malformed plans", () => {
    const base = { planId: "p", conversationId: "c", conversationVersion: 1, provider: "ollama_local" as const, endpoint: "http://127.0.0.1:11434/v1", model: "m", historyMessageCount: 0, userMessageBytes: 0, knowledgeItems: [], knowledgeTotalBytes: 0, totalSendBytes: 0, warnings: [], streaming: true, sessionOnly: true };
    expect(aiChatPlanExpired({ ...base, expiresAtEpochSeconds: Math.floor(Date.now() / 1_000) - 1 })).toBe(true);
    expect(aiChatPlanExpired({ ...base, expiresAtEpochSeconds: Number.NaN })).toBe(true);
    expect(aiChatPlanExpired({ ...base, expiresAtEpochSeconds: Math.floor(Date.now() / 1_000) + 60 })).toBe(false);
  });

  it("requires a UTF-8 twelve-byte vault passphrase and binds the reply mode", () => {
    expect(aiChatPassphraseIsLongEnough("12345678901")).toBe(false);
    expect(aiChatPassphraseIsLongEnough("1234567890中")).toBe(true);
    const plan = { planId: "p", conversationId: "c", conversationVersion: 1, provider: "ollama_local" as const, endpoint: "http://127.0.0.1:11434/v1", model: "m", historyMessageCount: 0, userMessageBytes: 0, knowledgeItems: [], knowledgeTotalBytes: 0, totalSendBytes: 0, warnings: [], streaming: true, sessionOnly: true, expiresAtEpochSeconds: Math.floor(Date.now() / 1_000) + 60 };
    expect(aiChatPlanMatchesStreaming(plan, true)).toBe(true);
    expect(aiChatPlanMatchesStreaming(plan, false)).toBe(false);
  });

  it("appends only fresh stream deltas and recognizes terminal snapshots", () => {
    const snapshot = { operationId: "op", conversationId: "c", state: "running" as const, cursor: 3, delta: "你好", accumulatedBytes: 6, conversation: null, errorCode: null, errorMessage: null, persistenceWarning: null };
    expect(appendAiChatStreamDelta("", snapshot, 0)).toBe("你好");
    expect(appendAiChatStreamDelta("已有", { ...snapshot, cursor: 0, delta: "旧" }, 1)).toBe("已有");
    expect(appendAiChatStreamDelta("已有", { ...snapshot, cursor: 3, delta: "重复" }, 3)).toBe("已有");
    expect(aiChatCancelSnapshotText({ ...snapshot, state: "cancelled", cursor: 1, delta: "完整缓冲" })).toBe("完整缓冲");
    expect(aiChatStreamTerminal("running")).toBe(false);
    expect(aiChatStreamTerminal("completed")).toBe(true);
    expect(aiChatStreamTerminal("cancelled")).toBe(true);
    expect(aiChatStreamTerminal("failed")).toBe(true);
    expect(aiChatStreamShowsUnpersistedPreview("running")).toBe(false);
    expect(aiChatStreamShowsUnpersistedPreview("completed")).toBe(false);
    expect(aiChatStreamShowsUnpersistedPreview("cancelled")).toBe(true);
    expect(aiChatStreamShowsUnpersistedPreview("failed")).toBe(true);
  });
});
