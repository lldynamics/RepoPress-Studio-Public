use super::*;
fn reply(url: &Url, status: u16, body: &str) -> Response {
    Response {
        url: url.clone(),
        status: StatusCode::from_u16(status).unwrap(),
        headers: reqwest::header::HeaderMap::new(),
        body: body.as_bytes().to_vec(),
    }
}
fn store() -> (RssReaderStore, String) {
    let store = RssReaderStore::default();
    let feed = store
        .add_feed("https://example.com/feed".into(), Some("Example".into()))
        .unwrap();
    (store, feed.id)
}
fn plan(store: &RssReaderStore, feed: &str) -> RssHistoryJob {
    store
        .history_discover_with(
            RssHistoryDiscoverInput {
                discovery_id: Uuid::new_v4().to_string(),
                feed_id: feed.into(),
                directory_url: "https://example.com/archive".into(),
                max_pages: 2,
                max_articles: 5,
                fill_existing: false,
            },
            |u| {
                Ok(if u.path() == "/archive" {
                    reply(
                        u,
                        200,
                        "<main><article><a href='/old'>Old article</a></article></main>",
                    )
                } else {
                    reply(u, 404, "")
                })
            },
        )
        .unwrap()
}
fn ready(store: &RssReaderStore, id: &str) {
    let c = store.db.lock().unwrap();
    let mut value = load(&c, id).unwrap();
    value.job.next_request_at = 0;
    save(&c, &value).unwrap();
}
fn step(id: &str) -> RssHistoryStepInput {
    RssHistoryStepInput {
        job_id: id.into(),
        retry_failures: false,
    }
}
fn content(u: &Url) -> Response {
    reply(u,200,"<html><title>Historical title</title><article><p>A historical article with more than forty characters of meaningful reading content.</p><script>secret()</script><img src='https://tracker.invalid/x'></article></html>")
}
#[test]
fn discovery_previews_without_importing_and_step_imports_sanitized_content() {
    let (s, f) = store();
    let job = plan(&s, &f);
    assert_eq!(job.status, "preview");
    assert_eq!(job.candidates.len(), 1);
    assert_eq!(s.snapshot().unwrap().unread_count, 0);
    ready(&s, &job.id);
    let job = s
        .history_step_with(step(&job.id), |u| Ok(content(u)))
        .unwrap();
    assert_eq!(job.added_count, 1);
    assert_eq!(job.status, "complete");
    let c = s.db.lock().unwrap();
    let html: String = c
        .query_row("SELECT content FROM articles", [], |r| r.get(0))
        .unwrap();
    assert!(!html.contains("script"));
    assert!(!html.contains("tracker"));
}
#[test]
fn pause_discards_an_inflight_article_and_resume_is_manual() {
    let (s, f) = store();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    let result = s.history_step_with(step(&job.id), |u| {
        s.history_pause(job.id.clone()).unwrap();
        Ok(content(u))
    });
    assert_eq!(result.unwrap_err().code, "rss_history_paused");
    assert_eq!(s.snapshot().unwrap().unread_count, 0);
    assert_eq!(s.history_status(f).unwrap().unwrap().status, "paused");
    ready(&s, &job.id);
    assert_eq!(
        s.history_step_with(step(&job.id), |u| Ok(content(u)))
            .unwrap()
            .added_count,
        1
    );
}
#[test]
fn duplicates_do_not_fetch_or_overwrite_reading_state() {
    let (s, f) = store();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    s.history_step_with(step(&job.id), |u| Ok(content(u)))
        .unwrap();
    {
        let c = s.db.lock().unwrap();
        c.execute("UPDATE articles SET read=1,starred=1,tags='[\"keep\"]'", [])
            .unwrap();
        let mut cp = load(&c, &job.id).unwrap();
        cp.job.candidates[0].status = "pending".into();
        cp.job.next_request_at = 0;
        save(&c, &cp).unwrap();
    }
    let done = s
        .history_step_with(step(&job.id), |_| panic!("duplicate must not fetch"))
        .unwrap();
    assert_eq!(done.duplicate_count, 1);
    let c = s.db.lock().unwrap();
    let state: (i64, i64, String) = c
        .query_row("SELECT read,starred,tags FROM articles", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .unwrap();
    assert_eq!(state, (1, 1, "[\"keep\"]".into()));
}
#[test]
fn feed_changes_reject_preview_and_inflight_writes() {
    let (s, f) = store();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    s.update_feed_url(f.clone(), "https://example.com/new-feed".into())
        .unwrap();
    assert!(s
        .history_step_with(step(&job.id), |_| panic!("drift must not fetch"))
        .is_err());
    s.history_clear(job.id).unwrap();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    let result = s.history_step_with(step(&job.id), |u| {
        s.update_feed_url(f.clone(), "https://example.com/changed-again".into())
            .unwrap();
        Ok(content(u))
    });
    assert!(result.is_err());
    assert_eq!(s.snapshot().unwrap().unread_count, 0);
}
#[test]
fn source_boundaries_and_limits_are_checked_before_contact() {
    let (s, f) = store();
    for raw in [
        "https://evil.invalid/archive",
        "https://example.com/archive?token=secret",
        "http://127.0.0.1/a",
        "https://user:secret@example.com/a",
    ] {
        assert!(s
            .history_discover_with(
                RssHistoryDiscoverInput {
                    discovery_id: Uuid::new_v4().to_string(),
                    feed_id: f.clone(),
                    directory_url: raw.into(),
                    max_pages: 2,
                    max_articles: 5,
                    fill_existing: false,
                },
                |_| panic!("invalid source contacted")
            )
            .is_err());
    }
    assert!(s
        .history_discover_with(
            RssHistoryDiscoverInput {
                discovery_id: Uuid::new_v4().to_string(),
                feed_id: f,
                directory_url: "https://example.com/archive".into(),
                max_pages: 11,
                max_articles: 501,
                fill_existing: false,
            },
            |_| panic!("limits contacted")
        )
        .is_err());
    let a = Url::parse("https://example.com/a").unwrap();
    assert!(check_history_url(&Url::parse("https://other.invalid/a").unwrap(), &a).is_err());
}
#[test]
fn robots_failure_disallow_and_noarchive_prevent_imports() {
    let (s, f) = store();
    for robots in [
        "User-agent: *\nDisallow: /archive",
        "User-agent: RepoPress\nDisallow: /",
    ] {
        assert!(s
            .history_discover_with(
                RssHistoryDiscoverInput {
                    discovery_id: Uuid::new_v4().to_string(),
                    feed_id: f.clone(),
                    directory_url: "https://example.com/archive".into(),
                    max_pages: 2,
                    max_articles: 5,
                    fill_existing: false,
                },
                |u| Ok(reply(u, 200, robots))
            )
            .is_err());
        let checkpoint = s.history_status(f.clone()).unwrap().unwrap();
        assert!(checkpoint.candidates.is_empty());
        s.history_clear(checkpoint.id).unwrap();
    }
    assert!(s
        .history_discover_with(
            RssHistoryDiscoverInput {
                discovery_id: Uuid::new_v4().to_string(),
                feed_id: f.clone(),
                directory_url: "https://example.com/archive".into(),
                max_pages: 2,
                max_articles: 5,
                fill_existing: false,
            },
            |u| Ok(reply(u, 503, ""))
        )
        .is_err());
    let checkpoint = s.history_status(f.clone()).unwrap().unwrap();
    assert!(checkpoint.candidates.is_empty());
    s.history_clear(checkpoint.id).unwrap();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    let done = s
        .history_step_with(step(&job.id), |u| {
            let mut r = content(u);
            r.headers
                .insert("x-robots-tag", "noarchive".parse().unwrap());
            Ok(r)
        })
        .unwrap();
    assert_eq!(done.failed_count, 1);
    assert_eq!(s.snapshot().unwrap().unread_count, 0);
}
#[test]
fn retry_requires_explicit_request_and_honors_backoff() {
    let (s, f) = store();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    let failed = s
        .history_step_with(step(&job.id), |u| {
            let mut r = reply(u, 429, "");
            r.headers.insert("retry-after", "120".parse().unwrap());
            Ok(r)
        })
        .unwrap();
    assert_eq!(failed.failed_count, 1);
    assert!(failed.next_request_at >= now() + 119);
    let retry = RssHistoryStepInput {
        job_id: job.id.clone(),
        retry_failures: true,
    };
    assert_eq!(
        s.history_step_with(retry.clone(), |_| panic!("backoff fetched"))
            .unwrap_err()
            .code,
        "rss_history_backoff"
    );
    ready(&s, &job.id);
    assert_eq!(
        s.history_step_with(step(&job.id), |_| panic!("failed retried automatically"))
            .unwrap()
            .failed_count,
        1
    );
    ready(&s, &job.id);
    assert_eq!(
        s.history_step_with(retry, |u| Ok(content(u)))
            .unwrap()
            .added_count,
        1
    );
}
#[test]
fn durable_restart_pauses_without_fetching() {
    let temp = tempfile::tempdir().unwrap();
    let s = RssReaderStore::new(temp.path().into()).unwrap();
    let f = s
        .add_feed("https://example.com/feed".into(), None)
        .unwrap()
        .id;
    let job = plan(&s, &f);
    {
        let c = s.db.lock().unwrap();
        let mut value = load(&c, &job.id).unwrap();
        value.job.status = "running".into();
        save(&c, &value).unwrap();
    }
    drop(s);
    let s = RssReaderStore::new(temp.path().into()).unwrap();
    assert_eq!(s.history_status(f).unwrap().unwrap().status, "paused");
    assert_eq!(s.snapshot().unwrap().unread_count, 0);
}
#[test]
fn backup_restore_clears_jobs_and_accepts_legacy_v2() {
    let (s, f) = store();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    let failed = s
        .history_step_with(step(&job.id), |u| Ok(reply(u, 404, "")))
        .unwrap();
    assert_eq!(failed.failed_count, 1);
    {
        let c = s.db.lock().unwrap();
        assert_eq!(
            c.query_row("SELECT count(*) FROM history_failures", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    let mut backup: serde_json::Value = serde_json::from_str(&s.export_backup().unwrap()).unwrap();
    backup["databaseSchemaVersion"] = 2.into();
    s.restore_backup(backup.to_string()).unwrap();
    assert!(s.history_status(job.feed_id).unwrap().is_none());
    assert_eq!(s.snapshot().unwrap().feeds.len(), 1);
    let c = s.db.lock().unwrap();
    assert_eq!(
        c.query_row("SELECT count(*) FROM history_failures", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn discovery_and_candidate_bounds_are_finite() {
    let (s, f) = store();
    let mut requests = 0;
    let job=s.history_discover_with(RssHistoryDiscoverInput{discovery_id:Uuid::new_v4().to_string(),feed_id:f,directory_url:"https://example.com/archive".into(),max_pages:2,max_articles:1,fill_existing:false},|u|{requests+=1;Ok(if u.path()=="/robots.txt" {reply(u,404,"")}else{reply(u,200,"<main><article><a href='/one'>One</a><a href='/two'>Two</a></article><a rel='next' href='/page2'>Next</a></main>")})}).unwrap();
    assert_eq!(job.candidates.len(), 1);
    assert!(job.reached_limit);
    assert!(requests <= 3);
}
#[test]
fn expired_robots_are_refreshed_without_article_contact_in_same_step() {
    let (s, f) = store();
    let job = plan(&s, &f);
    {
        let c = s.db.lock().unwrap();
        let mut value = load(&c, &job.id).unwrap();
        value.robots_at = 0;
        value.job.next_request_at = 0;
        save(&c, &value).unwrap();
    }
    let done = s
        .history_step_with(step(&job.id), |u| {
            assert_eq!(u.path(), "/robots.txt");
            Ok(reply(u, 200, "User-agent: *\nDisallow: /old"))
        })
        .unwrap();
    assert_eq!(done.added_count, 0);
    ready(&s, &job.id);
    let done = s
        .history_step_with(step(&job.id), |_| panic!("disallowed article contacted"))
        .unwrap();
    assert_eq!(done.failed_count, 1);
}
#[test]
fn rejects_future_database_without_changing_version() {
    let temp = tempfile::tempdir().unwrap();
    let s = RssReaderStore::new(temp.path().into()).unwrap();
    let path = s.path.clone().unwrap();
    {
        let c = s.db.lock().unwrap();
        set_meta(&c, "schema_version", "99").unwrap();
    }
    drop(s);
    assert!(RssReaderStore::new(temp.path().into()).is_err());
    let c = Connection::open(path).unwrap();
    assert_eq!(meta(&c, "schema_version", "").unwrap(), "99");
}
#[test]
fn multiple_steps_continue_but_overlapping_step_is_rejected() {
    let (s, f) = store();
    let job = plan(&s, &f);
    {
        let c = s.db.lock().unwrap();
        let mut cp = load(&c, &job.id).unwrap();
        cp.job.candidates.push(RssHistoryCandidate {
            url: "https://example.com/second".into(),
            title: "Second".into(),
            status: "pending".into(),
            message: None,
            kind: "article".into(),
        });
        cp.job.next_request_at = 0;
        save(&c, &cp).unwrap();
    }
    let next = s
        .history_step_with(step(&job.id), |u| {
            assert_eq!(
                s.history_step_with(step(&job.id), |_| panic!("overlap fetched"))
                    .unwrap_err()
                    .code,
                "rss_history_paused"
            );
            Ok(content(u))
        })
        .unwrap();
    assert_eq!(next.status, "running");
    ready(&s, &job.id);
    let next = s
        .history_step_with(step(&job.id), |u| Ok(content(u)))
        .unwrap();
    assert_eq!(next.added_count, 2);
    assert_eq!(next.status, "complete");
}
#[test]
fn canonical_identity_dedupes_aliases_without_followup_requests() {
    let (s, f) = store();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    let html="<html><head><title>Original</title><link rel='canonical' href='/canonical'/><meta property='article:published_time' content='2020-01-02T00:00:00Z'/><meta name='author' content='Writer'/></head><article>Old content with more than forty meaningful reading characters.</article></html>";
    s.history_step_with(step(&job.id), |u| Ok(reply(u, 200, html)))
        .unwrap();
    {
        let c = s.db.lock().unwrap();
        let row: (String, i64, String) = c
            .query_row("SELECT url,published,author FROM articles", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap();
        assert_eq!(
            row,
            (
                "https://example.com/canonical".into(),
                1577923200,
                "Writer".into()
            )
        );
        let mut cp = load(&c, &job.id).unwrap();
        cp.job.candidates[0].url = "https://example.com/alias".into();
        cp.job.candidates[0].status = "pending".into();
        cp.job.next_request_at = 0;
        save(&c, &cp).unwrap();
    }
    let result = s
        .history_step_with(step(&job.id), |u| {
            assert_eq!(u.path(), "/alias");
            Ok(reply(u, 200, html))
        })
        .unwrap();
    assert_eq!(result.duplicate_count, 1);
    assert_eq!(s.snapshot().unwrap().unread_count, 1);
}
#[test]
fn migration_v2_preserves_articles_and_adds_history_tables() {
    let temp = tempfile::tempdir().unwrap();
    let s = RssReaderStore::new(temp.path().into()).unwrap();
    let f = s.add_feed("https://example.com/feed".into(), None).unwrap();
    {
        let c = s.db.lock().unwrap();
        c.execute_batch("DROP TABLE history_failures; DROP TABLE history_jobs")
            .unwrap();
        set_meta(&c, "schema_version", "2").unwrap();
    }
    drop(s);
    let s = RssReaderStore::new(temp.path().into()).unwrap();
    assert_eq!(s.snapshot().unwrap().feeds[0].id, f.id);
    assert!(s.history_status(f.id).unwrap().is_none());
    let c = s.db.lock().unwrap();
    assert_eq!(meta(&c, "schema_version", "").unwrap(), "4");
    assert_eq!(
        c.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('history_jobs','history_failures')",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        2
    );
}

#[test]
fn archive_policy_scan_exhaustion_is_rejected() {
    let html = "<b>".repeat(50_001) + "<meta name='robots' content='noarchive'><article>A readable historical article with at least forty characters.</article>";
    assert!(parse::no_archive(&html));
    let (s, f) = store();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    assert_eq!(
        s.history_step_with(step(&job.id), |u| Ok(reply(u, 200, &html)))
            .unwrap()
            .failed_count,
        1
    );
    assert_eq!(s.snapshot().unwrap().unread_count, 0);
}
#[test]
fn legacy_opml_entrypoints_require_review_for_feed_and_site_secrets() {
    let (s, f) = store();
    assert!(s.import_opml("<opml><body><outline xmlUrl='https://safe.example/feed?token=TOPSECRET'/></body></opml>".into()).is_err());
    assert_eq!(s.snapshot().unwrap().feeds.len(), 1);
    s.update_feed_site_url(&f, Some("https://example.com/?api_key=SITESECRET".into()))
        .unwrap();
    assert_eq!(
        s.export_opml().unwrap_err().code,
        "rss_opml_review_required"
    );
}
#[test]
fn discovery_cancellation_before_start_or_after_response_prevents_more_requests_and_save() {
    let (s, f) = store();
    let token = Uuid::new_v4().to_string();
    s.history_cancel_discovery(token.clone()).unwrap();
    let input = RssHistoryDiscoverInput {
        discovery_id: token,
        feed_id: f.clone(),
        directory_url: "https://example.com/archive".into(),
        max_pages: 10,
        max_articles: 500,
        fill_existing: false,
    };
    assert_eq!(
        s.history_discover_with(input, |_| panic!("cancel-before-start fetched"))
            .unwrap_err()
            .code,
        "rss_history_paused"
    );
    assert!(s.history_status(f.clone()).unwrap().is_none());
    let token = Uuid::new_v4().to_string();
    let input = RssHistoryDiscoverInput {
        discovery_id: token.clone(),
        feed_id: f.clone(),
        directory_url: "https://example.com/archive".into(),
        max_pages: 10,
        max_articles: 500,
        fill_existing: false,
    };
    let mut requests = 0;
    assert_eq!(
        s.history_discover_with(input, |u| {
            requests += 1;
            s.history_cancel_discovery(token.clone()).unwrap();
            Ok(reply(u, 404, ""))
        })
        .unwrap_err()
        .code,
        "rss_history_paused"
    );
    assert_eq!(requests, 1);
    let saved = s.history_status(f).unwrap().unwrap();
    assert!(saved.candidates.is_empty());
    assert!(saved.has_more_discovery);
}
#[test]
fn expired_robots_throttle_retains_retry_after() {
    let (s, f) = store();
    let job = plan(&s, &f);
    {
        let c = s.db.lock().unwrap();
        let mut cp = load(&c, &job.id).unwrap();
        cp.robots_at = 0;
        cp.job.next_request_at = 0;
        save(&c, &cp).unwrap();
    }
    let done = s
        .history_step_with(step(&job.id), |u| {
            assert_eq!(u.path(), "/robots.txt");
            let mut r = reply(u, 429, "");
            r.headers.insert("retry-after", "3600".parse().unwrap());
            Ok(r)
        })
        .unwrap();
    assert_eq!(done.failed_count, 1);
    assert!(done.next_request_at >= now() + 3599);
    assert_eq!(
        s.history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: true
            },
            |_| panic!("robots retry beforebackoff")
        )
        .unwrap_err()
        .code,
        "rss_history_backoff"
    );
}
#[test]
fn metadata_scans_past_old_limit_linearly_without_missing_canonical() {
    let base = Url::parse("https://example.com/alias").unwrap();
    let html = "<i></i>".repeat(20_000) + "<link rel='canonical' href='/canonical'>";
    assert_eq!(
        source_metadata(&html, &base).unwrap().canonical.as_deref(),
        Some("https://example.com/canonical")
    );
    let excessive = "<i></i>".repeat(30_000) + "<link rel='canonical' href='/canonical'>";
    assert!(source_metadata(&excessive, &base).is_err());
    let comments =
        "<!--".to_string() + &"<".repeat(100_000) + "--><link rel='canonical' href='/canonical'>";
    assert_eq!(
        source_metadata(&comments, &base)
            .unwrap()
            .canonical
            .as_deref(),
        Some("https://example.com/canonical")
    );
}
#[test]
fn regular_feed_refresh_reuses_permalink_guid_and_preserves_historical_body_and_state() {
    let (s, f) = store();
    let job = plan(&s, &f);
    ready(&s, &job.id);
    s.history_step_with(step(&job.id), |u| Ok(content(u)))
        .unwrap();
    {
        let c = s.db.lock().unwrap();
        c.execute("UPDATE articles SET read=1,starred=1,tags='[\"keep\"]',published=123,author='Original'",[]).unwrap();
    }
    let body=b"<rss><channel><title>Feed</title><item><guid>https://example.com/old</guid><title>Updated title</title><description>short summary</description></item></channel></rss>".to_vec();
    let result = s
        .apply_feed_response(
            &f,
            "https://example.com/feed",
            (
                Url::parse("https://example.com/feed").unwrap(),
                StatusCode::OK,
                reqwest::header::HeaderMap::new(),
                body,
            ),
        )
        .unwrap();
    assert_eq!(result.inserted, 0);
    assert_eq!(result.updated, 1);
    let c = s.db.lock().unwrap();
    let row: (i64, i64, String, String, i64, String) = c
        .query_row(
            "SELECT read,starred,tags,content,published,author FROM articles",
            [],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .unwrap();
    assert_eq!((row.0, row.1, row.2), (1, 1, "[\"keep\"]".into()));
    assert!(row.3.contains("meaningful reading"));
    assert_eq!(row.4, 123);
    assert_eq!(row.5, "Original");
}
#[test]
fn network_scope_cancellation_precedes_dns_or_contact() {
    let url = Url::parse("https://not-contacted.invalid/article").unwrap();
    let cancelled = || Err(stopped());
    let scope = RssFetchScope {
        origin: &url,
        robots: Some(""),
        check_active: Some(&cancelled),
    };
    assert_eq!(
        fetch_bounded_scoped(&url, false, None, None, 1024, "bounded", Some(&scope))
            .unwrap_err()
            .code,
        "rss_history_paused"
    );
}

#[path = "rss_history_p57_tests.rs"]
mod p57;
#[path = "rss_history_p58_tests.rs"]
mod p58;

#[path = "rss_history_p59_tests.rs"]
mod p59;
