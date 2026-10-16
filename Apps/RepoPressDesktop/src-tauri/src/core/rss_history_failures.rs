//! Durable failures remain independent of the currently reviewed candidate batch.
use super::*;

const MAX_FAILURES: usize = 50_000;
const MAX_FAILURE_BYTES: usize = 32 * 1024;
#[derive(Serialize, Deserialize)]
struct FailureRecord {
    candidate: RssHistoryCandidate,
    target: Option<ExistingTarget>,
}
fn failure_capacity() -> CommandError {
    CommandError::new(
        "rss_history_failure_capacity",
        "History failure ledger exceeds its bounded capacity. The saved checkpoint was preserved.",
    )
}
fn failure_count(c: &Connection, id: &str) -> CommandResult<usize> {
    let count: usize = c
        .query_row(
            "SELECT count(*) FROM history_failures WHERE job_id=?",
            [id],
            |r| r.get(0),
        )
        .map_err(db_err)?;
    if count > MAX_FAILURES {
        return Err(failure_capacity());
    }
    Ok(count)
}
pub(super) fn hydrate_failures(c: &Connection, cp: &mut Checkpoint) -> CommandResult<()> {
    let mut count = failure_count(c, &cp.job.id)?;
    let mut seen = HashSet::new();
    for candidate in cp.job.candidates.iter().filter(|v| v.status == "failed") {
        if seen.insert(&candidate.url)
            && !c
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM history_failures WHERE job_id=? AND url=?)",
                    params![cp.job.id, candidate.url],
                    |r| r.get::<_, bool>(0),
                )
                .map_err(db_err)?
        {
            count += 1;
        }
    }
    if count > MAX_FAILURES {
        return Err(failure_capacity());
    }
    cp.failure_count = count;
    sync_counts(cp);
    Ok(())
}
// Call only inside the transaction that also saves the checkpoint / article.
fn persist_failures(c: &Connection, cp: &mut Checkpoint) -> CommandResult<()> {
    for candidate in &cp.job.candidates {
        if candidate.status == "failed" {
            let record = FailureRecord {
                candidate: candidate.clone(),
                target: cp.targets.get(&candidate.url).cloned(),
            };
            let json = serde_json::to_string(&record).map_err(|_| invalid())?;
            if json.len() > MAX_FAILURE_BYTES {
                return Err(failure_capacity());
            }
            c.execute("INSERT INTO history_failures(job_id,url,candidate_json) VALUES(?,?,?) ON CONFLICT(job_id,url) DO UPDATE SET candidate_json=excluded.candidate_json WHERE history_failures.candidate_json<>excluded.candidate_json", params![cp.job.id,candidate.url,json]).map_err(db_err)?;
        } else if matches!(candidate.status.as_str(), "added" | "updated" | "duplicate") {
            c.execute(
                "DELETE FROM history_failures WHERE job_id=? AND url=?",
                params![cp.job.id, candidate.url],
            )
            .map_err(db_err)?;
        }
    }
    cp.failure_count = failure_count(c, &cp.job.id)?;
    sync_counts(cp);
    Ok(())
}
pub(super) fn save_progress(c: &Connection, cp: &mut Checkpoint) -> CommandResult<()> {
    persist_failures(c, cp)?;
    save(c, cp)
}
fn archive_batch(cp: &mut Checkpoint) {
    cp.totals.added = cp.job.added_count;
    cp.totals.duplicate = cp.job.duplicate_count;
    cp.totals.updated = cp.job.updated_count;
    cp.totals.discovered = cp.job.discovered_count;
    cp.job.candidates.clear();
    cp.targets.clear();
    cp.job.status = "preview".into();
    cp.job.message = None;
    cp.job.reached_limit = false;
}
pub(super) fn check_batch_idle(cp: &Checkpoint) -> CommandResult<()> {
    if cp.in_flight
        || cp.job.status == "running"
        || cp.job.candidates.iter().any(|v| v.status == "pending")
    {
        return Err(CommandError::new(
            "rss_history_busy",
            "Finish the pending history batch before preparing another batch.",
        ));
    }
    Ok(())
}
impl RssReaderStore {
    pub fn history_prepare_retry(
        &self,
        input: RssHistoryRetryInput,
    ) -> CommandResult<RssHistoryJob> {
        if !(1..=500).contains(&input.max_articles) {
            return Err(invalid());
        }
        let c = self.db.lock().map_err(|_| lock_err())?;
        let tx = c.unchecked_transaction().map_err(db_err)?;
        let mut cp = load(&tx, &input.job_id)?;
        check_batch_idle(&cp)?;
        if self
            .history_busy
            .lock()
            .map_err(|_| lock_err())?
            .contains(&cp.job.feed_id)
            || binding(&tx, &cp.job.feed_id)? != cp.binding
        {
            return Err(stopped());
        }
        persist_failures(&tx, &mut cp)?;
        if cp.failure_count == 0 {
            return Err(CommandError::new(
                "rss_history_no_failures",
                "No unresolved history failures remain.",
            ));
        }
        let read_batch = |after: Option<&str>| -> CommandResult<Vec<(String, String)>> {
            let mut query = tx.prepare("SELECT url,candidate_json FROM history_failures WHERE job_id=? AND (? IS NULL OR url>?) ORDER BY url LIMIT ?").map_err(db_err)?;
            let rows = query
                .query_map(params![cp.job.id, after, after, input.max_articles], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .map_err(db_err)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(db_err)?;
            Ok(rows)
        };
        let mut rows = read_batch(cp.failure_retry_after_url.as_deref())?;
        if rows.is_empty() {
            rows = read_batch(None)?;
        }
        if rows.is_empty() {
            return Err(invalid());
        }
        archive_batch(&mut cp);
        cp.job.retrying_failures = true;
        cp.failure_retry_after_url = rows.last().map(|v| v.0.clone());
        let origin = Url::parse(&cp.job.directory_url).map_err(|_| invalid())?;
        for (url, json) in rows {
            if json.len() > MAX_FAILURE_BYTES {
                return Err(failure_capacity());
            }
            let mut record: FailureRecord = serde_json::from_str(&json).map_err(|_| invalid())?;
            if record.candidate.url != url
                || record.candidate.status != "failed"
                || !matches!(record.candidate.kind.as_str(), "article" | "fullText")
            {
                return Err(invalid());
            }
            check_history_url(&Url::parse(&url).map_err(|_| invalid())?, &origin)?;
            if let Some(old) = record.target {
                let current = existing_article(&tx, &old.id)?
                    .filter(|v| v.target.url == old.url)
                    .map(|v| v.target)
                    .unwrap_or(old);
                cp.targets.insert(url.clone(), current);
            } else if cp.job.fill_existing {
                if let Some(current) = existing_by_url(&tx, &cp.job.feed_id, &url)? {
                    cp.targets.insert(url.clone(), current.target);
                }
            }
            record.candidate.status = "pending".into();
            record.candidate.message = None;
            cp.job.candidates.push(record.candidate);
        }
        save_progress(&tx, &mut cp)?;
        tx.commit().map_err(db_err)?;
        Ok(cp.job)
    }
    pub(super) fn advance_discovery_batch(
        &self,
        cp: &mut Checkpoint,
        expected: &mut String,
        token: &str,
    ) -> CommandResult<()> {
        let c = self.db.lock().map_err(|_| lock_err())?;
        let tx = c.unchecked_transaction().map_err(db_err)?;
        let current: Option<String> = tx
            .query_row(
                "SELECT payload FROM history_jobs WHERE id=? AND feed_id=?",
                params![cp.job.id, cp.job.feed_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_err)?;
        if current.as_deref() != Some(expected.as_str())
            || binding(&tx, &cp.job.feed_id)? != cp.binding
        {
            return Err(stopped());
        }
        let cancelled = self.history_cancelled.lock().map_err(|_| lock_err())?;
        if cancelled.len() >= 64 || cancelled.contains_key(token) {
            return Err(stopped());
        }
        persist_failures(&tx, cp)?;
        archive_batch(cp);
        cp.job.retrying_failures = false;
        save_progress(&tx, cp)?;
        *expected = serde_json::to_string(cp).map_err(|_| invalid())?;
        tx.commit().map_err(db_err)?;
        drop(cancelled);
        Ok(())
    }
}
