use crate::model::{Chapter, InfoJson, Record, Segment, SubKind, VideoRef};
use crate::parse::{build_text, parse_json3, parse_vtt};
use crate::ytdlp::{YtdlpCtx, run_quiet};
use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};

pub fn fetch_video(
    v: &VideoRef,
    prefs: &[String],
    want_segments: bool,
    whisper: Option<&crate::whisper::WhisperCfg>,
    ctx: &YtdlpCtx,
) -> Result<Record> {
    let tmp = tempfile::Builder::new()
        .prefix("ytkb-")
        .tempdir()
        .context("création tempdir")?;
    let dir = tmp.path();

    // APPEL 1 — métadonnées seules (un seul hit de page)
    let mut c1 = ctx.base_cmd();
    c1.args([
        "--skip-download",
        "--write-info-json",
        "--no-write-playlist-metafiles",
        "--no-playlist",
        "-o",
        "%(id)s.%(ext)s",
        "-P",
    ])
    .arg(dir)
    .arg("--")
    .arg(&v.url);
    run_quiet(&mut c1).context("extraction métadonnées")?;

    let info_path = find_info_json(dir)?;
    let info: InfoJson = serde_json::from_str(&std::fs::read_to_string(&info_path)?)
        .context("parse info.json")?;

    if info.live_status.as_deref() == Some("is_live") {
        bail!("live en cours — pas de transcript");
    }

    let chapters: Vec<Chapter> = info
        .chapters
        .as_deref()
        .unwrap_or(&[])
        .iter()
        .filter_map(|c| {
            let start = c.start_time?;
            Some(Chapter {
                title: c.title.clone().unwrap_or_default(),
                start,
                end: c.end_time.unwrap_or(start),
            })
        })
        .collect();

    let track = select_track(&info, prefs);
    let (lang, sub_kind, segments) = match &track {
        Some((key, kind)) => {
            let segs = download_subs(dir, &info_path, &v.url, key, *kind, ctx)?;
            if segs.is_empty() {
                eprintln!("⚠ {}  transcript vide (piste {key})", info.id);
            }
            (Some(key.clone()), Some(*kind), segs)
        }
        None => match whisper {
            Some(cfg) => {
                let out = crate::whisper::transcribe(dir, &v.url, cfg, ctx)?;
                if out.segments.is_empty() {
                    eprintln!("⚠ {}  whisper: transcript vide", info.id);
                    (None, None, Vec::new())
                } else {
                    eprintln!(
                        "🎙  {}  transcrit via whisper ({} segments)",
                        info.id,
                        out.segments.len()
                    );
                    let lang = out.lang.or_else(|| info.language.clone());
                    (lang, Some(SubKind::Whisper), out.segments)
                }
            }
            None => {
                eprintln!("⚠ {}  pas de sous-titres disponibles", info.id);
                (None, None, Vec::new())
            }
        },
    };

    let text = if segments.is_empty() {
        None
    } else {
        Some(build_text(&segments, &chapters))
    };

    Ok(Record {
        id: info.id.clone(),
        url: info.webpage_url.clone().unwrap_or_else(|| v.url.clone()),
        title: info
            .title
            .clone()
            .or_else(|| v.title.clone())
            .unwrap_or_else(|| info.id.clone()),
        channel: info.channel.clone().or_else(|| info.uploader.clone()),
        channel_url: info.channel_url.clone(),
        upload_date: info.upload_date.as_deref().map(reformat_date),
        duration_sec: info.duration.map(|d| d.round() as u64),
        view_count: info.view_count,
        like_count: info.like_count,
        description: info.description.clone(),
        tags: info.tags.clone(),
        chapters,
        lang,
        sub_kind,
        text,
        segments: if want_segments && !segments.is_empty() {
            Some(segments)
        } else {
            None
        },
        fetched_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    })
}

/// Choix de piste — fidélité d'abord :
/// 1. manuel dans l'ordre de préférence (humain, langue voulue)
/// 2. manuel dans la langue ORIGINALE de la vidéo (humain + original)
/// 3. piste auto originale `*-orig` (ASR natif — les ~156 autres clés auto
///    sont des traductions machine, vérifié par probe)
/// 4. auto dans l'ordre de préférence (traduction machine, fallback)
/// 5. n'importe quel manuel, sinon première piste auto
pub fn select_track(info: &InfoJson, prefs: &[String]) -> Option<(String, SubKind)> {
    let manual_keys: Vec<&str> = info
        .subtitles
        .keys()
        .map(String::as_str)
        .filter(|k| *k != "live_chat")
        .collect();
    let auto_keys: Vec<&str> = info.automatic_captions.keys().map(String::as_str).collect();

    if let Some(k) = pick(&manual_keys, prefs) {
        return Some((k, SubKind::Manual));
    }
    if let Some(orig_lang) = &info.language {
        if let Some(k) = pick(&manual_keys, &[orig_lang.to_lowercase()]) {
            return Some((k, SubKind::Manual));
        }
    }
    let origs: Vec<&str> = auto_keys
        .iter()
        .copied()
        .filter(|k| k.to_lowercase().ends_with("-orig"))
        .collect();
    for p in prefs {
        let want = format!("{}-orig", p.to_lowercase());
        if let Some(k) = origs.iter().find(|k| k.to_lowercase() == want) {
            return Some((k.to_string(), SubKind::Auto));
        }
    }
    if let Some(k) = origs.first() {
        return Some((k.to_string(), SubKind::Auto));
    }
    if let Some(k) = pick(&auto_keys, prefs) {
        return Some((k, SubKind::Auto));
    }
    if let Some(k) = manual_keys.first() {
        return Some((k.to_string(), SubKind::Manual));
    }
    auto_keys.first().map(|k| (k.to_string(), SubKind::Auto))
}

/// exact > "<p>-orig" > préfixe "<p>-" (case-insensitive, clé originale retournée).
fn pick(keys: &[&str], prefs: &[String]) -> Option<String> {
    for p in prefs {
        let pl = p.to_lowercase();
        if let Some(k) = keys.iter().find(|k| k.to_lowercase() == pl) {
            return Some(k.to_string());
        }
        let orig = format!("{pl}-orig");
        if let Some(k) = keys.iter().find(|k| k.to_lowercase() == orig) {
            return Some(k.to_string());
        }
        let prefix = format!("{pl}-");
        if let Some(k) = keys.iter().find(|k| k.to_lowercase().starts_with(&prefix)) {
            return Some(k.to_string());
        }
    }
    None
}

fn sub_family_args(kind: SubKind) -> [&'static str; 2] {
    match kind {
        SubKind::Manual => ["--write-subs", "--no-write-auto-subs"],
        SubKind::Auto => ["--write-auto-subs", "--no-write-subs"],
        // Whisper ne passe jamais par le téléchargement de sous-titres yt-dlp
        SubKind::Whisper => unreachable!("sub_family_args ne reçoit que Manual/Auto"),
    }
}

/// APPEL 2 — captions ciblés. Réutilise info.json (zéro ré-extraction de page) ;
/// retry une fois en extraction fraîche si aucun fichier produit.
fn download_subs(
    dir: &Path,
    info_path: &Path,
    url: &str,
    key: &str,
    kind: SubKind,
    ctx: &YtdlpCtx,
) -> Result<Vec<Segment>> {
    let run = |fresh: bool| -> Result<()> {
        let mut c = ctx.base_cmd();
        c.arg("--skip-download");
        if !fresh {
            c.arg("--load-info-json").arg(info_path);
        }
        c.args(sub_family_args(kind))
            .args(["--sub-langs", key, "--sub-format", "json3/vtt", "-o", "%(id)s.%(ext)s", "-P"])
            .arg(dir);
        if fresh {
            c.arg("--").arg(url);
        }
        run_quiet(&mut c)
    };

    run(false).context("téléchargement sous-titres")?;
    if find_sub_file(dir).is_none() {
        run(true).context("téléchargement sous-titres (retry extraction fraîche)")?;
    }
    let Some((path, ext)) = find_sub_file(dir) else {
        bail!("piste '{key}' annoncée mais aucun fichier de sous-titres récupéré");
    };
    let raw = std::fs::read_to_string(&path)?;
    match ext {
        SubExt::Json3 => parse_json3(&raw),
        SubExt::Vtt => parse_vtt(&raw),
    }
}

enum SubExt {
    Json3,
    Vtt,
}

fn find_info_json(dir: &Path) -> Result<PathBuf> {
    for entry in std::fs::read_dir(dir)? {
        let p = entry?.path();
        if p.file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.ends_with(".info.json"))
        {
            return Ok(p);
        }
    }
    bail!("info.json introuvable après extraction")
}

/// Découverte par extension réelle (jamais par reconstruction de nom) : json3 prioritaire.
fn find_sub_file(dir: &Path) -> Option<(PathBuf, SubExt)> {
    let mut vtt: Option<PathBuf> = None;
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let p = entry.path();
        let Some(name) = p.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if name.ends_with(".info.json") {
            continue;
        }
        if name.ends_with(".json3") {
            return Some((p, SubExt::Json3));
        }
        if name.ends_with(".vtt") {
            vtt = Some(p.clone());
        }
    }
    vtt.map(|p| (p, SubExt::Vtt))
}

fn reformat_date(s: &str) -> String {
    if s.len() == 8 && s.chars().all(|c| c.is_ascii_digit()) {
        format!("{}-{}-{}", &s[0..4], &s[4..6], &s[6..8])
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn info(subs: &[&str], autos: &[&str], language: Option<&str>) -> InfoJson {
        let mk = |keys: &[&str]| {
            keys.iter()
                .map(|k| (k.to_string(), json!([{"ext": "json3"}])))
                .collect::<serde_json::Map<String, serde_json::Value>>()
        };
        serde_json::from_value(json!({
            "id": "xxxxxxxxxxx",
            "subtitles": mk(subs),
            "automatic_captions": mk(autos),
            "language": language,
        }))
        .unwrap()
    }

    #[test]
    fn select_manuel_prefere() {
        let i = info(&["en", "fr"], &["en-orig"], Some("en"));
        assert_eq!(
            select_track(&i, &["fr".into(), "en".into()]),
            Some(("fr".into(), SubKind::Manual))
        );
    }

    #[test]
    fn select_manuel_langue_originale_avant_auto() {
        // vidéo allemande avec sous-titres manuels de : humain + original > ASR
        let i = info(&["de"], &["de-orig", "fr", "en"], Some("de"));
        assert_eq!(
            select_track(&i, &["fr".into(), "en".into()]),
            Some(("de".into(), SubKind::Manual))
        );
    }

    #[test]
    fn select_auto_orig_avant_traduction_machine() {
        // cas réel fable-5 : 0 manuel, 157 pistes auto dont en-orig — fr serait une traduction
        let i = info(&[], &["en", "en-orig", "fr"], Some("en"));
        assert_eq!(
            select_track(&i, &["fr".into(), "en".into()]),
            Some(("en-orig".into(), SubKind::Auto))
        );
    }

    #[test]
    fn select_orig_hors_pref_avant_traduction() {
        // vidéo japonaise : ja-orig (fidèle) > fr (traduction machine)
        let i = info(&[], &["fr", "ja", "ja-orig"], Some("ja"));
        assert_eq!(
            select_track(&i, &["fr".into(), "en".into()]),
            Some(("ja-orig".into(), SubKind::Auto))
        );
    }

    #[test]
    fn select_auto_pref_si_aucun_orig() {
        let i = info(&[], &["fr", "ko"], None);
        assert_eq!(
            select_track(&i, &["fr".into(), "en".into()]),
            Some(("fr".into(), SubKind::Auto))
        );
    }

    #[test]
    fn select_any_manuel_en_dernier_recours_avant_auto() {
        let i = info(&["ko"], &["zh"], None);
        assert_eq!(
            select_track(&i, &["fr".into(), "en".into()]),
            Some(("ko".into(), SubKind::Manual))
        );
    }

    #[test]
    fn select_variante_locale() {
        let i = info(&["en-US"], &[], None);
        assert_eq!(
            select_track(&i, &["en".into()]),
            Some(("en-US".into(), SubKind::Manual))
        );
        // exact avant variante
        let i = info(&["en", "en-US"], &[], None);
        assert_eq!(
            select_track(&i, &["en".into()]),
            Some(("en".into(), SubKind::Manual))
        );
    }

    #[test]
    fn select_live_chat_exclu() {
        let i = info(&["live_chat"], &[], None);
        assert_eq!(select_track(&i, &["fr".into()]), None);
    }

    #[test]
    fn select_rien() {
        let i = info(&[], &[], None);
        assert_eq!(select_track(&i, &["fr".into()]), None);
    }

    #[test]
    fn reformat_date_ok_et_passthrough() {
        assert_eq!(reformat_date("20260515"), "2026-05-15");
        assert_eq!(reformat_date("garbage"), "garbage");
    }
}
