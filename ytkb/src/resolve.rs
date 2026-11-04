use crate::input::Source;
use crate::model::VideoRef;
use crate::ytdlp::{YtdlpCtx, run_capture};
use anyhow::{Context, Result};
use serde_json::Value;

pub fn resolve(src: &Source, ctx: &YtdlpCtx) -> Result<Vec<VideoRef>> {
    match src {
        Source::DirectVideo { url, id } => Ok(vec![VideoRef {
            id: id.clone(),
            url: url.clone(),
            title: None,
            channel: None,
            duration_sec: None,
            view_count: None,
        }]),
        Source::Expandable(target) => expand(target, None, ctx),
        Source::Search { target, limit } => expand(target, *limit, ctx),
    }
}

fn expand(target: &str, limit: Option<u32>, ctx: &YtdlpCtx) -> Result<Vec<VideoRef>> {
    let mut cmd = ctx.base_cmd();
    cmd.arg("--flat-playlist").arg("-J");
    if let Some(n) = limit {
        cmd.arg("-I").arg(format!("1:{n}"));
    }
    // `--` seulement devant une vraie URL : il casse les pseudo-schemes
    // ytsearch*: (yt-dlp les traiterait en URLs littérales)
    if target.starts_with("http") {
        cmd.arg("--");
    }
    cmd.arg(target);
    let raw = run_capture(&mut cmd).with_context(|| format!("résolution de {target}"))?;
    parse_flat_json(&raw)
}

/// Trois shapes possibles : playlist {entries:[...]}, entries imbriquées
/// (onglets de chaîne, profondeur 2 max), ou objet vidéo seul.
pub fn parse_flat_json(raw: &str) -> Result<Vec<VideoRef>> {
    let v: Value = serde_json::from_str(raw.trim()).context("JSON yt-dlp invalide")?;
    let mut out = Vec::new();
    collect_refs(&v, 0, &mut out);
    Ok(out)
}

fn collect_refs(v: &Value, depth: u8, out: &mut Vec<VideoRef>) {
    if let Some(entries) = v.get("entries").and_then(Value::as_array) {
        if depth >= 2 {
            return;
        }
        for e in entries {
            collect_refs(e, depth + 1, out);
        }
        return;
    }
    // feuille — ignorer les sous-playlists non chargées (onglets)
    let typ = v.get("_type").and_then(Value::as_str).unwrap_or("video");
    if typ == "playlist" {
        return;
    }
    if v.get("ie_key").and_then(Value::as_str) == Some("YoutubeTab") {
        return;
    }
    let id = v.get("id").and_then(Value::as_str);
    let url = v
        .get("url")
        .and_then(Value::as_str)
        .or_else(|| v.get("webpage_url").and_then(Value::as_str));
    let (Some(id), Some(url)) = (id, url) else {
        return;
    };
    out.push(VideoRef {
        id: id.to_string(),
        url: url.to_string(),
        title: v.get("title").and_then(Value::as_str).map(str::to_string),
        channel: v
            .get("channel")
            .and_then(Value::as_str)
            .or_else(|| v.get("uploader").and_then(Value::as_str))
            .map(str::to_string),
        duration_sec: v
            .get("duration")
            .and_then(Value::as_f64)
            .map(|d| d.round() as u64),
        view_count: v.get("view_count").and_then(Value::as_u64),
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flat_playlist_basique() {
        let raw = r#"{"_type":"playlist","entries":[
            {"_type":"url","ie_key":"Youtube","id":"aaaaaaaaaaa","url":"https://www.youtube.com/watch?v=aaaaaaaaaaa","title":"A","channel":"ChA","duration":114.4,"view_count":42},
            {"_type":"url","ie_key":"Youtube","id":"bbbbbbbbbbb","url":"https://www.youtube.com/watch?v=bbbbbbbbbbb","title":"B","channel":null,"uploader":"UpB","duration":null,"view_count":null}
        ]}"#;
        let refs = parse_flat_json(raw).unwrap();
        assert_eq!(refs.len(), 2);
        assert_eq!(refs[0].id, "aaaaaaaaaaa");
        assert_eq!(refs[0].duration_sec, Some(114));
        assert_eq!(refs[0].view_count, Some(42));
        assert_eq!(refs[1].channel.as_deref(), Some("UpB"));
        assert_eq!(refs[1].duration_sec, None);
    }

    #[test]
    fn flat_video_seule() {
        let raw = r#"{"id":"ccccccccccc","webpage_url":"https://www.youtube.com/watch?v=ccccccccccc","title":"C"}"#;
        let refs = parse_flat_json(raw).unwrap();
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].url, "https://www.youtube.com/watch?v=ccccccccccc");
    }

    #[test]
    fn flat_imbrique_onglets() {
        let raw = r#"{"_type":"playlist","entries":[
            {"_type":"playlist","entries":[
                {"_type":"url","id":"ddddddddddd","url":"https://www.youtube.com/watch?v=ddddddddddd","title":"D"}
            ]},
            {"_type":"playlist","id":"shorts-tab","url":"https://www.youtube.com/@x/shorts"}
        ]}"#;
        let refs = parse_flat_json(raw).unwrap();
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].id, "ddddddddddd");
    }

    #[test]
    fn flat_entries_lacunaires_ignorees() {
        let raw = r#"{"entries":[{"title":"sans id ni url"},{"id":"eeeeeeeeeee","url":"https://youtu.be/eeeeeeeeeee"}]}"#;
        let refs = parse_flat_json(raw).unwrap();
        assert_eq!(refs.len(), 1);
    }

    #[test]
    fn flat_json_invalide() {
        assert!(parse_flat_json("pas du json").is_err());
    }
}
