//! Durable, manually advanced discovery segments and checkpoint maintenance.
use super::*;

const MAX_PAGES: usize = 10;
const MAX_DISCOVERED: usize = MAX_PAGES * parse::MAX_DISCOVERY_URLS;
fn capacity() -> CommandError {
    CommandError::new("rss_history_capacity", "History checkpoint capacity reached. Clear an inactive checkpoint before discovering a new range.")
}
fn discovery_busy() -> CommandError {
    CommandError::new(
        "rss_history_busy",
        "Pause history import or finish discovery before changing its checkpoint.",
    )
}
impl RssReaderStore {
    fn discovery_guard(&self, feed_id: &str) -> CommandResult<DiscoveryGuard<'_>> {
        let mut busy = self.history_busy.lock().map_err(|_| lock_err())?;
        if busy.len() >= MAX_HISTORY_JOBS as usize || !busy.insert(feed_id.into()) {
            return Err(discovery_busy());
        }
        Ok(DiscoveryGuard {
            store: self,
            feed_id: feed_id.into(),
        })
    }
    fn discovery_transport<T>(
        &self,
        origin: Url,
        token: String,
        feed_id: String,
        operation: impl FnOnce(&mut dyn FnMut(&Url) -> CommandResult<Response>) -> CommandResult<T>,
    ) -> CommandResult<T> {
        let mut last = None;
        let mut policy = None;
        let check_active = || {
            self.history_discovery_active(&token)?;
            let c = self.db.lock().map_err(|_| lock_err())?;
            let raw: String = c
                .query_row(
                    "SELECT payload FROM history_jobs WHERE feed_id=?",
                    [&feed_id],
                    |r| r.get(0),
                )
                .map_err(db_err)?;
            let saved = decode(&raw)?;
            if saved.job.status != "preview" || binding(&c, &feed_id)? != saved.binding {
                return Err(stopped());
            }
            Ok(())
        };
        operation(&mut |url| {
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
                    policy.as_deref()
                },
                Some(&check_active),
            );
            if url.path() == "/robots.txt" {
                if let Ok(value) = &result {
                    if value.status == StatusCode::NOT_FOUND {
                        policy = Some(String::new());
                    } else if value.status.is_success() {
                        policy = Some(String::from_utf8_lossy(&value.body).to_string());
                    }
                }
            }
            last = Some(std::time::Instant::now());
            result
        })
    }
    pub fn history_discover(&self, input: RssHistoryDiscoverInput) -> CommandResult<RssHistoryJob> {
        let origin = validate_url(&input.directory_url, false)?;
        let token = input.discovery_id.clone();
        let feed = input.feed_id.clone();
        self.discovery_transport(origin, token, feed, |fetch| {
            self.history_discover_with(input, fetch)
        })
    }
    pub fn history_resume_discovery(
        &self,
        input: RssHistoryResumeInput,
    ) -> CommandResult<RssHistoryJob> {
        let (origin, feed) = {
            let c = self.db.lock().map_err(|_| lock_err())?;
            let cp = load(&c, &input.job_id)?;
            (
                Url::parse(&cp.job.directory_url).map_err(|_| invalid())?,
                cp.job.feed_id,
            )
        };
        let token = input.discovery_id.clone();
        self.discovery_transport(origin, token, feed, |fetch| {
            self.history_resume_discovery_with(input, fetch)
        })
    }
    pub(super) fn history_discover_with(
        &self,
        input: RssHistoryDiscoverInput,
        mut fetch: impl FnMut(&Url) -> CommandResult<Response>,
    ) -> CommandResult<RssHistoryJob> {
        validate_limits(&input.discovery_id, input.max_pages, input.max_articles)?;
        self.history_discovery_active(&input.discovery_id)?;
        let directory = validate_url(&input.directory_url, false)?;
        check_history_url(&directory, &directory)?;
        let _guard = self.discovery_guard(&input.feed_id)?;
        let (mut cp, mut expected) = {
            let c = self.db.lock().map_err(|_| lock_err())?;
            let tx = c.unchecked_transaction().map_err(db_err)?;
            let feed = load_feed(&tx, &input.feed_id)?;
            if ![Some(feed.url.as_str()), feed.site_url.as_deref()]
                .into_iter()
                .flatten()
                .any(|u| {
                    Url::parse(u)
                        .ok()
                        .is_some_and(|u| u.origin() == directory.origin())
                })
            {
                return Err(invalid());
            }
            let exists: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM history_jobs WHERE feed_id=?)",
                    [&input.feed_id],
                    |r| r.get(0),
                )
                .map_err(db_err)?;
            if exists {
                return Err(CommandError::new("rss_history_checkpoint_exists","This subscription already has a history checkpoint. Resume it or explicitly clear it before discovering a new range."));
            }
            let count: i64 = tx
                .query_row("SELECT count(*) FROM history_jobs", [], |r| r.get(0))
                .map_err(db_err)?;
            if count >= MAX_HISTORY_JOBS {
                return Err(capacity());
            }
            let mut cp = Checkpoint {
                job: RssHistoryJob {
                    id: Uuid::new_v4().to_string(),
                    feed_id: input.feed_id,
                    directory_url: directory.to_string(),
                    status: "preview".into(),
                    candidates: Vec::new(),
                    added_count: 0,
                    duplicate_count: 0,
                    failed_count: 0,
                    next_request_at: 0,
                    reached_limit: false,
                    message: None,
                    updated_count: 0,
                    discovered_count: 0,
                    has_more_discovery: true,
                    fill_existing: input.fill_existing,
                    retrying_failures: false,
                },
                binding: binding(&tx, &feed.id)?,
                robots: String::new(),
                robots_at: 0,
                in_flight: false,
                discovery: Some(DiscoveryState {
                    pending: VecDeque::from([HistorySource {
                        url: directory.to_string(),
                        sitemap: false,
                    }]),
                    visited: Vec::new(),
                    cursor: None,
                    sources_initialized: false,
                }),
                totals: HistoryTotals::default(),
                targets: HashMap::new(),
                step_nonce: String::new(),
                failure_count: 0,
                failure_retry_after_url: None,
            };
            sync_counts(&mut cp);
            let cancelled = self.history_cancelled.lock().map_err(|_| lock_err())?;
            if cancelled.len() >= 64 || cancelled.contains_key(&input.discovery_id) {
                return Err(stopped());
            }
            save(&tx, &cp)?;
            let raw = serde_json::to_string(&cp).map_err(|_| invalid())?;
            tx.commit().map_err(db_err)?;
            drop(cancelled);
            (cp, raw)
        };
        self.discover_segment(
            &mut cp,
            &mut expected,
            &input.discovery_id,
            input.max_pages,
            input.max_articles,
            &mut fetch,
        )
    }
    pub(super) fn history_resume_discovery_with(
        &self,
        input: RssHistoryResumeInput,
        mut fetch: impl FnMut(&Url) -> CommandResult<Response>,
    ) -> CommandResult<RssHistoryJob> {
        validate_limits(&input.discovery_id, input.max_pages, input.max_articles)?;
        self.history_discovery_active(&input.discovery_id)?;
        let (mut cp, mut expected) = {
            let c = self.db.lock().map_err(|_| lock_err())?;
            let raw: String = c
                .query_row(
                    "SELECT payload FROM history_jobs WHERE id=?",
                    [&input.job_id],
                    |r| r.get(0),
                )
                .map_err(db_err)?;
            (decode(&raw)?, raw)
        };
        let _guard = self.discovery_guard(&cp.job.feed_id)?;
        super::failures::check_batch_idle(&cp)?;
        if cp.discovery.is_none() || !cp.job.has_more_discovery {
            return Err(CommandError::new(
                "rss_history_no_cursor",
                "No verified discovery cursor is available. Review a new range instead.",
            ));
        }
        if now() < cp.job.next_request_at {
            return Err(CommandError::new(
                "rss_history_backoff",
                "Wait for the displayed retry time before continuing history discovery.",
            ));
        }
        self.advance_discovery_batch(&mut cp, &mut expected, &input.discovery_id)?;
        self.discover_segment(
            &mut cp,
            &mut expected,
            &input.discovery_id,
            input.max_pages,
            input.max_articles,
            &mut fetch,
        )
    }
    fn commit_discovery(
        &self,
        cp: &mut Checkpoint,
        expected: &mut String,
        token: &str,
    ) -> CommandResult<()> {
        sync_counts(cp);
        if cp.job.discovered_count > MAX_DISCOVERED {
            return Err(capacity());
        }
        let c = self.db.lock().map_err(|_| lock_err())?;
        let tx = c.unchecked_transaction().map_err(db_err)?;
        let raw: Option<String> = tx
            .query_row(
                "SELECT payload FROM history_jobs WHERE id=? AND feed_id=?",
                params![cp.job.id, cp.job.feed_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_err)?;
        if raw.as_deref() != Some(expected.as_str()) || binding(&tx, &cp.job.feed_id)? != cp.binding
        {
            return Err(stopped());
        }
        let cancelled = self.history_cancelled.lock().map_err(|_| lock_err())?;
        if cancelled.len() >= 64 || cancelled.contains_key(token) {
            return Err(stopped());
        }
        save_progress(&tx, cp)?;
        *expected = serde_json::to_string(cp).map_err(|_| invalid())?;
        tx.commit().map_err(db_err)?;
        drop(cancelled);
        Ok(())
    }
    fn discover_segment(
        &self,
        cp: &mut Checkpoint,
        expected: &mut String,
        token: &str,
        max_pages: usize,
        max_articles: usize,
        fetch: &mut impl FnMut(&Url) -> CommandResult<Response>,
    ) -> CommandResult<RssHistoryJob> {
        let directory = Url::parse(&cp.job.directory_url).map_err(|_| invalid())?;
        let outcome = (|| {
            self.history_discovery_active(token)?;
            let robots = fetch(&directory.join("/robots.txt").map_err(|_| invalid())?)?;
            self.history_discovery_active(token)?;
            cp.job.next_request_at = retry_at(&robots);
            check_history_url(&robots.url, &directory)?;
            cp.robots = robots_text(robots)?;
            cp.robots_at = now();
            if !parse::robots_allowed(&cp.robots, &directory) {
                return Err(unavailable());
            }
            if !cp
                .discovery
                .as_ref()
                .ok_or_else(invalid)?
                .sources_initialized
            {
                let mut maps = parse::robots_sitemaps(&cp.robots, &directory);
                maps.truncate(3);
                if maps.is_empty() {
                    maps.push(
                        directory
                            .join("/sitemap.xml")
                            .map_err(|_| invalid())?
                            .to_string(),
                    );
                }
                let state = cp.discovery.as_mut().ok_or_else(invalid)?;
                for raw in maps {
                    if !state.pending.iter().any(|p| p.url == raw) {
                        state.pending.push_back(HistorySource {
                            url: raw,
                            sitemap: true,
                        });
                    }
                }
                state.sources_initialized = true;
            }
            self.commit_discovery(cp, expected, token)?;
            let mut fetched = 0;
            while fetched < max_pages && cp.job.candidates.len() < max_articles {
                let state = cp.discovery.as_ref().ok_or_else(invalid)?;
                let Some(source) = state.pending.front().cloned() else {
                    break;
                };
                if state.visited.len() >= MAX_PAGES {
                    cp.job.message = Some(
                        "Source-page limit reached. Review a more specific public directory."
                            .into(),
                    );
                    break;
                }
                let page = Url::parse(&source.url).map_err(|_| invalid())?;
                check_history_url(&page, &directory)?;
                if !parse::robots_allowed(&cp.robots, &page) {
                    return Err(unavailable());
                }
                self.history_discovery_active(token)?;
                let value = fetch(&page)?;
                self.history_discovery_active(token)?;
                cp.job.next_request_at = retry_at(&value);
                check_history_url(&value.url, &directory)?;
                if !parse::robots_allowed(&cp.robots, &value.url) {
                    return Err(unavailable());
                }
                if matches!(value.status.as_u16(), 429 | 503) {
                    return Err(unavailable());
                }
                fetched += 1;
                if value.status == StatusCode::NOT_FOUND {
                    let state = cp.discovery.as_mut().ok_or_else(invalid)?;
                    if state.cursor.is_some() {
                        return Err(source_changed());
                    }
                    state.pending.pop_front();
                    state.visited.push(source.url);
                    cp.job.message=Some("Some discovery sources were unavailable or disallowed. Only listed candidates can be imported.".into());
                    self.commit_discovery(cp, expected, token)?;
                    continue;
                }
                if header_noarchive(&value) {
                    return Err(unavailable());
                }
                let html = text(&value)?;
                if parse::no_archive(html) {
                    return Err(unavailable());
                }
                let xml = source.sitemap
                    || html.trim_start().starts_with("<?xml")
                    || html.trim_start().starts_with("<urlset")
                    || html.trim_start().starts_with("<sitemapindex");
                let (articles, next) =
                    parse::discovery_links(html, &value.url, xml).map_err(|_| unavailable())?;
                let fingerprint = format!(
                    "{:x}",
                    Sha256::digest(
                        serde_json::to_vec(&(
                            value.url.as_str(),
                            xml,
                            articles.iter().map(|a| a.0.as_str()).collect::<Vec<_>>(),
                            &next
                        ))
                        .map_err(|_| invalid())?
                    )
                );
                let cursor = cp.discovery.as_ref().and_then(|d| d.cursor.as_ref());
                if cursor.is_some_and(|c| {
                    c.url != source.url || c.fingerprint != fingerprint || c.offset > articles.len()
                }) {
                    return Err(source_changed());
                }
                let mut offset = cursor.map_or(0, |c| c.offset);
                let mut known = cp
                    .job
                    .candidates
                    .iter()
                    .map(|c| c.url.clone())
                    .collect::<HashSet<_>>();
                {
                    let c = self.db.lock().map_err(|_| lock_err())?;
                    if binding(&c, &cp.job.feed_id)? != cp.binding {
                        return Err(stopped());
                    }
                    while offset < articles.len() && cp.job.candidates.len() < max_articles {
                        let (raw, title) = articles[offset].clone();
                        offset += 1;
                        let url = Url::parse(&raw).map_err(|_| invalid())?;
                        if url == directory
                            || check_history_url(&url, &directory).is_err()
                            || !parse::robots_allowed(&cp.robots, &url)
                            || !known.insert(raw.clone())
                        {
                            continue;
                        }
                        let candidate = classify_candidate(&c, cp, raw, title)?;
                        cp.job.candidates.push(candidate);
                    }
                }
                let state = cp.discovery.as_mut().ok_or_else(invalid)?;
                if offset < articles.len() {
                    state.cursor = Some(HistoryCursor {
                        url: source.url,
                        offset,
                        fingerprint,
                    });
                } else {
                    let mut queued = state.pending.clone();
                    queued.pop_front();
                    for (raw, sitemap) in next {
                        let url = Url::parse(&raw).map_err(|_| invalid())?;
                        if check_history_url(&url, &directory).is_ok()
                            && parse::robots_allowed(&cp.robots, &url)
                            && !state.visited.contains(&raw)
                            && raw != source.url
                            && !queued.iter().any(|p| p.url == raw)
                        {
                            if queued.len() >= MAX_PAGES {
                                return Err(capacity());
                            }
                            queued.push_back(HistorySource { url: raw, sitemap });
                        }
                    }
                    state.pending = queued;
                    state.visited.push(source.url);
                    state.cursor = None;
                }
                cp.job.reached_limit = cp.job.candidates.len() >= max_articles
                    && (!state.pending.is_empty() || state.cursor.is_some());
                self.commit_discovery(cp, expected, token)?;
            }
            let state = cp.discovery.as_ref().ok_or_else(invalid)?;
            cp.job.reached_limit = state.cursor.is_some() || !state.pending.is_empty();
            self.commit_discovery(cp, expected, token)?;
            Ok(cp.job.clone())
        })();
        if let Err(error) = &outcome {
            if error.code != "rss_history_paused" {
                // Persist only the last complete source boundary, including its backoff.
                let mut saved = decode(expected)?;
                saved.job.next_request_at = saved.job.next_request_at.max(cp.job.next_request_at);
                saved.job.message = Some(error.message.clone());
                self.commit_discovery(&mut saved, expected, token)?;
            }
        }
        outcome
    }
    pub fn history_list(&self) -> CommandResult<Vec<RssHistoryCheckpointSummary>> {
        let c = self.db.lock().map_err(|_| lock_err())?;
        let mut query = c
            .prepare("SELECT id,feed_id,payload FROM history_jobs ORDER BY feed_id,id LIMIT 21")
            .map_err(db_err)?;
        let rows = query
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            })
            .map_err(db_err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_err)?;
        if rows.len() > MAX_HISTORY_JOBS as usize {
            return Err(capacity());
        }
        rows.into_iter()
            .map(|(id, feed, raw)| {
                let mut cp = decode(&raw)?;
                hydrate_failures(&c, &mut cp)?;
                let j = cp.job;
                if j.id != id || j.feed_id != feed {
                    return Err(invalid());
                }
                let stale = binding(&c, &feed).map_or(true, |b| b != cp.binding);
                Ok(RssHistoryCheckpointSummary {
                    id,
                    feed_id: feed,
                    directory_url: j.directory_url,
                    status: j.status,
                    candidate_count: j.candidates.len(),
                    pending_count: j
                        .candidates
                        .iter()
                        .filter(|c| c.status == "pending")
                        .count(),
                    added_count: j.added_count,
                    duplicate_count: j.duplicate_count,
                    updated_count: j.updated_count,
                    failed_count: j.failed_count,
                    discovered_count: j.discovered_count,
                    has_more_discovery: j.has_more_discovery,
                    stale,
                    retrying_failures: j.retrying_failures,
                })
            })
            .collect()
    }
    pub fn history_clear(&self, job_id: String) -> CommandResult<()> {
        let c = self.db.lock().map_err(|_| lock_err())?;
        let tx = c.unchecked_transaction().map_err(db_err)?;
        let raw: String = tx
            .query_row(
                "SELECT payload FROM history_jobs WHERE id=?",
                [&job_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_err)?
            .ok_or_else(invalid)?;
        let cp = decode(&raw)?;
        if cp.job.id != job_id {
            return Err(invalid());
        }
        if cp.in_flight
            || cp.job.status == "running"
            || self
                .history_busy
                .lock()
                .map_err(|_| lock_err())?
                .contains(&cp.job.feed_id)
        {
            return Err(discovery_busy());
        }
        let changed = tx
            .execute(
                "DELETE FROM history_jobs WHERE id=? AND feed_id=? AND payload=?",
                params![job_id, cp.job.feed_id, raw],
            )
            .map_err(db_err)?;
        require_changed(
            changed,
            "rss_history_changed",
            "History checkpoint changed; review the queue again.",
        )?;
        tx.commit().map_err(db_err)
    }
}
fn validate_limits(token: &str, pages: usize, articles: usize) -> CommandResult<()> {
    Uuid::parse_str(token).map_err(|_| invalid())?;
    if !(1..=10).contains(&pages) || !(1..=500).contains(&articles) {
        return Err(invalid());
    }
    Ok(())
}
fn source_changed() -> CommandError {
    CommandError::new("rss_history_source_changed","Directory contents changed. Continuation stopped; explicitly clear this checkpoint and review a new range.")
}
