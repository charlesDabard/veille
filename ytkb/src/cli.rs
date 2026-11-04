use clap::Parser;

#[derive(Parser, Debug)]
#[command(
    name = "ytkb",
    version,
    about = "YouTube → NDJSON transcript filter (un objet JSON par vidéo sur stdout)",
    after_help = "Exemples :\n  ytkb 'https://www.youtube.com/watch?v=ID'\n  ytkb --list 'https://www.youtube.com/playlist?list=PL...'\n  ytkb --search \"claude fable 5\" --recent --max 15 --list\n  ytkb -f urls.txt > batch.ndjson\n\nNote : une URL watch contenant list= est traitée comme playlist ;\npour la seule vidéo, passer l'URL sans le paramètre list."
)]
pub struct Cli {
    /// URLs vidéo / playlist / chaîne
    #[arg(value_name = "URL")]
    pub urls: Vec<String>,

    /// Fichier d'URLs, une par ligne (- = stdin ; lignes vides et # ignorées)
    #[arg(short = 'f', long = "file", value_name = "FILE")]
    pub file: Option<String>,

    /// Recherche YouTube (exclusif avec URLs et -f)
    #[arg(long, value_name = "QUERY", conflicts_with_all = ["urls", "file"])]
    pub search: Option<String>,

    /// Nombre max de résultats de recherche
    #[arg(long, default_value_t = 10, requires = "search", value_parser = clap::value_parser!(u32).range(1..))]
    pub max: u32,

    /// Recherche triée par date d'upload (ytsearchdate)
    #[arg(long, requires = "search")]
    pub recent: bool,

    /// Résolution seule : NDJSON {id,url,title,channel,duration_sec,view_count}, aucun transcript
    #[arg(long)]
    pub list: bool,

    /// Ordre de préférence des langues de sous-titres
    #[arg(long, default_value = "fr,en", value_name = "LANGS")]
    pub lang: String,

    /// Ajoute segments [{start,dur,text}] au record
    #[arg(long)]
    pub segments: bool,

    /// Transcrit l'audio via whisper.cpp quand aucune piste de sous-titres n'existe
    #[arg(long)]
    pub transcribe: bool,

    /// Modèle ggml pour la transcription (~/.local/share/ytkb/models/ggml-<nom>.bin)
    #[arg(long, default_value = "large-v3", value_name = "NOM")]
    pub whisper_model: String,

    /// Langue forcée pour la transcription (sinon auto-détection whisper)
    #[arg(long, value_name = "CODE")]
    pub whisper_lang: Option<String>,

    /// Passthrough yt-dlp --cookies-from-browser (ex: chrome, safari)
    #[arg(long, value_name = "BROWSER")]
    pub cookies_from_browser: Option<String>,

    /// Arg brut ajouté à chaque invocation yt-dlp (répétable ; forme --opt=val)
    #[arg(long = "ytdlp-arg", value_name = "ARG")]
    pub ytdlp_args: Vec<String>,
}

pub fn parse_langs(s: &str) -> Vec<String> {
    s.split(',')
        .map(|p| p.trim().to_lowercase())
        .filter(|p| !p.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_langs_trim_lowercase_filtre() {
        assert_eq!(parse_langs("fr, EN ,,de"), vec!["fr", "en", "de"]);
        assert_eq!(parse_langs(""), Vec::<String>::new());
    }
}
