use crate::parse::{WhisperOut, parse_whisper_json};
use crate::ytdlp::{YtdlpCtx, run_quiet};
use anyhow::{Context, Result, anyhow, bail};
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct WhisperCfg {
    pub model: String,
    pub lang: Option<String>,
}

/// Compose le chemin d'un modèle ggml sous un répertoire de données.
pub fn model_file(data_base: &Path, model: &str) -> PathBuf {
    data_base
        .join("ytkb/models")
        .join(format!("ggml-{model}.bin"))
}

/// Racine de données : $XDG_DATA_HOME, sinon ~/.local/share.
fn data_base() -> Result<PathBuf> {
    if let Some(x) = std::env::var_os("XDG_DATA_HOME") {
        return Ok(PathBuf::from(x));
    }
    let home = std::env::var_os("HOME").context("HOME non défini")?;
    Ok(PathBuf::from(home).join(".local/share"))
}

/// Télécharge le meilleur audio en WAV 16 kHz mono dans `dir` ; retourne le chemin du WAV.
fn download_audio(dir: &Path, url: &str, ctx: &YtdlpCtx) -> Result<PathBuf> {
    let mut c = ctx.base_cmd();
    c.args([
        "-f",
        "bestaudio",
        "-x",
        "--audio-format",
        "wav",
        "--postprocessor-args",
        "-ar 16000 -ac 1",
        "-o",
        "%(id)s.%(ext)s",
        "-P",
    ])
    .arg(dir)
    .arg("--")
    .arg(url);
    run_quiet(&mut c).context("téléchargement audio (yt-dlp)")?;
    for entry in std::fs::read_dir(dir)? {
        let p = entry?.path();
        if p.extension().and_then(|e| e.to_str()) == Some("wav") {
            return Ok(p);
        }
    }
    bail!("aucun fichier .wav après extraction audio")
}

/// Transcrit `url` via whisper.cpp. `dir` = tempdir partagé avec fetch.
pub fn transcribe(dir: &Path, url: &str, cfg: &WhisperCfg, ctx: &YtdlpCtx) -> Result<WhisperOut> {
    let model = model_file(&data_base()?, &cfg.model);
    if !model.exists() {
        bail!(
            "modèle whisper absent ({}) : voir la section transcription du README du dépôt veille",
            model.display()
        );
    }
    let wav = download_audio(dir, url, ctx)?;
    let mut c = Command::new("whisper-cli");
    c.arg("-m")
        .arg(&model)
        .arg("-f")
        .arg(&wav)
        .arg("--output-json")
        .arg("--no-prints");
    if let Some(l) = &cfg.lang {
        c.arg("--language").arg(l);
    }
    let out = c.output().map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            anyhow!("whisper-cli introuvable : brew install whisper-cpp (voir le README du dépôt veille)")
        } else {
            anyhow!("échec lancement whisper-cli : {e}")
        }
    })?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        bail!(
            "whisper-cli a échoué : {}",
            err.lines().last().unwrap_or("(stderr vide)")
        );
    }
    // whisper-cli --output-json écrit "<input>.json"
    let json_path = PathBuf::from(format!("{}.json", wav.display()));
    let raw = std::fs::read_to_string(&json_path)
        .with_context(|| format!("lecture {}", json_path.display()))?;
    parse_whisper_json(&raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_file_compose_le_chemin() {
        let p = model_file(Path::new("/u/.local/share"), "large-v3");
        assert_eq!(p, Path::new("/u/.local/share/ytkb/models/ggml-large-v3.bin"));
    }
}
