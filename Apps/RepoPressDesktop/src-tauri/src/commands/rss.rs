//! Tauri boundary for the RSS gateway. Argument names mirror rssGateway.ts.
use super::AppState;
use crate::core::{
    CommandError, CommandResult, RssArticle, RssArticlePage, RssArticleQuery, RssArticleState,
    RssBackupSummary, RssFeed, RssOfflineTranslationCacheStatus, RssOfflineTranslationCleanup,
    RssOfflineTranslationRecord, RssOfflineTranslationRequest, RssOfflineTranslationResult,
    RssPreferences, RssReaderStore,
};
use serde::{Deserialize, Serialize};
use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::State;

fn store(state: &State<'_, AppState>) -> Arc<RssReaderStore> {
    Arc::clone(&state.rss)
}
async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> CommandResult<T> + Send + 'static,
) -> CommandResult<T> {
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|_| CommandError::new("rss_task_failed", "RSS task failed."))?
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedDto {
    id: String,
    title: String,
    url: String,
    site_url: Option<String>,
    icon_url: Option<String>,
    added_at: i64,
    last_updated_at: Option<i64>,
    etag: Option<String>,
    last_modified: Option<String>,
    last_error: Option<String>,
    last_issue: Option<crate::core::RssIssue>,
    last_refresh_attempt_at: Option<i64>,
    refresh_failure_count: u32,
    next_retry_at: Option<i64>,
    last_refresh_duration: Option<f64>,
}
impl From<RssFeed> for FeedDto {
    fn from(feed: RssFeed) -> Self {
        let has_refresh = feed.last_refreshed_at > 0;
        let issue = feed.issue;
        Self {
            id: feed.id,
            title: feed.title,
            url: feed.url,
            site_url: feed.site_url,
            icon_url: None,
            added_at: feed.added_at,
            last_updated_at: has_refresh.then_some(feed.last_refreshed_at),
            etag: feed.etag,
            last_modified: feed.last_modified,
            last_error: issue.as_ref().map(|value| value.user_message.clone()),
            last_issue: issue,
            last_refresh_attempt_at: has_refresh.then_some(feed.last_refreshed_at),
            refresh_failure_count: feed.refresh_failure_count,
            next_retry_at: feed.next_retry_at,
            last_refresh_duration: None,
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeaderDto {
    id: String,
    feed_id: String,
    title: String,
    link: Option<String>,
    cover_url: Option<String>,
    author: Option<String>,
    published_at: Option<i64>,
    readable_summary: String,
    fetched_at: i64,
    read_at: Option<i64>,
    is_starred: bool,
    tags: Vec<String>,
}
impl From<RssArticle> for HeaderDto {
    fn from(article: RssArticle) -> Self {
        Self {
            id: article.id,
            feed_id: article.feed_id,
            title: article.title,
            link: article.url,
            cover_url: article.cover_url,
            author: article.author,
            published_at: (article.published_at > 0).then_some(article.published_at),
            readable_summary: article.summary,
            fetched_at: article.fetched_at,
            read_at: article.read_at,
            is_starred: article.starred,
            tags: article.tags,
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ArticleDto {
    #[serde(flatten)]
    header: HeaderDto,
    summary_html: String,
    content_html: String,
    web_page_snapshot_html: Option<String>,
}
impl From<RssArticle> for ArticleDto {
    fn from(article: RssArticle) -> Self {
        let header = HeaderDto::from(article.clone());
        Self {
            header,
            summary_html: article.summary,
            content_html: article.content,
            web_page_snapshot_html: None,
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotDto {
    feeds: Vec<FeedDto>,
    articles: Vec<HeaderDto>,
    article_count: u32,
    unread_count: u32,
    starred_count: u32,
    unread_count_by_feed: std::collections::HashMap<String, u32>,
    authors: Vec<String>,
    tags: Vec<String>,
    status_message: Option<String>,
    error_message: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageDto {
    articles: Vec<HeaderDto>,
    total_count: u32,
    has_more: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RefreshSummary {
    success_count: u32,
    failure_count: u32,
    skipped_count: u32,
    status_text: String,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreferencesDto {
    automatic_pruning_enabled: bool,
    retention_days: u32,
    feed_body_offline_cache_enabled: bool,
    background_refresh_enabled: bool,
    background_refresh_interval_minutes: u32,
    automatic_mark_read_at_end_enabled: bool,
    automatic_full_text_extraction_enabled: bool,
    offline_cache_full_text_on_refresh_enabled: bool,
    remote_images_enabled: bool,
    private_network_access_enabled: bool,
    offline_translation_cache_enabled: bool,
    offline_translation_retention_days: u32,
    #[serde(rename = "offlineTranslationMaxMiB")]
    offline_translation_max_mib: u32,
    automatic_local_pretranslation_on_refresh_enabled: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreferencesInput {
    automatic_pruning_enabled: bool,
    retention_days: u32,
    feed_body_offline_cache_enabled: bool,
    background_refresh_enabled: bool,
    background_refresh_interval_minutes: u32,
    automatic_mark_read_at_end_enabled: bool,
    automatic_full_text_extraction_enabled: bool,
    offline_cache_full_text_on_refresh_enabled: bool,
    remote_images_enabled: bool,
    private_network_access_enabled: bool,
    offline_translation_cache_enabled: bool,
    offline_translation_retention_days: u32,
    #[serde(
        rename = "offlineTranslationMaxMiB",
        alias = "offlineTranslationMaxMib"
    )]
    offline_translation_max_mib: u32,
    automatic_local_pretranslation_on_refresh_enabled: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PruneSummary {
    removed_article_count: u32,
    removed_media_asset_count: u32,
    cutoff_date: i64,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UndoTokenDto {
    undo_token: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MarkReadDto {
    changed_count: u32,
    undo_token: Option<String>,
}
#[derive(Deserialize)]
#[serde(untagged)]
pub enum Scope {
    Name(String),
    Feed { feed: String },
}
impl Scope {
    fn into_parts(self) -> CommandResult<(String, Option<String>)> {
        match self {
            Self::Name(value) if matches!(value.as_str(), "all" | "unread" | "starred") => {
                Ok((value, None))
            }
            Self::Feed { feed } if !feed.is_empty() => Ok(("feed".to_owned(), Some(feed))),
            _ => Err(CommandError::new("rss_query_invalid", "Invalid RSS scope.")),
        }
    }
}

#[tauri::command]
pub async fn rss_snapshot(state: State<'_, AppState>) -> CommandResult<SnapshotDto> {
    let s = store(&state);
    blocking(move || {
        let snapshot = s.snapshot()?;
        let unread_count_by_feed = snapshot
            .feeds
            .iter()
            .map(|feed| (feed.id.clone(), feed.unread_count))
            .collect();
        let page = s.list_articles(RssArticleQuery {
            query: None,
            scope: "all".to_owned(),
            sort: "newest".to_owned(),
            feed_id: None,
            author: None,
            tag: None,
            offset: 0,
            limit: 500,
        })?;
        Ok(SnapshotDto {
            feeds: snapshot.feeds.into_iter().map(FeedDto::from).collect(),
            articles: page.articles.into_iter().map(HeaderDto::from).collect(),
            article_count: page.total,
            unread_count: snapshot.unread_count,
            starred_count: snapshot.starred_count,
            unread_count_by_feed,
            authors: snapshot.authors,
            tags: snapshot.tags,
            status_message: None,
            error_message: None,
        })
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_discover(
    homepage_url: String,
    state: State<'_, AppState>,
) -> CommandResult<Vec<String>> {
    let s = store(&state);
    blocking(move || {
        Ok(s.discover(homepage_url)?
            .candidates
            .into_iter()
            .map(|item| item.url)
            .collect())
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_add_feed(
    url: String,
    title: Option<String>,
    site_url: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<FeedDto> {
    let s = store(&state);
    blocking(move || {
        let feed = s.add_feed(url, title)?;
        let feed = if site_url.is_some() {
            s.update_feed_site_url(&feed.id, site_url)?
        } else {
            feed
        };
        Ok(FeedDto::from(feed))
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_update_feed_url(
    feed_id: String,
    new_url: String,
    state: State<'_, AppState>,
) -> CommandResult<FeedDto> {
    let s = store(&state);
    blocking(move || s.update_feed_url(feed_id, new_url).map(FeedDto::from)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_remove_feed(
    feed_id: String,
    state: State<'_, AppState>,
) -> CommandResult<UndoTokenDto> {
    let s = store(&state);
    blocking(move || {
        s.remove_feed(feed_id)
            .map(|undo_token| UndoTokenDto { undo_token })
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_refresh_feed(
    feed_id: String,
    force: bool,
    state: State<'_, AppState>,
) -> CommandResult<RefreshSummary> {
    let s = store(&state);
    blocking(move || {
        let result = s.refresh_feed_forced(feed_id, force)?;
        Ok(refresh_summary(vec![result], force))
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_refresh_all(
    force: bool,
    state: State<'_, AppState>,
) -> CommandResult<RefreshSummary> {
    let s = store(&state);
    blocking(move || {
        s.refresh_all_forced(force)
            .map(|results| refresh_summary(results, force))
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
// The renderer gateway intentionally exposes these fixed filters as flat Tauri arguments.
#[allow(clippy::too_many_arguments)]
pub async fn rss_list_articles(
    scope: Scope,
    search_text: String,
    unread_only: bool,
    author: Option<String>,
    tag: Option<String>,
    sort: String,
    offset: u32,
    limit: u32,
    state: State<'_, AppState>,
) -> CommandResult<PageDto> {
    let s = store(&state);
    blocking(move || {
        let (mut scope, feed_id) = scope.into_parts()?;
        if unread_only && scope == "all" {
            scope = "unread".to_owned();
        }
        let page: RssArticlePage = s.list_articles(RssArticleQuery {
            query: (!search_text.trim().is_empty()).then_some(search_text),
            scope,
            sort,
            feed_id,
            author,
            tag,
            offset,
            limit,
        })?;
        Ok(PageDto {
            articles: page.articles.into_iter().map(HeaderDto::from).collect(),
            total_count: page.total,
            has_more: page.has_more,
        })
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_get_article(
    article_id: String,
    state: State<'_, AppState>,
) -> CommandResult<Option<ArticleDto>> {
    let s = store(&state);
    blocking(move || {
        s.article(article_id)
            .map(|article| article.map(ArticleDto::from))
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_update_article_state(
    article_id: String,
    read: Option<bool>,
    read_at: Option<Option<i64>>,
    is_starred: Option<bool>,
    tags: Option<Vec<String>>,
    state: State<'_, AppState>,
) -> CommandResult<HeaderDto> {
    let s = store(&state);
    blocking(move || {
        s.update_article_state(
            article_id,
            RssArticleState {
                read: read.or_else(|| read_at.map(|value| value.is_some())),
                starred: is_starred,
                tags,
            },
        )
        .map(HeaderDto::from)
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_mark_all_read(
    scope: Scope,
    article_ids: Option<Vec<String>>,
    search_text: Option<String>,
    unread_only: Option<bool>,
    author: Option<String>,
    tag: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<MarkReadDto> {
    let s = store(&state);
    blocking(move || {
        if let Some(article_ids) = article_ids {
            return s
                .mark_articles_read(article_ids)
                .map(|(changed_count, undo_token)| MarkReadDto {
                    changed_count,
                    undo_token,
                });
        }
        let (scope, feed_id) = scope.into_parts()?;
        let scope = if unread_only.unwrap_or(false) && scope == "all" {
            "unread".to_owned()
        } else {
            scope
        };
        s.mark_filtered_read(RssArticleQuery {
            query: search_text.filter(|value| !value.trim().is_empty()),
            scope,
            sort: "newest".to_owned(),
            feed_id,
            author,
            tag,
            offset: 0,
            limit: 1,
        })
        .map(|(changed_count, undo_token)| MarkReadDto {
            changed_count,
            undo_token,
        })
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_undo_remove_feed(
    undo_token: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let s = store(&state);
    blocking(move || s.undo_remove_feed(undo_token)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_undo_mark_all_read(
    undo_token: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let s = store(&state);
    blocking(move || s.undo_mark_all_read(undo_token)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_import_opml(
    opml: String,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RssOpmlImportResult> {
    let s = store(&state);
    blocking(move || s.import_opml(opml)).await
}
#[tauri::command]
pub async fn rss_export_opml(state: State<'_, AppState>) -> CommandResult<String> {
    let s = store(&state);
    blocking(move || s.export_opml()).await
}

#[tauri::command]
pub async fn rss_export_backup(state: State<'_, AppState>) -> CommandResult<String> {
    let s = store(&state);
    blocking(move || s.export_backup()).await
}

#[tauri::command]
pub async fn rss_inspect_backup(
    backup_text: String,
    state: State<'_, AppState>,
) -> CommandResult<RssBackupSummary> {
    let s = store(&state);
    blocking(move || s.inspect_backup(backup_text)).await
}

#[tauri::command]
pub async fn rss_restore_backup(
    backup_text: String,
    state: State<'_, AppState>,
) -> CommandResult<RssBackupSummary> {
    let s = store(&state);
    blocking(move || s.restore_backup(backup_text)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_get_offline_translation(
    request: RssOfflineTranslationRequest,
    state: State<'_, AppState>,
) -> CommandResult<Option<RssOfflineTranslationRecord>> {
    let s = store(&state);
    blocking(move || s.get_offline_translation(request)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_save_offline_translation(
    request: RssOfflineTranslationRequest,
    result: RssOfflineTranslationResult,
    state: State<'_, AppState>,
) -> CommandResult<RssOfflineTranslationRecord> {
    let s = store(&state);
    blocking(move || s.save_offline_translation(request, result)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_delete_offline_translation(
    request: RssOfflineTranslationRequest,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let s = store(&state);
    blocking(move || s.delete_offline_translation(request)).await
}
#[tauri::command]
pub async fn rss_offline_translation_cache_status(
    state: State<'_, AppState>,
) -> CommandResult<RssOfflineTranslationCacheStatus> {
    let s = store(&state);
    blocking(move || s.offline_translation_cache_status()).await
}
#[tauri::command]
pub async fn rss_prune_offline_translations(
    state: State<'_, AppState>,
) -> CommandResult<RssOfflineTranslationCleanup> {
    let s = store(&state);
    blocking(move || s.prune_offline_translations()).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_clear_offline_translations(
    feed_id: Option<String>,
    state: State<'_, AppState>,
) -> CommandResult<RssOfflineTranslationCleanup> {
    let s = store(&state);
    blocking(move || s.clear_offline_translations(feed_id)).await
}
#[tauri::command]
pub async fn rss_get_preferences(state: State<'_, AppState>) -> CommandResult<PreferencesDto> {
    let s = store(&state);
    blocking(move || s.preferences().map(preferences_dto)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_update_preferences(
    preferences: PreferencesInput,
    state: State<'_, AppState>,
) -> CommandResult<PreferencesDto> {
    let s = store(&state);
    blocking(move || {
        let old = s.preferences()?;
        s.update_preferences(RssPreferences {
            refresh_interval_seconds: old.refresh_interval_seconds,
            max_articles_per_feed: old.max_articles_per_feed,
            refresh_interval_minutes: old.refresh_interval_minutes,
            retention_days: preferences.retention_days,
            automatic_pruning_enabled: preferences.automatic_pruning_enabled,
            feed_body_offline_cache_enabled: preferences.feed_body_offline_cache_enabled,
            background_refresh_enabled: preferences.background_refresh_enabled,
            background_refresh_interval_minutes: preferences.background_refresh_interval_minutes,
            automatic_mark_read_at_end_enabled: preferences.automatic_mark_read_at_end_enabled,
            automatic_full_text_extraction_enabled: preferences
                .automatic_full_text_extraction_enabled,
            offline_cache_full_text_on_refresh_enabled: preferences
                .offline_cache_full_text_on_refresh_enabled,
            remote_images_enabled: preferences.remote_images_enabled,
            private_network_access_enabled: preferences.private_network_access_enabled,
            offline_translation_cache_enabled: preferences.offline_translation_cache_enabled,
            offline_translation_retention_days: preferences.offline_translation_retention_days,
            offline_translation_max_mib: preferences.offline_translation_max_mib,
            automatic_local_pretranslation_on_refresh_enabled: preferences
                .automatic_local_pretranslation_on_refresh_enabled,
        })
        .map(preferences_dto)
    })
    .await
}
#[tauri::command]
pub async fn rss_prune(state: State<'_, AppState>) -> CommandResult<PruneSummary> {
    let s = store(&state);
    blocking(move || {
        let preferences = s.preferences()?;
        let cutoff_date = epoch_seconds() - i64::from(preferences.retention_days) * 86_400;
        let removed_article_count = s.prune()?;
        Ok(PruneSummary {
            removed_article_count,
            removed_media_asset_count: 0,
            cutoff_date,
        })
    })
    .await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_list_highlights(
    article_id: String,
    state: State<'_, AppState>,
) -> CommandResult<serde_json::Value> {
    let s = store(&state);
    blocking(move || s.list_highlights_json(article_id)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_save_highlight(
    article_id: String,
    id: Option<String>,
    text: String,
    note: Option<String>,
    tags: Option<Vec<String>>,
    state: State<'_, AppState>,
) -> CommandResult<serde_json::Value> {
    let s = store(&state);
    blocking(move || s.save_highlight_json(article_id, id, text, note, tags)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_delete_highlight(
    highlight_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let s = store(&state);
    blocking(move || s.delete_highlight(highlight_id)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_get_reading_progress(
    article_id: String,
    state: State<'_, AppState>,
) -> CommandResult<serde_json::Value> {
    let s = store(&state);
    blocking(move || s.get_reading_progress_json(article_id)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_save_reading_progress(
    article_id: String,
    progress: f64,
    revision: i64,
    state: State<'_, AppState>,
) -> CommandResult<serde_json::Value> {
    let s = store(&state);
    blocking(move || s.save_reading_progress_json(article_id, progress, revision)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_fetch_full_text(
    article_id: String,
    force: bool,
    state: State<'_, AppState>,
) -> CommandResult<serde_json::Value> {
    let s = store(&state);
    blocking(move || s.fetch_full_text_json(article_id, force)).await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn rss_fetch_cover(
    article_id: String,
    state: State<'_, AppState>,
) -> CommandResult<Option<String>> {
    let s = store(&state);
    blocking(move || s.fetch_cover_data_url(article_id)).await
}

fn refresh_summary(results: Vec<crate::core::RssRefreshResult>, force: bool) -> RefreshSummary {
    let failure_count = results.iter().filter(|result| result.failed).count() as u32;
    let skipped_count = results
        .iter()
        .filter(|result| result.not_modified || result.summary.starts_with("Refresh skipped"))
        .count() as u32;
    let success_count = results.len() as u32 - failure_count - skipped_count;
    RefreshSummary {
        success_count,
        failure_count,
        skipped_count,
        status_text: format!(
            "刷新完成：成功 {success_count}、失败 {failure_count}、跳过 {skipped_count}{}",
            if force {
                ""
            } else {
                "（遵循刷新计划）"
            }
        ),
    }
}
fn preferences_dto(value: RssPreferences) -> PreferencesDto {
    PreferencesDto {
        automatic_pruning_enabled: value.automatic_pruning_enabled,
        retention_days: value.retention_days,
        feed_body_offline_cache_enabled: value.feed_body_offline_cache_enabled,
        background_refresh_enabled: value.background_refresh_enabled,
        background_refresh_interval_minutes: value.background_refresh_interval_minutes,
        automatic_mark_read_at_end_enabled: value.automatic_mark_read_at_end_enabled,
        automatic_full_text_extraction_enabled: value.automatic_full_text_extraction_enabled,
        offline_cache_full_text_on_refresh_enabled: value
            .offline_cache_full_text_on_refresh_enabled,
        remote_images_enabled: value.remote_images_enabled,
        private_network_access_enabled: value.private_network_access_enabled,
        offline_translation_cache_enabled: value.offline_translation_cache_enabled,
        offline_translation_retention_days: value.offline_translation_retention_days,
        offline_translation_max_mib: value.offline_translation_max_mib,
        automatic_local_pretranslation_on_refresh_enabled: value
            .automatic_local_pretranslation_on_refresh_enabled,
    }
}
fn epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preferences_use_the_frontend_mi_b_casing_in_both_directions() {
        let preferences = RssReaderStore::default()
            .preferences()
            .expect("default RSS preferences");
        let value =
            serde_json::to_value(preferences_dto(preferences)).expect("serialize preferences DTO");
        assert_eq!(
            value.get("offlineTranslationMaxMiB"),
            Some(&serde_json::json!(100))
        );
        assert!(value.get("offlineTranslationMaxMib").is_none());

        let input: PreferencesInput =
            serde_json::from_value(value).expect("deserialize preferences input");
        assert_eq!(input.offline_translation_max_mib, 100);
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpmlReviewInput {
    direction: String,
    opml: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OpmlExecuteInput {
    direction: String,
    opml: Option<String>,
    fingerprint: String,
    action: String,
}
#[tauri::command]
pub async fn rss_review_opml(
    input: OpmlReviewInput,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RssOpmlReview> {
    let s = store(&state);
    blocking(move || s.review_opml(input.direction, input.opml)).await
}
#[tauri::command]
pub async fn rss_execute_opml(
    input: OpmlExecuteInput,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RssOpmlExecution> {
    let s = store(&state);
    blocking(move || s.execute_opml(input.direction, input.opml, input.fingerprint, input.action))
        .await
}
#[tauri::command]
pub async fn rss_history_discover(
    input: crate::core::RssHistoryDiscoverInput,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RssHistoryJob> {
    let s = store(&state);
    blocking(move || s.history_discover(input)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_history_status(
    feed_id: String,
    state: State<'_, AppState>,
) -> CommandResult<Option<crate::core::RssHistoryJob>> {
    let s = store(&state);
    blocking(move || s.history_status(feed_id)).await
}
#[tauri::command]
pub async fn rss_history_step(
    input: crate::core::RssHistoryStepInput,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RssHistoryJob> {
    let s = store(&state);
    blocking(move || s.history_step(input)).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_history_pause(
    job_id: String,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RssHistoryJob> {
    let s = store(&state);
    blocking(move || s.history_pause(job_id)).await
}

#[tauri::command(rename_all = "camelCase")]
pub async fn rss_history_cancel_discovery(
    discovery_id: String,
    state: State<'_, AppState>,
) -> CommandResult<()> {
    let s = store(&state);
    blocking(move || s.history_cancel_discovery(discovery_id)).await
}

#[tauri::command]
pub async fn rss_history_resume_discovery(
    input: crate::core::RssHistoryResumeInput,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RssHistoryJob> {
    let s = store(&state);
    blocking(move || s.history_resume_discovery(input)).await
}
#[tauri::command]
pub async fn rss_history_list(
    state: State<'_, AppState>,
) -> CommandResult<Vec<crate::core::RssHistoryCheckpointSummary>> {
    let s = store(&state);
    blocking(move || s.history_list()).await
}
#[tauri::command(rename_all = "camelCase")]
pub async fn rss_history_clear(job_id: String, state: State<'_, AppState>) -> CommandResult<()> {
    let s = store(&state);
    blocking(move || s.history_clear(job_id)).await
}

#[tauri::command]
pub async fn rss_history_prepare_retry(
    input: crate::core::RssHistoryRetryInput,
    state: State<'_, AppState>,
) -> CommandResult<crate::core::RssHistoryJob> {
    let s = store(&state);
    blocking(move || s.history_prepare_retry(input)).await
}
