use super::super::*;

fn response(url: &Url, status: u16, body: &str) -> Response {
    Response {
        url: url.clone(),
        status: StatusCode::from_u16(status).unwrap(),
        headers: reqwest::header::HeaderMap::new(),
        body: body.as_bytes().to_vec(),
    }
}

fn article_page(title: &str) -> String {
    format!(
        "<html><title>{title}</title><article><p>{}</p></article></html>",
        format!("{title} complete public article content. ").repeat(12)
    )
}

fn archive_body(paths: &[String]) -> String {
    paths
        .iter()
        .map(|path| format!("<article><a href='{path}'>Article {path}</a></article>"))
        .collect::<String>()
}

fn new_store() -> (RssReaderStore, String) {
    let store = RssReaderStore::default();
    let feed_id = store
        .add_feed("https://example.com/feed".into(), Some("Example".into()))
        .unwrap()
        .id;
    (store, feed_id)
}

fn discover(
    store: &RssReaderStore,
    feed_id: &str,
    paths: &[String],
    fill_existing: bool,
) -> RssHistoryJob {
    let body = archive_body(paths);
    store
        .history_discover_with(
            RssHistoryDiscoverInput {
                discovery_id: Uuid::new_v4().to_string(),
                feed_id: feed_id.into(),
                directory_url: "https://example.com/archive".into(),
                max_pages: 2,
                max_articles: 500,
                fill_existing,
            },
            |url| {
                Ok(match url.path() {
                    "/robots.txt" | "/sitemap.xml" => response(url, 404, ""),
                    "/archive" => response(url, 200, &body),
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

fn fail_current(store: &RssReaderStore, job_id: &str) -> RssHistoryJob {
    ready(store, job_id);
    store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job_id.into(),
                retry_failures: false,
            },
            |url| Ok(response(url, 404, "")),
        )
        .unwrap()
}

fn settle_pending_as_failed(store: &RssReaderStore, job_id: &str) {
    let connection = store.db.lock().unwrap();
    let transaction = connection.unchecked_transaction().unwrap();
    let mut checkpoint = load(&transaction, job_id).unwrap();
    for candidate in &mut checkpoint.job.candidates {
        if candidate.status == "pending" {
            candidate.status = "failed".into();
            candidate.message = Some("persistent test failure".into());
        }
    }
    checkpoint.in_flight = false;
    checkpoint.job.next_request_at = 0;
    recount(&mut checkpoint);
    save_progress(&transaction, &mut checkpoint).unwrap();
    transaction.commit().unwrap();
}

fn failure_rows(store: &RssReaderStore, job_id: &str) -> i64 {
    let connection = store.db.lock().unwrap();
    connection
        .query_row(
            "SELECT count(*) FROM history_failures WHERE job_id=?",
            [job_id],
            |row| row.get(0),
        )
        .unwrap()
}

fn raw_checkpoint(store: &RssReaderStore, job_id: &str) -> String {
    let connection = store.db.lock().unwrap();
    connection
        .query_row(
            "SELECT payload FROM history_jobs WHERE id=?",
            [job_id],
            |row| row.get(0),
        )
        .unwrap()
}

fn insert_existing(store: &RssReaderStore, feed_id: &str) {
    store
        .db
        .lock()
        .unwrap()
        .execute(
            "INSERT INTO articles(id,feed_id,identity,guid,title,url,summary,content,published,fetched) VALUES('existing',?,'existing-identity','existing-guid','Existing','https://example.com/old','Feed summary','',1,1)",
            [feed_id],
        )
        .unwrap();
}

fn insert_ready_cache(store: &RssReaderStore, source_url: &str, marker: &str) {
    store
        .db
        .lock()
        .unwrap()
        .execute(
            "INSERT INTO full_text_cache(article_id,status,content_html,plain_text,source_url,resolved_url,source_content_hash,confidence,attempted_at,retry_after) VALUES('existing','ready',?,?,?,?,?,900,1,0) ON CONFLICT(article_id) DO UPDATE SET status='ready',content_html=excluded.content_html,plain_text=excluded.plain_text,source_url=excluded.source_url,resolved_url=excluded.resolved_url,source_content_hash=excluded.source_content_hash,confidence=900,attempted_at=1,retry_after=0,failure_message=NULL",
            params![
                format!("<main>{marker}</main>"),
                marker,
                source_url,
                source_url,
                format!("hash-{marker}")
            ],
        )
        .unwrap();
}

#[test]
fn five_hundred_failure_windows_rotate_after_restart_without_starving_later_urls() {
    let temp = tempfile::tempdir().unwrap();
    let store = RssReaderStore::new(temp.path().into()).unwrap();
    let feed_id = store
        .add_feed("https://example.com/feed".into(), None)
        .unwrap()
        .id;
    let job = discover(&store, &feed_id, &["/legacy".into()], false);
    assert_eq!(fail_current(&store, &job.id).failed_count, 1);

    {
        let connection = store.db.lock().unwrap();
        let transaction = connection.unchecked_transaction().unwrap();
        for index in 0..504 {
            let url = format!("https://example.com/f{index:04}");
            let record = serde_json::json!({
                "candidate": {
                    "url": url,
                    "title": format!("Failure {index}"),
                    "status": "failed",
                    "message": "persistent failure",
                    "kind": "article"
                },
                "target": null
            });
            transaction
                .execute(
                    "INSERT INTO history_failures(job_id,url,candidate_json) VALUES(?,?,?)",
                    params![job.id, url, record.to_string()],
                )
                .unwrap();
        }
        transaction.commit().unwrap();
    }
    assert_eq!(failure_rows(&store, &job.id), 505);
    drop(store);

    let reopened = RssReaderStore::new(temp.path().into()).unwrap();
    let loaded = reopened.history_status(feed_id.clone()).unwrap().unwrap();
    assert_eq!(loaded.failed_count, 505);
    assert_eq!(loaded.discovered_count, 1);
    let first = reopened
        .history_prepare_retry(RssHistoryRetryInput {
            job_id: job.id.clone(),
            max_articles: 500,
        })
        .unwrap();
    assert!(first.retrying_failures);
    assert_eq!(first.candidates.len(), 500);
    assert_eq!(
        first.candidates.first().unwrap().url,
        "https://example.com/f0000"
    );
    assert_eq!(
        first.candidates.last().unwrap().url,
        "https://example.com/f0499"
    );
    assert_eq!(first.failed_count, 505);
    assert_eq!(first.discovered_count, 1);
    assert_eq!(
        reopened
            .db
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM articles", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        0,
        "preparing a retry is local-only"
    );
    settle_pending_as_failed(&reopened, &job.id);
    drop(reopened);

    let reopened = RssReaderStore::new(temp.path().into()).unwrap();
    let second = reopened
        .history_prepare_retry(RssHistoryRetryInput {
            job_id: job.id.clone(),
            max_articles: 500,
        })
        .unwrap();
    assert_eq!(second.candidates.len(), 5);
    assert_eq!(
        second.candidates.first().unwrap().url,
        "https://example.com/f0500"
    );
    assert_eq!(
        second.candidates.last().unwrap().url,
        "https://example.com/legacy"
    );
    assert_eq!(second.discovered_count, 1);

    ready(&reopened, &job.id);
    let imported = reopened
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id.clone(),
                retry_failures: false,
            },
            |url| Ok(response(url, 200, &article_page("Recovered"))),
        )
        .unwrap();
    assert_eq!(imported.added_count, 1);
    assert_eq!(imported.failed_count, 504);
    assert_eq!(imported.discovered_count, 1);
    assert_eq!(failure_rows(&reopened, &job.id), 504);
    assert_eq!(
        reopened
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT count(*) FROM history_failures WHERE job_id=? AND url='https://example.com/f0500'",
                [&job.id],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        0,
        "a successful retry must remove exactly its durable failure"
    );

    settle_pending_as_failed(&reopened, &job.id);
    let wrapped = reopened
        .history_prepare_retry(RssHistoryRetryInput {
            job_id: job.id.clone(),
            max_articles: 500,
        })
        .unwrap();
    assert_eq!(wrapped.candidates.len(), 500);
    assert_eq!(
        wrapped.candidates.first().unwrap().url,
        "https://example.com/f0000"
    );
    assert_eq!(
        wrapped.added_count, 1,
        "retry success must not be counted twice"
    );
    assert_eq!(
        wrapped.discovered_count, 1,
        "retry previews are not discoveries"
    );
}

#[test]
fn schema_three_checkpoint_lazily_migrates_current_failures_into_the_ledger() {
    let temp = tempfile::tempdir().unwrap();
    let store = RssReaderStore::new(temp.path().into()).unwrap();
    let feed_id = store
        .add_feed("https://example.com/feed".into(), None)
        .unwrap()
        .id;
    let job = discover(&store, &feed_id, &["/old".into()], false);
    assert_eq!(fail_current(&store, &job.id).failed_count, 1);
    {
        let connection = store.db.lock().unwrap();
        connection
            .execute("DELETE FROM history_failures WHERE job_id=?", [&job.id])
            .unwrap();
        let raw: String = connection
            .query_row(
                "SELECT payload FROM history_jobs WHERE id=?",
                [&job.id],
                |row| row.get(0),
            )
            .unwrap();
        let mut value: serde_json::Value = serde_json::from_str(&raw).unwrap();
        value.as_object_mut().unwrap().remove("failure_count");
        value
            .as_object_mut()
            .unwrap()
            .remove("failure_retry_after_url");
        value["job"]
            .as_object_mut()
            .unwrap()
            .remove("retryingFailures");
        connection
            .execute(
                "UPDATE history_jobs SET payload=? WHERE id=?",
                params![value.to_string(), job.id],
            )
            .unwrap();
        set_meta(&connection, "schema_version", "3").unwrap();
    }
    drop(store);

    let reopened = RssReaderStore::new(temp.path().into()).unwrap();
    assert_eq!(
        meta(&reopened.db.lock().unwrap(), "schema_version", "").unwrap(),
        "4"
    );
    assert_eq!(failure_rows(&reopened, &job.id), 0);
    let status = reopened.history_status(feed_id).unwrap().unwrap();
    assert_eq!(
        status.failed_count, 1,
        "legacy current failures count before mutation"
    );
    assert_eq!(
        failure_rows(&reopened, &job.id),
        0,
        "status hydration is read-only"
    );
    let retry = reopened
        .history_prepare_retry(RssHistoryRetryInput {
            job_id: job.id.clone(),
            max_articles: 1,
        })
        .unwrap();
    assert_eq!(retry.candidates.len(), 1);
    assert_eq!(retry.candidates[0].url, "https://example.com/old");
    assert_eq!(retry.failed_count, 1);
    assert_eq!(failure_rows(&reopened, &job.id), 1);
}

#[test]
fn retry_preserves_original_target_and_never_recreates_a_deleted_article() {
    let (store, feed_id) = new_store();
    insert_existing(&store, &feed_id);
    let job = discover(&store, &feed_id, &["/old".into()], true);
    assert_eq!(job.candidates[0].kind, "fullText");
    assert_eq!(fail_current(&store, &job.id).failed_count, 1);
    store
        .db
        .lock()
        .unwrap()
        .execute("DELETE FROM articles WHERE id='existing'", [])
        .unwrap();

    let preview = store
        .history_prepare_retry(RssHistoryRetryInput {
            job_id: job.id.clone(),
            max_articles: 1,
        })
        .unwrap();
    assert_eq!(preview.candidates[0].kind, "fullText");
    ready(&store, &job.id);
    let stopped = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id.clone(),
                retry_failures: false,
            },
            |_| panic!("a deleted full-text target must fail before network contact"),
        )
        .unwrap();
    assert_eq!(stopped.failed_count, 1);
    assert_eq!(failure_rows(&store, &job.id), 1);
    assert_eq!(
        store
            .db
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM articles", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        0,
        "a retry bound to a deleted target must not become a new article"
    );
}

#[test]
fn retry_reuses_a_new_ready_cache_without_fetching_or_overwriting_it() {
    let (store, feed_id) = new_store();
    insert_existing(&store, &feed_id);
    insert_ready_cache(&store, "https://example.com/former", "older ready cache");
    let job = discover(&store, &feed_id, &["/old".into()], true);
    assert_eq!(job.candidates[0].kind, "fullText");
    assert_eq!(fail_current(&store, &job.id).failed_count, 1);
    insert_ready_cache(&store, "https://example.com/old", "new ready cache");

    let preview = store
        .history_prepare_retry(RssHistoryRetryInput {
            job_id: job.id.clone(),
            max_articles: 1,
        })
        .unwrap();
    assert_eq!(preview.discovered_count, 1);
    ready(&store, &job.id);
    let done = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id.clone(),
                retry_failures: false,
            },
            |_| panic!("a same-source ready cache must suppress retry network work"),
        )
        .unwrap();
    assert_eq!(done.duplicate_count, 1);
    assert_eq!(done.failed_count, 0);
    assert_eq!(failure_rows(&store, &job.id), 0);
    let cache: (String, String, String) = store
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT status,plain_text,source_url FROM full_text_cache WHERE article_id='existing'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(
        cache,
        (
            "ready".into(),
            "new ready cache".into(),
            "https://example.com/old".into()
        )
    );
}

#[test]
fn transitions_backoff_cancellation_and_clear_preserve_the_ledger() {
    let (store, feed_id) = new_store();
    let job = discover(&store, &feed_id, &["/old".into()], false);
    assert_eq!(fail_current(&store, &job.id).failed_count, 1);

    store
        .update_feed_url(feed_id.clone(), "https://example.com/changed-feed".into())
        .unwrap();
    assert_eq!(
        store
            .history_prepare_retry(RssHistoryRetryInput {
                job_id: job.id.clone(),
                max_articles: 1,
            })
            .unwrap_err()
            .code,
        "rss_history_paused"
    );
    assert_eq!(failure_rows(&store, &job.id), 1);
    store
        .update_feed_url(feed_id.clone(), "https://example.com/feed".into())
        .unwrap();

    {
        let connection = store.db.lock().unwrap();
        let mut checkpoint = load(&connection, &job.id).unwrap();
        checkpoint.job.candidates.push(RssHistoryCandidate {
            url: "https://example.com/pending".into(),
            title: "Pending".into(),
            status: "pending".into(),
            message: None,
            kind: "article".into(),
        });
        save_progress(&connection, &mut checkpoint).unwrap();
    }
    assert_eq!(
        store
            .history_prepare_retry(RssHistoryRetryInput {
                job_id: job.id.clone(),
                max_articles: 1,
            })
            .unwrap_err()
            .code,
        "rss_history_busy"
    );
    {
        let connection = store.db.lock().unwrap();
        let mut checkpoint = load(&connection, &job.id).unwrap();
        checkpoint.job.candidates[1].status = "duplicate".into();
        checkpoint.in_flight = true;
        checkpoint.job.status = "paused".into();
        save(&connection, &checkpoint).unwrap();
    }
    assert_eq!(
        store
            .history_prepare_retry(RssHistoryRetryInput {
                job_id: job.id.clone(),
                max_articles: 1,
            })
            .unwrap_err()
            .code,
        "rss_history_busy"
    );
    assert!(store.history_clear(job.id.clone()).is_err());
    assert_eq!(failure_rows(&store, &job.id), 1);
    {
        let connection = store.db.lock().unwrap();
        let mut checkpoint = load(&connection, &job.id).unwrap();
        checkpoint.in_flight = false;
        checkpoint.job.status = "complete".into();
        checkpoint.job.next_request_at = now() + 3600;
        save(&connection, &checkpoint).unwrap();
    }
    store.history_busy.lock().unwrap().insert(feed_id.clone());
    assert_eq!(
        store
            .history_prepare_retry(RssHistoryRetryInput {
                job_id: job.id.clone(),
                max_articles: 1,
            })
            .unwrap_err()
            .code,
        "rss_history_paused"
    );
    store.history_busy.lock().unwrap().remove(&feed_id);

    let retry = store
        .history_prepare_retry(RssHistoryRetryInput {
            job_id: job.id.clone(),
            max_articles: 1,
        })
        .unwrap();
    assert_eq!(retry.candidates.len(), 1);
    assert_eq!(
        store
            .history_step_with(
                RssHistoryStepInput {
                    job_id: job.id.clone(),
                    retry_failures: false,
                },
                |_| panic!("backoff must stop retry network work"),
            )
            .unwrap_err()
            .code,
        "rss_history_backoff"
    );
    assert_eq!(failure_rows(&store, &job.id), 1);

    ready(&store, &job.id);
    let cancelled = store.history_step_with(
        RssHistoryStepInput {
            job_id: job.id.clone(),
            retry_failures: false,
        },
        |url| {
            store.history_pause(job.id.clone()).unwrap();
            Ok(response(url, 200, &article_page("Discarded")))
        },
    );
    assert_eq!(cancelled.unwrap_err().code, "rss_history_paused");
    assert_eq!(failure_rows(&store, &job.id), 1);
    store.history_clear(job.id.clone()).unwrap();
    assert_eq!(failure_rows(&store, &job.id), 0);
}

#[test]
fn invalid_oversized_and_over_capacity_ledgers_leave_the_checkpoint_unchanged() {
    let (store, feed_id) = new_store();
    let job = discover(&store, &feed_id, &["/old".into()], false);
    {
        let connection = store.db.lock().unwrap();
        let mut checkpoint = load(&connection, &job.id).unwrap();
        checkpoint.job.candidates[0].status = "duplicate".into();
        recount(&mut checkpoint);
        save(&connection, &checkpoint).unwrap();
        connection
            .execute(
                "INSERT INTO history_failures(job_id,url,candidate_json) VALUES(?,?,?)",
                params![job.id, "https://example.com/bad", "x".repeat(32 * 1024 + 1)],
            )
            .unwrap();
    }
    let before = raw_checkpoint(&store, &job.id);
    assert_eq!(
        store
            .history_prepare_retry(RssHistoryRetryInput {
                job_id: job.id.clone(),
                max_articles: 1,
            })
            .unwrap_err()
            .code,
        "rss_history_failure_capacity"
    );
    assert_eq!(raw_checkpoint(&store, &job.id), before);
    assert_eq!(failure_rows(&store, &job.id), 1);
    {
        let connection = store.db.lock().unwrap();
        connection
            .execute(
                "UPDATE history_failures SET candidate_json='{}' WHERE job_id=?",
                [&job.id],
            )
            .unwrap();
    }
    assert_eq!(
        store
            .history_prepare_retry(RssHistoryRetryInput {
                job_id: job.id.clone(),
                max_articles: 1,
            })
            .unwrap_err()
            .code,
        "rss_history_invalid"
    );
    assert_eq!(raw_checkpoint(&store, &job.id), before);
    assert_eq!(failure_rows(&store, &job.id), 1);
    assert_eq!(
        store
            .history_prepare_retry(RssHistoryRetryInput {
                job_id: job.id.clone(),
                max_articles: 501,
            })
            .unwrap_err()
            .code,
        "rss_history_invalid"
    );
    assert_eq!(raw_checkpoint(&store, &job.id), before);

    let (capacity_store, capacity_feed) = new_store();
    let capacity_job = discover(
        &capacity_store,
        &capacity_feed,
        &["/capacity".into()],
        false,
    );
    {
        let connection = capacity_store.db.lock().unwrap();
        let mut checkpoint = load(&connection, &capacity_job.id).unwrap();
        checkpoint.job.candidates[0].status = "duplicate".into();
        recount(&mut checkpoint);
        save(&connection, &checkpoint).unwrap();
        connection
            .execute(
                "WITH RECURSIVE numbers(value) AS (VALUES(0) UNION ALL SELECT value+1 FROM numbers WHERE value<50000) INSERT INTO history_failures(job_id,url,candidate_json) SELECT ?1,printf('https://example.com/f%05d',value),'{}' FROM numbers",
                [&capacity_job.id],
            )
            .unwrap();
    }
    let capacity_before = raw_checkpoint(&capacity_store, &capacity_job.id);
    assert_eq!(failure_rows(&capacity_store, &capacity_job.id), 50_001);
    assert_eq!(
        capacity_store
            .history_prepare_retry(RssHistoryRetryInput {
                job_id: capacity_job.id.clone(),
                max_articles: 500,
            })
            .unwrap_err()
            .code,
        "rss_history_failure_capacity"
    );
    assert_eq!(
        raw_checkpoint(&capacity_store, &capacity_job.id),
        capacity_before
    );
}
