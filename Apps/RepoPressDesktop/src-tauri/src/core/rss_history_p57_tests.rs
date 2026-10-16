use super::super::*;

#[derive(Debug, PartialEq, Eq)]
struct ArticleSnapshot {
    id: String,
    feed_id: String,
    identity: String,
    guid: String,
    title: String,
    url: Option<String>,
    cover_url: Option<String>,
    author: Option<String>,
    summary: String,
    content: String,
    published: i64,
    fetched: i64,
    read: i64,
    read_at: Option<i64>,
    starred: i64,
    tags: String,
}

fn response(url: &Url, status: u16, body: &str) -> Response {
    Response {
        url: url.clone(),
        status: StatusCode::from_u16(status).unwrap(),
        headers: reqwest::header::HeaderMap::new(),
        body: body.as_bytes().to_vec(),
    }
}

fn response_at(request: &Url, resolved: &str, status: u16, body: &str) -> Response {
    let mut value = response(request, status, body);
    value.url = Url::parse(resolved).unwrap();
    value
}

fn new_store() -> (RssReaderStore, String) {
    let store = RssReaderStore::default();
    let feed = store
        .add_feed("https://example.com/feed".into(), Some("Example".into()))
        .unwrap();
    (store, feed.id)
}

fn discover_input(
    feed_id: &str,
    max_articles: usize,
    fill_existing: bool,
) -> RssHistoryDiscoverInput {
    RssHistoryDiscoverInput {
        discovery_id: Uuid::new_v4().to_string(),
        feed_id: feed_id.into(),
        directory_url: "https://example.com/archive".into(),
        max_pages: 10,
        max_articles,
        fill_existing,
    }
}

fn resume_input(job_id: &str, max_articles: usize) -> RssHistoryResumeInput {
    RssHistoryResumeInput {
        discovery_id: Uuid::new_v4().to_string(),
        job_id: job_id.into(),
        max_pages: 10,
        max_articles,
    }
}

fn archive_body(paths: &[String], next: Option<&str>) -> String {
    let articles = paths
        .iter()
        .map(|path| format!("<article><a href='{path}'>Article {path}</a></article>"))
        .collect::<String>();
    let next = next
        .map(|path| format!("<a rel='next' href='{path}'>Next</a>"))
        .unwrap_or_default();
    format!("<main>{articles}{next}</main>")
}

fn article_page(title: &str, canonical: Option<&str>) -> String {
    let canonical = canonical
        .map(|url| format!("<link rel='canonical' href='{url}'>"))
        .unwrap_or_default();
    format!(
        "<html><head><title>{title}</title>{canonical}</head><article><p>{}</p></article></html>",
        format!("{title} complete public article content. ").repeat(12)
    )
}

fn discover_from_body(
    store: &RssReaderStore,
    feed_id: &str,
    body: &str,
    max_articles: usize,
    fill_existing: bool,
) -> RssHistoryJob {
    store
        .history_discover_with(
            discover_input(feed_id, max_articles, fill_existing),
            |url| {
                Ok(match url.path() {
                    "/robots.txt" | "/sitemap.xml" => response(url, 404, ""),
                    "/archive" => response(url, 200, body),
                    path => panic!("unexpected discovery request: {path}"),
                })
            },
        )
        .unwrap()
}

fn ready(store: &RssReaderStore, job_id: &str) {
    let connection = store.db.lock().unwrap();
    let mut checkpoint = load(&connection, job_id).unwrap();
    checkpoint.job.next_request_at = 0;
    save(&connection, &checkpoint).unwrap();
}

fn mark_segment_added(store: &RssReaderStore, job_id: &str) {
    let connection = store.db.lock().unwrap();
    let mut checkpoint = load(&connection, job_id).unwrap();
    for candidate in &mut checkpoint.job.candidates {
        candidate.status = "added".into();
    }
    checkpoint.job.added_count = checkpoint.job.candidates.len();
    checkpoint.job.duplicate_count = 0;
    checkpoint.job.updated_count = 0;
    checkpoint.job.failed_count = 0;
    checkpoint.job.status = "complete".into();
    checkpoint.job.next_request_at = 0;
    checkpoint.in_flight = false;
    save(&connection, &checkpoint).unwrap();
}

fn insert_existing(
    store: &RssReaderStore,
    feed_id: &str,
    id: &str,
    url: &str,
    summary: &str,
    content: &str,
) {
    let connection = store.db.lock().unwrap();
    connection
        .execute(
            "INSERT INTO articles(id,feed_id,identity,guid,title,url,cover_url,author,summary,content,published,fetched,read,read_at,starred,tags) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            params![
                id,
                feed_id,
                format!("identity-{id}"),
                format!("guid-{id}"),
                format!("Local {id}"),
                url,
                format!("https://example.com/{id}.jpg"),
                "Local author",
                summary,
                content,
                123_i64,
                456_i64,
                1_i64,
                789_i64,
                1_i64,
                "[\"keep\"]"
            ],
        )
        .unwrap();
}

fn insert_ready_cache(store: &RssReaderStore, article_id: &str, source_url: &str, marker: &str) {
    let connection = store.db.lock().unwrap();
    connection
        .execute(
            "INSERT INTO full_text_cache(article_id,status,content_html,plain_text,source_url,resolved_url,source_content_hash,confidence,attempted_at,retry_after) VALUES(?,'ready',?,?,?,?,?,?,?,0) ON CONFLICT(article_id) DO UPDATE SET status='ready',content_html=excluded.content_html,plain_text=excluded.plain_text,source_url=excluded.source_url,resolved_url=excluded.resolved_url,source_content_hash=excluded.source_content_hash,confidence=excluded.confidence,attempted_at=excluded.attempted_at,retry_after=0,failure_message=NULL",
            params![
                article_id,
                format!("<main>{marker}</main>"),
                marker,
                source_url,
                source_url,
                format!("hash-{marker}"),
                900_i64,
                222_i64
            ],
        )
        .unwrap();
}

fn article_snapshot(store: &RssReaderStore, id: &str) -> ArticleSnapshot {
    let connection = store.db.lock().unwrap();
    connection
        .query_row(
            "SELECT id,feed_id,identity,guid,title,url,cover_url,author,summary,content,published,fetched,read,read_at,starred,tags FROM articles WHERE id=?",
            [id],
            |row| {
                Ok(ArticleSnapshot {
                    id: row.get(0)?,
                    feed_id: row.get(1)?,
                    identity: row.get(2)?,
                    guid: row.get(3)?,
                    title: row.get(4)?,
                    url: row.get(5)?,
                    cover_url: row.get(6)?,
                    author: row.get(7)?,
                    summary: row.get(8)?,
                    content: row.get(9)?,
                    published: row.get(10)?,
                    fetched: row.get(11)?,
                    read: row.get(12)?,
                    read_at: row.get(13)?,
                    starred: row.get(14)?,
                    tags: row.get(15)?,
                })
            },
        )
        .unwrap()
}

fn scalar(store: &RssReaderStore, sql: &str) -> i64 {
    let connection = store.db.lock().unwrap();
    connection.query_row(sql, [], |row| row.get(0)).unwrap()
}

fn cache_marker(store: &RssReaderStore, article_id: &str) -> Option<(String, String, String)> {
    let connection = store.db.lock().unwrap();
    connection
        .query_row(
            "SELECT status,coalesce(plain_text,''),coalesce(source_url,'') FROM full_text_cache WHERE article_id=?",
            [article_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .unwrap()
}

#[test]
fn legacy_json_defaults_fill_mode_candidate_kind_and_checkpoint_fields() {
    let input: RssHistoryDiscoverInput = serde_json::from_value(serde_json::json!({
        "discoveryId": Uuid::new_v4().to_string(),
        "feedId": "feed",
        "directoryUrl": "https://example.com/archive",
        "maxPages": 1,
        "maxArticles": 1
    }))
    .unwrap();
    assert!(!input.fill_existing);
    let candidate: RssHistoryCandidate = serde_json::from_value(serde_json::json!({
        "url": "https://example.com/old",
        "title": "Old",
        "status": "pending",
        "message": null
    }))
    .unwrap();
    assert_eq!(candidate.kind, "article");

    let (store, feed_id) = new_store();
    let job = discover_from_body(
        &store,
        &feed_id,
        &archive_body(&["/old".into()], None),
        1,
        false,
    );
    let connection = store.db.lock().unwrap();
    let raw: String = connection
        .query_row(
            "SELECT payload FROM history_jobs WHERE id=?",
            [&job.id],
            |row| row.get(0),
        )
        .unwrap();
    let mut json: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let root = json.as_object_mut().unwrap();
    root.remove("discovery");
    root.remove("totals");
    root.remove("targets");
    let saved_job = root.get_mut("job").unwrap().as_object_mut().unwrap();
    for field in [
        "updatedCount",
        "discoveredCount",
        "hasMoreDiscovery",
        "fillExisting",
    ] {
        saved_job.remove(field);
    }
    saved_job
        .get_mut("candidates")
        .unwrap()
        .as_array_mut()
        .unwrap()[0]
        .as_object_mut()
        .unwrap()
        .remove("kind");
    connection
        .execute(
            "UPDATE history_jobs SET payload=? WHERE id=?",
            params![serde_json::to_string(&json).unwrap(), job.id],
        )
        .unwrap();
    drop(connection);
    let loaded = store.history_status(feed_id).unwrap().unwrap();
    assert!(!loaded.fill_existing);
    assert_eq!(loaded.updated_count, 0);
    assert_eq!(loaded.candidates[0].kind, "article");
}

#[test]
fn resume_over_five_hundred_survives_restart_and_keeps_cumulative_counts() {
    let temp = tempfile::tempdir().unwrap();
    let store = RssReaderStore::new(temp.path().into()).unwrap();
    let feed_id = store
        .add_feed("https://example.com/feed".into(), None)
        .unwrap()
        .id;
    let paths = (1..=505)
        .map(|index| format!("/article-{index:04}"))
        .collect::<Vec<_>>();
    let body = archive_body(&paths, None);
    let job = discover_from_body(&store, &feed_id, &body, 500, false);
    assert_eq!(job.candidates.len(), 500);
    assert_eq!(job.discovered_count, 500);
    assert!(job.has_more_discovery);
    {
        let connection = store.db.lock().unwrap();
        let checkpoint = load(&connection, &job.id).unwrap();
        let cursor = checkpoint.discovery.unwrap().cursor.unwrap();
        assert_eq!(cursor.url, "https://example.com/archive");
        assert_eq!(cursor.offset, 500);
        assert!(!cursor.fingerprint.is_empty());
    }
    mark_segment_added(&store, &job.id);
    drop(store);

    let reopened = RssReaderStore::new(temp.path().into()).unwrap();
    let loaded = reopened.history_status(feed_id).unwrap().unwrap();
    assert_eq!(loaded.candidates.len(), 500);
    let mut requests = Vec::new();
    let resumed = reopened
        .history_resume_discovery_with(resume_input(&job.id, 500), |url| {
            requests.push(url.to_string());
            Ok(match url.path() {
                "/robots.txt" | "/sitemap.xml" => response(url, 404, ""),
                "/archive" => response(url, 200, &body),
                path => panic!("unexpected resume request: {path}"),
            })
        })
        .unwrap();
    assert!(
        !requests.is_empty(),
        "resume is the explicit network action"
    );
    assert_eq!(resumed.candidates.len(), 5);
    assert_eq!(resumed.discovered_count, 505);
    assert_eq!(resumed.added_count, 500);
    assert!(!resumed.has_more_discovery);
}

#[test]
fn restart_after_initial_robots_failure_does_not_skip_sitemap_initialization() {
    let temp = tempfile::tempdir().unwrap();
    let store = RssReaderStore::new(temp.path().into()).unwrap();
    let feed_id = store
        .add_feed("https://example.com/feed".into(), None)
        .unwrap()
        .id;
    let input = discover_input(&feed_id, 10, false);
    let failed = store.history_discover_with(input, |url| {
        assert_eq!(url.path(), "/robots.txt");
        Err(CommandError::new(
            "rss_history_unavailable",
            "simulated robots failure",
        ))
    });
    assert!(failed.is_err());
    let job = store.history_status(feed_id.clone()).unwrap().unwrap();
    assert!(job.candidates.is_empty());
    assert!(job.has_more_discovery);
    drop(store);

    let reopened = RssReaderStore::new(temp.path().into()).unwrap();
    let sitemap = "<?xml version='1.0'?><urlset><url><loc>https://example.com/from-sitemap</loc></url></urlset>";
    let mut requests = Vec::new();
    let resumed = reopened
        .history_resume_discovery_with(resume_input(&job.id, 10), |url| {
            requests.push(url.path().to_string());
            Ok(match url.path() {
                "/robots.txt" => response(url, 404, ""),
                "/archive" => response(url, 200, "<main></main>"),
                "/sitemap.xml" => response(url, 200, sitemap),
                path => panic!("unexpected recovery request: {path}"),
            })
        })
        .unwrap();
    assert!(
        requests.iter().any(|path| path == "/sitemap.xml"),
        "a durable pre-source checkpoint must retain or reconstruct sitemap initialization"
    );
    assert_eq!(resumed.candidates.len(), 1);
    assert_eq!(
        resumed.candidates[0].url,
        "https://example.com/from-sitemap"
    );
}

#[test]
fn resume_rejects_article_order_next_link_and_resolved_url_drift_without_skipping() {
    let original = archive_body(&["/a".into(), "/b".into(), "/c".into()], Some("/page-2"));
    let cases = [
        (
            "article order",
            archive_body(&["/new".into(), "/b".into(), "/c".into()], Some("/page-2")),
            "https://example.com/archive",
        ),
        (
            "next link",
            archive_body(&["/a".into(), "/b".into(), "/c".into()], Some("/changed")),
            "https://example.com/archive",
        ),
        (
            "resolved URL",
            original.clone(),
            "https://example.com/moved-archive",
        ),
    ];
    for (label, changed, resolved) in cases {
        let (store, feed_id) = new_store();
        let job = discover_from_body(&store, &feed_id, &original, 2, false);
        mark_segment_added(&store, &job.id);
        let before = {
            let connection = store.db.lock().unwrap();
            let checkpoint = load(&connection, &job.id).unwrap();
            let cursor = checkpoint
                .discovery
                .as_ref()
                .unwrap()
                .cursor
                .as_ref()
                .unwrap();
            (cursor.offset, cursor.fingerprint.clone())
        };
        let error = store
            .history_resume_discovery_with(resume_input(&job.id, 2), |url| {
                Ok(match url.path() {
                    "/archive" => response_at(url, resolved, 200, &changed),
                    "/robots.txt" | "/sitemap.xml" => response(url, 404, ""),
                    path => panic!("unexpected {label} request: {path}"),
                })
            })
            .unwrap_err();
        assert_eq!(
            error.code, "rss_history_source_changed",
            "{label} drift must fail closed with an actionable cursor error: {error:?}"
        );
        let connection = store.db.lock().unwrap();
        let checkpoint = load(&connection, &job.id).unwrap();
        let cursor = checkpoint
            .discovery
            .as_ref()
            .unwrap()
            .cursor
            .as_ref()
            .unwrap();
        assert_eq!(
            (cursor.offset, cursor.fingerprint.clone()),
            before,
            "{label}"
        );
        assert_eq!(checkpoint.job.discovered_count, 2, "{label}");
        assert_eq!(checkpoint.job.added_count, 2, "{label}");
    }
}

#[test]
fn cancellation_after_a_source_commit_keeps_the_durable_discovery_checkpoint() {
    let (store, feed_id) = new_store();
    let token = Uuid::new_v4().to_string();
    let input = RssHistoryDiscoverInput {
        discovery_id: token.clone(),
        feed_id: feed_id.clone(),
        directory_url: "https://example.com/archive".into(),
        max_pages: 10,
        max_articles: 500,
        fill_existing: false,
    };
    let first = archive_body(&["/a".into()], Some("/page-2"));
    let error = store
        .history_discover_with(input, |url| {
            Ok(match url.path() {
                "/robots.txt" => response(url, 404, ""),
                "/archive" => response(url, 200, &first),
                "/sitemap.xml" => {
                    store.history_cancel_discovery(token.clone()).unwrap();
                    response(url, 404, "")
                }
                path => panic!("request after cancellation: {path}"),
            })
        })
        .unwrap_err();
    assert_eq!(error.code, "rss_history_paused");
    let saved = store.history_status(feed_id).unwrap().unwrap();
    assert_eq!(saved.candidates.len(), 1);
    assert_eq!(saved.candidates[0].url, "https://example.com/a");
    assert_eq!(saved.discovered_count, 1);
    assert!(saved.has_more_discovery);
}

#[test]
fn failed_candidates_survive_discovery_resume_and_can_be_retried_after_later_work() {
    let (store, feed_id) = new_store();
    let body = archive_body(&["/a".into(), "/b".into(), "/c".into()], None);
    let job = discover_from_body(&store, &feed_id, &body, 2, false);
    ready(&store, &job.id);
    let first = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id.clone(),
                retry_failures: false,
            },
            |url| Ok(response(url, 200, &article_page("A", None))),
        )
        .unwrap();
    assert_eq!(first.added_count, 1);
    ready(&store, &job.id);
    let failed = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id.clone(),
                retry_failures: false,
            },
            |url| Ok(response(url, 404, "")),
        )
        .unwrap();
    assert_eq!(failed.failed_count, 1);
    ready(&store, &job.id);
    let resumed = store
        .history_resume_discovery_with(resume_input(&job.id, 2), |url| {
            Ok(match url.path() {
                "/archive" => response(url, 200, &body),
                "/robots.txt" | "/sitemap.xml" => response(url, 404, ""),
                path => panic!("unexpected resume request: {path}"),
            })
        })
        .unwrap();
    assert_eq!(resumed.candidates.len(), 1);
    assert_eq!(resumed.candidates[0].url, "https://example.com/c");
    assert_eq!(resumed.failed_count, 1);
    assert_eq!(resumed.added_count, 1);
    assert_eq!(resumed.discovered_count, 3);

    ready(&store, &job.id);
    let later = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id.clone(),
                retry_failures: false,
            },
            |url| Ok(response(url, 200, &article_page("C", None))),
        )
        .unwrap();
    assert_eq!(later.failed_count, 1);
    assert_eq!(later.added_count, 2);
    assert_eq!(later.discovered_count, 3);

    let retry = store
        .history_prepare_retry(RssHistoryRetryInput {
            job_id: job.id.clone(),
            max_articles: 2,
        })
        .unwrap();
    assert!(retry.retrying_failures);
    assert_eq!(retry.candidates.len(), 1);
    assert_eq!(retry.candidates[0].url, "https://example.com/b");
    assert_eq!(retry.discovered_count, 3);
    ready(&store, &job.id);
    let retried = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |url| Ok(response(url, 200, &article_page("B", None))),
        )
        .unwrap();
    assert_eq!(retried.failed_count, 0);
    assert_eq!(retried.added_count, 3);
    assert_eq!(retried.discovered_count, 3);
}

#[test]
fn step_nonce_rejects_a_paused_request_after_the_same_candidate_is_reclaimed() {
    let (store, feed_id) = new_store();
    let job = discover_from_body(
        &store,
        &feed_id,
        &archive_body(&["/old".into()], None),
        1,
        false,
    );
    ready(&store, &job.id);
    let outer = store.history_step_with(
        RssHistoryStepInput {
            job_id: job.id.clone(),
            retry_failures: false,
        },
        |url| {
            store.history_pause(job.id.clone()).unwrap();
            ready(&store, &job.id);
            let reclaimed = store
                .history_step_with(
                    RssHistoryStepInput {
                        job_id: job.id.clone(),
                        retry_failures: false,
                    },
                    |nested_url| {
                        assert_eq!(nested_url, url);
                        Ok(response(nested_url, 200, &article_page("Reclaimed", None)))
                    },
                )
                .unwrap();
            assert_eq!(reclaimed.added_count, 1);
            Ok(response(url, 200, &article_page("Stale outer", None)))
        },
    );
    assert_eq!(outer.unwrap_err().code, "rss_history_paused");
    let connection = store.db.lock().unwrap();
    let content: String = connection
        .query_row("SELECT content FROM articles", [], |row| row.get(0))
        .unwrap();
    assert!(content.contains("Reclaimed"));
    assert!(!content.contains("Stale outer"));
}

#[test]
fn existing_summary_full_text_is_opt_in_and_preserves_all_article_state() {
    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "existing",
        "https://example.com/old",
        "Feed summary",
        "",
    );
    {
        let connection = store.db.lock().unwrap();
        connection
            .execute(
                "INSERT INTO highlights(id,article_id,text,note,tags,created_at,updated_at) VALUES('highlight','existing','quote','note','[\"local\"]',1,2)",
                [],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO reading_progress(article_id,progress,revision,updated_at) VALUES('existing',0.5,7,3)",
                [],
            )
            .unwrap();
    }
    let body = archive_body(&["/old".into()], None);
    let no_fill = discover_from_body(&store, &feed_id, &body, 1, false);
    assert_eq!(no_fill.candidates[0].status, "duplicate");
    assert_eq!(no_fill.candidates[0].kind, "article");
    ready(&store, &no_fill.id);
    store
        .history_step_with(
            RssHistoryStepInput {
                job_id: no_fill.id.clone(),
                retry_failures: false,
            },
            |_| panic!("fill_existing=false must never fetch an existing article"),
        )
        .unwrap();
    store.history_clear(no_fill.id).unwrap();

    let before = article_snapshot(&store, "existing");
    let fill = discover_from_body(&store, &feed_id, &body, 1, true);
    assert_eq!(fill.candidates[0].kind, "fullText");
    assert_eq!(fill.candidates[0].status, "pending");
    ready(&store, &fill.id);
    let updated = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: fill.id.clone(),
                retry_failures: false,
            },
            |url| Ok(response(url, 200, &article_page("Remote", None))),
        )
        .unwrap();
    assert_eq!(updated.added_count, 0);
    assert_eq!(updated.updated_count, 1);
    assert_eq!(updated.candidates[0].status, "updated");
    assert_eq!(article_snapshot(&store, "existing"), before);
    assert_eq!(scalar(&store, "SELECT count(*) FROM highlights WHERE id='highlight' AND text='quote' AND note='note' AND tags='[\"local\"]'"), 1);
    assert_eq!(scalar(&store, "SELECT count(*) FROM reading_progress WHERE article_id='existing' AND progress=0.5 AND revision=7"), 1);
    let cache = cache_marker(&store, "existing").unwrap();
    assert_eq!(cache.0, "ready");
    assert!(cache.1.contains("Remote complete public article"));
    assert_eq!(cache.2, "https://example.com/old");
}

#[test]
fn same_source_ready_full_text_is_reused_without_request_or_overwrite() {
    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "existing",
        "https://example.com/old",
        "Feed summary",
        "",
    );
    insert_ready_cache(
        &store,
        "existing",
        "https://example.com/old",
        "preserved ready text",
    );
    let body = archive_body(&["/old".into()], None);
    let job = discover_from_body(&store, &feed_id, &body, 1, true);
    assert!(!job
        .candidates
        .iter()
        .any(|candidate| candidate.status == "pending"));
    ready(&store, &job.id);
    store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |_| panic!("a same-source ready cache must be reused"),
        )
        .unwrap();
    assert_eq!(
        cache_marker(&store, "existing"),
        Some((
            "ready".into(),
            "preserved ready text".into(),
            "https://example.com/old".into()
        ))
    );
}

#[test]
fn same_source_ready_status_is_authoritative_even_if_restored_body_is_empty() {
    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "existing",
        "https://example.com/old",
        "Feed summary",
        "",
    );
    insert_ready_cache(
        &store,
        "existing",
        "https://example.com/old",
        "temporary body",
    );
    store
        .db
        .lock()
        .unwrap()
        .execute(
            "UPDATE full_text_cache SET content_html='',plain_text='' WHERE article_id='existing'",
            [],
        )
        .unwrap();

    let body = archive_body(&["/old".into()], None);
    let job = discover_from_body(&store, &feed_id, &body, 1, true);
    assert!(!job
        .candidates
        .iter()
        .any(|candidate| candidate.status == "pending"));
    ready(&store, &job.id);
    store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |_| panic!("a same-source ready status must suppress history refetch"),
        )
        .unwrap();
    assert_eq!(
        cache_marker(&store, "existing"),
        Some((
            "ready".into(),
            String::new(),
            "https://example.com/old".into()
        ))
    );
}

#[test]
fn failed_full_text_refresh_preserves_an_existing_ready_cache() {
    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "existing",
        "https://example.com/old",
        "Feed summary",
        "",
    );
    insert_ready_cache(
        &store,
        "existing",
        "https://example.com/former-source",
        "last known ready text",
    );
    let body = archive_body(&["/old".into()], None);
    let job = discover_from_body(&store, &feed_id, &body, 1, true);
    assert_eq!(job.candidates[0].kind, "fullText");
    ready(&store, &job.id);
    let failed = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |url| Ok(response(url, 404, "")),
        )
        .unwrap();
    assert_eq!(failed.candidates[0].status, "failed");
    assert_eq!(
        cache_marker(&store, "existing"),
        Some((
            "ready".into(),
            "last known ready text".into(),
            "https://example.com/former-source".into(),
        ))
    );
}

#[test]
fn existing_target_or_cache_drift_cannot_overwrite_concurrent_state() {
    let body = archive_body(&["/old".into()], None);

    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "existing",
        "https://example.com/old",
        "Summary",
        "",
    );
    let job = discover_from_body(&store, &feed_id, &body, 1, true);
    ready(&store, &job.id);
    let result = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |url| {
                let connection = store.db.lock().unwrap();
                connection
                    .execute(
                        "UPDATE articles SET title='Concurrent title',url='https://example.com/moved' WHERE id='existing'",
                        [],
                    )
                    .unwrap();
                drop(connection);
                Ok(response(url, 200, &article_page("Remote", None)))
            },
        )
        .unwrap();
    assert_eq!(
        result.candidates[0].status, "failed",
        "target drift must invalidate the in-flight result"
    );
    assert_eq!(cache_marker(&store, "existing"), None);
    assert_eq!(
        article_snapshot(&store, "existing").title,
        "Concurrent title"
    );

    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "existing",
        "https://example.com/old",
        "Summary",
        "",
    );
    let job = discover_from_body(&store, &feed_id, &body, 1, true);
    ready(&store, &job.id);
    let _ = store.history_step_with(
        RssHistoryStepInput {
            job_id: job.id,
            retry_failures: false,
        },
        |url| {
            insert_ready_cache(
                &store,
                "existing",
                "https://example.com/old",
                "concurrent ready text",
            );
            Ok(response(url, 200, &article_page("Must not win", None)))
        },
    );
    assert_eq!(
        cache_marker(&store, "existing"),
        Some((
            "ready".into(),
            "concurrent ready text".into(),
            "https://example.com/old".into()
        ))
    );
}

#[test]
fn slash_alias_requires_shared_redirect_or_canonical_evidence_and_preserves_original() {
    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "original",
        "https://example.com//old",
        "Local summary",
        "<p>A locally complete article body.</p>",
    );
    let before = article_snapshot(&store, "original");
    let body = archive_body(&["/old".into()], None);
    let job = discover_from_body(&store, &feed_id, &body, 1, false);
    ready(&store, &job.id);
    let mut requests = Vec::new();
    let done = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |url| {
                requests.push(url.to_string());
                Ok(match url.path() {
                    "/old" => response(url, 200, &article_page("Candidate", Some("/old"))),
                    "//old" => response(url, 200, &article_page("Original", Some("/old"))),
                    path => panic!("unexpected alias request: {path}"),
                })
            },
        )
        .unwrap();
    assert_eq!(requests.len(), 2);
    assert_eq!(done.duplicate_count, 1);
    assert_eq!(scalar(&store, "SELECT count(*) FROM articles"), 1);
    assert_eq!(article_snapshot(&store, "original"), before);
}

#[test]
fn slash_hint_without_evidence_stays_distinct_and_checks_at_most_two_old_urls() {
    let (store, feed_id) = new_store();
    for (id, url) in [
        ("one", "https://example.com//old"),
        ("two", "https://example.com///old"),
        ("three", "https://example.com/old/"),
    ] {
        insert_existing(
            &store,
            &feed_id,
            id,
            url,
            "Local summary",
            "<p>A locally complete body.</p>",
        );
    }
    let body = archive_body(&["/old".into()], None);
    let job = discover_from_body(&store, &feed_id, &body, 1, false);
    ready(&store, &job.id);
    let mut requests = Vec::new();
    let done = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |url| {
                requests.push(url.to_string());
                Ok(response(
                    url,
                    200,
                    &article_page("No shared identity", None),
                ))
            },
        )
        .unwrap();
    let old_requests = requests
        .iter()
        .filter(|url| url.as_str() != "https://example.com/old")
        .count();
    assert!(
        old_requests <= 2,
        "slash hints must not cause an unbounded fan-out: {requests:?}"
    );
    assert_eq!(done.added_count, 1);
    assert_eq!(scalar(&store, "SELECT count(*) FROM articles"), 4);
}

#[test]
fn slash_alias_probes_honor_robots_noarchive_and_same_origin() {
    let body = archive_body(&["/old".into()], None);

    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "original",
        "https://example.com//old",
        "Local summary",
        "<p>A locally complete body.</p>",
    );
    let job = discover_from_body(&store, &feed_id, &body, 1, false);
    {
        let connection = store.db.lock().unwrap();
        let mut checkpoint = load(&connection, &job.id).unwrap();
        checkpoint.robots = "User-agent: *\nDisallow: //old".into();
        checkpoint.robots_at = now();
        checkpoint.job.next_request_at = 0;
        save(&connection, &checkpoint).unwrap();
    }
    let mut requests = Vec::new();
    let done = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |url| {
                requests.push(url.to_string());
                assert_eq!(url.path(), "/old", "robots-disallowed alias contacted");
                Ok(response(url, 200, &article_page("Candidate", None)))
            },
        )
        .unwrap();
    assert_eq!(requests, ["https://example.com/old"]);
    assert_eq!(done.added_count, 1);
    assert_eq!(scalar(&store, "SELECT count(*) FROM articles"), 2);

    for boundary in ["noarchive", "cross-origin"] {
        let (store, feed_id) = new_store();
        insert_existing(
            &store,
            &feed_id,
            "original",
            "https://example.com//old",
            "Local summary",
            "<p>A locally complete body.</p>",
        );
        let before = article_snapshot(&store, "original");
        let job = discover_from_body(&store, &feed_id, &body, 1, false);
        ready(&store, &job.id);
        let done = store
            .history_step_with(
                RssHistoryStepInput {
                    job_id: job.id,
                    retry_failures: false,
                },
                |url| match url.path() {
                    "/old" => Ok(response(url, 200, &article_page("Candidate", None))),
                    "//old" if boundary == "noarchive" => {
                        let mut value = response(url, 200, &article_page("Old", Some("/old")));
                        value
                            .headers
                            .insert("x-robots-tag", "noarchive".parse().unwrap());
                        Ok(value)
                    }
                    "//old" => Ok(response_at(
                        url,
                        "https://other.invalid/old",
                        200,
                        &article_page("Old", Some("https://example.com/old")),
                    )),
                    path => panic!("unexpected {boundary} alias request: {path}"),
                },
            )
            .unwrap();
        assert_eq!(done.candidates[0].status, "failed", "{boundary}");
        assert_eq!(done.duplicate_count, 0, "{boundary}");
        assert_eq!(
            scalar(&store, "SELECT count(*) FROM articles"),
            1,
            "{boundary}"
        );
        assert_eq!(article_snapshot(&store, "original"), before, "{boundary}");
    }
}

#[test]
fn clear_is_compare_delete_rejects_active_jobs_preserves_data_and_releases_capacity() {
    let (store, feed_id) = new_store();
    insert_existing(
        &store,
        &feed_id,
        "existing",
        "https://example.com/existing",
        "summary",
        "<p>body</p>",
    );
    insert_ready_cache(&store, "existing", "https://example.com/existing", "cached");
    {
        let connection = store.db.lock().unwrap();
        connection.execute("INSERT INTO highlights(id,article_id,text,note,created_at,updated_at) VALUES('h','existing','quote','note',1,2)", []).unwrap();
        connection.execute("INSERT INTO reading_progress(article_id,progress,revision,updated_at) VALUES('existing',0.25,3,4)", []).unwrap();
    }
    let before = article_snapshot(&store, "existing");
    let job = discover_from_body(
        &store,
        &feed_id,
        &archive_body(&["/old".into()], None),
        1,
        false,
    );
    assert!(store.history_clear(Uuid::new_v4().to_string()).is_err());
    {
        let connection = store.db.lock().unwrap();
        let mut checkpoint = load(&connection, &job.id).unwrap();
        checkpoint.job.status = "running".into();
        checkpoint.in_flight = true;
        save(&connection, &checkpoint).unwrap();
    }
    assert!(store.history_clear(job.id.clone()).is_err());
    {
        let connection = store.db.lock().unwrap();
        let mut checkpoint = load(&connection, &job.id).unwrap();
        checkpoint.job.status = "paused".into();
        checkpoint.in_flight = false;
        save(&connection, &checkpoint).unwrap();
    }
    store.history_busy.lock().unwrap().insert(feed_id.clone());
    assert!(store.history_clear(job.id.clone()).is_err());
    store.history_busy.lock().unwrap().remove(&feed_id);
    store
        .update_feed_url(feed_id.clone(), "https://example.com/changed-feed".into())
        .unwrap();
    let summary = store
        .history_list()
        .unwrap()
        .into_iter()
        .find(|value| value.id == job.id)
        .unwrap();
    assert!(summary.stale);
    store.history_clear(job.id).unwrap();
    assert!(store.history_status(feed_id).unwrap().is_none());
    assert_eq!(article_snapshot(&store, "existing"), before);
    assert_eq!(scalar(&store, "SELECT count(*) FROM full_text_cache WHERE article_id='existing' AND plain_text='cached'"), 1);
    assert_eq!(
        scalar(&store, "SELECT count(*) FROM highlights WHERE id='h'"),
        1
    );
    assert_eq!(
        scalar(
            &store,
            "SELECT count(*) FROM reading_progress WHERE article_id='existing' AND revision=3"
        ),
        1
    );

    let store = RssReaderStore::default();
    let mut jobs = Vec::new();
    for index in 0..MAX_HISTORY_JOBS {
        let feed = store
            .add_feed(format!("https://example.com/feed-{index}"), None)
            .unwrap();
        let body = archive_body(&[format!("/article-{index}")], None);
        jobs.push(discover_from_body(&store, &feed.id, &body, 1, false));
    }
    let overflow_feed = store
        .add_feed("https://example.com/feed-overflow".into(), None)
        .unwrap();
    let mut requests = 0;
    let overflow = store.history_discover_with(discover_input(&overflow_feed.id, 1, false), |_| {
        requests += 1;
        panic!("capacity must be rejected before network contact")
    });
    assert!(overflow.is_err());
    assert_eq!(requests, 0);
    store.history_clear(jobs[0].id.clone()).unwrap();
    let replacement = discover_from_body(
        &store,
        &overflow_feed.id,
        &archive_body(&["/replacement".into()], None),
        1,
        false,
    );
    assert!(!replacement.id.is_empty());
    assert_eq!(
        store.history_list().unwrap().len(),
        MAX_HISTORY_JOBS as usize
    );
}

#[test]
fn fresh_discovery_requires_explicit_clear_instead_of_overwriting_checkpoint() {
    let (store, feed_id) = new_store();
    let body = archive_body(&["/old".into()], None);
    let first = discover_from_body(&store, &feed_id, &body, 1, false);
    let mut requests = 0;
    let replacement = store.history_discover_with(discover_input(&feed_id, 1, false), |_| {
        requests += 1;
        panic!("an existing checkpoint must be rejected before network")
    });
    assert!(replacement.is_err());
    assert_eq!(requests, 0);
    assert_eq!(
        store.history_status(feed_id.clone()).unwrap().unwrap().id,
        first.id
    );
    store.history_clear(first.id).unwrap();
    let second = discover_from_body(&store, &feed_id, &body, 1, false);
    assert!(!second.id.is_empty());
}
