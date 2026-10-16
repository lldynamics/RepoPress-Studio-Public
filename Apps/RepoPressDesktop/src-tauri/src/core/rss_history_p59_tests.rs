use super::super::*;

fn response(url: &Url, status: u16, body: &str) -> Response {
    Response {
        url: url.clone(),
        status: StatusCode::from_u16(status).unwrap(),
        headers: reqwest::header::HeaderMap::new(),
        body: body.as_bytes().to_vec(),
    }
}

fn parse_one(xml: &str) -> Parsed {
    let base = Url::parse("https://example.com/feed.xml").unwrap();
    let mut parsed = parse_xml(xml.as_bytes(), &base).unwrap();
    assert_eq!(parsed.len(), 1);
    parsed.remove(0)
}

fn store_with_parsed(xml: &str) -> (RssReaderStore, String, String) {
    let parsed = parse_one(xml);
    let store = RssReaderStore::default();
    let feed_id = store
        .add_feed(
            "https://example.com/feed.xml".into(),
            Some("Example".into()),
        )
        .unwrap()
        .id;
    let article_id = "p59-existing".to_owned();
    store
        .db
        .lock()
        .unwrap()
        .execute(
            "INSERT INTO articles(id,feed_id,identity,guid,title,url,author,summary,content,published,fetched,read,read_at,starred,tags) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            params![
                article_id,
                feed_id,
                parsed.identity,
                parsed.guid,
                parsed.title,
                parsed.url,
                parsed.author,
                parsed.summary,
                parsed.content,
                parsed.published,
                456_i64,
                1_i64,
                789_i64,
                1_i64,
                "[\"keep\"]"
            ],
        )
        .unwrap();
    (store, feed_id, article_id)
}

fn discover(
    store: &RssReaderStore,
    feed_id: &str,
    fill_existing: bool,
    requests: &mut Vec<String>,
) -> RssHistoryJob {
    store
        .history_discover_with(
            RssHistoryDiscoverInput {
                discovery_id: Uuid::new_v4().to_string(),
                feed_id: feed_id.into(),
                directory_url: "https://example.com/archive".into(),
                max_pages: 2,
                max_articles: 10,
                fill_existing,
            },
            |url| {
                requests.push(url.to_string());
                Ok(match url.path() {
                    "/robots.txt" | "/sitemap.xml" => response(url, 404, ""),
                    "/archive" => response(
                        url,
                        200,
                        "<main><article><a href='/post'>Existing post</a></article></main>",
                    ),
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

fn article_state(store: &RssReaderStore, article_id: &str) -> (String, String, i64, i64, i64) {
    store
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT summary,content,read,read_at,starred FROM articles WHERE id=?",
            [article_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .unwrap()
}

#[test]
fn short_feed_body_equal_to_summary_is_full_text_only_when_fill_is_enabled() {
    let xml = r#"<feed xmlns="http://www.w3.org/2005/Atom"><entry>
      <title>Teaser</title><id>teaser-id</id><link href="/post"/>
      <summary type="text">Short &amp; complete-looking teaser</summary>
    </entry></feed>"#;
    let (store, feed_id, article_id) = store_with_parsed(xml);
    let before = article_state(&store, &article_id);

    let mut no_fill_requests = Vec::new();
    let no_fill = discover(&store, &feed_id, false, &mut no_fill_requests);
    assert_eq!(no_fill.candidates[0].kind, "article");
    assert_eq!(no_fill.candidates[0].status, "duplicate");
    ready(&store, &no_fill.id);
    store
        .history_step_with(
            RssHistoryStepInput {
                job_id: no_fill.id.clone(),
                retry_failures: false,
            },
            |_| panic!("fillExisting=false must not fetch the existing article"),
        )
        .unwrap();
    store.history_clear(no_fill.id).unwrap();

    let mut fill_requests = Vec::new();
    let fill = discover(&store, &feed_id, true, &mut fill_requests);
    assert_eq!(fill.candidates[0].kind, "fullText");
    assert_eq!(fill.candidates[0].status, "pending");
    assert_eq!(article_state(&store, &article_id), before);
    assert_eq!(no_fill_requests.len(), fill_requests.len());

    ready(&store, &fill.id);
    let mut article_requests = Vec::new();
    let completed = store
        .history_step_with(
            RssHistoryStepInput {
                job_id: fill.id,
                retry_failures: false,
            },
            |url| {
                article_requests.push(url.to_string());
                Ok(response(
                    url,
                    200,
                    &format!(
                        "<html><title>Remote</title><article><p>{}</p></article></html>",
                        "Complete public article body. ".repeat(12)
                    ),
                ))
            },
        )
        .unwrap();
    assert_eq!(completed.updated_count, 1);
    assert_eq!(article_requests, vec!["https://example.com/post"]);
    assert_eq!(article_state(&store, &article_id), before);
    let cache: (String, String) = store
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT status,source_url FROM full_text_cache WHERE article_id=?",
            [&article_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(cache, ("ready".into(), "https://example.com/post".into()));
}

#[test]
fn complete_atom_xhtml_body_is_not_refetched_just_because_it_is_short() {
    let xml = r#"<feed xmlns="http://www.w3.org/2005/Atom"><entry>
      <title>Complete</title><id>complete-id</id><link href="/post"/>
      <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Separate <em>summary</em></p></div></summary>
      <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Short but complete <strong>body</strong>.</p></div></content>
    </entry></feed>"#;
    let (store, feed_id, article_id) = store_with_parsed(xml);
    let before = article_state(&store, &article_id);
    assert_ne!(before.0, before.1);
    assert!(before.1.contains("<strong>body</strong>"));

    let mut requests = Vec::new();
    let job = discover(&store, &feed_id, true, &mut requests);
    assert_eq!(job.candidates[0].kind, "article");
    assert_eq!(job.candidates[0].status, "duplicate");
    ready(&store, &job.id);
    store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |_| panic!("a complete XHTML body must not be fetched again"),
        )
        .unwrap();
    assert_eq!(article_state(&store, &article_id), before);
    assert_eq!(
        store
            .db
            .lock()
            .unwrap()
            .query_row(
                "SELECT count(*) FROM full_text_cache WHERE article_id=?",
                [&article_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
}

#[test]
fn ready_cache_suppresses_short_body_refetch_and_atom_src_is_never_requested() {
    let xml = r#"<feed xmlns="http://www.w3.org/2005/Atom"><entry>
      <title>External</title><id>external-id</id><link href="/post"/>
      <summary type="html">&lt;p&gt;Fallback teaser&lt;/p&gt;</summary>
      <content type="html" src="https://cdn.example/payload">&lt;b&gt;ignored inline payload&lt;/b&gt;</content>
    </entry></feed>"#;
    let (store, feed_id, article_id) = store_with_parsed(xml);
    let state = article_state(&store, &article_id);
    assert_eq!(state.0, "<p>Fallback teaser</p>");
    assert_eq!(state.1, state.0);
    store
        .db
        .lock()
        .unwrap()
        .execute(
            "INSERT INTO full_text_cache(article_id,status,content_html,plain_text,source_url,resolved_url,confidence,attempted_at,retry_after) VALUES(?,'ready','<p>cached</p>','cached','https://example.com/post','https://example.com/post',900,1,0)",
            [&article_id],
        )
        .unwrap();

    let mut requests = Vec::new();
    let job = discover(&store, &feed_id, true, &mut requests);
    assert_eq!(job.candidates[0].status, "duplicate");
    assert!(
        requests
            .iter()
            .all(|url| url != "https://cdn.example/payload"),
        "Atom content src leaked into network requests: {requests:?}"
    );
    ready(&store, &job.id);
    store
        .history_step_with(
            RssHistoryStepInput {
                job_id: job.id,
                retry_failures: false,
            },
            |_| panic!("same-source ready cache must suppress network work"),
        )
        .unwrap();
    let cache: (String, String, String) = store
        .db
        .lock()
        .unwrap()
        .query_row(
            "SELECT status,plain_text,source_url FROM full_text_cache WHERE article_id=?",
            [&article_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert_eq!(
        cache,
        (
            "ready".into(),
            "cached".into(),
            "https://example.com/post".into()
        )
    );
    assert_eq!(article_state(&store, &article_id), state);
}
