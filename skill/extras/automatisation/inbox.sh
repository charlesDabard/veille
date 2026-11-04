#!/usr/bin/env bash
# inbox.sh · boîte d'entrée iPhone de la veille, lancée par launchd (com.example.veille-inbox,
# WatchPaths sur le fichier iCloud que remplit le raccourci iPhone « Partager vers veille »).
#
# Chemin : l'iPhone ajoute une URL à iCloud Drive/Shortcuts/veille-inbox.txt, launchd voit le
# fichier changer et lance ce script, qui le lit PAR le raccourci Mac « Veille · lire la boîte ».
# Pourquoi ce détour : un job launchd en bash reçoit « Operation not permitted » sur
# ~/Library/Mobile Documents (TCC, mesuré le 2026-11-01), alors que `shortcuts run` lancé du même
# job passe. On ne réécrit jamais le fichier iCloud : les URLs déjà traitées sont retenues dans
# inbox-vus.txt, ce qui rend le script idempotent (launchd relance parfois sans changement réel,
# et bride à un lancement toutes les 10 s environ).
#
# Sorties, dans ~/.config/veille :
#   inbox-queue.txt   vidéos YouTube (https://youtu.be/<id>), consommées par loop-harvest.sh
#   inbox-autres.tsv  tout autre lien (date, url), à lire à la main ou par une /veille ciblée
#   inbox-etat        « ok <date> » ou « echec <date> code N » : dernière lecture, lue par oc-doctor
# Une vidéo en file réveille veille-loop tout de suite (kickstart, sans effet s'il tourne déjà).
#
# Variables (tests) : INBOX_READER (commande qui imprime le contenu de la boîte), VEILLE_CFG,
# OSASCRIPT, INBOX_KICK (commande lancée quand une vidéo arrive), INBOX_NOTIFY=0.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

CFGDIR="${VEILLE_CFG:-$HOME/.config/veille}"
OSASCRIPT="${OSASCRIPT:-/usr/bin/osascript}"
RACCOURCI="Veille · lire la boîte"
LOG="$CFGDIR/inbox.log"
VUS="$CFGDIR/inbox-vus.txt"
QUEUE="$CFGDIR/inbox-queue.txt"
AUTRES="$CFGDIR/inbox-autres.tsv"
mkdir -p "$CFGDIR"
touch "$VUS"
log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }
# État de la dernière lecture, lu par oc-doctor : « ok <date> » ou « echec <date> code N ».
ETAT="$CFGDIR/inbox-etat"

# Un seul passage à la fois. Un verrou de plus de 10 min est un reste de plantage.
VERROU="$CFGDIR/inbox.lock"
if ! mkdir "$VERROU" 2>/dev/null; then
	if [ -n "$(find "$VERROU" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
		rm -rf "$VERROU" && mkdir "$VERROU" || exit 0
		log "verrou périmé retiré"
	else
		exit 0
	fi
fi
TMP="$(mktemp -d /tmp/veille-inbox.XXXXXX)"
trap 'rm -rf "$VERROU" "$TMP"' EXIT

if [ -n "${INBOX_READER:-}" ]; then
	bash -c "$INBOX_READER" >"$TMP/boite" 2>>"$LOG"
else
	/usr/bin/shortcuts run "$RACCOURCI" --output-path "$TMP/boite" >>"$LOG" 2>&1
fi
rc=$?
if [ "$rc" -ne 0 ]; then
	log "ECHEC lecture de la boîte (code $rc) : le raccourci « $RACCOURCI » existe-t-il sur ce Mac ?"
	# Le journal seul a laissé la boîte morte deux jours (1er au 2/11/2026, raccourci introuvable) :
	# l'échec se notifie, et oc-doctor le relève chaque matin par inbox-etat.
	echo "echec $(date '+%F %T') code $rc" >"$ETAT"
	if [ "${INBOX_NOTIFY:-1}" != 0 ]; then
		"$OSASCRIPT" -e "display notification \"lecture en échec (code $rc) : raccourci « $RACCOURCI » introuvable ?\" with title \"veille : boîte iPhone\"" >/dev/null 2>&1 || true
	fi
	exit 1
fi
echo "ok $(date '+%F %T')" >"$ETAT"

# URLs nouvelles, dans l'ordre d'arrivée, sans doublon.
grep -oE 'https?://[^][:space:]<>"'"'"'()]+' "$TMP/boite" 2>/dev/null | awk '!vu[$0]++' >"$TMP/urls"
grep -vxF -f "$VUS" "$TMP/urls" >"$TMP/neuves" 2>/dev/null || true
# grep -f sur un fichier vide ne filtre rien et rend 1 : sans URL vue, tout est neuf.
[ -s "$VUS" ] || cp "$TMP/urls" "$TMP/neuves"

videos=0
autres=0
while IFS= read -r url; do
	[ -z "$url" ] && continue
	id="$(printf '%s\n' "$url" | sed -nE \
		-e 's#^https?://(www\.|m\.|music\.)?youtube\.com/(watch\?(.*&)?v=|shorts/|live/|embed/)([A-Za-z0-9_-]{11}).*#\4#p' \
		-e 's#^https?://youtu\.be/([A-Za-z0-9_-]{11}).*#\1#p' | head -1)"
	if [ -n "$id" ]; then
		grep -qx "https://youtu.be/$id" "$QUEUE" 2>/dev/null || {
			echo "https://youtu.be/$id" >>"$QUEUE"
			videos=$((videos + 1))
		}
	else
		printf '%s\t%s\n' "$(date '+%F %T')" "$url" >>"$AUTRES"
		autres=$((autres + 1))
	fi
	echo "$url" >>"$VUS"
done <"$TMP/neuves"

[ $((videos + autres)) -eq 0 ] && exit 0
log "boîte : $videos vidéo(s) en file, $autres autre(s) lien(s)"
if [ "${INBOX_NOTIFY:-1}" != 0 ]; then
	msg="$videos vidéo(s) en file de distillation"
	[ "$autres" -gt 0 ] && msg="$msg, $autres lien(s) dans inbox-autres.tsv"
	"$OSASCRIPT" -e "display notification \"$msg\" with title \"veille : boîte iPhone\"" >/dev/null 2>&1 || true
fi
if [ "$videos" -gt 0 ]; then
	if [ -n "${INBOX_KICK:-}" ]; then
		bash -c "$INBOX_KICK" >>"$LOG" 2>&1
	else
		launchctl kickstart "gui/$(id -u)/${VEILLE_LABEL:-com.example.veille-loop}" >>"$LOG" 2>&1
	fi || log "veille-loop non relancée (déjà en cours ?), la file attend le prochain run"
fi
exit 0
