use anyhow::{Result, anyhow, bail};
use std::process::Command;

pub struct YtdlpCtx {
    pub cookies_from_browser: Option<String>,
    pub extra_args: Vec<String>,
}

impl YtdlpCtx {
    pub fn base_cmd(&self) -> Command {
        let mut c = Command::new("yt-dlp");
        c.arg("--no-warnings").arg("--no-progress");
        if let Some(b) = &self.cookies_from_browser {
            c.arg("--cookies-from-browser").arg(b);
        }
        for a in &self.extra_args {
            c.arg(a);
        }
        c
    }
}

fn spawn_error(e: &std::io::Error) -> anyhow::Error {
    if e.kind() == std::io::ErrorKind::NotFound {
        anyhow!("yt-dlp introuvable dans le PATH (brew install yt-dlp ou pipx install yt-dlp, puis bash install.sh à la racine du dépôt veille)")
    } else {
        anyhow!("échec lancement yt-dlp : {e}")
    }
}

/// Extrait un message exploitable du stderr yt-dlp : lignes ERROR: (max 2),
/// sinon dernières lignes non vides. Ajoute un hint actionnable sur les
/// signatures connues (yt-dlp obsolète / bot-check).
pub fn extract_error(stderr: &str) -> String {
    let mut lines: Vec<&str> = stderr
        .lines()
        .filter(|l| l.trim_start().starts_with("ERROR:"))
        .take(2)
        .collect();
    if lines.is_empty() {
        lines = stderr
            .lines()
            .rev()
            .filter(|l| !l.trim().is_empty())
            .take(2)
            .collect();
        lines.reverse();
    }
    let mut msg = lines.join(" | ");
    if msg.is_empty() {
        msg = "yt-dlp a échoué sans message".into();
    }
    if msg.contains("nsig") || msg.contains("Sign in to confirm") {
        msg.push_str(" (yt-dlp obsolète ? brew upgrade yt-dlp ; ou --cookies-from-browser chrome)");
    }
    msg
}

pub fn run_capture(cmd: &mut Command) -> Result<String> {
    let out = cmd.output().map_err(|e| spawn_error(&e))?;
    if !out.status.success() {
        bail!(extract_error(&String::from_utf8_lossy(&out.stderr)));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

pub fn run_quiet(cmd: &mut Command) -> Result<()> {
    run_capture(cmd).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_error_prend_lignes_error() {
        let stderr = "WARNING: blabla\nERROR: [youtube] abc: Video unavailable\nautre bruit";
        assert_eq!(extract_error(stderr), "ERROR: [youtube] abc: Video unavailable");
    }

    #[test]
    fn extract_error_hint_bot_check() {
        let stderr = "ERROR: [youtube] x: Sign in to confirm you're not a bot.";
        let msg = extract_error(stderr);
        assert!(msg.contains("brew upgrade yt-dlp"));
    }

    #[test]
    fn extract_error_fallback_dernieres_lignes() {
        let stderr = "premiere\n\nderniere ligne utile\n";
        assert_eq!(extract_error(stderr), "premiere | derniere ligne utile");
    }
}
