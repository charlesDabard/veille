#!/usr/bin/env bash
# loop-harvest.test.sh · récolte Bilibili de la loop, sur le vrai loop-harvest.sh, dans un HOME
# jetable, avec yt-dlp, ytkb, bili et whisper-cli simulés.
#   bash loop-harvest.test.sh                  -> tout doit passer
#   bash loop-harvest.test.sh <autre-script>   -> rejoue le banc sur une autre version (sabotage :
#                                                  le loop-harvest.sh d'avant Bilibili DOIT tomber)
set -uo pipefail
unset VEILLE_KB
HERE="$(cd "$(dirname "$0")" && /bin/pwd)"
HARVEST="${1:-$HERE/loop-harvest.sh}"
TD="$(/usr/bin/mktemp -d /tmp/veille-loop-harvest-test.XXXXXX)"
trap 'rm -rf "$TD"' EXIT

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

FH="$TD/home"
KB="$FH/veille-kb"
B="$TD/bin"
mkdir -p "$FH/.config/veille" "$B" "$TD/tmp"
printf 'en\thttps://www.youtube.com/@a/videos\n' >"$FH/.config/veille/channels.txt"
printf '# test\n111\tUP-un\n222\tUP-deux\n' >"$TD/bilibili.txt"

# yt-dlp : deux vidéos neuves pour l'unique chaîne. ytkb : un transcript par URL reçue.
printf '#!/usr/bin/env bash\nprintf "yt000000001\\nyt000000002\\n"\n' >"$B/yt-dlp"
cat >"$B/ytkb" <<'EOS'
#!/usr/bin/env bash
sed -n 's#.*youtu.be/##p' "$2" | while read -r id; do printf '{"id":"%s","text":"t","error":null}\n' "$id"; done
EOS
# bili : l'UP 111 échoue au premier appel puis répond (412 intermittent) ; l'UP 222 répond.
# Pas de sous-titres : le texte vient de whisper-cli, sur les segments posés par `bili audio`.
cat >"$B/bili" <<'EOS'
#!/usr/bin/env bash
case "$1" in
user-videos)
	if [ "$2" = 111 ] && [ ! -f "$TD/deja-111" ]; then
		: >"$TD/deja-111"
		echo '{"ok":false,"error":{"code":"network_error"}}'
		exit 1
	fi
	[ "$2" = 111 ] && echo '{"ok":true,"data":[{"bvid":"BVun1"},{"bvid":"BVvu"}]}'
	[ "$2" = 222 ] && echo '{"ok":true,"data":[{"bvid":"BVdeux1"},{"bvid":"BVdeux2"}]}'
	;;
video)
	printf '{"ok":true,"data":{"subtitle":{"available":false},"video":{"bvid":"%s","title":"titre %s","url":"https://www.bilibili.com/video/%s","owner":{"name":"up"},"duration_seconds":60}}}\n' "$2" "$2" "$2"
	;;
audio)
	mkdir -p "${TMPDIR}x" && : >"${TMPDIR}x/seg_000.wav" && : >"${TMPDIR}x/seg_001.wav"
	;;
esac
EOS
printf '#!/usr/bin/env bash\necho "segment ${@: -1}"\n' >"$B/whisper-cli"
chmod +x "$B"/*

kb_neuve() { # BVvu est déjà ingérée dans un topic
	rm -rf "$KB"
	mkdir -p "$KB/t/transcripts"
	echo '{"id":"BVvu","text":"deja"}' >"$KB/t/transcripts/BVvu.json"
	rm -f "$TD/deja-111"
}
run() { # $1 MAX_TOTAL, $2 BILI_MAX
	env HOME="$FH" PATH="$B:$PATH" TD="$TD" TMPDIR="$TD/tmp" VEILLE_BILI_CFG="$TD/bilibili.txt" VEILLE_BILI_MAX="$2" \
		VEILLE_BILI_PAUSE=0 VEILLE_WHISPER_MODEL=/dev/null bash "$HARVEST" 2 "$1" 2>"$TD/err"
}
W="$KB/_loop-staging/worklist.json"

kb_neuve
run 4 2 >/dev/null
jq -e '[.[] | select(.source == "Bilibili") | .id] == ["BVun1", "BVdeux1"]' "$W" >/dev/null
verifie "Bilibili : UP en 412 relancé, déjà ingérée écartée, plafond Bilibili tenu" $?
jq -e '[.[] | select(.source == "YouTube")] | length == 2' "$W" >/dev/null
verifie "YouTube garde les places restantes du plafond global (4 - 2)" $?
T="$KB/_loop-staging/transcripts/BVun1.json"
jq -e '.sub_kind == "whisper" and .lang == "zh" and (.text | test("seg_000.wav")) and (.text | test("seg_001.wav")) and .title == "titre BVun1"' "$T" >/dev/null 2>&1
verifie "transcript Bilibili au schéma ytkb, tous les segments whisper dans l'ordre" $?

kb_neuve
run 3 2 >/dev/null
jq -e '([.[] | select(.source == "Bilibili")] | length) == 2 and ([.[] | select(.source == "YouTube")] | length) == 1' "$W" >/dev/null
verifie "plafond global 3 : Bilibili réserve 2 places, YouTube prend la dernière" $?

# Reprise du staging : un transcript resté d'un run en échec (19 jours d'octobre 2026, 48 orphelins)
# doit revenir au worklist, sinon il dort pour toujours, la récolte ne listant que les nouveautés.
staging_orphelins() {
	local S="$KB/_loop-staging/transcripts"
	mkdir -p "$S"
	echo '{"id":"orph00000a1","url":"https://www.youtube.com/watch?v=orph00000a1","lang":"fr","text":"vieux"}' >"$S/orph00000a1.json"
	echo '{"id":"orph00000b2","url":"https://www.youtube.com/watch?v=orph00000b2","lang":"en","text":"moyen"}' >"$S/orph00000b2.json"
	echo '{"id":"orph00000c3","url":"https://www.youtube.com/watch?v=orph00000c3","lang":"en","text":"recent"}' >"$S/orph00000c3.json"
	echo '{"id":"BVorph","url":"https://www.bilibili.com/video/BVorph","lang":"zh","text":"bili"}' >"$S/BVorph.json"
	echo '{"id":"orphvide001","url":"https://youtu.be/orphvide001","lang":"en","text":null}' >"$S/orphvide001.json"
	echo '{"id":"BVvu","text":"copie restee"}' >"$S/BVvu.json"
	touch -t 202610120000 "$S/orph00000a1.json"
	touch -t 202610130000 "$S/BVorph.json"
	touch -t 202610140000 "$S/orph00000b2.json"
	touch -t 202610150000 "$S/orph00000c3.json"
}
kb_neuve
staging_orphelins
VEILLE_REPRISE_MAX=3 run 4 2 >/dev/null
jq -e '[.[] | select(.reprise == true) | .id] == ["orph00000a1", "BVorph", "orph00000b2"]' "$W" >/dev/null 2>&1
verifie "reprise : orphelins du staging au worklist, plus ancien d'abord, plafond de reprise tenu" $?
jq -e '([.[] | select(.reprise != true)] | length) == 4 and ([.[] | select(.reprise == true)] | length) == 3 and ([.[] | select(.id == "orphvide001" or .id == "BVvu")] | length) == 0' "$W" >/dev/null 2>&1
verifie "reprise hors plafond des nouveautés ; sans texte ou déjà ingéré : écarté" $?
jq -e '(.[] | select(.id == "BVorph") | .source == "Bilibili" and .lang == "zh") and (.[] | select(.id == "orph00000a1") | .source == "YouTube" and .url == "https://youtu.be/orph00000a1" and .noteName == "orph00000a1.md")' "$W" >/dev/null 2>&1
verifie "reprise : source, langue, url et noteName reconstruits depuis le transcript" $?

# Un id YouTube peut commencer par un tiret (-GTePEMyyyA, vu au staging le 2026-11-02) : passé nu à
# grep, il devient une option, la comparaison échoue et une vidéo déjà ingérée repart au worklist.
kb_neuve
mkdir -p "$KB/_loop-staging/transcripts"
echo '{"id":"-deja000001","text":"deja"}' >"$KB/t/transcripts/-deja000001.json"
echo '{"id":"-deja000001","url":"https://youtu.be/-deja000001","lang":"en","text":"copie"}' >"$KB/_loop-staging/transcripts/-deja000001.json"
echo '{"id":"-orphtiret1","url":"https://youtu.be/-orphtiret1","lang":"en","text":"neuf"}' >"$KB/_loop-staging/transcripts/-orphtiret1.json"
printf '#!/usr/bin/env bash\nprintf -- "-deja000001\\nyt000000001\\n"\n' >"$B/yt-dlp"
run 4 2 >/dev/null
jq -e '([.[] | select(.id == "-deja000001")] | length) == 0 and ([.[] | select(.id == "-orphtiret1" and .reprise == true)] | length) == 1 and ([.[] | select(.id == "yt000000001")] | length) == 1' "$W" >/dev/null 2>&1
verifie "id à tiret : déjà ingéré écarté (nouveauté comme reprise), orphelin à tiret repris" $?
! grep -q 'invalid option' "$TD/err"
verifie "id à tiret : aucune erreur grep dans le journal de récolte" $?

# Un orphelin encore en tête de sa chaîne revient aussi comme nouveauté : une seule entrée au worklist.
kb_neuve
mkdir -p "$KB/_loop-staging/transcripts"
echo '{"id":"yt000000001","url":"https://youtu.be/yt000000001","lang":"en","text":"vieux"}' >"$KB/_loop-staging/transcripts/yt000000001.json"
printf '#!/usr/bin/env bash\nprintf "yt000000001\\nyt000000002\\n"\n' >"$B/yt-dlp"
run 4 2 >/dev/null
jq -e '([.[] | select(.id == "yt000000001")] | length) == 1' "$W" >/dev/null 2>&1
verifie "orphelin relisté comme nouveauté : une seule entrée au worklist" $?

kb_neuve
printf '#!/usr/bin/env bash\nexit 0\n' >"$B/yt-dlp"
for bv in BVun1 BVdeux1 BVdeux2; do echo "{\"id\":\"$bv\",\"text\":\"x\"}" >"$KB/t/transcripts/$bv.json"; done
staging_orphelins
out="$(VEILLE_REPRISE_MAX=10 run 15 3)"
! printf '%s' "$out" | grep -q RIEN_DE_NEUF && jq -e 'length == 4 and all(.reprise == true)' "$W" >/dev/null 2>&1
verifie "rien de neuf mais des orphelins : pas de RIEN_DE_NEUF, le worklist les porte" $?

kb_neuve
printf '#!/usr/bin/env bash\nexit 0\n' >"$B/yt-dlp"
for bv in BVun1 BVdeux1 BVdeux2; do echo "{\"id\":\"$bv\",\"text\":\"x\"}" >"$KB/t/transcripts/$bv.json"; done
out="$(run 15 3)"
printf '%s' "$out" | grep -q RIEN_DE_NEUF
verifie "rien de neuf nulle part : RIEN_DE_NEUF" $?

# Fichiers de travail : dans un dossier privé sous TMPDIR, nettoyé à la sortie, jamais à un nom fixe
# de /tmp (un autre compte pourrait y poser un lien à l'avance et détourner l'écriture).
touch "$TD/repere"
run 15 3 >/dev/null
fixes="$(find /tmp/ -maxdepth 1 -name 'veille-loop-*' ! -name 'veille-loop-harvest-test.*' -newer "$TD/repere" 2>/dev/null)"
[ -z "$fixes" ] && [ -z "$(ls -A "$TD/tmp")" ]
verifie "temporaires : aucun nom fixe dans /tmp, dossier privé nettoyé${fixes:+ ($fixes)}" $?

echo "---"
echo "$PASS ok, $FAIL échec(s)"
[ "$FAIL" -eq 0 ]
