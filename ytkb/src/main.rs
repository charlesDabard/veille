mod cli;
mod fetch;
mod input;
mod model;
mod parse;
mod resolve;
mod whisper;
mod ytdlp;

use clap::Parser;
use cli::{Cli, parse_langs};
use model::ErrorRecord;
use std::io::Write;
use ytdlp::YtdlpCtx;

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    let cli = Cli::parse();
    let prefs = parse_langs(&cli.lang);
    let ctx = YtdlpCtx {
        cookies_from_browser: cli.cookies_from_browser.clone(),
        extra_args: cli.ytdlp_args.clone(),
    };
    let whisper = if cli.transcribe {
        Some(whisper::WhisperCfg {
            model: cli.whisper_model.clone(),
            lang: cli.whisper_lang.clone(),
        })
    } else {
        None
    };

    let sources = match input::collect(&cli) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("ytkb: {e:#}");
            return 2;
        }
    };

    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let mut ok: usize = 0;
    let mut failed: usize = 0;

    for src in &sources {
        let refs = match resolve::resolve(src, &ctx) {
            Ok(r) => r,
            Err(e) => {
                failed += 1;
                eprintln!("✗ {}  {e:#}", src.display_target());
                let rec = ErrorRecord {
                    id: None,
                    url: src.display_target().to_string(),
                    error: format!("{e:#}"),
                };
                if let Err(code) = emit(&mut out, &rec) {
                    return code;
                }
                continue;
            }
        };
        if refs.is_empty() {
            eprintln!("⚠ {}  aucune vidéo trouvée", src.display_target());
            continue;
        }
        for vref in refs {
            if cli.list {
                match emit(&mut out, &vref) {
                    Ok(()) => ok += 1,
                    Err(code) => return code,
                }
                continue;
            }
            match fetch::fetch_video(&vref, &prefs, cli.segments, whisper.as_ref(), &ctx) {
                Ok(rec) => {
                    eprintln!("✓ {}  {}", rec.id, rec.title);
                    match emit(&mut out, &rec) {
                        Ok(()) => ok += 1,
                        Err(code) => return code,
                    }
                }
                Err(e) => {
                    failed += 1;
                    eprintln!("✗ {}  {e:#}", vref.id);
                    let rec = ErrorRecord {
                        id: Some(vref.id.clone()),
                        url: vref.url.clone(),
                        error: format!("{e:#}"),
                    };
                    if let Err(code) = emit(&mut out, &rec) {
                        return code;
                    }
                }
            }
        }
    }

    eprintln!("{ok} ok, {failed} failed");
    i32::from(compute_exit(ok, failed))
}

/// Une ligne NDJSON compacte par valeur. BrokenPipe (ex: | head -1) → exit 0 silencieux.
fn emit<T: serde::Serialize>(out: &mut impl Write, value: &T) -> Result<(), i32> {
    let line = serde_json::to_string(value).expect("sérialisation JSON");
    match writeln!(out, "{line}") {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe => Err(0),
        Err(e) => {
            eprintln!("ytkb: stdout: {e}");
            Err(2)
        }
    }
}

/// 0 = tout ok, 1 = partiel, 2 = rien produit.
fn compute_exit(ok: usize, failed: usize) -> u8 {
    match (ok, failed) {
        (o, 0) if o > 0 => 0,
        (o, f) if o > 0 && f > 0 => 1,
        _ => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::compute_exit;

    #[test]
    fn exit_codes() {
        for (ok, failed, want) in [(3, 0, 0), (2, 1, 1), (0, 2, 2), (0, 0, 2)] {
            assert_eq!(compute_exit(ok, failed), want, "({ok},{failed})");
        }
    }
}
