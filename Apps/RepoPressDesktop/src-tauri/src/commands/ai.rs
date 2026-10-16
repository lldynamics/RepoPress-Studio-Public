use super::{blocking_task_failed, AppState};
use crate::core::{
    ai_secret_service_available, apply_accepted_proposals, AiChatExecutionResult,
    AiChatKnowledgeInput, AiChatPlan, AiChatStore, AiChatStreamSnapshot, AiChatStreamState,
    AiChatVault, AiChatVaultState, AiConnectionExecution, AiConnectionOperation, AiConnectionPlan,
    AiConnectionRequest, AiConnectionResult, AiConnectionStore, AiConversationDeleteResult,
    AiConversationSnapshot, AiCredential, AiCredentialScope, AiCredentialStatus,
    AiCredentialStorage, AiCredentialStore, AiEditResponse, AiEditStore, AiError,
    AiPersistedConversation, AiProviderConfig, AiProviderKind, AiProviderProfile,
    AiProviderProfileDeleteResult, AiProviderProfileStore, CommandError, CommandResult,
    EditProposal, KnowledgeLibraryStore, ReqwestAiTransport, SharedAiTransport,
    TextTranslationPlan, TextTranslationResponse, TranslationConfig, TranslationGlossaryEntry,
    TranslationProviderKind, TranslationStore, Utf16Range,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::State;
use time::{format_description::well_known::Rfc3339, OffsetDateTime};
use zeroize::Zeroizing;

const AI_ACCOUNT: &str = "default";
const MAX_COMMAND_PLANS: usize = 64;
const AI_CHAT_VAULT_PAYLOAD_VERSION: u32 = 1;
const MAX_FINALIZED_STREAMS: usize = 64;

pub(super) struct AiState {
    background_streams: std::sync::atomic::AtomicUsize,
    credentials: AiCredentialStore,
    connections: Option<Arc<AiConnectionStore>>,
    edits: Option<Arc<AiEditStore>>,
    translations: Option<Arc<TranslationStore>>,
    chats: Option<Arc<AiChatStore>>,
    chat_vault: Option<Mutex<AiChatVault>>,
    provider_profiles: Option<Mutex<AiProviderProfileStore>>,
    chat_persistence_gate: Mutex<()>,
    chat_persistence_warning: Mutex<Option<String>>,
    finalized_streams: Mutex<HashSet<String>>,
    bindings: Mutex<HashMap<String, AiPlanBinding>>,
}

struct ActiveStream(Arc<AiState>);
impl Drop for ActiveStream {
    fn drop(&mut self) {
        self.0
            .background_streams
            .fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

impl AiState {
    pub(super) fn ensure_exit_idle(&self) -> CommandResult<()> {
        if self
            .background_streams
            .load(std::sync::atomic::Ordering::SeqCst)
            != 0
        {
            return Err(CommandError::new(
                "exit_ai_busy",
                "Wait for the AI streaming task to finish before exiting.",
            ));
        }
        Ok(())
    }
}

impl Default for AiState {
    fn default() -> Self {
        let transport: Option<SharedAiTransport> = ReqwestAiTransport::new()
            .ok()
            .map(|transport| Arc::new(transport) as SharedAiTransport);
        let edits = transport
            .as_ref()
            .map(|transport| Arc::new(AiEditStore::with_transport(Arc::clone(transport))));
        let translations = transport.as_ref().and_then(|transport| {
            TranslationStore::with_transport(Arc::clone(transport))
                .ok()
                .map(Arc::new)
        });
        let chats = transport
            .as_ref()
            .map(|transport| Arc::new(AiChatStore::with_transport(Arc::clone(transport))));
        Self {
            background_streams: std::sync::atomic::AtomicUsize::new(0),
            credentials: AiCredentialStore::default(),
            connections: AiConnectionStore::new().ok().map(Arc::new),
            edits,
            translations,
            chats,
            chat_vault: None,
            provider_profiles: None,
            chat_persistence_gate: Mutex::new(()),
            chat_persistence_warning: Mutex::new(None),
            finalized_streams: Mutex::new(HashSet::new()),
            bindings: Mutex::new(HashMap::new()),
        }
    }
}

impl AiState {
    pub(super) fn new(app_data_dir: PathBuf) -> Self {
        Self {
            chat_vault: Some(Mutex::new(AiChatVault::new(app_data_dir.clone()))),
            provider_profiles: Some(Mutex::new(AiProviderProfileStore::new(app_data_dir))),
            ..Self::default()
        }
    }
}

#[derive(Clone)]
struct AiPlanBinding {
    session_id: String,
    root: PathBuf,
    document_id: String,
    document_revision: u64,
    selection_start: u32,
    selection_end: u32,
    expires_at_unix_seconds: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum AiCredentialStorageView {
    SecretService,
    SessionMemory,
    Unavailable,
    NotRequired,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiCredentialStatusSnapshot {
    configured: bool,
    storage: AiCredentialStorageView,
    session_only: bool,
    secret_service_available: bool,
    warning: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiEditPlanView {
    plan_id: String,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    selection_bytes: usize,
    instruction_bytes: usize,
    expires_at: String,
    summary: String,
    warnings: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StructuredTextTranslationSegmentInput {
    id: String,
    text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StructuredTextTranslationPlan {
    plan_id: String,
    provider: TranslationProviderKind,
    endpoint: String,
    model: String,
    source_language: String,
    target_language: String,
    text_bytes: usize,
    glossary_count: usize,
    expires_at: String,
    summary: String,
    warnings: Vec<String>,
    segment_count: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StructuredTextTranslationOutputSegment {
    id: String,
    translated_text: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StructuredTextTranslationResponse {
    translations: Vec<StructuredTextTranslationOutputSegment>,
    detected_source_language: Option<String>,
    provider: TranslationProviderKind,
    model: String,
    target_language: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiAppliedEdit {
    text: String,
    applied_proposal_ids: Vec<u32>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AiChatVaultStatusSnapshot {
    state: AiChatVaultState,
    has_vault: bool,
    persistent_conversation_count: usize,
    summary: String,
    warning: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct AiChatVaultPayload {
    schema_version: u32,
    conversations: Vec<AiPersistedConversation>,
}

#[tauri::command]
pub async fn list_ai_conversations(
    state: State<'_, AppState>,
) -> CommandResult<Vec<AiConversationSnapshot>> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ai.chat_store()?.list_conversations().map_err(ai_error)
    })
    .await
    .map_err(|_| {
        blocking_task_failed("ai_conversation_list_task_failed", "list AI conversations")
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn create_ai_conversation(
    title: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<AiConversationSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _gate = ai.persistence_guard()?;
        let chats = ai.chat_store()?;
        let mut conversation = chats
            .create_conversation(title.as_deref())
            .map_err(ai_error)?;
        conversation.persistence_warning = ai.attempt_chat_persistence(&chats);
        Ok(conversation)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_conversation_create_task_failed",
            "create an AI conversation",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn delete_ai_conversation(
    conversation_id: String,
    state: State<'_, AppState>,
) -> CommandResult<AiConversationDeleteResult> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _gate = ai.persistence_guard()?;
        let chats = ai.chat_store()?;
        let mut result = chats
            .delete_conversation(&conversation_id)
            .map_err(ai_error)?;
        result.persistence_warning = ai.attempt_chat_persistence(&chats);
        Ok(result)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_conversation_delete_task_failed",
            "delete an AI conversation",
        )
    })?
}

#[tauri::command]
pub async fn get_ai_chat_vault_status(
    state: State<'_, AppState>,
) -> CommandResult<AiChatVaultStatusSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _gate = ai.persistence_guard()?;
        let chats = ai.chat_store()?;
        ai.chat_vault_status_snapshot(&chats)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_vault_status_task_failed",
            "read encrypted AI chat storage status",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn initialize_ai_chat_vault(
    passphrase: String,
    state: State<'_, AppState>,
) -> CommandResult<AiChatVaultStatusSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let passphrase = Zeroizing::new(passphrase);
        let _gate = ai.persistence_guard()?;
        let chats = ai.chat_store()?;
        if chats.persistence_active().map_err(ai_error)? {
            return Err(CommandError::new(
                "ai_chat_vault_already_unlocked",
                "Encrypted AI chat storage is already unlocked.",
            ));
        }
        let payload = encode_chat_vault_payload(&chats)?;
        {
            let mut vault = ai.chat_vault()?.lock().map_err(|_| {
                CommandError::new(
                    "ai_chat_vault_unavailable",
                    "Encrypted AI chat storage is unavailable.",
                )
            })?;
            vault
                .initialize(passphrase.as_str(), payload.as_slice())
                .map_err(ai_error)?;
        }
        if let Err(error) = chats.activate_persistence(Vec::new()).map_err(ai_error) {
            if let Ok(vault_store) = ai.chat_vault() {
                if let Ok(mut vault) = vault_store.lock() {
                    if vault.delete().is_err() {
                        vault.lock();
                    }
                }
            }
            return Err(error);
        }
        ai.clear_chat_persistence_warning();
        ai.chat_vault_status_snapshot(&chats)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_vault_initialize_task_failed",
            "initialize encrypted AI chat storage",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn unlock_ai_chat_vault(
    passphrase: String,
    state: State<'_, AppState>,
) -> CommandResult<AiChatVaultStatusSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let passphrase = Zeroizing::new(passphrase);
        let _gate = ai.persistence_guard()?;
        let chats = ai.chat_store()?;
        if chats.persistence_active().map_err(ai_error)? {
            return Err(CommandError::new(
                "ai_chat_vault_already_unlocked",
                "Encrypted AI chat storage is already unlocked.",
            ));
        }
        let plaintext = {
            let mut vault = ai.chat_vault()?.lock().map_err(|_| {
                CommandError::new(
                    "ai_chat_vault_unavailable",
                    "Encrypted AI chat storage is unavailable.",
                )
            })?;
            Zeroizing::new(vault.unlock(passphrase.as_str()).map_err(ai_error)?)
        };
        let restored = match decode_chat_vault_payload(plaintext.as_slice()) {
            Ok(restored) => restored,
            Err(error) => {
                ai.lock_chat_vault_key()?;
                return Err(error);
            }
        };
        if let Err(error) = chats.activate_persistence(restored).map_err(ai_error) {
            ai.lock_chat_vault_key()?;
            return Err(error);
        }
        let _ = ai.attempt_chat_persistence(&chats);
        ai.chat_vault_status_snapshot(&chats)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_vault_unlock_task_failed",
            "unlock encrypted AI chat storage",
        )
    })?
}

#[tauri::command]
pub async fn lock_ai_chat_vault(
    state: State<'_, AppState>,
) -> CommandResult<AiChatVaultStatusSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _gate = ai.persistence_guard()?;
        let chats = ai.chat_store()?;
        if chats.persistence_active().map_err(ai_error)? {
            ai.persist_chat_history(&chats)?;
            chats.deactivate_persistence().map_err(ai_error)?;
        }
        ai.lock_chat_vault_key()?;
        ai.clear_chat_persistence_warning();
        ai.chat_vault_status_snapshot(&chats)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_vault_lock_task_failed",
            "lock encrypted AI chat storage",
        )
    })?
}

#[tauri::command]
pub async fn delete_ai_chat_vault(
    state: State<'_, AppState>,
) -> CommandResult<AiChatVaultStatusSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _gate = ai.persistence_guard()?;
        let chats = ai.chat_store()?;
        let was_active = chats.persistence_active().map_err(ai_error)?;
        {
            let mut vault = ai.chat_vault()?.lock().map_err(|_| {
                CommandError::new(
                    "ai_chat_vault_unavailable",
                    "Encrypted AI chat storage is unavailable.",
                )
            })?;
            vault.delete().map_err(ai_error)?;
        }
        if was_active {
            chats.deactivate_persistence().map_err(ai_error)?;
        }
        ai.clear_chat_persistence_warning();
        ai.chat_vault_status_snapshot(&chats)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_vault_delete_task_failed",
            "delete encrypted AI chat storage",
        )
    })?
}

#[tauri::command]
pub async fn list_ai_provider_profiles(
    state: State<'_, AppState>,
) -> CommandResult<Vec<AiProviderProfile>> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ai.provider_profile_store()?
            .lock()
            .map_err(|_| ai_profile_store_unavailable())?
            .list()
            .map_err(ai_error)
    })
    .await
    .map_err(|_| blocking_task_failed("ai_profile_list_task_failed", "list AI provider profiles"))?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn save_ai_provider_profile(
    profile_id: Option<String>,
    name: String,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    streaming: bool,
    state: State<'_, AppState>,
) -> CommandResult<AiProviderProfile> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let config = provider_config(provider, &endpoint, &model)?;
        ai.provider_profile_store()?
            .lock()
            .map_err(|_| ai_profile_store_unavailable())?
            .save(profile_id.as_deref(), &name, config, streaming)
            .map_err(ai_error)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_profile_save_task_failed",
            "save the AI provider profile",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn delete_ai_provider_profile(
    profile_id: String,
    state: State<'_, AppState>,
) -> CommandResult<AiProviderProfileDeleteResult> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        ai.provider_profile_store()?
            .lock()
            .map_err(|_| ai_profile_store_unavailable())?
            .delete(&profile_id)
            .map_err(ai_error)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_profile_delete_task_failed",
            "delete the AI provider profile",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn plan_ai_chat(
    conversation_id: String,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    message: String,
    knowledge_item_ids: Vec<String>,
    streaming: bool,
    state: State<'_, AppState>,
) -> CommandResult<AiChatPlan> {
    let ai = state.ai.clone();
    let knowledge = state.knowledge.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let config = provider_config(provider, &endpoint, &model)?;
        let selected = load_chat_knowledge(&knowledge, &knowledge_item_ids)?;
        let chats = ai.chat_store()?;
        if streaming {
            chats
                .create_plan_with_streaming(config, &conversation_id, &message, selected, true)
                .map_err(ai_error)
        } else {
            chats
                .create_plan(config, &conversation_id, &message, selected)
                .map_err(ai_error)
        }
    })
    .await
    .map_err(|_| blocking_task_failed("ai_chat_plan_task_failed", "plan the AI chat request"))?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn execute_ai_chat(
    plan_id: String,
    conversation_id: String,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    message: String,
    knowledge_item_ids: Vec<String>,
    streaming: bool,
    state: State<'_, AppState>,
) -> CommandResult<AiChatExecutionResult> {
    if streaming {
        return Err(CommandError::new(
            "ai_chat_plan_mode_mismatch",
            "Use the streaming command for a reviewed streaming plan.",
        ));
    }
    let ai = state.ai.clone();
    let persistence = ai.clone();
    let knowledge = state.knowledge.clone();
    let (chats, config, selected, credential) = tauri::async_runtime::spawn_blocking(move || {
        let config = provider_config(provider, &endpoint, &model)?;
        let selected = load_chat_knowledge(&knowledge, &knowledge_item_ids)?;
        let credential = match config.provider {
            AiProviderKind::OpenaiCompatible => ai
                .credentials
                .lookup(&ai_scope(&config)?)
                .map_err(ai_error)?,
            AiProviderKind::OllamaLocal => None,
        };
        Ok::<_, CommandError>((ai.chat_store()?, config, selected, credential))
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_execute_prepare_task_failed",
            "prepare the AI chat request",
        )
    })??;
    let result = chats
        .execute_plan(
            &plan_id,
            &conversation_id,
            &config,
            &message,
            selected,
            credential,
        )
        .await
        .map_err(ai_error)?;
    tauri::async_runtime::spawn_blocking(move || {
        let _gate = persistence.persistence_guard()?;
        let mut result = result;
        result.persistence_warning = persistence.attempt_chat_persistence(&chats);
        result.conversation.persistence_warning = result.persistence_warning.clone();
        Ok(result)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_persist_task_failed",
            "save the completed AI conversation",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn start_ai_chat_stream(
    plan_id: String,
    conversation_id: String,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    message: String,
    knowledge_item_ids: Vec<String>,
    streaming: bool,
    state: State<'_, AppState>,
) -> CommandResult<AiChatStreamSnapshot> {
    if !streaming {
        return Err(CommandError::new(
            "ai_chat_plan_mode_mismatch",
            "Use the one-shot command for a reviewed non-streaming plan.",
        ));
    }
    let ai = state.ai.clone();
    let knowledge = state.knowledge.clone();
    let prepare_ai = ai.clone();
    let (chats, initial, task) = tauri::async_runtime::spawn_blocking(move || {
        let config = provider_config(provider, &endpoint, &model)?;
        let selected = load_chat_knowledge(&knowledge, &knowledge_item_ids)?;
        let credential = match config.provider {
            AiProviderKind::OpenaiCompatible => prepare_ai
                .credentials
                .lookup(&ai_scope(&config)?)
                .map_err(ai_error)?,
            AiProviderKind::OllamaLocal => None,
        };
        let chats = prepare_ai.chat_store()?;
        let (initial, task) = chats
            .begin_stream_plan(
                &plan_id,
                &conversation_id,
                &config,
                &message,
                selected,
                credential,
            )
            .map_err(ai_error)?;
        Ok::<_, CommandError>((chats, initial, task))
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_stream_prepare_task_failed",
            "prepare the AI streaming request",
        )
    })??;

    let operation_id = initial.operation_id.clone();
    ai.background_streams
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let active_stream = ActiveStream(ai.clone());
    tauri::async_runtime::spawn(async move {
        let _active_stream = active_stream;
        if chats.run_stream_task(task).await.is_ok() {
            let finalized_chats = chats.clone();
            let _ = tauri::async_runtime::spawn_blocking(move || {
                ai.finalize_stream_persistence(&finalized_chats, &operation_id)
            })
            .await;
        }
    });
    Ok(initial)
}

#[tauri::command(rename_all = "camelCase")]
pub async fn poll_ai_chat_stream(
    operation_id: String,
    after_cursor: usize,
    state: State<'_, AppState>,
) -> CommandResult<AiChatStreamSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let chats = ai.chat_store()?;
        let mut snapshot = chats
            .poll_stream(&operation_id, after_cursor)
            .map_err(ai_error)?;
        if snapshot.state == AiChatStreamState::Completed {
            ai.finalize_stream_persistence(&chats, &operation_id)?;
            snapshot = chats
                .poll_stream(&operation_id, after_cursor)
                .map_err(ai_error)?;
        }
        Ok(snapshot)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_stream_poll_task_failed",
            "read the AI streaming request",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn cancel_ai_chat_stream(
    operation_id: String,
    state: State<'_, AppState>,
) -> CommandResult<AiChatStreamSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let chats = ai.chat_store()?;
        let mut snapshot = chats.cancel_stream(&operation_id).map_err(ai_error)?;
        if snapshot.state == AiChatStreamState::Completed {
            ai.finalize_stream_persistence(&chats, &operation_id)?;
            snapshot = chats.poll_stream(&operation_id, 0).map_err(ai_error)?;
        }
        Ok(snapshot)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_chat_stream_cancel_task_failed",
            "cancel the AI streaming request",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn plan_text_translation(
    provider: TranslationProviderKind,
    endpoint: String,
    model: String,
    source_language: String,
    target_language: String,
    text: String,
    glossary: Option<Vec<TranslationGlossaryEntry>>,
    state: State<'_, AppState>,
) -> CommandResult<TextTranslationPlan> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let config = translation_config(
            provider,
            &endpoint,
            &model,
            &source_language,
            &target_language,
            glossary,
        )?;
        ai.translation_store()?
            .create_plan(config, &text)
            .map_err(ai_error)
    })
    .await
    .map_err(|_| blocking_task_failed("translation_plan_task_failed", "plan text translation"))?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn execute_text_translation(
    plan_id: String,
    provider: TranslationProviderKind,
    endpoint: String,
    model: String,
    source_language: String,
    target_language: String,
    text: String,
    glossary: Option<Vec<TranslationGlossaryEntry>>,
    state: State<'_, AppState>,
) -> CommandResult<TextTranslationResponse> {
    let ai = state.ai.clone();
    let (store, config, credential) = tauri::async_runtime::spawn_blocking(move || {
        let config = translation_config(
            provider,
            &endpoint,
            &model,
            &source_language,
            &target_language,
            glossary,
        )?;
        let credential = match config.provider {
            TranslationProviderKind::OpenaiCompatible => {
                let hosted = AiProviderConfig::new(
                    AiProviderKind::OpenaiCompatible,
                    &config.endpoint,
                    &config.model,
                )
                .map_err(ai_error)?;
                ai.credentials
                    .lookup(&ai_scope(&hosted)?)
                    .map_err(ai_error)?
            }
            TranslationProviderKind::LibretranslateLocal | TranslationProviderKind::OllamaLocal => {
                None
            }
        };
        Ok::<_, CommandError>((ai.translation_store()?, config, credential))
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "translation_execute_prepare_task_failed",
            "prepare text translation",
        )
    })??;
    store
        .execute_plan(&plan_id, &config, &text, credential)
        .await
        .map_err(ai_error)
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn plan_structured_text_translation(
    provider: TranslationProviderKind,
    endpoint: String,
    model: String,
    source_language: String,
    target_language: String,
    glossary: Option<Vec<TranslationGlossaryEntry>>,
    segments: Vec<StructuredTextTranslationSegmentInput>,
    state: State<'_, AppState>,
) -> CommandResult<StructuredTextTranslationPlan> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let config = translation_config(
            provider,
            &endpoint,
            &model,
            &source_language,
            &target_language,
            glossary,
        )?;
        let segments = segments
            .into_iter()
            .map(|segment| (segment.id, segment.text))
            .collect::<Vec<_>>();
        let segment_count = segments.len();
        let plan = ai
            .translation_store()?
            .create_structured_plan(config, &segments)
            .map_err(ai_error)?;
        Ok(structured_translation_plan(plan, segment_count))
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "structured_translation_plan_task_failed",
            "plan structured text translation",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn execute_structured_text_translation(
    plan_id: String,
    provider: TranslationProviderKind,
    endpoint: String,
    model: String,
    source_language: String,
    target_language: String,
    glossary: Option<Vec<TranslationGlossaryEntry>>,
    segments: Vec<StructuredTextTranslationSegmentInput>,
    state: State<'_, AppState>,
) -> CommandResult<StructuredTextTranslationResponse> {
    let ai = state.ai.clone();
    let (store, config, credential, segments) = tauri::async_runtime::spawn_blocking(move || {
        let config = translation_config(
            provider,
            &endpoint,
            &model,
            &source_language,
            &target_language,
            glossary,
        )?;
        let credential = match config.provider {
            TranslationProviderKind::OpenaiCompatible => {
                let hosted = AiProviderConfig::new(
                    AiProviderKind::OpenaiCompatible,
                    &config.endpoint,
                    &config.model,
                )
                .map_err(ai_error)?;
                ai.credentials
                    .lookup(&ai_scope(&hosted)?)
                    .map_err(ai_error)?
            }
            TranslationProviderKind::LibretranslateLocal | TranslationProviderKind::OllamaLocal => {
                None
            }
        };
        let segments = segments
            .into_iter()
            .map(|segment| (segment.id, segment.text))
            .collect::<Vec<_>>();
        Ok::<_, CommandError>((ai.translation_store()?, config, credential, segments))
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "structured_translation_execute_prepare_task_failed",
            "prepare structured text translation",
        )
    })??;
    let (translations, detected_source_language) = store
        .execute_structured_plan(&plan_id, &config, &segments, credential)
        .await
        .map_err(ai_error)?;
    Ok(StructuredTextTranslationResponse {
        translations: translations
            .into_iter()
            .map(
                |(id, translated_text)| StructuredTextTranslationOutputSegment {
                    id,
                    translated_text,
                },
            )
            .collect(),
        detected_source_language,
        provider: config.provider,
        model: config.model,
        target_language: config.target_language,
    })
}

#[tauri::command(rename_all = "camelCase")]
pub async fn ai_credential_status(
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    state: State<'_, AppState>,
) -> CommandResult<AiCredentialStatusSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let config = credential_config(provider, &endpoint, &model)?;
        ai.credential_snapshot(&config)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_credential_status_task_failed",
            "read AI credential status",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn store_ai_credential(
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    token: String,
    state: State<'_, AppState>,
) -> CommandResult<AiCredentialStatusSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let config = credential_config(provider, &endpoint, &model)?;
        if config.provider == AiProviderKind::OllamaLocal {
            return Err(CommandError::new(
                "ai_credential_not_required",
                "Local Ollama does not accept a hosted-provider credential.",
            ));
        }
        let scope = ai_scope(&config)?;
        let credential = AiCredential::from_token(token).map_err(ai_error)?;
        ai.credentials.save(scope, credential).map_err(ai_error)?;
        ai.credential_snapshot(&config)
    })
    .await
    .map_err(|_| {
        blocking_task_failed("ai_credential_store_task_failed", "store the AI credential")
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn delete_ai_credential(
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    state: State<'_, AppState>,
) -> CommandResult<AiCredentialStatusSnapshot> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let config = credential_config(provider, &endpoint, &model)?;
        if config.provider == AiProviderKind::OllamaLocal {
            return Ok(not_required_credential_snapshot());
        }
        let warning = ai
            .credentials
            .delete(&ai_scope(&config)?)
            .map_err(ai_error)?;
        let mut snapshot = unconfigured_credential_snapshot();
        snapshot.warning = warning;
        Ok(snapshot)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_credential_delete_task_failed",
            "delete the AI credential",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn plan_ai_edit(
    session_id: String,
    document_id: String,
    document_revision: u64,
    selection_start: u32,
    selection_end: u32,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    source_text: String,
    instruction: String,
    state: State<'_, AppState>,
) -> CommandResult<AiEditPlanView> {
    let repositories = state.repositories.clone();
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let (root, current_revision, writable) =
            repositories.document_context_for_session(&session_id, &document_id)?;
        validate_document_context(current_revision, writable, document_revision)?;
        validate_editor_selection(&source_text, selection_start, selection_end)?;
        ai.reserve_plan_slot()?;
        let config = provider_config(provider, &endpoint, &model)?;
        let selection = entire_selection(&source_text)?;
        let plan = ai
            .edit_store()?
            .create_plan(config, &source_text, selection, &instruction)
            .map_err(ai_error)?;
        let warnings = match plan.provider {
            AiProviderKind::OpenaiCompatible => vec![
                "确认后，指令与选中文本将发送到所示外部 HTTPS 服务；完整文档不会发送。".to_string(),
            ],
            AiProviderKind::OllamaLocal => {
                vec!["确认后，指令与选中文本仅发送到严格 loopback 的本机 Ollama 端点。".to_string()]
            }
        };
        let view = AiEditPlanView {
            plan_id: plan.plan_id.clone(),
            provider: plan.provider,
            endpoint: plan.endpoint,
            model: plan.model,
            selection_bytes: plan.selection_bytes,
            instruction_bytes: instruction.len(),
            expires_at: rfc3339_from_seconds(plan.expires_at_unix_seconds)?,
            summary: "将只请求当前选区的编辑提案；不会自动改写文件或保存到磁盘。".to_string(),
            warnings,
        };
        ai.bindings
            .lock()
            .map_err(|_| ai_state_unavailable())?
            .insert(
                plan.plan_id,
                AiPlanBinding {
                    session_id,
                    root,
                    document_id,
                    document_revision,
                    selection_start,
                    selection_end,
                    expires_at_unix_seconds: plan.expires_at_unix_seconds,
                },
            );
        Ok(view)
    })
    .await
    .map_err(|_| blocking_task_failed("ai_plan_task_failed", "plan the AI edit"))?
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn execute_ai_edit(
    session_id: String,
    plan_id: String,
    document_id: String,
    document_revision: u64,
    selection_start: u32,
    selection_end: u32,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    source_text: String,
    instruction: String,
    state: State<'_, AppState>,
) -> CommandResult<AiEditResponse> {
    let repositories = state.repositories.clone();
    let ai = state.ai.clone();
    let prepared_plan_id = plan_id.clone();
    let prepared_source = source_text.clone();
    let (edits, config, selection, credential) = tauri::async_runtime::spawn_blocking(move || {
        let binding = ai
            .bindings
            .lock()
            .map_err(|_| ai_state_unavailable())?
            .remove(&prepared_plan_id)
            .ok_or_else(|| {
                CommandError::new("ai_plan_not_found", "AI request plan is unavailable.")
            })?;
        let (root, current_revision, writable) =
            repositories.document_context_for_session(&session_id, &document_id)?;
        validate_document_context(current_revision, writable, document_revision)?;
        validate_editor_selection(&prepared_source, selection_start, selection_end)?;
        if binding.session_id != session_id
            || binding.root != root
            || binding.document_id != document_id
            || binding.document_revision != document_revision
            || binding.selection_start != selection_start
            || binding.selection_end != selection_end
        {
            return Err(CommandError::new(
                "ai_session_mismatch",
                "The reviewed AI plan belongs to another repository session.",
            ));
        }
        let config = provider_config(provider, &endpoint, &model)?;
        let credential = match config.provider {
            AiProviderKind::OpenaiCompatible => ai
                .credentials
                .lookup(&ai_scope(&config)?)
                .map_err(ai_error)?,
            AiProviderKind::OllamaLocal => None,
        };
        Ok((
            ai.edit_store()?,
            config,
            entire_selection(&prepared_source)?,
            credential,
        ))
    })
    .await
    .map_err(|_| blocking_task_failed("ai_execute_prepare_task_failed", "prepare the AI edit"))??;

    edits
        .execute_plan(
            &plan_id,
            true,
            &config,
            &source_text,
            selection,
            &instruction,
            credential,
        )
        .await
        .map_err(ai_error)
}

#[tauri::command(rename_all = "camelCase")]
#[allow(clippy::too_many_arguments)]
pub async fn apply_ai_edits(
    session_id: String,
    document_id: String,
    document_revision: u64,
    selection_start: u32,
    selection_end: u32,
    source_text: String,
    proposals: Vec<EditProposal>,
    accepted_ids: Vec<u32>,
    state: State<'_, AppState>,
) -> CommandResult<AiAppliedEdit> {
    let repositories = state.repositories.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let (_, current_revision, writable) =
            repositories.document_context_for_session(&session_id, &document_id)?;
        validate_document_context(current_revision, writable, document_revision)?;
        validate_editor_selection(&source_text, selection_start, selection_end)?;
        let accepted = accepted_ids.into_iter().collect::<BTreeSet<_>>();
        if accepted.is_empty() {
            return Err(CommandError::new(
                "ai_acceptance_required",
                "Select at least one AI edit proposal to apply.",
            ));
        }
        let text =
            apply_accepted_proposals(&source_text, &proposals, &accepted).map_err(ai_error)?;
        Ok(AiAppliedEdit {
            text,
            applied_proposal_ids: accepted.into_iter().collect(),
        })
    })
    .await
    .map_err(|_| blocking_task_failed("ai_apply_task_failed", "apply accepted AI edits"))?
}

impl AiState {
    fn persistence_guard(&self) -> CommandResult<std::sync::MutexGuard<'_, ()>> {
        self.chat_persistence_gate.lock().map_err(|_| {
            CommandError::new(
                "ai_chat_persistence_unavailable",
                "Encrypted AI chat storage is temporarily unavailable.",
            )
        })
    }

    fn chat_vault(&self) -> CommandResult<&Mutex<AiChatVault>> {
        self.chat_vault.as_ref().ok_or_else(|| {
            CommandError::new(
                "ai_chat_vault_unavailable",
                "Encrypted AI chat storage is unavailable.",
            )
        })
    }

    fn provider_profile_store(&self) -> CommandResult<&Mutex<AiProviderProfileStore>> {
        self.provider_profiles
            .as_ref()
            .ok_or_else(ai_profile_store_unavailable)
    }

    fn persist_chat_history(&self, chats: &AiChatStore) -> CommandResult<()> {
        if !chats.persistence_active().map_err(ai_error)? {
            return Ok(());
        }
        let payload = encode_chat_vault_payload(chats)?;
        let result = self
            .chat_vault()?
            .lock()
            .map_err(|_| {
                CommandError::new(
                    "ai_chat_vault_unavailable",
                    "Encrypted AI chat storage is unavailable.",
                )
            })?
            .save(payload.as_slice())
            .map_err(ai_error);
        match result {
            Ok(()) => {
                self.clear_chat_persistence_warning();
                Ok(())
            }
            Err(error) => {
                self.set_chat_persistence_warning(persistence_warning(&error));
                Err(error)
            }
        }
    }

    fn attempt_chat_persistence(&self, chats: &AiChatStore) -> Option<String> {
        match self.persist_chat_history(chats) {
            Ok(()) => None,
            Err(error) => {
                let warning = persistence_warning(&error);
                self.set_chat_persistence_warning(warning.clone());
                Some(warning)
            }
        }
    }

    fn set_chat_persistence_warning(&self, warning: String) {
        if let Ok(mut stored) = self.chat_persistence_warning.lock() {
            *stored = Some(warning);
        }
    }

    fn clear_chat_persistence_warning(&self) {
        if let Ok(mut stored) = self.chat_persistence_warning.lock() {
            *stored = None;
        }
    }

    fn chat_persistence_warning(&self) -> Option<String> {
        self.chat_persistence_warning
            .lock()
            .ok()
            .and_then(|warning| warning.clone())
    }

    fn chat_vault_status_snapshot(
        &self,
        chats: &AiChatStore,
    ) -> CommandResult<AiChatVaultStatusSnapshot> {
        let status = self
            .chat_vault()?
            .lock()
            .map_err(|_| {
                CommandError::new(
                    "ai_chat_vault_unavailable",
                    "Encrypted AI chat storage is unavailable.",
                )
            })?
            .status()
            .map_err(ai_error)?;
        let persistence_active = chats.persistence_active().map_err(ai_error)?;
        let persistent_conversation_count = if persistence_active {
            chats.list_conversations().map_err(ai_error)?.len()
        } else {
            0
        };
        let summary = match status.state {
            AiChatVaultState::Disabled => "默认仅保留在本次运行；尚未创建加密对话库。".to_string(),
            AiChatVaultState::Locked => "加密对话库已锁定；解锁前不会读取历史。".to_string(),
            AiChatVaultState::Unlocked => {
                format!("加密对话库已解锁，当前载入 {persistent_conversation_count} 个对话。")
            }
        };
        let mut warning = self.chat_persistence_warning();
        if (status.state == AiChatVaultState::Unlocked) != persistence_active {
            warning = Some("加密对话状态不一致；为保护历史，请锁定后重新解锁。".to_string());
        }
        Ok(AiChatVaultStatusSnapshot {
            state: status.state,
            has_vault: status.has_vault,
            persistent_conversation_count,
            summary,
            warning,
        })
    }

    fn lock_chat_vault_key(&self) -> CommandResult<()> {
        self.chat_vault()?
            .lock()
            .map_err(|_| {
                CommandError::new(
                    "ai_chat_vault_unavailable",
                    "Encrypted AI chat storage is unavailable.",
                )
            })?
            .lock();
        Ok(())
    }

    fn finalize_stream_persistence(
        &self,
        chats: &AiChatStore,
        operation_id: &str,
    ) -> CommandResult<()> {
        let _gate = self.persistence_guard()?;
        let mut finalized = self
            .finalized_streams
            .lock()
            .map_err(|_| ai_state_unavailable())?;
        if finalized.contains(operation_id) {
            return Ok(());
        }
        let warning = self.attempt_chat_persistence(chats);
        chats
            .set_stream_persistence_warning(operation_id, warning)
            .map_err(ai_error)?;
        if finalized.len() >= MAX_FINALIZED_STREAMS {
            finalized.clear();
        }
        finalized.insert(operation_id.to_string());
        Ok(())
    }

    fn chat_store(&self) -> CommandResult<Arc<AiChatStore>> {
        self.chats.clone().ok_or_else(|| {
            CommandError::new(
                "ai_chat_transport_unavailable",
                "The AI chat transport is unavailable.",
            )
        })
    }

    fn edit_store(&self) -> CommandResult<Arc<AiEditStore>> {
        self.edits.clone().ok_or_else(|| {
            CommandError::new(
                "ai_transport_unavailable",
                "The AI transport is unavailable.",
            )
        })
    }

    fn translation_store(&self) -> CommandResult<Arc<TranslationStore>> {
        self.translations.clone().ok_or_else(|| {
            CommandError::new(
                "translation_transport_unavailable",
                "The translation transport is unavailable.",
            )
        })
    }

    fn reserve_plan_slot(&self) -> CommandResult<()> {
        let now = unix_seconds();
        let mut bindings = self.bindings.lock().map_err(|_| ai_state_unavailable())?;
        bindings.retain(|_, binding| binding.expires_at_unix_seconds > now);
        if bindings.len() >= MAX_COMMAND_PLANS {
            return Err(CommandError::new(
                "ai_plan_limit",
                "Too many AI request plans are pending.",
            ));
        }
        Ok(())
    }

    fn credential_snapshot(
        &self,
        config: &AiProviderConfig,
    ) -> CommandResult<AiCredentialStatusSnapshot> {
        if config.provider == AiProviderKind::OllamaLocal {
            return Ok(not_required_credential_snapshot());
        }
        let status = self
            .credentials
            .status(&ai_scope(config)?)
            .map_err(ai_error)?;
        Ok(match status {
            Some(status) => configured_credential_snapshot(status),
            None => unconfigured_credential_snapshot(),
        })
    }
}

fn load_chat_knowledge(
    store: &KnowledgeLibraryStore,
    item_ids: &[String],
) -> CommandResult<Vec<AiChatKnowledgeInput>> {
    if item_ids.len() > 8 {
        return Err(CommandError::new(
            "ai_chat_knowledge_limit",
            "At most eight knowledge items may be selected.",
        ));
    }
    item_ids
        .iter()
        .map(|item_id| {
            let item = store.get(item_id)?;
            Ok(AiChatKnowledgeInput {
                item_id: item.summary.item_id,
                title: item.summary.title,
                revision_number: item.summary.revision_number,
                allows_remote_ai_use: item.summary.allows_remote_ai_use,
                text: item.text,
            })
        })
        .collect()
}

// Credential operations validate the endpoint/account scope independently of a
// selected model. This scope-only config must never be used for generation.
fn credential_config(
    provider: AiProviderKind,
    endpoint: &str,
    _model: &str,
) -> CommandResult<AiProviderConfig> {
    let config = AiProviderConfig {
        provider,
        endpoint: endpoint.trim().to_string(),
        model: String::new(),
    };
    let scope = AiCredentialScope::new(&config, AI_ACCOUNT).map_err(ai_error)?;
    Ok(AiProviderConfig {
        endpoint: scope.endpoint,
        ..config
    })
}

fn connection_credential(
    ai: &AiState,
    request: &AiConnectionRequest,
) -> CommandResult<Option<AiCredential>> {
    let config = credential_config(request.provider, &request.endpoint, "")?;
    match config.provider {
        AiProviderKind::OpenaiCompatible => {
            ai.credentials.lookup(&ai_scope(&config)?).map_err(ai_error)
        }
        AiProviderKind::OllamaLocal => Ok(None),
    }
}

fn prepare_connection_execution(
    store: &AiConnectionStore,
    plan_id: &str,
    credential_lookup: impl FnOnce() -> CommandResult<Option<AiCredential>>,
) -> CommandResult<(AiConnectionExecution, Option<AiCredential>)> {
    let execution = store.take_execution(plan_id).map_err(ai_error)?;
    let credential = credential_lookup()?;
    Ok((execution, credential))
}

#[tauri::command(rename_all = "camelCase")]
pub async fn plan_ai_connection(
    operation: AiConnectionOperation,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    state: State<'_, AppState>,
) -> CommandResult<AiConnectionPlan> {
    let ai = state.ai.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let request = AiConnectionRequest {
            operation,
            provider,
            endpoint,
            model,
        };
        let credential = connection_credential(&ai, &request)?;
        let store = ai.connections.as_ref().ok_or_else(|| {
            CommandError::new(
                "ai_connection_unavailable",
                "AI connection checks are unavailable.",
            )
        })?;
        store.plan(request, credential.as_ref()).map_err(ai_error)
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_connection_plan_task_failed",
            "prepare an AI connection check",
        )
    })?
}

#[tauri::command(rename_all = "camelCase")]
pub async fn execute_ai_connection(
    plan_id: String,
    operation: AiConnectionOperation,
    provider: AiProviderKind,
    endpoint: String,
    model: String,
    state: State<'_, AppState>,
) -> CommandResult<AiConnectionResult> {
    let ai = state.ai.clone();
    let (store, execution, request, credential) = tauri::async_runtime::spawn_blocking(move || {
        let request = AiConnectionRequest {
            operation,
            provider,
            endpoint,
            model,
        };
        let store = ai.connections.clone().ok_or_else(|| {
            CommandError::new(
                "ai_connection_unavailable",
                "AI connection checks are unavailable.",
            )
        })?;
        let (execution, credential) = prepare_connection_execution(&store, &plan_id, || {
            connection_credential(&ai, &request)
        })?;
        Ok::<_, CommandError>((store, execution, request, credential))
    })
    .await
    .map_err(|_| {
        blocking_task_failed(
            "ai_connection_execute_task_failed",
            "prepare an AI connection request",
        )
    })??;
    store
        .execute_prepared(execution, request, credential.as_ref())
        .await
        .map_err(ai_error)
}

fn provider_config(
    provider: AiProviderKind,
    endpoint: &str,
    model: &str,
) -> CommandResult<AiProviderConfig> {
    AiProviderConfig::new(provider, endpoint.trim(), model.trim()).map_err(ai_error)
}

fn translation_config(
    provider: TranslationProviderKind,
    endpoint: &str,
    model: &str,
    source_language: &str,
    target_language: &str,
    glossary: Option<Vec<TranslationGlossaryEntry>>,
) -> CommandResult<TranslationConfig> {
    TranslationConfig::new_with_glossary(
        provider,
        endpoint.trim(),
        model.trim(),
        source_language.trim(),
        target_language.trim(),
        glossary,
    )
    .map_err(ai_error)
}

fn structured_translation_plan(
    plan: TextTranslationPlan,
    segment_count: usize,
) -> StructuredTextTranslationPlan {
    StructuredTextTranslationPlan {
        plan_id: plan.plan_id,
        provider: plan.provider,
        endpoint: plan.endpoint,
        model: plan.model,
        source_language: plan.source_language,
        target_language: plan.target_language,
        text_bytes: plan.text_bytes,
        glossary_count: plan.glossary_count,
        expires_at: plan.expires_at,
        summary: plan.summary,
        warnings: plan.warnings,
        segment_count,
    }
}

fn ai_scope(config: &AiProviderConfig) -> CommandResult<AiCredentialScope> {
    AiCredentialScope::new(config, AI_ACCOUNT).map_err(ai_error)
}

fn entire_selection(source: &str) -> CommandResult<Utf16Range> {
    let end = u32::try_from(source.encode_utf16().count())
        .map_err(|_| CommandError::new("ai_selection_invalid", "Selected text is too large."))?;
    Ok(Utf16Range { start: 0, end })
}

fn validate_editor_selection(source: &str, start: u32, end: u32) -> CommandResult<()> {
    let length = u32::try_from(source.encode_utf16().count())
        .map_err(|_| CommandError::new("ai_selection_invalid", "Selected text is too large."))?;
    if start >= end || end.checked_sub(start) != Some(length) {
        return Err(CommandError::new(
            "ai_selection_invalid",
            "The editor selection no longer matches the selected text.",
        ));
    }
    Ok(())
}

fn validate_document_context(
    current_revision: u64,
    writable: bool,
    requested_revision: u64,
) -> CommandResult<()> {
    if !writable {
        return Err(CommandError::new(
            "ai_document_read_only",
            "AI edits require a writable document.",
        ));
    }
    if current_revision != requested_revision {
        return Err(CommandError::new(
            "ai_document_drifted",
            "The document session changed; create a new AI edit plan.",
        ));
    }
    Ok(())
}

fn configured_credential_snapshot(status: AiCredentialStatus) -> AiCredentialStatusSnapshot {
    AiCredentialStatusSnapshot {
        configured: true,
        storage: match status.storage {
            AiCredentialStorage::SecretService => AiCredentialStorageView::SecretService,
            AiCredentialStorage::SessionMemory => AiCredentialStorageView::SessionMemory,
        },
        session_only: status.session_only,
        secret_service_available: ai_secret_service_available(),
        warning: status.warning,
    }
}

fn unconfigured_credential_snapshot() -> AiCredentialStatusSnapshot {
    AiCredentialStatusSnapshot {
        configured: false,
        storage: AiCredentialStorageView::Unavailable,
        session_only: false,
        secret_service_available: ai_secret_service_available(),
        warning: None,
    }
}

fn not_required_credential_snapshot() -> AiCredentialStatusSnapshot {
    AiCredentialStatusSnapshot {
        configured: true,
        storage: AiCredentialStorageView::NotRequired,
        session_only: false,
        secret_service_available: ai_secret_service_available(),
        warning: None,
    }
}

fn ai_error(error: AiError) -> CommandError {
    CommandError::new(error.code, error.message)
}

fn ai_profile_store_unavailable() -> CommandError {
    CommandError::new(
        "ai_profile_store_unavailable",
        "AI provider profile storage is unavailable.",
    )
}

fn encode_chat_vault_payload(chats: &AiChatStore) -> CommandResult<Zeroizing<Vec<u8>>> {
    let payload = AiChatVaultPayload {
        schema_version: AI_CHAT_VAULT_PAYLOAD_VERSION,
        conversations: chats.export_persisted_conversations().map_err(ai_error)?,
    };
    serde_json::to_vec(&payload)
        .map(Zeroizing::new)
        .map_err(|_| {
            CommandError::new(
                "ai_chat_vault_payload_invalid",
                "AI chat history could not be encoded safely.",
            )
        })
}

fn decode_chat_vault_payload(bytes: &[u8]) -> CommandResult<Vec<AiPersistedConversation>> {
    let payload: AiChatVaultPayload = serde_json::from_slice(bytes).map_err(|_| {
        CommandError::new(
            "ai_chat_vault_payload_invalid",
            "Encrypted AI chat history has an unsupported or invalid format.",
        )
    })?;
    if payload.schema_version != AI_CHAT_VAULT_PAYLOAD_VERSION {
        return Err(CommandError::new(
            "ai_chat_vault_payload_invalid",
            "Encrypted AI chat history has an unsupported or invalid format.",
        ));
    }
    Ok(payload.conversations)
}

fn persistence_warning(error: &CommandError) -> String {
    format!(
        "对话仍保留在本次运行内，但未能写入加密历史（{}）。锁定或退出前请重试。",
        error.code
    )
}

fn ai_state_unavailable() -> CommandError {
    CommandError::new("ai_state_unavailable", "AI request state is unavailable.")
}

fn unix_seconds() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn rfc3339_from_seconds(value: u64) -> CommandResult<String> {
    let value = i64::try_from(value)
        .map_err(|_| CommandError::new("ai_plan_time_invalid", "AI plan expiry is invalid."))?;
    OffsetDateTime::from_unix_timestamp(value)
        .map_err(|_| CommandError::new("ai_plan_time_invalid", "AI plan expiry is invalid."))?
        .format(&Rfc3339)
        .map_err(|_| CommandError::new("ai_plan_time_invalid", "AI plan expiry is invalid."))
}

#[cfg(test)]
mod connection_tests {
    use super::*;

    #[test]
    fn credential_lookup_failure_consumes_approval_before_a_retry() {
        let store = AiConnectionStore::new().unwrap();
        let credential = AiCredential::from_token("fixture-token".to_string()).unwrap();
        let request = AiConnectionRequest {
            operation: AiConnectionOperation::Models,
            provider: AiProviderKind::OpenaiCompatible,
            endpoint: "https://api.example.test/v1".to_string(),
            model: String::new(),
        };
        let plan = store.plan(request, Some(&credential)).unwrap();
        let failure = prepare_connection_execution(&store, &plan.plan_id, || {
            Err(CommandError::new(
                "ai_secret_service_failed",
                "fixture failure",
            ))
        });
        assert_eq!(failure.err().unwrap().code, "ai_secret_service_failed");

        // Even if the identical credential becomes available again, the old
        // approval must be rejected before trying to read it a second time.
        let mut lookup_called = false;
        let retry = prepare_connection_execution(&store, &plan.plan_id, || {
            lookup_called = true;
            Ok(Some(credential))
        });
        assert_eq!(retry.err().unwrap().code, "invalid_response");
        assert!(!lookup_called);
    }
}

#[cfg(test)]
mod p12_tests {
    use super::*;

    #[test]
    fn encrypted_chat_payload_round_trips_across_lock_and_unlock() {
        let directory = tempfile::tempdir().unwrap();
        let ai = AiState::new(directory.path().join("app-data"));
        let chats = ai.chat_store().unwrap();
        chats.create_conversation(Some("Before vault")).unwrap();

        let initial = encode_chat_vault_payload(&chats).unwrap();
        ai.chat_vault()
            .unwrap()
            .lock()
            .unwrap()
            .initialize("correct horse battery staple", initial.as_slice())
            .unwrap();
        chats.activate_persistence(Vec::new()).unwrap();
        chats.create_conversation(Some("After vault")).unwrap();
        ai.persist_chat_history(&chats).unwrap();
        assert_eq!(
            ai.chat_vault_status_snapshot(&chats)
                .unwrap()
                .persistent_conversation_count,
            2
        );

        chats.deactivate_persistence().unwrap();
        ai.lock_chat_vault_key().unwrap();
        assert!(chats.list_conversations().unwrap().is_empty());
        let plaintext = Zeroizing::new(
            ai.chat_vault()
                .unwrap()
                .lock()
                .unwrap()
                .unlock("correct horse battery staple")
                .unwrap(),
        );
        let restored = decode_chat_vault_payload(plaintext.as_slice()).unwrap();
        chats.activate_persistence(restored).unwrap();
        assert_eq!(chats.list_conversations().unwrap().len(), 2);
        assert!(chats
            .list_conversations()
            .unwrap()
            .iter()
            .all(|conversation| !conversation.session_only));
    }

    #[test]
    fn chat_payload_rejects_unknown_schema() {
        let payload = br#"{"schemaVersion":99,"conversations":[]}"#;
        assert_eq!(
            decode_chat_vault_payload(payload).unwrap_err().code,
            "ai_chat_vault_payload_invalid"
        );
    }
}
