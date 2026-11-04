#!/usr/bin/env bash
# ytdlp-hebdo.test.sh · les issues du job hebdo yt-dlp, avec faux brew, yt-dlp, ytkb et osascript.
#   bash ytdlp-hebdo.test.sh             -> tout doit passer
#   bash ytdlp-hebdo.test.sh --sabotage  -> alerte neutralisée : les cas de panne DOIVENT tomber
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && /bin/pwd)"
JOB="$HERE/ytdlp-hebdo.sh"
TD="$(/usr/bin/mktemp -d /tmp/ytdlp-hebdo-test.XXXXXX)"
trap 'rm -rf "$TD"' EXIT
if [ "${1:-}" = "--sabotage" ]; then
	/usr/bin/sed 's/^\t"\$OSASCRIPT" -e/\t: "$OSASCRIPT" -e/' "$JOB" >"$TD/job-sabote"
	JOB="$TD/job-sabote"
fi

# Faux binaires pilotés par des variables : BREW_RETARD=1 (outdated rend 1), YTDLP_IDS (ids listés),
# YTKB_TEXTE (texte rendu pour chaque id, vide = pas de sous-titres).
mkdir -p "$TD/bin"
cat >"$TD/bin/brew" <<'EOS'
#!/usr/bin/env bash
echo "brew $*" >>"$TRACE"
case "$1" in outdated) [ "${BREW_RETARD:-0}" = 1 ] && { echo yt-dlp; exit 1; }; exit 0 ;; upgrade) exit 0 ;; esac
EOS
cat >"$TD/bin/yt-dlp" <<'EOS'
#!/usr/bin/env bash
[ "$1" = --version ] && { echo 2026.11.01; exit 0; }
for i in ${YTDLP_IDS:-}; do echo "$i"; done
EOS
cat >"$TD/bin/ytkb" <<'EOS'
#!/usr/bin/env bash
printf '{"id":"x","text":"%s"}\n' "${YTKB_TEXTE:-}"
EOS
cat >"$TD/bin/osascript" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$MARKER"
EOS
chmod +x "$TD/bin/"*
LONG="$(printf 'mot %.0s' $(seq 1 100))"

PASS=0
FAIL=0
verifie() { # $1 nom, $2 code (0 = vrai)
	if [ "$2" -eq 0 ]; then
		PASS=$((PASS + 1))
		echo "ok   $1"
	else
		FAIL=$((FAIL + 1))
		echo "FAIL $1"
	fi
}
lancer() { # env supplémentaire en arguments
	rm -rf "$TD/cfg"
	mkdir -p "$TD/cfg"
	printf '# commentaire\n\nen\thttps://www.youtube.com/@x/videos\n' >"$TD/cfg/channels.txt"
	: >"$TD/marker"
	: >"$TD/trace"
	env YTDLP_BIN="$TD/bin/yt-dlp" YTKB_BIN="$TD/bin/ytkb" BREW_BIN="$TD/bin/brew" OSASCRIPT="$TD/bin/osascript" \
		VEILLE_CFG="$TD/cfg" MARKER="$TD/marker" TRACE="$TD/trace" "$@" bash "$JOB"
}

lancer YTDLP_IDS="a b c" YTKB_TEXTE="$LONG"
rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TD/marker" ] && grep -q 'sonde OK' "$TD/cfg/ytdlp.log"
verifie "sonde saine : code 0, journal OK, aucune notification" $?
! grep -q 'brew upgrade' "$TD/trace"
verifie "yt-dlp à jour : pas de brew upgrade" $?

lancer BREW_RETARD=1 YTDLP_IDS="a" YTKB_TEXTE="$LONG"
grep -q 'brew upgrade yt-dlp' "$TD/trace" && grep -q 'mis à jour' "$TD/cfg/ytdlp.log"
verifie "yt-dlp en retard : brew upgrade lancé et journalisé" $?

lancer YTDLP_IDS="" YTKB_TEXTE="$LONG"
rc=$?
[ "$rc" -eq 1 ] && grep -q 'display notification' "$TD/marker" && grep -q 'ne liste plus' "$TD/cfg/ytdlp.log"
verifie "yt-dlp ne liste rien : code 1 et notification" $?

lancer YTDLP_IDS="a b c" YTKB_TEXTE=""
rc=$?
[ "$rc" -eq 1 ] && grep -q 'display notification' "$TD/marker" && [ "$(grep -c 'pas de transcript' "$TD/cfg/ytdlp.log")" -eq 3 ]
verifie "aucun transcript sur 3 vidéos : 3 essais, code 1 et notification" $?

lancer YTDLP_IDS="a b c" YTKB_TEXTE="$LONG" YTDLP_NOTIFY=0
[ ! -s "$TD/marker" ]
verifie "YTDLP_NOTIFY=0 respecté" $?

rm -f "$TD/cfg/channels.txt"
echo "---"
echo "$PASS ok, $FAIL échec(s)"
[ "$FAIL" -eq 0 ]
