#!/usr/bin/env bash
# ytdlp-hebdo.sh · entretien hebdomadaire de yt-dlp pour la veille, lancé par launchd
# (com.example.veille-ytdlp, lundi 6h47, avant veille-loop de 7h13).
#
# Pourquoi : YouTube casse yt-dlp plusieurs fois par an, et la veille-loop ne le voit que sous la
# forme d'une récolte vide (RIEN_DE_NEUF), indiscernable d'une semaine calme. Au 2026-11-01 la
# version installée datait du 2026-08-19. Ce job met yt-dlp à jour, puis prouve le vrai chemin
# (liste d'une chaîne par yt-dlp, transcript par ytkb) et notifie si la preuve échoue.
#
# La sonde essaie les 3 dernières vidéos de la première chaîne de channels.txt : une vidéo sans
# sous-titres n'est pas une panne, trois d'affilée en sont une.
#
# Variables (tests) : YTDLP_BIN, YTKB_BIN, BREW_BIN, OSASCRIPT, VEILLE_CFG, YTDLP_NOTIFY=0.
# Sortie : 0 si la sonde passe, 1 sinon. Journal : ~/.config/veille/ytdlp.log
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

YTDLP="${YTDLP_BIN:-yt-dlp}"
YTKB="${YTKB_BIN:-ytkb}"
BREW="${BREW_BIN:-brew}"
OSASCRIPT="${OSASCRIPT:-/usr/bin/osascript}"
CFGDIR="${VEILLE_CFG:-$HOME/.config/veille}"
LOG="$CFGDIR/ytdlp.log"
mkdir -p "$CFGDIR"
log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }
alerte() {
	[ "${YTDLP_NOTIFY:-1}" = 0 ] && return 0
	"$OSASCRIPT" -e "display notification \"$1\" with title \"veille : yt-dlp en panne\" sound name \"Basso\"" >/dev/null 2>&1 || true
}
fin() {
	log "===== ytdlp-hebdo END (exit $1) ====="
	exit "$1"
}

echo "" >>"$LOG"
log "===== ytdlp-hebdo START ====="

# 1. Mise à jour. `brew outdated <formule>` rend 1 quand la formule est en retard. Un échec de
#    mise à jour est journalisé sans alerte : seule la sonde dit si la veille est réellement touchée.
avant="$("$YTDLP" --version 2>/dev/null)"
if ! "$BREW" outdated yt-dlp >/dev/null 2>&1; then
	if "$BREW" upgrade yt-dlp >>"$LOG" 2>&1; then
		log "yt-dlp mis à jour : $avant -> $("$YTDLP" --version 2>/dev/null)"
	else
		log "ATTENTION : brew upgrade yt-dlp a échoué, version $avant gardée"
	fi
else
	log "yt-dlp à jour ($avant)"
fi

# 2. Sonde sur le vrai chemin.
canal="$(grep -vE '^\s*(#|$)' "$CFGDIR/channels.txt" 2>/dev/null | head -1 | cut -f2)"
if [ -z "$canal" ]; then
	log "ECHEC sonde : aucune chaîne lisible dans $CFGDIR/channels.txt"
	alerte "channels.txt illisible, sonde impossible"
	fin 1
fi
ids="$("$YTDLP" --no-warnings --flat-playlist --playlist-end 3 --print '%(id)s' "$canal" 2>>"$LOG")"
if [ -z "$ids" ]; then
	log "ECHEC sonde : yt-dlp ne liste plus aucune vidéo de $canal"
	alerte "yt-dlp ne liste plus les chaînes ($("$YTDLP" --version 2>/dev/null))"
	fin 1
fi
for id in $ids; do
	n="$("$YTKB" --lang en,fr,de,es "https://youtu.be/$id" 2>>"$LOG" |
		/usr/bin/python3 -c 'import json,sys; print(max([len(json.loads(l).get("text") or "") for l in sys.stdin if l.strip()] or [0]))' 2>/dev/null)"
	if [ "${n:-0}" -gt 200 ]; then
		log "sonde OK : transcript de $id ($n caractères) par $canal"
		fin 0
	fi
	log "sonde : pas de transcript pour $id (${n:-0} caractères)"
done
log "ECHEC sonde : aucun transcript sur les 3 dernières vidéos de $canal"
alerte "aucun transcript sur 3 vidéos ($("$YTDLP" --version 2>/dev/null)), voir ~/.config/veille/ytdlp.log"
fin 1
