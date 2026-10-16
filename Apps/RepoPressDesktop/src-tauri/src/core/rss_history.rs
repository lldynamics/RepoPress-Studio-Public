//! Explicit, bounded historical RSS import. No startup/background network work.
use super::*;
use std::collections::{HashMap, VecDeque};
#[path = "rss_history_content.rs"]
mod content;
#[path = "rss_history_discovery.rs"]
mod discovery;
#[path = "rss_history_failures.rs"]
mod failures;
use failures::{hydrate_failures, save_progress};
#[path = "rss_history_parse.rs"]
mod parse;
pub(super) fn robots_allowed(text: &str, url: &Url) -> bool {
    parse::robots_allowed(text, url)
}

const MAX_HISTORY_JOBS: i64 = 20;
const MAX_SOURCE_BYTES: usize = 1024 * 1024;
const MAX_JOB_BYTES: usize = 5 * 1024 * 1024;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RssHistoryDiscoverInput {
    pub discovery_id: String,
    pub feed_id: String,
    pub directory_url: String,
    pub max_pages: usize,
    pub max_articles: usize,
    #[serde(default)]
    pub fill_existing: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RssHistoryResumeInput {
    pub discovery_id: String,
    pub job_id: String,
    pub max_pages: usize,
    pub max_articles: usize,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RssHistoryRetryInput {
    pub job_id: String,
    pub max_articles: usize,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RssHistoryStepInput {
    pub job_id: String,
    #[serde(default)]
    pub retry_failures: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RssHistoryCandidate {
    pub url: String,
    pub title: String,
    pub status: String,
    pub message: Option<String>,
    #[serde(default = "article_kind")]
    pub kind: String,
}
fn article_kind() -> String {
    "article".into()
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RssHistoryJob {
    pub id: String,
    pub feed_id: String,
    pub directory_url: String,
    pub status: String,
    pub candidates: Vec<RssHistoryCandidate>,
    pub added_count: usize,
    pub duplicate_count: usize,
    pub failed_count: usize,
    pub next_request_at: i64,
    pub reached_limit: bool,
    pub message: Option<String>,
    #[serde(default)]
    pub updated_count: usize,
    #[serde(default)]
    pub discovered_count: usize,
    #[serde(default)]
    pub has_more_discovery: bool,
    #[serde(default)]
    pub fill_existing: bool,
    #[serde(default)]
    pub retrying_failures: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RssHistoryCheckpointSummary {
    pub id: String,
    pub feed_id: String,
    pub directory_url: String,
    pub status: String,
    pub candidate_count: usize,
    pub pending_count: usize,
    pub added_count: usize,
    pub duplicate_count: usize,
    pub updated_count: usize,
    pub failed_count: usize,
    pub discovered_count: usize,
    pub has_more_discovery: bool,
    pub stale: bool,
    pub retrying_failures: bool,
}
#[derive(Clone, Default, Serialize, Deserialize)]
struct HistoryTotals {
    added: usize,
    duplicate: usize,
    updated: usize,
    discovered: usize,
}
#[derive(Clone, Serialize, Deserialize)]
struct HistorySource {
    url: String,
    sitemap: bool,
}
#[derive(Clone, Serialize, Deserialize)]
struct HistoryCursor {
    url: String,
    offset: usize,
    fingerprint: String,
}
#[derive(Clone, Serialize, Deserialize)]
struct DiscoveryState {
    pending: VecDeque<HistorySource>,
    visited: Vec<String>,
    cursor: Option<HistoryCursor>,
    #[serde(default)]
    sources_initialized: bool,
}
#[derive(Clone, Serialize, Deserialize)]
struct ExistingTarget {
    id: String,
    url: String,
    fingerprint: String,
}
#[derive(Clone, Serialize, Deserialize)]
struct Checkpoint {
    job: RssHistoryJob,
    binding: String,
    robots: String,
    robots_at: i64,
    #[serde(default)]
    in_flight: bool,
    #[serde(default)]
    discovery: Option<DiscoveryState>,
    #[serde(default)]
    totals: HistoryTotals,
    #[serde(default)]
    targets: HashMap<String, ExistingTarget>,
    #[serde(default)]
    step_nonce: String,
    #[serde(default)]
    failure_count: usize,
    #[serde(default)]
    failure_retry_after_url: Option<String>,
}
struct Response {
    url: Url,
    status: StatusCode,
    headers: reqwest::header::HeaderMap,
    body: Vec<u8>,
}
fn invalid() -> CommandError {
    CommandError::new(
        "rss_history_invalid",
        "History source, limits or saved feed changed. Discover and review a new range.",
    )
}
fn unavailable() -> CommandError {
    CommandError::new(
        "rss_history_unavailable",
        "Historical source is unavailable or disallows archival. No article was imported.",
    )
}
fn stopped() -> CommandError {
    CommandError::new(
        "rss_history_paused",
        "History import was paused or changed; the in-flight result was discarded.",
    )
}
pub(super) fn migrate(c: &Connection) -> CommandResult<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS history_jobs (id TEXT PRIMARY KEY,feed_id TEXT NOT NULL UNIQUE REFERENCES feeds(id) ON DELETE CASCADE,payload TEXT NOT NULL); CREATE TABLE IF NOT EXISTS history_failures (job_id TEXT NOT NULL REFERENCES history_jobs(id) ON DELETE CASCADE,url TEXT NOT NULL,candidate_json TEXT NOT NULL,PRIMARY KEY(job_id,url));").map_err(db_err)
}
pub(super) fn recover_interrupted(c: &Connection) -> CommandResult<()> {
    let mut statement = c
        .prepare("SELECT payload FROM history_jobs LIMIT 21")
        .map_err(db_err)?;
    let rows = statement
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(db_err)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_err)?;
    drop(statement);
    if rows.len() > MAX_HISTORY_JOBS as usize {
        return Err(invalid());
    }
    for raw in rows {
        let mut value = decode(&raw)?;
        if value.job.status == "running" {
            value.job.status = "paused".into();
            value.in_flight = false;
            let tx = c.unchecked_transaction().map_err(db_err)?;
            save_progress(&tx, &mut value)?;
            tx.commit().map_err(db_err)?;
        }
    }
    Ok(())
}
fn decode(raw: &str) -> CommandResult<Checkpoint> {
    if raw.len() > MAX_JOB_BYTES {
        return Err(invalid());
    }
    let mut value: Checkpoint = serde_json::from_str(raw).map_err(|_| invalid())?;
    if value.job.candidates.len() > 500 || value.robots.len() > 128 * 1024 {
        return Err(invalid());
    }
    if value.failure_count > 50_000
        || value.targets.len() > 500
        || value.totals.discovered > 50_000
        || value.discovery.as_ref().is_some_and(|d| {
            d.pending.len() > 10
                || d.visited.len() > 10
                || d.cursor
                    .as_ref()
                    .is_some_and(|c| c.offset > parse::MAX_DISCOVERY_URLS)
        })
    {
        return Err(invalid());
    }
    if !matches!(
        value.job.status.as_str(),
        "preview" | "paused" | "running" | "complete"
    ) || value.job.candidates.iter().any(|c| {
        !matches!(
            c.status.as_str(),
            "pending" | "added" | "updated" | "duplicate" | "failed"
        ) || !matches!(c.kind.as_str(), "article" | "fullText")
    }) {
        return Err(invalid());
    }
    sync_counts(&mut value);
    if value.job.discovered_count > 50_000 {
        return Err(invalid());
    }
    Ok(value)
}
fn save(c: &Connection, checkpoint: &Checkpoint) -> CommandResult<()> {
    let raw = serde_json::to_string(checkpoint).map_err(|_| invalid())?;
    if raw.len() > MAX_JOB_BYTES {
        return Err(invalid());
    }
    c.execute("INSERT INTO history_jobs(id,feed_id,payload) VALUES(?,?,?) ON CONFLICT(feed_id) DO UPDATE SET id=excluded.id,payload=excluded.payload", params![checkpoint.job.id, checkpoint.job.feed_id, raw]).map_err(db_err)?;
    Ok(())
}
fn load(c: &Connection, id: &str) -> CommandResult<Checkpoint> {
    let raw = c
        .query_row("SELECT payload FROM history_jobs WHERE id=?", [id], |r| {
            r.get::<_, String>(0)
        })
        .optional()
        .map_err(db_err)?
        .ok_or_else(invalid)?;
    let mut cp = decode(&raw)?;
    hydrate_failures(c, &mut cp)?;
    Ok(cp)
}
fn binding(c: &Connection, feed_id: &str) -> CommandResult<String> {
    let feed = load_feed(c, feed_id)?;
    let private = preferences_from(c)?.private_network_access_enabled;
    Ok(format!(
        "{:x}",
        Sha256::digest(
            serde_json::to_vec(&(feed.id, feed.url, feed.site_url, private))
                .map_err(|_| invalid())?
        )
    ))
}
pub(super) fn check_history_url(url: &Url, origin: &Url) -> CommandResult<()> {
    validate_url(url.as_str(), false)?;
    if url.origin() != origin.origin()
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(invalid());
    }
    Ok(())
}
fn response(
    url: &Url,
    origin: &Url,
    robots: Option<&str>,
    check_active: Option<&dyn Fn() -> CommandResult<()>>,
) -> CommandResult<Response> {
    check_history_url(url, origin)?;
    let (url, status, headers, body) = fetch_bounded_scoped(
        url,
        false,
        None,
        None,
        MAX_SOURCE_BYTES,
        "History response exceeds 1 MiB.",
        Some(&RssFetchScope {
            origin,
            robots,
            check_active,
        }),
    )
    .map_err(|_| unavailable())?;
    Ok(Response {
        url,
        status,
        headers,
        body,
    })
}
fn text(response: &Response) -> CommandResult<&str> {
    if !response.status.is_success() {
        return Err(unavailable());
    }
    std::str::from_utf8(&response.body).map_err(|_| unavailable())
}
fn robots_text(value: Response) -> CommandResult<String> {
    if value.status == StatusCode::NOT_FOUND {
        return Ok(String::new());
    }
    let raw = text(&value)?;
    if raw.len() > 128 * 1024 {
        return Err(unavailable());
    }
    Ok(raw.to_owned())
}
fn retry_at(response: &Response) -> i64 {
    if matches!(response.status.as_u16(), 429 | 503) {
        let delay = response
            .headers
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| {
                v.parse::<i64>().ok().or_else(|| {
                    DateTime::parse_from_rfc2822(v)
                        .ok()
                        .map(|d| d.timestamp().saturating_sub(now()))
                })
            })
            .unwrap_or(60)
            .clamp(1, 86_400);
        now() + delay
    } else {
        now() + 1
    }
}
fn header_noarchive(response: &Response) -> bool {
    response
        .headers
        .get_all("x-robots-tag")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .any(|v| {
            v.to_ascii_lowercase()
                .split(|c: char| !c.is_ascii_alphabetic())
                .any(|v| matches!(v, "noarchive" | "none"))
        })
}
#[derive(Default)]
struct SourceMetadata {
    published: i64,
    author: Option<String>,
    canonical: Option<String>,
}
fn source_metadata(html: &str, base: &Url) -> CommandResult<SourceMetadata> {
    let cleaned = remove_reader_chrome(html);
    let lower = cleaned.to_ascii_lowercase();
    let mut meta = SourceMetadata::default();
    let mut cursor = 0;
    let mut tags = 0;
    while let Some(offset) = lower[cursor..].find('<') {
        let start = cursor + offset;
        if lower[start..].starts_with("<!--") {
            let end = lower[start + 4..].find("-->").ok_or_else(unavailable)?;
            cursor = start + 4 + end + 3;
            continue;
        }
        tags += 1;
        if tags > 50_000 {
            return Err(unavailable());
        }
        let end = parse::find_tag_end(&cleaned, start).ok_or_else(unavailable)?;
        cursor = end + 1;
        let raw = &cleaned[start + 1..end];
        let name = raw
            .split_ascii_whitespace()
            .next()
            .unwrap_or_default()
            .trim_end_matches('/')
            .to_ascii_lowercase();
        if !matches!(name.as_str(), "meta" | "link") {
            continue;
        }
        let xml = format!("<{} />", raw.trim_end_matches('/'));
        let mut reader = Reader::from_str(&xml);
        let Ok(Event::Empty(tag)) = reader.read_event() else {
            continue;
        };
        let get = |key: &str| {
            attribute(&tag, key.as_bytes())
                .ok()
                .flatten()
                .and_then(|v| quick_xml::escape::unescape(&v).ok().map(|v| v.into_owned()))
        };
        if name == "meta" {
            let key = get("property")
                .or_else(|| get("name"))
                .unwrap_or_default()
                .to_ascii_lowercase();
            let Some(value) = get("content") else {
                continue;
            };
            if matches!(
                key.as_str(),
                "article:published_time" | "datepublished" | "date" | "pubdate"
            ) && meta.published == 0
            {
                meta.published = parse_date(&value)
                    .filter(|date| *date > 0)
                    .unwrap_or_default();
            } else if matches!(key.as_str(), "author" | "article:author") && meta.author.is_none() {
                let value = clean_text(value);
                if !value.is_empty() {
                    meta.author = Some(value);
                }
            }
        } else if get("rel").is_some_and(|v| {
            v.split_ascii_whitespace()
                .any(|p| p.eq_ignore_ascii_case("canonical"))
        }) {
            if let Some(url) = get("href")
                .and_then(|u| base.join(&u).ok())
                .filter(|u| check_history_url(u, base).is_ok())
            {
                meta.canonical = Some(url.to_string());
            }
        }
    }
    Ok(meta)
}

fn sync_counts(checkpoint: &mut Checkpoint) {
    let job = &mut checkpoint.job;
    job.added_count = checkpoint.totals.added
        + job
            .candidates
            .iter()
            .filter(|c| c.status == "added")
            .count();
    job.duplicate_count = checkpoint.totals.duplicate
        + job
            .candidates
            .iter()
            .filter(|c| c.status == "duplicate")
            .count();
    job.updated_count = checkpoint.totals.updated
        + job
            .candidates
            .iter()
            .filter(|c| c.status == "updated")
            .count();
    job.failed_count = checkpoint.failure_count.max(
        job.candidates
            .iter()
            .filter(|c| c.status == "failed")
            .count(),
    );
    job.discovered_count = checkpoint.totals.discovered
        + if job.retrying_failures {
            0
        } else {
            job.candidates.len()
        };
    job.has_more_discovery = checkpoint
        .discovery
        .as_ref()
        .is_some_and(|d| d.cursor.is_some() || !d.pending.is_empty() && d.visited.len() < 10);
}
fn recount(checkpoint: &mut Checkpoint) {
    sync_counts(checkpoint);
    checkpoint.job.status = if checkpoint
        .job
        .candidates
        .iter()
        .any(|c| c.status == "pending")
    {
        "running"
    } else {
        "complete"
    }
    .into();
}
type HistoryCacheRevision = (String, Option<String>, Option<String>, Option<String>, i64);

struct ExistingArticle {
    target: ExistingTarget,
    eligible: bool,
}
fn existing_article(c: &Connection, id: &str) -> CommandResult<Option<ExistingArticle>> {
    let row: Option<(String, String, String)> = c
        .query_row(
            "SELECT url,content,summary FROM articles WHERE id=?",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_err)?;
    let Some((url, content_html, summary)) = row else {
        return Ok(None);
    };
    let cache: Option<HistoryCacheRevision> = c.query_row("SELECT status,source_url,content_html,plain_text,attempted_at FROM full_text_cache WHERE article_id=?", [id], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional().map_err(db_err)?;
    let ready = cache.as_ref().is_some_and(|(status, source, _, _, _)| {
        status == "ready" && source.as_deref() == Some(url.as_str())
    });
    let readable = html_text(&content_html);
    let eligible = !ready && content::needs_full_text(&content_html, &summary, &readable);
    let fingerprint = format!(
        "{:x}",
        Sha256::digest(
            serde_json::to_vec(&(&url, &content_html, &summary, &cache)).map_err(|_| invalid())?
        )
    );
    Ok(Some(ExistingArticle {
        target: ExistingTarget {
            id: id.into(),
            url,
            fingerprint,
        },
        eligible,
    }))
}
fn existing_by_url(
    c: &Connection,
    feed: &str,
    url: &str,
) -> CommandResult<Option<ExistingArticle>> {
    let id: Option<String> = c
        .query_row(
            "SELECT id FROM articles WHERE feed_id=? AND url=? ORDER BY id LIMIT 1",
            params![feed, url],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_err)?;
    id.map(|id| existing_article(c, &id))
        .transpose()
        .map(Option::flatten)
}
fn classify_candidate(
    c: &Connection,
    checkpoint: &mut Checkpoint,
    url: String,
    title: String,
) -> CommandResult<RssHistoryCandidate> {
    let mut candidate = RssHistoryCandidate {
        url: url.clone(),
        title: truncate_utf8(clean_text(title), 4096),
        status: "pending".into(),
        message: None,
        kind: article_kind(),
    };
    if let Some(existing) = existing_by_url(c, &checkpoint.job.feed_id, &url)? {
        if checkpoint.job.fill_existing && existing.eligible {
            candidate.kind = "fullText".into();
            checkpoint.targets.insert(url, existing.target);
        } else {
            candidate.status = "duplicate".into();
        }
    }
    Ok(candidate)
}
struct PreparedHistory {
    resolved: String,
    title: String,
    content: String,
    plain: String,
    confidence: f64,
    metadata: SourceMetadata,
    aliases: Vec<String>,
    target: Option<ExistingTarget>,
    source_hash: String,
}
fn checked_metadata(value: &Response, origin: &Url, robots: &str) -> CommandResult<SourceMetadata> {
    check_history_url(&value.url, origin)?;
    if !parse::robots_allowed(robots, &value.url) || header_noarchive(value) {
        return Err(unavailable());
    }
    let html = text(value)?;
    let mime = header_text(&value.headers, "content-type")
        .unwrap_or_default()
        .to_ascii_lowercase();
    if !mime.is_empty()
        && !mime.starts_with("text/html")
        && !mime.starts_with("application/xhtml+xml")
        || parse::no_archive(html)
    {
        return Err(unavailable());
    }
    let mut metadata = source_metadata(html, &value.url)?;
    metadata.canonical = metadata.canonical.filter(|raw| {
        Url::parse(raw)
            .ok()
            .is_some_and(|u| parse::robots_allowed(robots, &u))
    });
    Ok(metadata)
}
struct DiscoveryGuard<'a> {
    store: &'a RssReaderStore,
    feed_id: String,
}
impl Drop for DiscoveryGuard<'_> {
    fn drop(&mut self) {
        if let Ok(mut busy) = self.store.history_busy.lock() {
            busy.remove(&self.feed_id);
        }
    }
}
impl RssReaderStore {
    pub fn history_cancel_discovery(&self, discovery_id: String) -> CommandResult<()> {
        Uuid::parse_str(&discovery_id).map_err(|_| invalid())?;
        let mut cancelled = self.history_cancelled.lock().map_err(|_| lock_err())?;
        cancelled.retain(|_, time| time.elapsed() < Duration::from_secs(3600));
        if cancelled.len() >= 64 && !cancelled.contains_key(&discovery_id) {
            return Err(CommandError::new(
                "rss_history_capacity",
                "History cancellation capacity reached; wait before starting another discovery.",
            ));
        }
        cancelled.insert(discovery_id, std::time::Instant::now());
        Ok(())
    }
    fn history_discovery_active(&self, discovery_id: &str) -> CommandResult<()> {
        let mut cancelled = self.history_cancelled.lock().map_err(|_| lock_err())?;
        cancelled.retain(|_, time| time.elapsed() < Duration::from_secs(3600));
        if cancelled.len() >= 64 || cancelled.contains_key(discovery_id) {
            return Err(stopped());
        }
        Ok(())
    }
    pub fn history_status(&self, feed_id: String) -> CommandResult<Option<RssHistoryJob>> {
        let c = self.db.lock().map_err(|_| lock_err())?;
        let raw: Option<String> = c
            .query_row(
                "SELECT payload FROM history_jobs WHERE feed_id=?",
                [&feed_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_err)?;
        raw.map(|s| {
            let mut value = decode(&s)?;
            hydrate_failures(&c, &mut value)?;
            if binding(&c, &feed_id)? != value.binding {
                return Err(invalid());
            }
            Ok(value.job)
        })
        .transpose()
    }
    pub fn history_pause(&self, job_id: String) -> CommandResult<RssHistoryJob> {
        let c = self.db.lock().map_err(|_| lock_err())?;
        let tx = c.unchecked_transaction().map_err(db_err)?;
        let mut value = load(&tx, &job_id)?;
        // Mutating the checkpoint invalidates any fetch holding the old serialized value.
        value.job.status = "paused".into();
        value.in_flight = false;
        value.job.next_request_at = value.job.next_request_at.max(now() + 1);
        save_progress(&tx, &mut value)?;
        tx.commit().map_err(db_err)?;
        Ok(value.job)
    }
    pub fn history_step(&self, input: RssHistoryStepInput) -> CommandResult<RssHistoryJob> {
        let (origin, mut policy) = {
            let c = self.db.lock().map_err(|_| lock_err())?;
            let cp = load(&c, &input.job_id)?;
            (
                Url::parse(&cp.job.directory_url).map_err(|_| invalid())?,
                cp.robots,
            )
        };
        let nonce = Uuid::new_v4().to_string();
        let job_id = input.job_id.clone();
        let check_active = || self.history_step_active(&job_id, &nonce);
        let mut last = None;
        self.history_step_with_nonce(input, nonce.clone(), |url| {
            check_active()?;
            if let Some(last) = last {
                let elapsed = std::time::Instant::now().duration_since(last);
                if elapsed < Duration::from_secs(1) {
                    std::thread::sleep(Duration::from_secs(1) - elapsed);
                }
            }
            let result = response(
                url,
                &origin,
                if url.path() == "/robots.txt" {
                    None
                } else {
                    Some(&policy)
                },
                Some(&check_active),
            );
            last = Some(std::time::Instant::now());
            if url.path() == "/robots.txt" {
                if let Ok(value) = &result {
                    if value.status == StatusCode::NOT_FOUND {
                        policy.clear();
                    } else if value.status.is_success() {
                        policy = String::from_utf8_lossy(&value.body).to_string();
                    }
                }
            }
            result
        })
    }
    fn history_step_active(&self, job_id: &str, nonce: &str) -> CommandResult<()> {
        let c = self.db.lock().map_err(|_| lock_err())?;
        let value = load(&c, job_id)?;
        if value.in_flight
            && value.job.status == "running"
            && value.step_nonce == nonce
            && binding(&c, &value.job.feed_id)? == value.binding
        {
            Ok(())
        } else {
            Err(stopped())
        }
    }
    #[cfg(test)]
    fn history_step_with(
        &self,
        input: RssHistoryStepInput,
        fetch: impl FnMut(&Url) -> CommandResult<Response>,
    ) -> CommandResult<RssHistoryJob> {
        self.history_step_with_nonce(input, Uuid::new_v4().to_string(), fetch)
    }
    fn history_step_with_nonce(
        &self,
        input: RssHistoryStepInput,
        nonce: String,
        mut fetch: impl FnMut(&Url) -> CommandResult<Response>,
    ) -> CommandResult<RssHistoryJob> {
        let (mut checkpoint, index, running_payload, exact_target, possible_aliases) = {
            let c = self.db.lock().map_err(|_| lock_err())?;
            let tx = c.unchecked_transaction().map_err(db_err)?;
            let mut cp = load(&tx, &input.job_id)?;
            if self
                .history_busy
                .lock()
                .map_err(|_| lock_err())?
                .contains(&cp.job.feed_id)
                || binding(&tx, &cp.job.feed_id)? != cp.binding
                || cp.in_flight
            {
                return Err(stopped());
            }
            if now() < cp.job.next_request_at {
                return Err(CommandError::new(
                    "rss_history_backoff",
                    "Wait for the displayed retry time before continuing history import.",
                ));
            }
            if input.retry_failures {
                for candidate in &mut cp.job.candidates {
                    if candidate.status == "failed" {
                        candidate.status = "pending".into();
                        candidate.message = None;
                    }
                }
            }
            let Some(index) = cp.job.candidates.iter().position(|c| c.status == "pending") else {
                recount(&mut cp);
                save_progress(&tx, &mut cp)?;
                tx.commit().map_err(db_err)?;
                return Ok(cp.job);
            };
            let candidate_url = cp.job.candidates[index].url.clone();
            let exact = existing_by_url(&tx, &cp.job.feed_id, &candidate_url)?;
            let mut exact_target = None;
            if let Some(existing) = exact {
                if !cp.job.fill_existing || !existing.eligible {
                    cp.job.candidates[index].status = "duplicate".into();
                    recount(&mut cp);
                    save_progress(&tx, &mut cp)?;
                    tx.commit().map_err(db_err)?;
                    return Ok(cp.job);
                }
                if !input.retry_failures
                    && cp.targets.get(&candidate_url).is_some_and(|t| {
                        t.id != existing.target.id || t.fingerprint != existing.target.fingerprint
                    })
                {
                    cp.job.candidates[index].status = "failed".into();
                    cp.job.candidates[index].message = Some(
                        "Existing article changed. Review it before manually retrying full text."
                            .into(),
                    );
                    recount(&mut cp);
                    save_progress(&tx, &mut cp)?;
                    tx.commit().map_err(db_err)?;
                    return Ok(cp.job);
                }
                cp.job.candidates[index].kind = "fullText".into();
                cp.targets
                    .insert(candidate_url.clone(), existing.target.clone());
                exact_target = Some(existing.target);
            } else if cp.targets.contains_key(&candidate_url) {
                cp.job.candidates[index].status = "failed".into();
                cp.job.candidates[index].message =
                    Some("Existing article was removed. Review a new range.".into());
                recount(&mut cp);
                save_progress(&tx, &mut cp)?;
                tx.commit().map_err(db_err)?;
                return Ok(cp.job);
            }
            let candidate = Url::parse(&candidate_url).map_err(|_| invalid())?;
            let origin = Url::parse(&cp.job.directory_url).map_err(|_| invalid())?;
            let mut probes = Vec::new();
            if exact_target.is_none() {
                let mut query=tx.prepare("SELECT id,url FROM articles WHERE feed_id=? AND url IS NOT NULL AND url<>? ORDER BY id LIMIT 2000").map_err(db_err)?;
                let rows = query
                    .query_map(params![cp.job.feed_id, candidate_url], |r| {
                        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                    })
                    .map_err(db_err)?
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(db_err)?;
                for (id, raw) in rows {
                    let Ok(old) = Url::parse(&raw) else { continue };
                    if check_history_url(&old, &origin).is_ok()
                        && parse::robots_allowed(&cp.robots, &old)
                        && content::may_be_slash_alias(&old, &candidate)
                    {
                        if let Some(existing) = existing_article(&tx, &id)? {
                            probes.push(existing.target);
                            if probes.len() == 2 {
                                break;
                            }
                        }
                    }
                }
            }
            cp.job.status = "running".into();
            cp.in_flight = true;
            cp.step_nonce = nonce.clone();
            sync_counts(&mut cp);
            save_progress(&tx, &mut cp)?;
            let payload = serde_json::to_string(&cp).map_err(|_| invalid())?;
            tx.commit().map_err(db_err)?;
            (cp, index, payload, exact_target, probes)
        };
        let origin = Url::parse(&checkpoint.job.directory_url).map_err(|_| invalid())?;
        let url = Url::parse(&checkpoint.job.candidates[index].url).map_err(|_| invalid())?;
        let mut robots_update = None;
        let outcome = (|| {
            check_history_url(&url, &origin)?;
            self.history_step_active(&input.job_id, &nonce)?;
            if now().saturating_sub(checkpoint.robots_at) >= 300 {
                let robots_url = origin.join("/robots.txt").map_err(|_| invalid())?;
                let response = fetch(&robots_url)?;
                self.history_step_active(&input.job_id, &nonce)?;
                checkpoint.job.next_request_at = retry_at(&response);
                check_history_url(&response.url, &origin)?;
                robots_update = Some(robots_text(response)?);
                return Ok(None);
            }
            if !parse::robots_allowed(&checkpoint.robots, &url) {
                return Err(unavailable());
            }
            let value = fetch(&url)?;
            self.history_step_active(&input.job_id, &nonce)?;
            checkpoint.job.next_request_at = retry_at(&value);
            let metadata = checked_metadata(&value, &origin, &checkpoint.robots)?;
            let html = text(&value)?;
            let (content, plain, confidence) = extract_readable_html(html);
            if plain.trim().chars().count() < 40 {
                return Err(unavailable());
            }
            let title = find_html_element(html, "title")
                .map(|t| clean_text(html_text(t)))
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| checkpoint.job.candidates[index].title.clone());
            let resolved = value.url.to_string();
            let mut aliases = vec![url.to_string(), resolved.clone()];
            if let Some(canonical) = metadata.canonical.as_ref() {
                if !aliases.contains(canonical) {
                    aliases.push(canonical.clone());
                }
            }
            let mut target = exact_target;
            if target.is_none() {
                // Exact resolved/canonical matches need no slash probe. Capture a target revision before later network.
                let c = self.db.lock().map_err(|_| lock_err())?;
                for alias in &aliases {
                    if let Some(existing) = existing_by_url(&c, &checkpoint.job.feed_id, alias)? {
                        target = Some(existing.target);
                        break;
                    }
                }
            }
            if target.is_none() {
                for old in possible_aliases {
                    if aliases.contains(&old.url) {
                        continue;
                    }
                    let old_url = Url::parse(&old.url).map_err(|_| invalid())?;
                    check_history_url(&old_url, &origin)?;
                    if !parse::robots_allowed(&checkpoint.robots, &old_url) {
                        return Err(unavailable());
                    }
                    self.history_step_active(&input.job_id, &nonce)?;
                    let old_response = fetch(&old_url)?;
                    self.history_step_active(&input.job_id, &nonce)?;
                    checkpoint.job.next_request_at =
                        checkpoint.job.next_request_at.max(retry_at(&old_response));
                    let old_meta = checked_metadata(&old_response, &origin, &checkpoint.robots)?;
                    if aliases.contains(&old_response.url.to_string())
                        || old_meta
                            .canonical
                            .as_ref()
                            .is_some_and(|u| aliases.contains(u))
                    {
                        aliases.push(old.url.clone());
                        target = Some(old);
                        break;
                    }
                }
            }
            Ok(Some(PreparedHistory {
                resolved,
                title,
                content,
                plain,
                confidence,
                metadata,
                aliases,
                target,
                source_hash: format!("{:x}", Sha256::digest(&value.body)),
            }))
        })();
        let c = self.db.lock().map_err(|_| lock_err())?;
        let tx = c.unchecked_transaction().map_err(db_err)?;
        let current: Option<String> = tx
            .query_row(
                "SELECT payload FROM history_jobs WHERE id=?",
                [&input.job_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_err)?;
        if current.as_deref() != Some(running_payload.as_str())
            || binding(&tx, &checkpoint.job.feed_id)? != checkpoint.binding
        {
            if current.as_deref() == Some(running_payload.as_str()) {
                checkpoint.job.status = "paused".into();
                checkpoint.in_flight = false;
                save_progress(&tx, &mut checkpoint)?;
                tx.commit().map_err(db_err)?;
            }
            return Err(stopped());
        }
        checkpoint.job.next_request_at = checkpoint.job.next_request_at.max(now() + 1);
        match outcome {
            Ok(Some(prepared)) => {
                let mut existing = HashMap::new();
                for alias in &prepared.aliases {
                    if let Some(value) = existing_by_url(&tx, &checkpoint.job.feed_id, alias)? {
                        existing.insert(value.target.id.clone(), value);
                    }
                }
                if existing.len() > 1 {
                    checkpoint.job.candidates[index].status = "failed".into();
                    checkpoint.job.candidates[index].message =
                        Some("Conflicting existing article identities. Review a new range.".into());
                } else if let Some(existing) = existing.into_values().next() {
                    if checkpoint.job.fill_existing && existing.eligible {
                        if prepared.target.as_ref().is_some_and(|t| {
                            t.id == existing.target.id
                                && t.fingerprint == existing.target.fingerprint
                        }) {
                            tx.execute("INSERT INTO full_text_cache(article_id,status,content_html,plain_text,source_url,resolved_url,source_content_hash,confidence,attempted_at,retry_after,failure_message) VALUES(?,'ready',?,?,?,?,?,?,?,0,NULL) ON CONFLICT(article_id) DO UPDATE SET status='ready',content_html=excluded.content_html,plain_text=excluded.plain_text,source_url=excluded.source_url,resolved_url=excluded.resolved_url,source_etag=NULL,source_last_modified=NULL,source_content_hash=excluded.source_content_hash,confidence=excluded.confidence,attempted_at=excluded.attempted_at,retry_after=0,failure_message=NULL",params![existing.target.id,prepared.content,prepared.plain,existing.target.url,prepared.resolved,prepared.source_hash,(prepared.confidence.clamp(0.0,1.0)*1000.0).round() as i64,now()]).map_err(db_err)?;
                            checkpoint.job.candidates[index].status = "updated".into();
                            checkpoint.job.candidates[index].kind = "fullText".into();
                        } else {
                            checkpoint.job.candidates[index].status = "failed".into();
                            checkpoint.job.candidates[index].message=Some("Existing article changed. Review it before manually retrying full text.".into());
                        }
                    } else {
                        checkpoint.job.candidates[index].status = "duplicate".into();
                    }
                } else if prepared.target.is_some() {
                    checkpoint.job.candidates[index].status = "failed".into();
                    checkpoint.job.candidates[index].message =
                        Some("Existing article changed or was removed. Review a new range.".into());
                } else {
                    let canonical = prepared
                        .metadata
                        .canonical
                        .as_deref()
                        .unwrap_or(&prepared.resolved);
                    let identity = format!("history:{:x}", Sha256::digest(canonical.as_bytes()));
                    tx.execute("INSERT INTO articles(id,feed_id,identity,guid,title,url,summary,content,published,fetched,author) VALUES(?,?,?,?,?,?,?,?,?,?,?)",params![Uuid::new_v4().to_string(),checkpoint.job.feed_id,identity,canonical,prepared.title,canonical,truncate_utf8(prepared.plain,4096),prepared.content,prepared.metadata.published,now(),prepared.metadata.author]).map_err(db_err)?;
                    checkpoint.job.candidates[index].status = "added".into();
                }
            }
            Ok(None) => {
                checkpoint.robots = robots_update.unwrap_or_default();
                checkpoint.robots_at = now();
            }
            Err(_) => {
                checkpoint.job.candidates[index].status = "failed".into();
                checkpoint.job.candidates[index].message=Some("Source unavailable, unsafe, too short or disallows archival. Retry manually after review.".into());
            }
        }
        recount(&mut checkpoint);
        checkpoint.in_flight = false;
        save_progress(&tx, &mut checkpoint)?;
        tx.commit().map_err(db_err)?;
        Ok(checkpoint.job)
    }
}
#[cfg(test)]
#[path = "rss_history_tests.rs"]
mod tests;
