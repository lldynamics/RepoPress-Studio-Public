//! Confirmed, non-streaming AI edit requests and strict edit proposal handling.
//!
//! Plans are in-memory, expire after five minutes, and are consumed before any
//! network I/O. This layer never writes a file: applying accepted proposals is a
//! pure string transformation owned by the caller.

use super::{
    ai_credentials::AiCredential,
    ai_provider::{
        openai_edit_body, validate_instruction, AiError, AiPreparedRequest, AiProviderConfig,
        AiProviderKind, SharedAiTransport,
    },
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeSet, HashMap},
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

pub const PLAN_LIFETIME: Duration = Duration::from_secs(5 * 60);
pub const MAX_PROPOSALS: usize = 32;
pub const MAX_PROPOSAL_TEXT_BYTES: usize = 64 * 1024;
const MAX_PENDING_PLANS: usize = 64;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Utf16Range {
    pub start: u32,
    pub end: u32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiEditPlan {
    pub plan_id: String,
    pub provider: super::ai_provider::AiProviderKind,
    pub endpoint: String,
    pub model: String,
    pub source_sha256: String,
    pub instruction_sha256: String,
    pub selection: Utf16Range,
    pub selection_bytes: usize,
    pub expires_at_unix_seconds: u64,
}

#[derive(Clone)]
struct PendingAiEditPlan {
    config: AiProviderConfig,
    source_sha256: String,
    instruction_sha256: String,
    instruction: String,
    selection: Utf16Range,
    selection_text: String,
    expires_at_unix_seconds: u64,
}

/// Stores confirmation plans only in the running process.
pub struct AiEditStore {
    transport: SharedAiTransport,
    plans: Mutex<HashMap<String, PendingAiEditPlan>>,
}

impl AiEditStore {
    pub fn with_transport(transport: SharedAiTransport) -> Self {
        Self {
            transport,
            plans: Mutex::new(HashMap::new()),
        }
    }

    pub fn create_plan(
        &self,
        config: AiProviderConfig,
        source: &str,
        selection: Utf16Range,
        instruction: &str,
    ) -> Result<AiEditPlan, AiError> {
        validate_instruction(instruction)?;
        let selection_text = slice_utf16(source, selection)?;
        if selection_text.is_empty()
            || selection_text.len() > super::ai_provider::MAX_SELECTION_BYTES
        {
            return Err(AiError::new(
                "ai_selection_invalid",
                "Selected text is invalid.",
            ));
        }
        let source_sha256 = sha256(source);
        let instruction_sha256 = sha256(instruction);
        let now = now_unix_seconds()?;
        let expires_at_unix_seconds = now.saturating_add(PLAN_LIFETIME.as_secs());
        let plan_id = Uuid::new_v4().to_string();
        let pending = PendingAiEditPlan {
            config: config.clone(),
            source_sha256: source_sha256.clone(),
            instruction_sha256: instruction_sha256.clone(),
            instruction: instruction.to_string(),
            selection,
            selection_text: selection_text.to_string(),
            expires_at_unix_seconds,
        };
        let mut plans = self.plans.lock().map_err(|_| plan_store_unavailable())?;
        plans.retain(|_, plan| plan.expires_at_unix_seconds > now);
        if plans.len() >= MAX_PENDING_PLANS {
            return Err(AiError::new(
                "ai_plan_limit",
                "Too many AI request plans are pending.",
            ));
        }
        plans.insert(plan_id.clone(), pending);
        Ok(AiEditPlan {
            plan_id,
            provider: config.provider,
            endpoint: config.endpoint,
            model: config.model,
            source_sha256,
            instruction_sha256,
            selection,
            selection_bytes: selection_text.len(),
            expires_at_unix_seconds,
        })
    }

    /// Valid confirmation consumes a plan before I/O. The passed config/source/range
    /// must exactly revalidate the plan to prevent stale content or target drift.
    // Each argument is an independent part of the reviewed plan binding and is
    // deliberately re-supplied for drift detection at execution time.
    #[allow(clippy::too_many_arguments)]
    pub async fn execute_plan(
        &self,
        plan_id: &str,
        confirmed: bool,
        config: &AiProviderConfig,
        source: &str,
        selection: Utf16Range,
        instruction: &str,
        credential: Option<AiCredential>,
    ) -> Result<AiEditResponse, AiError> {
        if !confirmed {
            return Err(AiError::new(
                "ai_confirmation_required",
                "Explicit confirmation is required.",
            ));
        }
        let pending = self
            .plans
            .lock()
            .map_err(|_| plan_store_unavailable())?
            .remove(plan_id)
            .ok_or_else(|| AiError::new("ai_plan_not_found", "AI request plan is unavailable."))?;
        if now_unix_seconds()? > pending.expires_at_unix_seconds {
            return Err(AiError::new("ai_plan_expired", "AI request plan expired."));
        }
        let selected = slice_utf16(source, selection)?;
        if pending.config != *config
            || pending.source_sha256 != sha256(source)
            || pending.instruction_sha256 != sha256(instruction)
            || pending.instruction != instruction
            || pending.selection != selection
            || pending.selection_text != selected
        {
            return Err(AiError::new(
                "ai_plan_drifted",
                "AI request target changed; create a new plan.",
            ));
        }
        validate_instruction(instruction)?;
        let bearer_token = match config.provider {
            AiProviderKind::OpenaiCompatible => credential
                .ok_or_else(|| {
                    AiError::new(
                        "ai_token_required",
                        "Hosted AI providers require a credential.",
                    )
                })?
                .token()
                .to_string()
                .into(),
            // A local Ollama request never receives an unrelated hosted token.
            AiProviderKind::OllamaLocal => None,
        };
        let json_body = openai_edit_body(&config.model, instruction, selected)?;
        let request = AiPreparedRequest {
            url: config.chat_completions_url()?,
            bearer_token,
            json_body,
        };
        let response = self.transport.execute(request).await?;
        if response.status < 200 || response.status >= 300 {
            return Err(AiError::new(
                "ai_service_rejected",
                "AI service rejected the request.",
            ));
        }
        if response
            .content_length
            .is_some_and(|length| length > super::ai_provider::MAX_RESPONSE_BYTES)
            || response.body.len() > super::ai_provider::MAX_RESPONSE_BYTES
        {
            return Err(AiError::new(
                "ai_response_too_large",
                "AI response exceeded the limit.",
            ));
        }
        let content = parse_chat_completion(&response.body)?;
        // Ranges in model output are relative to exactly the selected text; the
        // surrounding source document never crosses this provider boundary.
        let proposals = parse_edit_proposals(selected, &content)?;
        Ok(AiEditResponse { proposals })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiEditResponse {
    pub proposals: Vec<EditProposal>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditProposal {
    pub id: u32,
    pub range: Utf16Range,
    pub original_text: String,
    pub replacement_text: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireProposalSet {
    proposals: Vec<WireProposal>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WireProposal {
    range: Utf16Range,
    #[serde(rename = "originalText")]
    original_text: String,
    #[serde(rename = "replacementText")]
    replacement_text: String,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatMessage,
}

#[derive(Deserialize)]
struct ChatMessage {
    content: String,
}

/// Parses proposals whose UTF-16 ranges are relative to `selected_text`, not a
/// containing document. This makes it impossible for a provider response to
/// target text outside the selection sent to that provider.
pub fn parse_edit_proposals(
    selected_text: &str,
    payload: &str,
) -> Result<Vec<EditProposal>, AiError> {
    if payload.is_empty() || payload.len() > super::ai_provider::MAX_RESPONSE_BYTES {
        return Err(AiError::new(
            "ai_proposal_payload_invalid",
            "AI edit proposals are invalid.",
        ));
    }
    let wire: WireProposalSet = serde_json::from_str(payload).map_err(|_| {
        AiError::new(
            "ai_proposal_payload_invalid",
            "AI edit proposals are invalid.",
        )
    })?;
    if wire.proposals.len() > MAX_PROPOSALS {
        return Err(AiError::new(
            "ai_proposal_limit_exceeded",
            "Too many AI edit proposals.",
        ));
    }
    let mut proposals = Vec::with_capacity(wire.proposals.len());
    for (index, proposal) in wire.proposals.into_iter().enumerate() {
        if proposal.original_text.len() > MAX_PROPOSAL_TEXT_BYTES
            || !valid_replacement_text(&proposal.replacement_text)
            || proposal.range.start >= proposal.range.end
        {
            return Err(AiError::new(
                "ai_proposal_invalid",
                "An AI edit proposal is invalid.",
            ));
        }
        let actual = slice_utf16(selected_text, proposal.range)?;
        if actual != proposal.original_text {
            return Err(AiError::new(
                "ai_proposal_stale",
                "An AI edit proposal no longer matches the document.",
            ));
        }
        proposals.push(EditProposal {
            id: index as u32,
            range: proposal.range,
            original_text: proposal.original_text,
            replacement_text: proposal.replacement_text,
        });
    }
    reject_overlaps(&proposals)?;
    Ok(proposals)
}

/// Applies only IDs that the caller explicitly accepted, in reverse source order.
/// It validates again, making this safe even when proposals cross a process/UI boundary.
/// `selected_text` must be the same selected text that generated the proposals.
pub fn apply_accepted_proposals(
    selected_text: &str,
    proposals: &[EditProposal],
    accepted_ids: &BTreeSet<u32>,
) -> Result<String, AiError> {
    if proposals.len() > MAX_PROPOSALS {
        return Err(AiError::new(
            "ai_proposal_limit_exceeded",
            "Too many AI edit proposals.",
        ));
    }
    let selected: Vec<&EditProposal> = proposals
        .iter()
        .filter(|proposal| accepted_ids.contains(&proposal.id))
        .collect();
    if selected.len() != accepted_ids.len() {
        return Err(AiError::new(
            "ai_proposal_invalid",
            "An accepted AI edit proposal is invalid.",
        ));
    }
    let unique_ids = selected
        .iter()
        .map(|proposal| proposal.id)
        .collect::<BTreeSet<_>>();
    if unique_ids.len() != selected.len()
        || selected.iter().any(|proposal| {
            proposal.range.start >= proposal.range.end
                || proposal.original_text.len() > MAX_PROPOSAL_TEXT_BYTES
                || !valid_replacement_text(&proposal.replacement_text)
        })
    {
        return Err(AiError::new(
            "ai_proposal_invalid",
            "An accepted AI edit proposal is invalid.",
        ));
    }
    reject_overlaps(
        &selected
            .iter()
            .map(|proposal| (*proposal).clone())
            .collect::<Vec<_>>(),
    )?;
    let mut replacements = Vec::with_capacity(selected.len());
    for proposal in selected {
        let (start, end) = byte_range_utf16(selected_text, proposal.range)?;
        if selected_text[start..end] != proposal.original_text {
            return Err(AiError::new(
                "ai_proposal_stale",
                "An accepted AI edit proposal no longer matches the document.",
            ));
        }
        replacements.push((start, end, proposal.replacement_text.as_str()));
    }
    replacements.sort_by(|left, right| right.0.cmp(&left.0));
    let mut result = selected_text.to_string();
    for (start, end, replacement) in replacements {
        result.replace_range(start..end, replacement);
    }
    Ok(result)
}

fn parse_chat_completion(bytes: &[u8]) -> Result<String, AiError> {
    let response: ChatResponse = serde_json::from_slice(bytes).map_err(|_| {
        AiError::new(
            "ai_response_invalid",
            "AI service returned an invalid response.",
        )
    })?;
    response
        .choices
        .into_iter()
        .next()
        .map(|choice| choice.message.content)
        .filter(|value| !value.is_empty() && value.len() <= super::ai_provider::MAX_RESPONSE_BYTES)
        .ok_or_else(|| {
            AiError::new(
                "ai_response_invalid",
                "AI service returned an invalid response.",
            )
        })
}

fn reject_overlaps(proposals: &[EditProposal]) -> Result<(), AiError> {
    let mut ranges: Vec<Utf16Range> = proposals.iter().map(|proposal| proposal.range).collect();
    ranges.sort_unstable_by_key(|range| (range.start, range.end));
    for pair in ranges.windows(2) {
        if pair[0].end > pair[1].start {
            return Err(AiError::new(
                "ai_proposal_overlap",
                "AI edit proposals overlap.",
            ));
        }
    }
    Ok(())
}

fn valid_replacement_text(value: &str) -> bool {
    value.len() <= MAX_PROPOSAL_TEXT_BYTES
        && !value
            .chars()
            .any(|character| character.is_control() && character != '\n' && character != '\t')
}

fn slice_utf16(source: &str, range: Utf16Range) -> Result<&str, AiError> {
    let (start, end) = byte_range_utf16(source, range)?;
    Ok(&source[start..end])
}

fn byte_range_utf16(source: &str, range: Utf16Range) -> Result<(usize, usize), AiError> {
    if range.start > range.end {
        return Err(AiError::new("ai_range_invalid", "UTF-16 range is invalid."));
    }
    let start = utf16_offset_to_byte(source, range.start)
        .ok_or_else(|| AiError::new("ai_range_invalid", "UTF-16 range is invalid."))?;
    let end = utf16_offset_to_byte(source, range.end)
        .ok_or_else(|| AiError::new("ai_range_invalid", "UTF-16 range is invalid."))?;
    (start <= end)
        .then_some((start, end))
        .ok_or_else(|| AiError::new("ai_range_invalid", "UTF-16 range is invalid."))
}

fn utf16_offset_to_byte(source: &str, target: u32) -> Option<usize> {
    if target == 0 {
        return Some(0);
    }
    let mut utf16 = 0u32;
    for (byte, character) in source.char_indices() {
        if utf16 == target {
            return Some(byte);
        }
        utf16 = utf16.checked_add(character.len_utf16() as u32)?;
        if utf16 == target {
            return Some(byte + character.len_utf8());
        }
        if utf16 > target {
            return None;
        }
    }
    None
}

fn sha256(text: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn now_unix_seconds() -> Result<u64, AiError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| AiError::new("ai_clock_invalid", "System clock is invalid."))
}

fn plan_store_unavailable() -> AiError {
    AiError::new(
        "ai_plan_store_unavailable",
        "AI request state is unavailable.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::ai_provider::{
        AiPreparedRequest, AiProviderKind, AiTransport, AiTransportResponse,
    };
    use std::{
        future::Future,
        pin::Pin,
        sync::{Arc, Mutex},
        task::{Context, Poll, RawWaker, RawWakerVTable, Waker},
    };

    struct MockTransport {
        calls: Mutex<u32>,
        response: Vec<u8>,
    }
    impl AiTransport for MockTransport {
        fn execute(
            &self,
            _request: AiPreparedRequest,
        ) -> Pin<Box<dyn Future<Output = Result<AiTransportResponse, AiError>> + Send + '_>>
        {
            *self.calls.lock().unwrap() += 1;
            let body = self.response.clone();
            Box::pin(async move {
                Ok(AiTransportResponse {
                    status: 200,
                    content_length: Some(body.len()),
                    body,
                })
            })
        }
    }

    fn config() -> AiProviderConfig {
        AiProviderConfig::new(
            AiProviderKind::OllamaLocal,
            "http://localhost:11434/v1",
            "test-model",
        )
        .unwrap()
    }

    fn block_on<F: Future>(mut future: F) -> F::Output {
        fn no_op(_: *const ()) {}
        fn clone(_: *const ()) -> RawWaker {
            RawWaker::new(
                std::ptr::null(),
                &RawWakerVTable::new(clone, no_op, no_op, no_op),
            )
        }
        let waker = unsafe { Waker::from_raw(clone(std::ptr::null())) };
        let mut context = Context::from_waker(&waker);
        // Mock futures complete immediately; this loop intentionally has no executor.
        loop {
            match unsafe { Pin::new_unchecked(&mut future) }.poll(&mut context) {
                Poll::Ready(value) => return value,
                Poll::Pending => std::thread::yield_now(),
            }
        }
    }

    #[test]
    fn plan_is_one_shot_and_requires_confirmation() {
        let completion = serde_json::json!({
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "created": 1,
            "model": "test-model",
            "choices": [{
                "index": 0,
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": r#"{"proposals":[{"range":{"start":0,"end":1},"originalText":"a","replacementText":"b"}]}"#}
            }]
        })
        .to_string()
        .into_bytes();
        let mock = Arc::new(MockTransport {
            calls: Mutex::new(0),
            response: completion,
        });
        let store = AiEditStore::with_transport(mock.clone());
        let plan = store
            .create_plan(config(), "a", Utf16Range { start: 0, end: 1 }, "replace a")
            .unwrap();
        assert_eq!(
            block_on(store.execute_plan(
                &plan.plan_id,
                false,
                &config(),
                "a",
                Utf16Range { start: 0, end: 1 },
                "replace a",
                None
            ))
            .unwrap_err()
            .code,
            "ai_confirmation_required"
        );
        assert_eq!(
            block_on(store.execute_plan(
                &plan.plan_id,
                true,
                &config(),
                "a",
                Utf16Range { start: 0, end: 1 },
                "replace a",
                None
            ))
            .unwrap()
            .proposals
            .len(),
            1
        );
        assert_eq!(*mock.calls.lock().unwrap(), 1);
        assert_eq!(
            block_on(store.execute_plan(
                &plan.plan_id,
                true,
                &config(),
                "a",
                Utf16Range { start: 0, end: 1 },
                "replace a",
                None
            ))
            .unwrap_err()
            .code,
            "ai_plan_not_found"
        );
    }

    #[test]
    fn plan_rejects_source_drift_before_transport() {
        let mock = Arc::new(MockTransport {
            calls: Mutex::new(0),
            response: Vec::new(),
        });
        let store = AiEditStore::with_transport(mock.clone());
        let plan = store
            .create_plan(
                config(),
                "abc",
                Utf16Range { start: 0, end: 3 },
                "improve it",
            )
            .unwrap();
        assert_eq!(
            block_on(store.execute_plan(
                &plan.plan_id,
                true,
                &config(),
                "abd",
                Utf16Range { start: 0, end: 3 },
                "improve it",
                None
            ))
            .unwrap_err()
            .code,
            "ai_plan_drifted"
        );
        assert_eq!(*mock.calls.lock().unwrap(), 0);
    }

    #[test]
    fn plan_rejects_instruction_drift_and_hosted_requires_token() {
        let mock = Arc::new(MockTransport {
            calls: Mutex::new(0),
            response: Vec::new(),
        });
        let store = AiEditStore::with_transport(mock.clone());
        let plan = store
            .create_plan(
                config(),
                "abc",
                Utf16Range { start: 0, end: 3 },
                "make concise",
            )
            .unwrap();
        assert_eq!(
            block_on(store.execute_plan(
                &plan.plan_id,
                true,
                &config(),
                "abc",
                Utf16Range { start: 0, end: 3 },
                "make formal",
                None
            ))
            .unwrap_err()
            .code,
            "ai_plan_drifted"
        );
        let hosted = AiProviderConfig::new(
            AiProviderKind::OpenaiCompatible,
            "https://api.example.test/v1",
            "hosted",
        )
        .unwrap();
        let hosted_plan = store
            .create_plan(
                hosted.clone(),
                "abc",
                Utf16Range { start: 0, end: 3 },
                "make concise",
            )
            .unwrap();
        assert_eq!(
            block_on(store.execute_plan(
                &hosted_plan.plan_id,
                true,
                &hosted,
                "abc",
                Utf16Range { start: 0, end: 3 },
                "make concise",
                None
            ))
            .unwrap_err()
            .code,
            "ai_token_required"
        );
        assert_eq!(*mock.calls.lock().unwrap(), 0);
    }

    #[test]
    fn utf16_emoji_ranges_stale_overlap_and_acceptance_are_strict() {
        let selected_text = "😀b"; // Relative UTF-16: emoji=0..2, b=2..3
        let payload = r#"{"proposals":[{"range":{"start":0,"end":2},"originalText":"😀","replacementText":"X"},{"range":{"start":2,"end":3},"originalText":"b","replacementText":"Y"}]}"#;
        let proposals = parse_edit_proposals(selected_text, payload).unwrap();
        let accepted = BTreeSet::from([0]);
        assert_eq!(
            apply_accepted_proposals(selected_text, &proposals, &accepted).unwrap(),
            "Xb"
        );
        assert_eq!(parse_edit_proposals(selected_text, r#"{"proposals":[{"range":{"start":1,"end":2},"originalText":"x","replacementText":"y"}]}"#).unwrap_err().code, "ai_range_invalid");
        assert_eq!(parse_edit_proposals(selected_text, r#"{"proposals":[{"range":{"start":0,"end":3},"originalText":"😀b","replacementText":"x"},{"range":{"start":0,"end":2},"originalText":"😀","replacementText":"y"}]}"#).unwrap_err().code, "ai_proposal_overlap");
        assert_eq!(parse_edit_proposals(selected_text, r#"{"proposals":[{"range":{"start":0,"end":2,"unexpected":true},"originalText":"😀","replacementText":"x"}]}"#).unwrap_err().code, "ai_proposal_payload_invalid");
        assert_eq!(parse_edit_proposals(selected_text, r#"{"proposals":[{"range":{"start":0,"end":2},"originalText":"😀","replacementText":"x\u0000y"}]}"#).unwrap_err().code, "ai_proposal_invalid");
        assert_eq!(
            apply_accepted_proposals("😀c", &proposals, &BTreeSet::from([1]))
                .unwrap_err()
                .code,
            "ai_proposal_stale"
        );
        assert_eq!(
            apply_accepted_proposals(selected_text, &proposals, &BTreeSet::from([99]))
                .unwrap_err()
                .code,
            "ai_proposal_invalid"
        );
    }

    #[test]
    fn plan_rejects_an_oversized_selection_before_storing_it() {
        let mock = Arc::new(MockTransport {
            calls: Mutex::new(0),
            response: Vec::new(),
        });
        let store = AiEditStore::with_transport(mock);
        let source = "x".repeat(super::super::ai_provider::MAX_SELECTION_BYTES + 1);
        assert_eq!(
            store
                .create_plan(
                    config(),
                    &source,
                    Utf16Range {
                        start: 0,
                        end: source.len() as u32,
                    },
                    "shorten it",
                )
                .unwrap_err()
                .code,
            "ai_selection_invalid"
        );
    }
}
