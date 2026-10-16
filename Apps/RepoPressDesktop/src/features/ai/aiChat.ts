import type { AiChatPlan, AiChatStreamSnapshot, AiChatStreamState } from "../../contracts/repository";

export const MAX_AI_CHAT_KNOWLEDGE_ITEMS = 8;

/** UTF-8 byte count matches the amount shown in the remote-send confirmation. */
export function aiChatUtf8Bytes(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

/** Returns the unchanged selection when a ninth material is attempted. */
export function toggleAiChatKnowledgeSelection(selectedIds: readonly string[], itemId: string): string[] {
  if (selectedIds.includes(itemId)) return selectedIds.filter((id) => id !== itemId);
  if (selectedIds.length >= MAX_AI_CHAT_KNOWLEDGE_ITEMS) return [...selectedIds];
  return [...selectedIds, itemId];
}

export function aiChatPlanExpired(plan: AiChatPlan): boolean {
  return !Number.isSafeInteger(plan.expiresAtEpochSeconds)
    || plan.expiresAtEpochSeconds * 1_000 <= Date.now();
}

/** A plan may only execute in the response mode it was explicitly confirmed for. */
export function aiChatPlanMatchesStreaming(plan: AiChatPlan, streaming: boolean): boolean {
  return !aiChatPlanExpired(plan) && plan.streaming === streaming;
}

export function aiChatPassphraseIsLongEnough(value: string): boolean {
  return aiChatUtf8Bytes(value) >= 12;
}

export function aiChatStreamTerminal(state: AiChatStreamState): boolean {
  return state === "completed" || state === "cancelled" || state === "failed";
}

/** Only interrupted streams have a partial response that was deliberately not saved. */
export function aiChatStreamShowsUnpersistedPreview(state: AiChatStreamState): boolean {
  return state === "cancelled" || state === "failed";
}

/** Delta is already relative to `afterCursor`; never append an old snapshot twice. */
export function appendAiChatStreamDelta(current: string, snapshot: AiChatStreamSnapshot, previousCursor: number): string {
  if (snapshot.cursor <= previousCursor || !snapshot.delta) return current;
  return current + snapshot.delta;
}

/** Cancellation snapshots carry the authoritative buffer from cursor zero. */
export function aiChatCancelSnapshotText(snapshot: AiChatStreamSnapshot): string {
  return snapshot.delta;
}
