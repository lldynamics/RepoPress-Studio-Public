use super::metadata_field::{transform_metadata_field, MetadataBatchField, MetadataBatchOperation};
use super::{CommandError, CommandResult, DraftHistoryStore, DraftVersionReason, RepositoryStore};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

const MAX_FILES: usize = 20;
const TTL: Duration = Duration::from_secs(300);

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataBatchPreview {
    pub relative_path: String,
    pub original_values: Vec<String>,
    pub proposed_values: Vec<String>,
    pub status: String,
    pub message: Option<String>,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataBatchPlan {
    pub plan_id: String,
    pub session_id: String,
    pub field: MetadataBatchField,
    pub operation: MetadataBatchOperation,
    pub previews: Vec<MetadataBatchPreview>,
    pub expires_at: String,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataBatchItemResult {
    pub relative_path: String,
    pub status: String,
    pub message: Option<String>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataBatchResult {
    pub results: Vec<MetadataBatchItemResult>,
    pub summary: String,
}
struct PendingPlan {
    preview: MetadataBatchPlan,
    root: PathBuf,
    identity: (u64, u64),
    expires: Instant,
}
#[derive(Default)]
pub struct MetadataBatchStore {
    plans: Mutex<HashMap<String, PendingPlan>>,
}

impl MetadataBatchStore {
    pub fn plan(
        &self,
        repositories: &RepositoryStore,
        session_id: &str,
        paths: &[String],
        field: MetadataBatchField,
        operation: MetadataBatchOperation,
    ) -> CommandResult<MetadataBatchPlan> {
        if operation.value.len() > 8192
            || operation
                .replacement
                .as_ref()
                .is_some_and(|s| s.len() > 8192)
        {
            return Err(error(
                "invalid_metadata_batch_operation",
                "输入超过 8 KiB 上限。",
            ));
        }
        if paths.is_empty()
            || paths.len() > MAX_FILES
            || paths.iter().any(|p| p.len() > 4096)
            || paths.iter().collect::<HashSet<_>>().len() != paths.len()
        {
            return Err(error(
                "invalid_metadata_targets",
                "请选择 1–20 篇不重复的文章。",
            ));
        }
        let root = repositories.root_for_session(session_id)?;
        let identity = root_identity(&root)?;
        let mut previews = Vec::new();
        for path in paths {
            let inspected = repositories
                .open_document(session_id, path)
                .and_then(|document| {
                    let result = if !document.writable {
                        Err(error("document_read_only", "此文章只读，不能批量修改。"))
                    } else {
                        transform_metadata_field(&document.text, &field, &operation)
                    };
                    repositories.release_internal_document(session_id, &document.document_id)?;
                    result
                });
            previews.push(match inspected {
                Ok(edit) => MetadataBatchPreview {
                    relative_path: path.clone(),
                    status: if edit.original_values == edit.proposed_values {
                        "unchanged"
                    } else {
                        "change"
                    }
                    .into(),
                    original_values: edit.original_values,
                    proposed_values: edit.proposed_values,
                    message: None,
                },
                Err(e) => MetadataBatchPreview {
                    relative_path: path.clone(),
                    status: "unavailable".into(),
                    original_values: vec![],
                    proposed_values: vec![],
                    message: Some(safe_message(&e)),
                },
            });
        }
        if root_identity(&root)? != identity {
            return Err(error(
                "metadata_root_changed",
                "仓库目录已变化，请重新打开。",
            ));
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| error("metadata_clock", "系统时钟不可用。"))?
            .as_secs();
        let expires_at = time::OffsetDateTime::from_unix_timestamp((now + TTL.as_secs()) as i64)
            .map_err(|_| error("metadata_clock", "系统时钟不可用。"))?
            .format(&Rfc3339)
            .map_err(|_| error("metadata_clock", "无法生成计划有效期。"))?;
        let preview = MetadataBatchPlan {
            plan_id: Uuid::new_v4().to_string(),
            session_id: session_id.into(),
            field,
            operation,
            previews,
            expires_at,
        };
        let mut plans = self
            .plans
            .lock()
            .map_err(|_| error("metadata_lock", "批量计划暂不可用。"))?;
        plans.retain(|_, plan| {
            plan.expires > Instant::now() && plan.preview.session_id != session_id
        });
        if plans.len() >= 16 {
            return Err(error("metadata_plan_limit", "待处理计划过多，请稍后重试。"));
        }
        plans.insert(
            preview.plan_id.clone(),
            PendingPlan {
                preview: preview.clone(),
                root,
                identity,
                expires: Instant::now() + TTL,
            },
        );
        Ok(preview)
    }

    pub fn execute(
        &self,
        repositories: &RepositoryStore,
        history: &DraftHistoryStore,
        session_id: &str,
        plan_id: &str,
    ) -> CommandResult<MetadataBatchResult> {
        let root = repositories.root_for_session(session_id)?;
        let plan = {
            let mut plans = self
                .plans
                .lock()
                .map_err(|_| error("metadata_lock", "批量计划暂不可用。"))?;
            let plan = plans
                .get(plan_id)
                .ok_or_else(|| error("metadata_plan_expired", "计划已使用或失效，请重新预览。"))?;
            if plan.preview.session_id != session_id || plan.root != root {
                return Err(error("metadata_plan_session", "计划不属于当前仓库会话。"));
            }
            plans
                .remove(plan_id)
                .ok_or_else(|| error("metadata_plan_expired", "计划已失效。"))?
        };
        if plan.expires <= Instant::now() {
            return Err(error("metadata_plan_expired", "计划已过期，请重新预览。"));
        }
        if root_identity(&root)? != plan.identity {
            return Err(error(
                "metadata_root_changed",
                "仓库目录已变化，请重新打开。",
            ));
        }
        // Serialize with the existing save/history/restore operations. The plan is already consumed.
        let _operation = repositories.lock_recovery_operation()?;
        let mut results = Vec::new();
        for preview in &plan.preview.previews {
            let outcome = if preview.status != "change" {
                MetadataBatchItemResult {
                    relative_path: preview.relative_path.clone(),
                    status: if preview.status == "unchanged" {
                        "unchanged"
                    } else {
                        "failed"
                    }
                    .into(),
                    message: preview.message.clone(),
                }
            } else {
                let result = (|| {
                    if root_identity(&root)? != plan.identity {
                        return Err(error("metadata_root_changed", "仓库目录已变化。"));
                    }
                    let document =
                        repositories.open_document(session_id, &preview.relative_path)?;
                    let updated = (|| {
                        let edit = transform_metadata_field(
                            &document.text,
                            &plan.preview.field,
                            &plan.preview.operation,
                        )?;
                        if edit.original_values != preview.original_values
                            || edit.proposed_values != preview.proposed_values
                        {
                            return Err(error(
                                "metadata_field_conflict",
                                "目标字段已变化；未写入，请重新预览。",
                            ));
                        }
                        let context = repositories.history_context_for_session(
                            session_id,
                            &document.document_id,
                            &document.baseline_sha256,
                        )?;
                        history.record_version(
                            &context.root,
                            &context.relative_path,
                            &context.text,
                            &context.baseline_sha256,
                            DraftVersionReason::BeforeSave,
                        )?;
                        if root_identity(&root)? != plan.identity {
                            return Err(error("metadata_root_changed", "仓库目录已变化。"));
                        }
                        // Transform the freshly read document, not a whole-document preview snapshot.
                        repositories.save_document(
                            session_id,
                            &document.document_id,
                            &edit.text,
                            &document.baseline_sha256,
                        )?;
                        Ok(())
                    })();
                    let released =
                        repositories.release_internal_document(session_id, &document.document_id);
                    updated.and(released)
                })();
                match result {
                    Ok(()) => MetadataBatchItemResult {
                        relative_path: preview.relative_path.clone(),
                        status: "applied".into(),
                        message: None,
                    },
                    Err(e) => MetadataBatchItemResult {
                        relative_path: preview.relative_path.clone(),
                        status: if e.code == "metadata_field_conflict" || e.code == "save_conflict"
                        {
                            "conflict"
                        } else {
                            "failed"
                        }
                        .into(),
                        message: Some(safe_message(&e)),
                    },
                }
            };
            results.push(outcome);
        }
        let applied = results.iter().filter(|r| r.status == "applied").count();
        let failed = results
            .iter()
            .filter(|r| r.status == "failed" || r.status == "conflict")
            .count();
        Ok(MetadataBatchResult { summary: format!("已修改 {applied} 篇，冲突或未完成 {failed} 篇。修改前版本可在历史与回收站查看；失败项请检查磁盘状态后重新预览。"), results })
    }
}
fn error(code: &str, message: &str) -> CommandError {
    CommandError::new(code, message)
}
fn safe_message(e: &CommandError) -> String {
    match e.code.as_str() {
        "unsupported_metadata_front_matter" => {
            "Front Matter 缺失、复杂或有歧义，未修改；请检查格式或手动维护。".into()
        }
        "invalid_metadata_batch_operation" => {
            "操作值无效或超限：最多 64 项，每项 128 字；重命名仅接受一个源值和一个目标值。".into()
        }
        "metadata_field_conflict" | "save_conflict" => {
            "目标内容已变化，未覆盖，请重新预览。".into()
        }
        _ if e.code.starts_with("metadata_") => e.message.clone(),
        _ => format!("无法安全处理（{}）；请检查文件与历史版本后重试。", e.code),
    }
}
fn root_identity(root: &Path) -> CommandResult<(u64, u64)> {
    let metadata = std::fs::symlink_metadata(root)
        .map_err(|_| error("metadata_root_changed", "无法核验仓库目录。"))?;
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return Err(error("metadata_root_changed", "仓库目录已变化。"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Ok((metadata.dev(), metadata.ino()))
    }
    #[cfg(not(unix))]
    {
        Err(error("metadata_platform", "当前平台暂不支持批量维护。"))
    }
}

#[cfg(test)]
#[path = "metadata_batch_tests.rs"]
mod tests;
