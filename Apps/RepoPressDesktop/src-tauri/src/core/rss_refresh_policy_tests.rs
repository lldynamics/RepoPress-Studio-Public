use super::*;
use reqwest::header::HeaderMap;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

struct TestTransportGuard<'a> {
    store: &'a RssReaderStore,
}

impl Drop for TestTransportGuard<'_> {
    fn drop(&mut self) {
        self.store
            .test_feed_transport
            .lock()
            .expect("lock test transport")
            .take();
    }
}

fn install_transport(
    store: &RssReaderStore,
    fetch: impl Fn(&Url, bool, Option<&str>, Option<&str>) -> CommandResult<RssFetchResponse>
        + Send
        + Sync
        + 'static,
) -> TestTransportGuard<'_> {
    let mut slot = store
        .test_feed_transport
        .lock()
        .expect("lock test transport");
    assert!(slot.is_none(), "test transport was already installed");
    *slot = Some(Arc::new(fetch));
    drop(slot);
    TestTransportGuard { store }
}

fn add_feed(store: &RssReaderStore) -> RssFeed {
    add_feed_at(store, "current")
}

fn add_feed_at(store: &RssReaderStore, slug: &str) -> RssFeed {
    store
        .add_feed(
            format!("https://feeds.example.test/{slug}.xml"),
            Some(format!("Policy fixture {slug}")),
        )
        .expect("add feed")
}

fn add_stateful_article(store: &RssReaderStore, feed_id: &str, article_id: &str) -> String {
    let article_id = article_id.to_owned();
    let connection = store.db.lock().expect("lock database");
    connection
        .execute(
            "INSERT INTO articles(id,feed_id,identity,guid,title,url,author,summary,content,published,fetched,read,read_at,starred,tags) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            params![
                &article_id,
                feed_id,
                "preserved-identity",
                "preserved-guid",
                "Preserved title",
                "https://example.test/preserved",
                "Fixture author",
                "Preserved summary",
                "Preserved body",
                1_700_000_000_i64,
                1_700_000_001_i64,
                1_i64,
                1_700_000_002_i64,
                1_i64,
                "[\"policy\",\"preserved\"]",
            ],
        )
        .expect("insert article");
    article_id
}

fn set_schedule(store: &RssReaderStore, feed_id: &str, next_refresh: i64, next_retry: i64) {
    let connection = store.db.lock().expect("lock database");
    connection
        .execute(
            "UPDATE feeds SET next_refresh=?,next_retry=? WHERE id=?",
            params![next_refresh, next_retry, feed_id],
        )
        .expect("set refresh schedule");
}

fn test_feed_xml() -> Vec<u8> {
    br#"<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Scheduled fixture</title>
    <link>https://example.test/</link>
    <description>Refresh policy fixture</description>
    <item>
      <guid>scheduled-item</guid>
      <title>Scheduled article</title>
      <link>https://example.test/scheduled-item</link>
      <description>Fetched by an eligible automatic refresh.</description>
      <pubDate>Wed, 15 Oct 2025 10:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>"#
        .to_vec()
}

#[test]
fn automatic_refresh_honors_future_refresh_and_retry_without_mutating_state() {
    let store = RssReaderStore::default();
    let feed = add_feed(&store);
    let article_id = add_stateful_article(&store, &feed.id, "preserved-article");
    let mut preferences = store.preferences().expect("load preferences");
    preferences.refresh_interval_seconds = 300;
    preferences.refresh_interval_minutes = 5;
    preferences.max_articles_per_feed = 321;
    preferences.remote_images_enabled = false;
    let preferences = store
        .update_preferences(preferences)
        .expect("save preferences");
    let article = store
        .article(article_id.clone())
        .expect("load article")
        .expect("article exists");
    let calls = Arc::new(AtomicUsize::new(0));
    let transport_calls = Arc::clone(&calls);
    let _transport = install_transport(&store, move |_, _, _, _| {
        transport_calls.fetch_add(1, Ordering::SeqCst);
        panic!("a deferred automatic refresh must not reach the transport")
    });

    let future = now() + 3_600;
    set_schedule(&store, &feed.id, future, 0);
    let refresh_deferred = store
        .refresh_feed_forced(feed.id.clone(), false)
        .expect("defer next refresh");
    assert_eq!(refresh_deferred.fetched, 0);
    assert!(!refresh_deferred.failed);
    assert!(refresh_deferred.summary.contains("skipped"));

    set_schedule(&store, &feed.id, 0, future);
    let retry_deferred = store
        .refresh_feed_forced(feed.id.clone(), false)
        .expect("defer retry");
    assert_eq!(retry_deferred.fetched, 0);
    assert!(!retry_deferred.failed);
    assert!(retry_deferred.summary.contains("skipped"));

    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert_eq!(
        store
            .article(article_id)
            .expect("reload article")
            .expect("article remains"),
        article
    );
    assert_eq!(
        store.preferences().expect("reload preferences"),
        preferences
    );
    let snapshot = store.snapshot().expect("snapshot");
    assert_eq!(snapshot.unread_count, 0);
    assert_eq!(snapshot.starred_count, 1);
    let persisted_feed = snapshot
        .feeds
        .into_iter()
        .find(|candidate| candidate.id == feed.id)
        .expect("feed remains");
    assert_eq!(persisted_feed.next_refresh_at, 0);
    assert_eq!(persisted_feed.next_retry_at, Some(future));
}

#[test]
fn all_feeds_refresh_only_fetches_the_eligible_feed() {
    let store = RssReaderStore::default();
    let refresh_deferred = add_feed_at(&store, "refresh-deferred");
    let retry_deferred = add_feed_at(&store, "retry-deferred");
    let eligible = add_feed_at(&store, "eligible");
    let refresh_article_id =
        add_stateful_article(&store, &refresh_deferred.id, "refresh-deferred-article");
    let retry_article_id =
        add_stateful_article(&store, &retry_deferred.id, "retry-deferred-article");
    let refresh_article = store
        .article(refresh_article_id.clone())
        .expect("load refresh-deferred article")
        .expect("refresh-deferred article exists");
    let retry_article = store
        .article(retry_article_id.clone())
        .expect("load retry-deferred article")
        .expect("retry-deferred article exists");
    let future = now() + 3_600;
    set_schedule(&store, &refresh_deferred.id, future, 0);
    set_schedule(&store, &retry_deferred.id, 0, future);
    set_schedule(&store, &eligible.id, 0, 0);
    let calls = Arc::new(AtomicUsize::new(0));
    let transport_calls = Arc::clone(&calls);
    let _transport = install_transport(&store, move |url, _, _, _| {
        transport_calls.fetch_add(1, Ordering::SeqCst);
        assert_eq!(url.path(), "/eligible.xml");
        Ok((
            url.clone(),
            StatusCode::OK,
            HeaderMap::new(),
            test_feed_xml(),
        ))
    });

    let results = store
        .refresh_all_forced(false)
        .expect("refresh all eligible feeds");

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(results.len(), 3);
    for deferred_id in [&refresh_deferred.id, &retry_deferred.id] {
        let result = results
            .iter()
            .find(|candidate| &candidate.feed_id == deferred_id)
            .expect("deferred result");
        assert_eq!(result.fetched, 0);
        assert!(!result.failed);
        assert!(result.summary.contains("skipped"));
    }
    let eligible_result = results
        .iter()
        .find(|candidate| candidate.feed_id == eligible.id)
        .expect("eligible result");
    assert_eq!(eligible_result.fetched, 1);
    assert_eq!(eligible_result.inserted, 1);
    assert!(!eligible_result.failed);
    assert_eq!(
        store
            .article(refresh_article_id)
            .expect("reload refresh-deferred article")
            .expect("refresh-deferred article remains"),
        refresh_article
    );
    assert_eq!(
        store
            .article(retry_article_id)
            .expect("reload retry-deferred article")
            .expect("retry-deferred article remains"),
        retry_article
    );
    let snapshot = store.snapshot().expect("snapshot");
    let persisted_refresh_deferred = snapshot
        .feeds
        .iter()
        .find(|candidate| candidate.id == refresh_deferred.id)
        .expect("refresh-deferred feed remains");
    assert_eq!(persisted_refresh_deferred.next_refresh_at, future);
    assert_eq!(persisted_refresh_deferred.next_retry_at, None);
    let persisted_retry_deferred = snapshot
        .feeds
        .iter()
        .find(|candidate| candidate.id == retry_deferred.id)
        .expect("retry-deferred feed remains");
    assert_eq!(persisted_retry_deferred.next_refresh_at, 0);
    assert_eq!(persisted_retry_deferred.next_retry_at, Some(future));
    let persisted_eligible = snapshot
        .feeds
        .iter()
        .find(|candidate| candidate.id == eligible.id)
        .expect("eligible feed remains");
    assert!(persisted_eligible.last_refreshed_at > 0);
    assert!(persisted_eligible.next_refresh_at > persisted_eligible.last_refreshed_at);
    assert_eq!(persisted_eligible.next_retry_at, None);
    assert_eq!(snapshot.unread_count, 1);
    assert_eq!(snapshot.starred_count, 2);
}

#[test]
fn manual_refresh_bypasses_a_future_schedule_and_reaches_transport() {
    let store = RssReaderStore::default();
    let feed = add_feed(&store);
    set_schedule(&store, &feed.id, now() + 3_600, now() + 3_600);
    let calls = Arc::new(AtomicUsize::new(0));
    let transport_calls = Arc::clone(&calls);
    let _transport = install_transport(&store, move |url, _, _, _| {
        transport_calls.fetch_add(1, Ordering::SeqCst);
        Ok((
            url.clone(),
            StatusCode::NOT_MODIFIED,
            HeaderMap::new(),
            Vec::new(),
        ))
    });

    let result = store
        .refresh_feed_forced(feed.id.clone(), true)
        .expect("manual refresh");

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert!(result.not_modified);
    assert!(!result.failed);
    let refreshed = store
        .snapshot()
        .expect("snapshot")
        .feeds
        .into_iter()
        .find(|candidate| candidate.id == feed.id)
        .expect("feed remains");
    assert_eq!(refreshed.refresh_failure_count, 0);
    assert_eq!(refreshed.next_retry_at, None);
    assert!(refreshed.next_refresh_at > now());
}

#[test]
fn eligible_automatic_refresh_fetches_and_persists_articles() {
    let store = RssReaderStore::default();
    let feed = add_feed(&store);
    let calls = Arc::new(AtomicUsize::new(0));
    let transport_calls = Arc::clone(&calls);
    let _transport = install_transport(&store, move |url, _, _, _| {
        transport_calls.fetch_add(1, Ordering::SeqCst);
        Ok((
            url.clone(),
            StatusCode::OK,
            HeaderMap::new(),
            test_feed_xml(),
        ))
    });

    let result = store
        .refresh_feed_forced(feed.id.clone(), false)
        .expect("automatic refresh");

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(result.fetched, 1);
    assert_eq!(result.inserted, 1);
    assert!(!result.failed);
    let page = store
        .list_articles(RssArticleQuery {
            query: None,
            scope: "feed".to_owned(),
            sort: "newest".to_owned(),
            feed_id: Some(feed.id.clone()),
            author: None,
            tag: None,
            offset: 0,
            limit: 10,
        })
        .expect("list fetched article");
    assert_eq!(page.total, 1);
    assert_eq!(page.articles.len(), 1);
    assert_eq!(page.articles[0].title, "Scheduled article");
    assert_eq!(page.articles[0].feed_id, feed.id);
    let refreshed = store
        .snapshot()
        .expect("snapshot")
        .feeds
        .into_iter()
        .find(|candidate| candidate.id == feed.id)
        .expect("feed remains");
    assert_eq!(refreshed.refresh_failure_count, 0);
    assert_eq!(refreshed.next_retry_at, None);
    assert!(refreshed.last_refreshed_at > 0);
    assert!(refreshed.next_refresh_at > refreshed.last_refreshed_at);
}

#[test]
fn refresh_failures_schedule_and_enforce_exponential_retry_backoff() {
    let store = RssReaderStore::default();
    let feed = add_feed(&store);
    let calls = Arc::new(AtomicUsize::new(0));
    let transport_calls = Arc::clone(&calls);
    let _transport = install_transport(&store, move |_, _, _, _| {
        transport_calls.fetch_add(1, Ordering::SeqCst);
        Err(CommandError::new(
            "rss_transport_error",
            "synthetic transport failure",
        ))
    });

    let first_started_at = now();
    let first = store
        .refresh_feed_forced(feed.id.clone(), false)
        .expect("record first failure");
    let first_finished_at = now();
    assert!(first.failed);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let first_feed = store
        .snapshot()
        .expect("first snapshot")
        .feeds
        .into_iter()
        .find(|candidate| candidate.id == feed.id)
        .expect("feed remains");
    let first_retry = first_feed.next_retry_at.expect("retry scheduled");
    assert_eq!(first_feed.refresh_failure_count, 1);
    assert!(first_retry >= first_started_at + 60);
    assert!(first_retry <= first_finished_at + 60);
    let issue = first.issue.expect("failure issue");
    assert_eq!(issue.stage, "transport");
    assert_eq!(issue.category, "network");
    assert_eq!(issue.retry_at, Some(first_retry));

    let deferred = store
        .refresh_feed_forced(feed.id.clone(), false)
        .expect("retry remains deferred");
    assert!(!deferred.failed);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let deferred_feed = store
        .snapshot()
        .expect("deferred snapshot")
        .feeds
        .into_iter()
        .find(|candidate| candidate.id == feed.id)
        .expect("feed remains");
    assert_eq!(deferred_feed.refresh_failure_count, 1);
    assert_eq!(deferred_feed.next_retry_at, Some(first_retry));

    let second_started_at = now();
    let second = store
        .refresh_feed_forced(feed.id.clone(), true)
        .expect("record forced retry failure");
    let second_finished_at = now();
    assert!(second.failed);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    let second_feed = store
        .snapshot()
        .expect("second snapshot")
        .feeds
        .into_iter()
        .find(|candidate| candidate.id == feed.id)
        .expect("feed remains");
    let second_retry = second_feed.next_retry_at.expect("second retry scheduled");
    assert_eq!(second_feed.refresh_failure_count, 2);
    assert!(second_retry >= second_started_at + 120);
    assert!(second_retry <= second_finished_at + 120);
    assert!(second_retry > first_retry);
}
