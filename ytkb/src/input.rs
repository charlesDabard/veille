use crate::cli::Cli;
use anyhow::{Context, Result, bail};
use std::io::Read;

#[derive(Debug, Clone, PartialEq)]
pub enum Source {
    DirectVideo { url: String, id: String },
    Expandable(String),
    Search { target: String, limit: Option<u32> },
}

impl Source {
    pub fn display_target(&self) -> &str {
        match self {
            Source::DirectVideo { url, .. } => url,
            Source::Expandable(t) => t,
            Source::Search { target, .. } => target,
        }
    }
}

pub fn collect(cli: &Cli) -> Result<Vec<Source>> {
    let mut raws: Vec<String> = cli.urls.clone();

    if let Some(path) = &cli.file {
        let content = if path == "-" {
            let mut s = String::new();
            std::io::stdin()
                .read_to_string(&mut s)
                .context("lecture stdin")?;
            s
        } else {
            std::fs::read_to_string(path).with_context(|| format!("lecture {path}"))?
        };
        for line in content.lines() {
            let t = line.trim();
            if t.is_empty() || t.starts_with('#') {
                continue;
            }
            raws.push(t.to_string());
        }
    }

    let mut sources: Vec<Source> = raws.iter().map(|r| classify(r)).collect();

    if let Some(q) = &cli.search {
        sources.push(search_target(q, cli.max, cli.recent));
    }

    if sources.is_empty() {
        bail!("aucune entrée : passe des URLs, -f FILE ou --search \"query\" (voir --help)");
    }
    Ok(sources)
}

/// Recherche : ytsearchN: par pertinence ; pour --recent, le pseudo-scheme
/// ytsearchdate a été retiré de yt-dlp (2026.x) → URL de résultats avec le
/// filtre "Upload date" (sp=CAI%3D), bornée côté resolve par -I 1:N.
pub fn search_target(query: &str, max: u32, recent: bool) -> Source {
    if recent {
        Source::Search {
            target: format!(
                "https://www.youtube.com/results?search_query={}&sp=CAI%3D",
                encode_query(query)
            ),
            limit: Some(max),
        }
    } else {
        Source::Search {
            target: format!("ytsearch{max}:{query}"),
            limit: None,
        }
    }
}

/// Encodage minimal de query string : espace → +, le reste hors [A-Za-z0-9-._~] → %XX.
fn encode_query(q: &str) -> String {
    let mut out = String::with_capacity(q.len());
    for b in q.bytes() {
        match b {
            b' ' => out.push('+'),
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

pub fn classify(raw: &str) -> Source {
    let r = raw.trim();
    if r.contains("list=") {
        return Source::Expandable(r.to_string());
    }
    if let Some(id) = extract_video_id(r) {
        return Source::DirectVideo {
            url: r.to_string(),
            id,
        };
    }
    Source::Expandable(normalize_channel(r))
}

/// Extrait un id vidéo (11 chars [A-Za-z0-9_-]) des formes watch?v=, youtu.be/, /shorts/, /live/.
pub fn extract_video_id(url: &str) -> Option<String> {
    let candidates = [
        url.split_once("watch?").and_then(|(_, q)| {
            q.split('&')
                .find_map(|kv| kv.strip_prefix("v="))
                .map(str::to_string)
        }),
        url.split_once("youtu.be/").map(|(_, rest)| rest.to_string()),
        url.split_once("/shorts/").map(|(_, rest)| rest.to_string()),
        url.split_once("/live/").map(|(_, rest)| rest.to_string()),
    ];
    for c in candidates.into_iter().flatten() {
        let id: String = c
            .chars()
            .take_while(|ch| ch.is_ascii_alphanumeric() || *ch == '_' || *ch == '-')
            .collect();
        if id.len() == 11 {
            return Some(id);
        }
    }
    None
}

/// Racine de chaîne (/@x, /channel/x, /c/x, /user/x sans sous-path) → suffixe /videos
/// (évite la playlist d'onglets imbriquée Videos/Shorts/Live au flat-playlist).
fn normalize_channel(url: &str) -> String {
    let u = url.trim_end_matches('/');
    if let Some((_, path)) = u.split_once("youtube.com/") {
        let parts: Vec<&str> = path.split('/').collect();
        let is_channel_root = match parts.as_slice() {
            [p] if p.starts_with('@') => true,
            ["channel", _] | ["c", _] | ["user", _] => true,
            _ => false,
        };
        if is_channel_root {
            return format!("{u}/videos");
        }
    }
    u.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn direct(url: &str, id: &str) -> Source {
        Source::DirectVideo {
            url: url.to_string(),
            id: id.to_string(),
        }
    }

    #[test]
    fn classify_watch() {
        let u = "https://www.youtube.com/watch?v=Y9Wz2PV404E";
        assert_eq!(classify(u), direct(u, "Y9Wz2PV404E"));
    }

    #[test]
    fn classify_watch_avec_params() {
        let u = "https://www.youtube.com/watch?app=desktop&v=Y9Wz2PV404E&t=30s";
        assert_eq!(classify(u), direct(u, "Y9Wz2PV404E"));
    }

    #[test]
    fn classify_youtu_be() {
        let u = "https://youtu.be/Y9Wz2PV404E?si=abc";
        assert_eq!(classify(u), direct(u, "Y9Wz2PV404E"));
    }

    #[test]
    fn classify_shorts_et_live() {
        let s = "https://www.youtube.com/shorts/Y9Wz2PV404E";
        let l = "https://www.youtube.com/live/Y9Wz2PV404E/";
        assert_eq!(classify(s), direct(s, "Y9Wz2PV404E"));
        assert_eq!(classify(l), direct(l, "Y9Wz2PV404E"));
    }

    #[test]
    fn classify_watch_avec_list_est_expandable() {
        let u = "https://www.youtube.com/watch?v=Y9Wz2PV404E&list=PLabc";
        assert_eq!(classify(u), Source::Expandable(u.to_string()));
    }

    #[test]
    fn classify_handle_normalise_videos() {
        assert_eq!(
            classify("https://www.youtube.com/@AnthropicAI/"),
            Source::Expandable("https://www.youtube.com/@AnthropicAI/videos".to_string())
        );
        // déjà sur /videos : inchangé
        assert_eq!(
            classify("https://www.youtube.com/@AnthropicAI/videos"),
            Source::Expandable("https://www.youtube.com/@AnthropicAI/videos".to_string())
        );
    }

    #[test]
    fn classify_channel_et_user() {
        assert_eq!(
            classify("https://www.youtube.com/channel/UCabc123"),
            Source::Expandable("https://www.youtube.com/channel/UCabc123/videos".to_string())
        );
        assert_eq!(
            classify("https://www.youtube.com/user/somebody"),
            Source::Expandable("https://www.youtube.com/user/somebody/videos".to_string())
        );
    }

    #[test]
    fn extract_id_invalide() {
        assert_eq!(extract_video_id("https://www.youtube.com/watch?v=short"), None);
        assert_eq!(extract_video_id("https://example.com/foo"), None);
    }

    #[test]
    fn search_target_pertinence() {
        assert_eq!(
            search_target("claude fable 5", 10, false),
            Source::Search {
                target: "ytsearch10:claude fable 5".to_string(),
                limit: None
            }
        );
    }

    #[test]
    fn search_target_recent_encode_et_borne() {
        assert_eq!(
            search_target("claude fable 5 & co", 15, true),
            Source::Search {
                target: "https://www.youtube.com/results?search_query=claude+fable+5+%26+co&sp=CAI%3D"
                    .to_string(),
                limit: Some(15)
            }
        );
    }
}
