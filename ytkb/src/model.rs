use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

// ---- Sortie NDJSON ----

#[derive(Serialize, Clone, Debug)]
pub struct VideoRef {
    pub id: String,
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_sec: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub view_count: Option<u64>,
}

#[derive(Serialize, PartialEq, Clone, Debug)]
pub struct Segment {
    pub start: f64,
    pub dur: f64,
    pub text: String,
}

#[derive(Serialize, Clone, Debug)]
pub struct Chapter {
    pub title: String,
    pub start: f64,
    pub end: f64,
}

#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum SubKind {
    Manual,
    Auto,
    Whisper,
}

#[derive(Serialize, Debug)]
pub struct Record {
    pub id: String,
    pub url: String,
    pub title: String,
    pub channel: Option<String>,
    pub channel_url: Option<String>,
    pub upload_date: Option<String>,
    pub duration_sec: Option<u64>,
    pub view_count: Option<u64>,
    pub like_count: Option<u64>,
    pub description: Option<String>,
    pub tags: Vec<String>,
    pub chapters: Vec<Chapter>,
    pub lang: Option<String>,
    pub sub_kind: Option<SubKind>,
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub segments: Option<Vec<Segment>>,
    pub fetched_at: String,
}

#[derive(Serialize, Debug)]
pub struct ErrorRecord {
    pub id: Option<String>,
    pub url: String,
    pub error: String,
}

// ---- Désérialisation yt-dlp (souple : tout Option / default) ----

#[derive(Deserialize, Debug)]
pub struct InfoJson {
    pub id: String,
    pub title: Option<String>,
    pub webpage_url: Option<String>,
    pub channel: Option<String>,
    pub uploader: Option<String>,
    pub channel_url: Option<String>,
    pub upload_date: Option<String>,
    pub duration: Option<f64>,
    pub view_count: Option<u64>,
    pub like_count: Option<u64>,
    pub description: Option<String>,
    pub language: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub chapters: Option<Vec<InfoChapter>>,
    // seules les CLÉS (codes langue) sont exploitées — les valeurs (formats/urls)
    // restent à yt-dlp, qui fait lui-même le fetch des captions
    #[serde(default)]
    pub subtitles: BTreeMap<String, serde_json::Value>,
    #[serde(default)]
    pub automatic_captions: BTreeMap<String, serde_json::Value>,
    pub live_status: Option<String>,
}

#[derive(Deserialize, Debug)]
pub struct InfoChapter {
    pub title: Option<String>,
    pub start_time: Option<f64>,
    pub end_time: Option<f64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subkind_whisper_serialise_en_lowercase() {
        assert_eq!(serde_json::to_string(&SubKind::Whisper).unwrap(), "\"whisper\"");
    }
}
