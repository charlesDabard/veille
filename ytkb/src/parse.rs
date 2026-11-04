use crate::model::{Chapter, Segment};
use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::VecDeque;

// ---- Whisper (sortie `whisper-cli --output-json`) ----

#[derive(Deserialize)]
struct WhisperDoc {
    result: Option<WhisperResult>,
    #[serde(default)]
    transcription: Vec<WhisperSeg>,
}
#[derive(Deserialize)]
struct WhisperResult {
    language: Option<String>,
}
#[derive(Deserialize)]
struct WhisperSeg {
    offsets: Option<WhisperOffsets>,
    text: Option<String>,
}
#[derive(Deserialize)]
struct WhisperOffsets {
    from: Option<f64>,
    to: Option<f64>,
}

pub struct WhisperOut {
    pub lang: Option<String>,
    pub segments: Vec<Segment>,
}

/// Parse la sortie `whisper-cli --output-json` en segments + langue détectée.
pub fn parse_whisper_json(raw: &str) -> Result<WhisperOut> {
    let doc: WhisperDoc = serde_json::from_str(raw).context("json whisper invalide")?;
    let lang = doc.result.and_then(|r| r.language).filter(|l| !l.is_empty());
    let mut segments = Vec::new();
    for seg in doc.transcription {
        let text = normalize_ws(seg.text.as_deref().unwrap_or(""));
        if text.is_empty() {
            continue;
        }
        let from = seg.offsets.as_ref().and_then(|o| o.from).unwrap_or(0.0);
        let to = seg.offsets.as_ref().and_then(|o| o.to).unwrap_or(from);
        segments.push(Segment {
            start: from / 1000.0,
            dur: (to - from).max(0.0) / 1000.0,
            text,
        });
    }
    Ok(WhisperOut { lang, segments })
}

// ---- json3 (format timedtext natif YouTube — jamais de duplication par construction) ----

#[derive(Deserialize)]
struct J3 {
    #[serde(default)]
    events: Vec<J3Event>,
}

#[derive(Deserialize)]
struct J3Event {
    #[serde(rename = "tStartMs")]
    t_start_ms: Option<f64>,
    #[serde(rename = "dDurationMs")]
    d_duration_ms: Option<f64>,
    segs: Option<Vec<J3Seg>>,
}

#[derive(Deserialize)]
struct J3Seg {
    utf8: Option<String>,
}

pub fn parse_json3(raw: &str) -> Result<Vec<Segment>> {
    let doc: J3 = serde_json::from_str(raw).context("json3 invalide")?;
    let mut out = Vec::new();
    for ev in doc.events {
        // events sans segs = définitions de fenêtre/style
        let Some(segs) = ev.segs else { continue };
        let concat: String = segs.iter().filter_map(|s| s.utf8.as_deref()).collect();
        let text = normalize_ws(&concat);
        if text.is_empty() {
            continue; // events newline-only (aAppend) et bruit
        }
        out.push(Segment {
            start: ev.t_start_ms.unwrap_or(0.0) / 1000.0,
            dur: ev.d_duration_ms.unwrap_or(0.0) / 1000.0,
            text,
        });
    }
    out.sort_by(|a, b| a.start.partial_cmp(&b.start).unwrap_or(std::cmp::Ordering::Equal));
    Ok(out)
}

// ---- VTT (fallback — l'auto-caption "rollup" ré-affiche la dernière ligne du cue précédent) ----

pub fn parse_vtt(raw: &str) -> Result<Vec<Segment>> {
    const W: usize = 8; // fenêtre de dédup, en lignes émises
    let mut out: Vec<Segment> = Vec::new();
    let mut window: VecDeque<String> = VecDeque::with_capacity(W + 1);

    let normalized = raw.replace("\r\n", "\n");
    for block in normalized.split("\n\n") {
        let lines: Vec<&str> = block.lines().collect();
        let Some(timing_idx) = lines.iter().position(|l| l.contains("-->")) else {
            continue; // en-tête WEBVTT, NOTE, STYLE, REGION
        };
        let timing = lines[timing_idx];
        let mut parts = timing.split("-->");
        let (Some(a), Some(b)) = (parts.next(), parts.next()) else {
            continue;
        };
        let Some(start) = parse_ts(a.trim()) else { continue };
        let end_str = b.trim().split_whitespace().next().unwrap_or("");
        let Some(end) = parse_ts(end_str) else { continue };
        let dur = (end - start).max(0.0);

        for line in &lines[timing_idx + 1..] {
            let cleaned = normalize_ws(&decode_entities(&strip_tags(line)));
            if cleaned.is_empty() {
                continue;
            }
            let key = cleaned.to_lowercase();
            if window.contains(&key) {
                continue; // doublon rollup
            }
            out.push(Segment {
                start,
                dur,
                text: cleaned,
            });
            window.push_back(key);
            if window.len() > W {
                window.pop_front();
            }
        }
    }
    Ok(out)
}

/// "H:MM:SS.mmm" ou "MM:SS.mmm" → secondes.
fn parse_ts(s: &str) -> Option<f64> {
    let fields: Vec<&str> = s.split(':').collect();
    let (h, m, rest) = match fields.as_slice() {
        [h, m, sec] => (h.parse::<f64>().ok()?, m.parse::<f64>().ok()?, *sec),
        [m, sec] => (0.0, m.parse::<f64>().ok()?, *sec),
        _ => return None,
    };
    let sec = rest.parse::<f64>().ok()?;
    Some(h * 3600.0 + m * 60.0 + sec)
}

/// Retire les tags inline (<c>, </c>, <00:00:00.920>, <v Speaker>) par scanner d'état.
fn strip_tags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            c if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

/// &amp; décodé en DERNIER (sinon &amp;lt; serait double-décodé).
fn decode_entities(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
}

fn normalize_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

// ---- Reconstruction du texte en paragraphes ----

pub fn build_text(segs: &[Segment], chapters: &[Chapter]) -> String {
    const GAP: f64 = 4.0; // s de silence → césure
    const SOFT: usize = 1200; // chars + fin de phrase → césure
    const HARD: usize = 2500; // garde-fou auto-captions sans ponctuation
    const EPS: f64 = 0.5;

    let mut paragraphs: Vec<String> = Vec::new();
    let mut cur = String::new();

    for (i, seg) in segs.iter().enumerate() {
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(&seg.text);

        let is_last = i + 1 == segs.len();
        let break_here = if is_last {
            true
        } else {
            let next = &segs[i + 1];
            let gap = next.start - (seg.start + seg.dur);
            let crosses_chapter = chapters
                .iter()
                .any(|c| c.start > seg.start + EPS && c.start <= next.start + EPS);
            gap > GAP
                || crosses_chapter
                || (cur.len() > SOFT && seg.text.ends_with(['.', '!', '?', '…']))
                || cur.len() > HARD
        };
        if break_here && !cur.is_empty() {
            paragraphs.push(std::mem::take(&mut cur));
        }
    }
    paragraphs.join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(start: f64, dur: f64, text: &str) -> Segment {
        Segment {
            start,
            dur,
            text: text.to_string(),
        }
    }

    #[test]
    fn whisper_json_basique() {
        let raw = r#"{"result":{"language":"fr"},"transcription":[
            {"offsets":{"from":0,"to":3000},"text":" Bonjour"},
            {"offsets":{"from":3000,"to":5200},"text":" tout le monde "}
        ]}"#;
        let out = parse_whisper_json(raw).unwrap();
        assert_eq!(out.lang.as_deref(), Some("fr"));
        assert_eq!(out.segments.len(), 2);
        assert_eq!(out.segments[0], seg(0.0, 3.0, "Bonjour"));
        assert_eq!(out.segments[1].start, 3.0);
    }

    #[test]
    fn whisper_json_vides_ignores_et_invalide() {
        let raw = r#"{"transcription":[{"offsets":{"from":0,"to":1000},"text":"   "}]}"#;
        let out = parse_whisper_json(raw).unwrap();
        assert_eq!(out.segments.len(), 0);
        assert_eq!(out.lang, None);
        assert!(parse_whisper_json("pas du json").is_err());
    }

    // ---- json3 ----

    #[test]
    fn json3_manuel_basique() {
        let raw = r#"{"wireMagic":"pb3","events":[
            {"tStartMs":280,"dDurationMs":3680,"segs":[{"utf8":"bonjour"},{"utf8":" à tous"}]},
            {"tStartMs":4000,"dDurationMs":2000,"segs":[{"utf8":"la suite"}]}
        ]}"#;
        let segs = parse_json3(raw).unwrap();
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0], seg(0.28, 3.68, "bonjour à tous"));
        assert_eq!(segs[1].text, "la suite");
    }

    #[test]
    fn json3_auto_rollup() {
        // event de fenêtre sans segs + events mots + aAppend newline-only
        let raw = r#"{"events":[
            {"tStartMs":0,"dDurationMs":540880,"id":1,"wpWinPosId":1,"wsWinStyleId":1},
            {"tStartMs":280,"dDurationMs":3680,"wWinId":1,"segs":[{"utf8":"hello","acAsrConf":216},{"utf8":" world","tOffsetMs":640}]},
            {"tStartMs":2150,"dDurationMs":1810,"wWinId":1,"aAppend":1,"segs":[{"utf8":"\n"}]},
            {"tStartMs":2160,"dDurationMs":2000,"wWinId":1,"segs":[{"utf8":"next words"}]}
        ]}"#;
        let segs = parse_json3(raw).unwrap();
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0].text, "hello world");
        assert_eq!(segs[1].text, "next words");
    }

    #[test]
    fn json3_degenere() {
        assert_eq!(parse_json3(r#"{"events":[]}"#).unwrap().len(), 0);
        assert_eq!(parse_json3(r#"{}"#).unwrap().len(), 0);
        // segs sans utf8
        let raw = r#"{"events":[{"tStartMs":0,"segs":[{"acAsrConf":100}]}]}"#;
        assert_eq!(parse_json3(raw).unwrap().len(), 0);
        assert!(parse_json3("garbage").is_err());
    }

    #[test]
    fn json3_normalisation_blancs() {
        let raw = r#"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"foo"},{"utf8":"\n"},{"utf8":"  bar"}]}]}"#;
        let segs = parse_json3(raw).unwrap();
        assert_eq!(segs[0].text, "foo bar");
    }

    // ---- vtt ----

    #[test]
    fn vtt_manuel_basique() {
        let raw = "WEBVTT\nKind: captions\nLanguage: fr\n\n00:01:02.500 --> 00:01:04.000\npremière ligne\n\n2\n00:01:04.000 --> 01:00:00.000 align:start position:0%\ndeuxième ligne\n";
        let segs = parse_vtt(raw).unwrap();
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[0], seg(62.5, 1.5, "première ligne"));
        assert_eq!(segs[1].start, 64.0);
    }

    #[test]
    fn vtt_rollup_dedup() {
        let raw = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nhello world\n\n00:00:03.000 --> 00:00:05.000\nhello world\nnext words here\n\n00:00:05.000 --> 00:00:07.000\nnext words here\nand the end\n";
        let segs = parse_vtt(raw).unwrap();
        let texts: Vec<&str> = segs.iter().map(|s| s.text.as_str()).collect();
        assert_eq!(texts, vec!["hello world", "next words here", "and the end"]);
    }

    #[test]
    fn vtt_tags_et_entites() {
        let raw = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n<v Bob>tom &amp; jerry <00:00:01.920><c>rule</c> &#39;ok&#39;\n";
        let segs = parse_vtt(raw).unwrap();
        assert_eq!(segs[0].text, "tom & jerry rule 'ok'");
    }

    #[test]
    fn vtt_note_style_ignores() {
        let raw = "WEBVTT\n\nNOTE\nceci est un commentaire\n\nSTYLE\n::cue { color: red }\n\n00:00:01.000 --> 00:00:02.000\ntexte\n";
        let segs = parse_vtt(raw).unwrap();
        assert_eq!(segs.len(), 1);
        assert_eq!(segs[0].text, "texte");
    }

    #[test]
    fn vtt_timing_sans_heures() {
        let raw = "WEBVTT\n\n01:02.500 --> 01:04.000\ntexte\n";
        let segs = parse_vtt(raw).unwrap();
        assert_eq!(segs[0].start, 62.5);
    }

    #[test]
    fn vtt_dedup_fenetre_bornee() {
        // même ligne répétée à distance > W lignes → conservée
        let mut raw = String::from("WEBVTT\n");
        raw.push_str("\n00:00:00.000 --> 00:00:01.000\nrefrain\n");
        for i in 0..9 {
            raw.push_str(&format!(
                "\n00:00:{:02}.000 --> 00:00:{:02}.000\nligne unique {i}\n",
                i + 1,
                i + 2
            ));
        }
        raw.push_str("\n00:00:20.000 --> 00:00:21.000\nrefrain\n");
        let segs = parse_vtt(&raw).unwrap();
        let refrains = segs.iter().filter(|s| s.text == "refrain").count();
        assert_eq!(refrains, 2);
    }

    // ---- build_text ----

    #[test]
    fn build_text_gap() {
        let segs = vec![seg(0.0, 2.0, "premier."), seg(10.0, 2.0, "second.")];
        assert_eq!(build_text(&segs, &[]), "premier.\n\nsecond.");
    }

    #[test]
    fn build_text_frontiere_chapitre() {
        let segs = vec![seg(0.0, 2.0, "intro"), seg(2.0, 2.0, "chapitre un")];
        let chapters = vec![Chapter {
            title: "Un".into(),
            start: 2.0,
            end: 4.0,
        }];
        assert_eq!(build_text(&segs, &chapters), "intro\n\nchapitre un");
    }

    #[test]
    fn build_text_continu() {
        let segs = vec![seg(0.0, 2.0, "a"), seg(2.0, 2.0, "b"), seg(4.0, 2.0, "c")];
        assert_eq!(build_text(&segs, &[]), "a b c");
    }
}
