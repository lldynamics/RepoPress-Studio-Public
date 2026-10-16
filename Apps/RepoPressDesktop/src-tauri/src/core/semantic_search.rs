//! Querying for the in-memory offline semantic index.

use super::semantic_index::{
    normalized_embedding, semantic_features, SemanticIndexStore, EMBEDDING_DIMENSIONS,
    SEMANTIC_ENCODING_VERSION, SEMANTIC_MODEL_ID,
};
use super::{CommandError, CommandResult};
use serde::Serialize;
use std::cmp::Ordering;
use std::collections::HashSet;

const MAX_QUERY_CHARS: usize = 300;
const MAX_RESULTS: usize = 50;
const MAX_SNIPPET_CHARS: usize = 280;

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SemanticSearchResult {
    pub chunk_id: String,
    pub path: String,
    pub line: u32,
    pub end_line: u32,
    pub heading: Option<String>,
    pub score: f32,
    pub lexical_score: f32,
    pub semantic_score: f32,
    pub snippet: String,
    pub reason: String,
    pub model_id: String,
    pub encoding_version: u32,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SemanticSearchSnapshot {
    pub query: String,
    pub model_id: String,
    pub encoding_version: u32,
    pub results: Vec<SemanticSearchResult>,
    pub truncated: bool,
}

impl SemanticIndexStore {
    /// Search an already-built session index. Query strings are deliberately
    /// neither persisted nor logged by this module.
    pub fn search(
        &self,
        session_id: &str,
        query: &str,
        requested_limit: usize,
    ) -> CommandResult<SemanticSearchSnapshot> {
        let query = validate_query(query)?;
        let limit = requested_limit.clamp(1, MAX_RESULTS);
        let query_features = semantic_features(query);
        let query_embedding = normalized_embedding(&query_features);
        let query_terms = query_features.into_iter().collect::<HashSet<_>>();
        let index = self.index_for_search(session_id)?;
        let mut scored = Vec::new();
        for file in index.files.values() {
            for chunk in &file.chunks {
                let semantic_score = cosine(&query_embedding, &chunk.embedding);
                let lexical_score = lexical_overlap(&query_terms, &chunk.terms);
                // A direct feature hit makes exact terms useful, while the
                // cosine component permits synonyms and CJK semantic groups.
                let score = (semantic_score * 0.78 + lexical_score * 0.22).clamp(-1.0, 1.0);
                if score <= 0.0 {
                    continue;
                }
                scored.push(SemanticSearchResult {
                    chunk_id: chunk.id.clone(),
                    path: chunk.path.clone(),
                    line: chunk.start_line,
                    end_line: chunk.end_line,
                    heading: chunk.heading.clone(),
                    score,
                    lexical_score,
                    semantic_score,
                    snippet: bounded_snippet(&chunk.text),
                    reason: match (lexical_score > 0.0, semantic_score > 0.0) {
                        (true, true) => "lexical match and semantic feature similarity".to_string(),
                        (true, false) => "lexical feature match".to_string(),
                        (false, true) => "semantic feature similarity".to_string(),
                        (false, false) => "semantic ranking".to_string(),
                    },
                    model_id: SEMANTIC_MODEL_ID.to_string(),
                    encoding_version: SEMANTIC_ENCODING_VERSION,
                });
            }
        }
        scored.sort_by(|left, right| {
            right
                .score
                .partial_cmp(&left.score)
                .unwrap_or(Ordering::Equal)
                .then_with(|| left.path.cmp(&right.path))
                .then_with(|| left.line.cmp(&right.line))
                .then_with(|| left.chunk_id.cmp(&right.chunk_id))
        });
        let truncated = scored.len() > limit;
        scored.truncate(limit);
        Ok(SemanticSearchSnapshot {
            query: query.to_string(),
            model_id: SEMANTIC_MODEL_ID.to_string(),
            encoding_version: SEMANTIC_ENCODING_VERSION,
            results: scored,
            truncated,
        })
    }
}

fn validate_query(query: &str) -> CommandResult<&str> {
    let query = query.trim();
    if query.is_empty() {
        return Err(CommandError::new(
            "invalid_semantic_query",
            "Semantic-search queries cannot be empty.",
        ));
    }
    if query.chars().count() > MAX_QUERY_CHARS || query.chars().any(char::is_control) {
        return Err(CommandError::new(
            "invalid_semantic_query",
            format!(
                "Semantic-search queries must contain at most {MAX_QUERY_CHARS} printable characters."
            ),
        ));
    }
    Ok(query)
}

fn cosine(left: &[f32], right: &[f32]) -> f32 {
    debug_assert_eq!(left.len(), EMBEDDING_DIMENSIONS);
    debug_assert_eq!(right.len(), EMBEDDING_DIMENSIONS);
    left.iter()
        .zip(right)
        .map(|(left, right)| left * right)
        .sum::<f32>()
        .clamp(-1.0, 1.0)
}

fn lexical_overlap(query_terms: &HashSet<String>, chunk_terms: &[String]) -> f32 {
    if query_terms.is_empty() || chunk_terms.is_empty() {
        return 0.0;
    }
    let matched = chunk_terms
        .iter()
        .filter(|term| query_terms.contains(*term))
        .count();
    matched as f32 / query_terms.len().min(chunk_terms.len()) as f32
}

fn bounded_snippet(value: &str) -> String {
    let single_line = value.replace(['\r', '\n'], " ");
    let mut result = single_line
        .chars()
        .take(MAX_SNIPPET_CHARS)
        .collect::<String>();
    if single_line.chars().count() > MAX_SNIPPET_CHARS {
        result.push('…');
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn ranks_a_non_literal_chinese_semantic_relation() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(
            directory.path().join("cars.md"),
            "# 汽车保养\n定期保养可以延长使用寿命。",
        )
        .unwrap();
        fs::write(directory.path().join("other.md"), "# 食谱\n烹饪技巧。").unwrap();
        let store = SemanticIndexStore::default();
        store.rebuild("session", directory.path()).unwrap();
        let result = store.search("session", "车辆维护", 10).unwrap();
        assert_eq!(result.results[0].path, "cars.md");
        assert!(result.results[0].semantic_score > 0.0);
        assert!(result.results[0].reason.contains("semantic"));
    }

    #[test]
    fn is_deterministic_and_limits_results() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("a.md"), "release deployment notes").unwrap();
        fs::write(directory.path().join("b.md"), "publish release checklist").unwrap();
        let store = SemanticIndexStore::default();
        store.rebuild("session", directory.path()).unwrap();
        let first = store.search("session", "deploy", 1).unwrap();
        let second = store.search("session", "deploy", 1).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.results.len(), 1);
        assert!(first.truncated);
    }

    #[test]
    fn rejects_empty_and_control_character_queries() {
        let store = SemanticIndexStore::default();
        assert!(store.search("missing", " ", 10).is_err());
        assert!(store.search("missing", "bad\u{0007}", 10).is_err());
    }
}
