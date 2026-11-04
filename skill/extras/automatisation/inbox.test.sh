#!/usr/bin/env bash
# inbox.test.sh · boîte iPhone de bout en bout : inbox.sh (tri des liens, idempotence, réveil de la
# boucle) puis loop-harvest.sh (la file passe en tête, le plafond la respecte, le reste attend).
#   bash inbox.test.sh                       -> tout doit passer
#   HARVEST=<autre loop-harvest> bash ...   -> rejouer contre une autre version (sabotage)
set -uo pipefail
unset VEILLE_KB
HERE="$(cd "$(dirname "$0")" && /bin/pwd)"
INBOX="${INBOX:-$HERE/inbox.sh}"
HARVEST="${HARVEST:-$HERE/loop-harvest.sh}"
TD="$(/usr/bin/mktemp -d /tmp/veille-inbox-test.XXXXXX)"
trap 'rm -rf "$TD"' EXIT
FH="$TD/home"
CFG="$FH/.config/veille"

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

# ---------- inbox.sh ----------
mkdir -p "$TD/bin" "$CFG"
cat >"$TD/bin/osascript" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$MARKER"
EOS
chmod +x "$TD/bin/osascript"
boite() { printf '%s\n' "$@" >"$TD/boite.txt"; }
inbox() {
	: >"$TD/marker"
	: >"$TD/kick"
	env HOME="$FH" VEILLE_CFG="$CFG" OSASCRIPT="$TD/bin/osascript" MARKER="$TD/marker" \
		INBOX_READER="cat '$TD/boite.txt'" INBOX_KICK="echo kick >>'$TD/kick'" "$@" bash "$INBOX"
}

boite "https://www.youtube.com/watch?v=AAAAAAAAAA1&t=42s" "regarde ça https://youtu.be/BBBBBBBBBB2?si=xyz" \
	"https://m.youtube.com/shorts/CCCCCCCCCC3" "https://example.com/article" "pas une url"
inbox
[ "$(cat "$CFG/inbox-queue.txt" 2>/dev/null)" = "$(printf 'https://youtu.be/AAAAAAAAAA1\nhttps://youtu.be/BBBBBBBBBB2\nhttps://youtu.be/CCCCCCCCCC3')" ]
verifie "watch, youtu.be et shorts normalisés en file, dans l'ordre" $?
[ "$(cut -f2 "$CFG/inbox-autres.tsv")" = "https://example.com/article" ]
verifie "lien hors YouTube rangé dans inbox-autres.tsv" $?
grep -q '3 vidéo' "$TD/marker" && [ -s "$TD/kick" ]
verifie "notification et réveil de veille-loop" $?
grep -q '^ok ' "$CFG/inbox-etat" 2>/dev/null
verifie "lecture réussie : inbox-etat à ok (lu par oc-doctor)" $?

inbox
[ "$(wc -l <"$CFG/inbox-queue.txt" | tr -d ' ')" -eq 3 ] && [ ! -s "$TD/marker" ] && [ ! -s "$TD/kick" ]
verifie "relance sans changement : rien en double, ni notification ni réveil" $?

boite "https://youtu.be/BBBBBBBBBB2" "https://example.com/autre" "https://youtu.be/BBBBBBBBBB2"
inbox
[ "$(wc -l <"$CFG/inbox-queue.txt" | tr -d ' ')" -eq 3 ] && [ "$(wc -l <"$CFG/inbox-autres.tsv" | tr -d ' ')" -eq 2 ] && [ ! -s "$TD/kick" ]
verifie "lien autre seul : rangé, notifié, sans réveil de la boucle" $?

mkdir "$CFG/inbox.lock"
boite "https://youtu.be/DDDDDDDDDD4"
inbox
! grep -q DDDDDDDDDD4 "$CFG/inbox-queue.txt"
verifie "verrou frais : le second passage s'abstient" $?
rmdir "$CFG/inbox.lock"

inbox INBOX_READER="exit 3"
rc=$?
[ "$rc" -eq 1 ] && grep -q 'ECHEC lecture' "$CFG/inbox.log"
verifie "raccourci en échec : code 1 et cause journalisée" $?
# Le journal seul ne suffit pas : du 1er au 2/11/2026 la boîte est restée morte (raccourci Mac
# introuvable) sans que personne le sache. L'échec doit se voir tout de suite et au docteur.
grep -q 'échec' "$TD/marker"
verifie "raccourci en échec : notification envoyée" $?
grep -q '^echec ' "$CFG/inbox-etat" 2>/dev/null
verifie "raccourci en échec : inbox-etat à echec (lu par oc-doctor)" $?
inbox
grep -q '^ok ' "$CFG/inbox-etat" 2>/dev/null
verifie "lecture revenue : inbox-etat repasse à ok, même sans lien neuf" $?

# ---------- loop-harvest.sh ----------
cat >"$TD/bin/yt-dlp" <<'EOS'
#!/usr/bin/env bash
for i in ${CHAN_IDS:-}; do echo "$i"; done
EOS
cat >"$TD/bin/ytkb" <<'EOS'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = -f ] && { f="$2"; shift; }; shift; done
sed -E 's#.*/##' "$f" | while read -r id; do printf '{"id":"%s","text":"texte"}\n' "$id"; done
EOS
chmod +x "$TD/bin/yt-dlp" "$TD/bin/ytkb"
recolte() { # $1 MAX
	rm -rf "$FH/veille-kb"
	mkdir -p "$FH/veille-kb/topic/transcripts"
	echo '{"id":"DEJAVU0000a","text":"deja"}' >"$FH/veille-kb/topic/transcripts/DEJAVU0000a.json"
	printf 'en\thttps://www.youtube.com/@x/videos\n' >"$CFG/channels.txt"
	env HOME="$FH" PATH="$TD/bin:$PATH" CHAN_IDS="ZZZZZZZZZZ1 ZZZZZZZZZZ2 ZZZZZZZZZZ3" bash "$HARVEST" 2 "$1" >/dev/null 2>"$TD/harvest.err"
	jq -r '.[].id' "$FH/veille-kb/_loop-staging/worklist.json" 2>/dev/null | tr '\n' ' '
}

printf 'https://youtu.be/DEJAVU0000a\nhttps://youtu.be/BOITE000001\n' >"$CFG/inbox-queue.txt"
rm -f "$CFG/inbox-queue.txt.en-cours"
ids="$(recolte 2)"
case "$ids" in "BOITE000001 ZZZZZZZZZZ1 ") r=0 ;; *) r=1 ;; esac
verifie "file en tête du plafond, vidéo déjà ingérée écartée (obtenu : $ids)" $r
[ ! -e "$CFG/inbox-queue.txt" ] && [ ! -e "$CFG/inbox-queue.txt.en-cours" ]
verifie "file vidée une fois tentée" $?

printf 'https://youtu.be/BOITE000001\nhttps://youtu.be/BOITE000002\nhttps://youtu.be/BOITE000003\n' >"$CFG/inbox-queue.txt"
ids="$(recolte 2)"
[ "$ids" = "BOITE000001 BOITE000002 " ] && [ "$(cat "$CFG/inbox-queue.txt" 2>/dev/null)" = "https://youtu.be/BOITE000003" ]
verifie "au-delà du plafond, le reste de la file attend le run suivant" $?

printf 'https://youtu.be/BOITE000004\n' >"$CFG/inbox-queue.txt.en-cours"
rm -f "$CFG/inbox-queue.txt"
ids="$(recolte 5)"
case "$ids" in "BOITE000004 "*) r=0 ;; *) r=1 ;; esac
verifie "file « en cours » d'un run interrompu reprise" $r

echo "---"
echo "$PASS ok, $FAIL échec(s)"
[ "$FAIL" -eq 0 ]
