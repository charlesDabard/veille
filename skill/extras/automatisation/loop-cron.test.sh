#!/usr/bin/env bash
# loop-cron.test.sh · garde des SYNTHESIS et des fiches _ENTITIES sur le vrai chemin : loop-cron.sh complet, dans un HOME
# jetable, avec une récolte et un opencode simulés. Une SYNTHESIS qui perd une ligne doit rester
# hors du commit et faire sortir le run en échec ; une SYNTHESIS enrichie doit passer.
#   bash loop-cron.test.sh              -> tout doit passer
#   bash loop-cron.test.sh --sabotage   -> check-merge (.sh et .py) remplacé par « exit 0 » : les cas perte DOIVENT tomber
#   bash loop-cron.test.sh --sabotage-gardes -> treize gardes de loop-cron.sh neutralisées une à une : chacune DOIT faire tomber le banc
set -uo pipefail
unset VEILLE_KB VEILLE_HARVEST VEILLE_MODEL VEILLE_CHECK_MERGE
HERE="$(cd "$(dirname "$0")" && /bin/pwd)"
SKILL="$(cd "$HERE/../.." && /bin/pwd)"
SABOTAGE="${1:-}"
CIBLE="${VEILLE_CRON_CIBLE:-$HERE/loop-cron.sh}"
# Une copie sabotée vit hors de l'arbre : la résolution relative ne trouverait plus la garde.
[ "$CIBLE" = "$HERE/loop-cron.sh" ] || export VEILLE_CHECK_MERGE="$SKILL/check-merge.sh"

if [ "$SABOTAGE" = --sabotage-gardes ]; then
	COPIE="$(/usr/bin/mktemp -d /tmp/veille-loop-cron-sab.XXXXXX)"
	trap 'rm -rf "$COPIE"' EXIT
	rate=0
	while IFS='|' read -r nom expr; do
		sed -e "$expr" "$HERE/loop-cron.sh" >"$COPIE/loop-cron.sh"
		if cmp -s "$HERE/loop-cron.sh" "$COPIE/loop-cron.sh"; then
			echo "SED SANS EFFET : $nom"
			rate=1
		elif VEILLE_CRON_CIBLE="$COPIE/loop-cron.sh" bash "$0" >/dev/null 2>&1; then
			echo "NON DÉTECTÉ : $nom"
			rate=1
		else
			echo "détecté : $nom"
		fi
	done <<'EOS'
reset de l'index après refus du pre-commit|s#/usr/bin/git -C "$KB" reset -q$#:#
code 1 sur refus du pre-commit|/ECHEC commit refusé/{n;s/code=1/:/;}
plafond de 2 essais|s/"$attempt" -ge 2/"$attempt" -ge 3/
relance unique|s/"$attempt" -ge 2/"$attempt" -ge 1/
entrée standard sur /dev/null|s#-- "$PROMPT" </dev/null)#-- "$PROMPT")#
config purgée de plugin et mcp|s/del(.plugin, .mcp)/./
sortie de l'agent hors de loop.log|s#>>"$AGENT_LOG" 2>&1#>>"$LOG" 2>\&1#
rotation au-delà du seuil|s/-gt "$LOG_MAX"/-gt 999999999999/
rotation limitée aux lignes datées|s#/usr/bin/grep -a .* "$LOG" | /usr/bin/tail#/bin/cat "$LOG" | /usr/bin/tail#
rotation aux dernières lignes|s/tail -n "$LOG_LIGNES"/tail -n +1/
rétention de loop-agent|s/tail -n +14/tail -n +99/
contrôle de l'index|s/^		INDEX_MANQUE="$INDEX_MANQUE $f"$/		:/
repli sur l'URL de la note|s/\[ -n "$url" \] \&\& /false \&\& /
EOS
	exit "$rate"
fi
TD="$(/usr/bin/mktemp -d /tmp/veille-loop-cron-test.XXXXXX)"
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
FAUX="$TD/faux"
mkdir -p "$FAUX" "$FH/.config/opencode/agent" "$TD/bin"
# config réelle en miniature : plugin et mcp doivent disparaître de la copie vue par opencode
echo '{"plugin":["garde-md"],"mcp":{"x":{}},"provider":{"deepseek":{"options":{"baseURL":"http://127.0.0.1:8787"}}}}' >"$FH/.config/opencode/opencode.json"
: >"$FH/.config/opencode/AGENTS.md"
printf '#!/usr/bin/env bash\necho "récolte simulée"\n' >"$FAUX/loop-harvest.sh"
export VEILLE_HARVEST="$FAUX/loop-harvest.sh"
# Sans sabotage, loop-cron.sh trouve la vraie garde par son chemin relatif (skill/check-merge.sh).
if [ "$SABOTAGE" = --sabotage ]; then
	printf '#!/usr/bin/env bash\nexit 0\n' >"$FAUX/check-merge.sh"
	printf 'import sys\nsys.exit(0)\n' >"$FAUX/check-merge.py"
	export VEILLE_CHECK_MERGE="$FAUX/check-merge.sh"
fi

# opencode simulé : MODE=perte retire une ligne de la synthèse, MODE=ajout en ajoute une ; les deux
# écrivent une note. Il tourne dans la KB (le script y fait un cd). Chaque appel laisse une trace
# dans $TD/appels : rang, nature de l'entrée standard, config vue.
cat >"$TD/bin/opencode" <<'EOS'
#!/usr/bin/env bash
n=$(($(cat "$TD/appels" 2>/dev/null | wc -l) + 1))
entree=autre
[ -c /dev/stdin ] && entree=null
[ -p /dev/stdin ] && entree=tuyau
printf '%s %s %s\n' "$n" "$entree" "$(jq -c 'keys' "$XDG_CONFIG_HOME/opencode/opencode.json" 2>/dev/null)" >>"$TD/appels"
echo "sortie brute de l'agent : ECHEC cité dans une note, veille-loop END (exit 0)"
case "$MODE" in
echec) exit 1 ;;
echec-puis-ajout) [ "$n" -eq 1 ] && exit 1 ;;
esac
mkdir -p t/notes
printf -- '---\ntitre: n\nurl: https://exemple.org/video/%s\n---\nnote\n' "$(printf %s "$MODE" | md5 | cut -c1-8)" >"t/notes/n-$MODE.md"
case "$MODE" in
perte) grep -v 'beta' t/SYNTHESIS.md >t/S.tmp && mv t/S.tmp t/SYNTHESIS.md ;;
ajout | echec-puis-ajout | refus) echo '- delta' >>t/SYNTHESIS.md ;;
entite-perte) grep -v 'vieille' _ENTITIES/x.md >_ENTITIES/x.tmp && mv _ENTITIES/x.tmp _ENTITIES/x.md ;;
entite-ajout) echo '- [t](../t/notes/n.md) · neuve' >>_ENTITIES/x.md && printf '# Y\n' >_ENTITIES/y.md ;;
indexe) echo '- [n](notes/n-indexe.md)' >>t/_index.md ;;
indexe-url) echo '| 2026-11-03 | [n](https://exemple.org/video/9e6b4d8c) | web |' >>t/_index.md ;;
esac
EOS
chmod +x "$TD/bin/opencode"

kb_neuve() {
	rm -rf "$KB"
	mkdir -p "$KB/t"
	printf '# t\n\n- alpha\n- beta\n- gamma\n' >"$KB/t/SYNTHESIS.md"
	mkdir -p "$KB/_ENTITIES"
	printf '# X\n- [t](../t/notes/a.md) · vieille\n' >"$KB/_ENTITIES/x.md"
	git -C "$KB" init -q
	git -C "$KB" add -A
	git -C "$KB" -c user.name=t -c user.email=t@t commit -q -m init
	rm -f "$TD/appels"
}
run() { # $1 MODE
	env HOME="$FH" MODE="$1" TD="$TD" VEILLE_RELANCE_S=0 VEILLE_OPENCODE="$TD/bin/opencode" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
		GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t bash "$CIBLE"
}

kb_neuve
run ajout
rc=$?
[ "$rc" -eq 0 ] && git -C "$KB" show --name-only --format= HEAD | grep -qx 't/SYNTHESIS.md' &&
	git -C "$KB" show --name-only --format= HEAD | grep -qx 't/notes/n-ajout.md'
verifie "synthèse enrichie : committée avec la note, run en succès (code $rc)" $?

kb_neuve
run perte
rc=$?
dernier="$(git -C "$KB" show --name-only --format= HEAD)"
[ "$rc" -eq 1 ]
verifie "synthèse amputée : run en échec (code $rc)" $?
! printf '%s\n' "$dernier" | grep -qx 't/SYNTHESIS.md' && [ -n "$(git -C "$KB" status --porcelain t/SYNTHESIS.md)" ]
verifie "synthèse amputée : hors du commit, laissée modifiée sur le disque" $?
printf '%s\n' "$dernier" | grep -qx 't/notes/n-perte.md'
verifie "la note du même run est committée quand même" $?
grep -q 'ECHEC t/SYNTHESIS.md perd des lignes' "$FH/.config/veille/loop.log"
verifie "cause journalisée dans loop.log" $?

kb_neuve
run entite-ajout
rc=$?
dernier="$(git -C "$KB" show --name-only --format= HEAD)"
[ "$rc" -eq 0 ] && printf '%s\n' "$dernier" | grep -qx '_ENTITIES/x.md' && printf '%s\n' "$dernier" | grep -qx '_ENTITIES/y.md'
verifie "entités : fiche enrichie et fiche neuve committées, run en succès (code $rc)" $?

kb_neuve
run entite-perte
rc=$?
dernier="$(git -C "$KB" show --name-only --format= HEAD)"
[ "$rc" -eq 1 ] && ! printf '%s\n' "$dernier" | grep -qx '_ENTITIES/x.md' && printf '%s\n' "$dernier" | grep -qx 't/notes/n-entite-perte.md'
verifie "entités : fiche amputée hors du commit, note committée, run en échec (code $rc)" $?

# Pre-commit de la KB qui refuse (depuis le 2026-11-01) : sans reset, l'index resté chargé faisait
# annuler le commit de chaque run suivant, en silence.
kb_neuve
printf '#!/bin/sh\necho "pre-commit : refus simulé" >&2\nexit 1\n' >"$KB/.git/hooks/pre-commit"
chmod +x "$KB/.git/hooks/pre-commit"
avant="$(git -C "$KB" rev-parse HEAD)"
run refus
rc=$?
[ "$rc" -eq 1 ] && grep -q 'ECHEC commit refusé' "$FH/.config/veille/loop.log"
verifie "pre-commit qui refuse : run en échec, cause journalisée (code $rc)" $?
git -C "$KB" diff --cached --quiet && [ "$(git -C "$KB" rev-parse HEAD)" = "$avant" ] && [ -f "$KB/t/notes/n-refus.md" ]
verifie "pre-commit qui refuse : index vidé, aucun commit, fichiers laissés sur le disque" $?

# Relance : un échec est retenté une fois, pas plus.
kb_neuve
run echec-puis-ajout
rc=$?
[ "$rc" -eq 0 ] && [ "$(wc -l <"$TD/appels" | tr -d ' ')" -eq 2 ] && git -C "$KB" show --name-only --format= HEAD | grep -qx 't/notes/n-echec-puis-ajout.md'
verifie "échec puis succès : relancé une fois, run en succès et committé (code $rc)" $?
kb_neuve
run echec
rc=$?
[ "$rc" -eq 1 ] && [ "$(wc -l <"$TD/appels" | tr -d ' ')" -eq 2 ]
verifie "échec persistant : exactement 2 essais, run en échec (code $rc)" $?

# Entrée standard : un tuyau ouvert bloquait opencode 30 min (2026-10-31), il doit voir /dev/null.
kb_neuve
printf 'x\n' | run ajout >/dev/null
awk '{print $2}' "$TD/appels" | grep -qx null && ! grep -q tuyau "$TD/appels"
verifie "opencode lit /dev/null même lancé derrière un tuyau" $?

# Config vue par opencode : la vraie, moins plugin et mcp (un plugin garde-fou refuserait chaque note).
grep -qF '["provider"]' "$TD/appels"
verifie "config sans plugin ni mcp, provider gardé" $?
kb_neuve
echo '{pas du json' >"$FH/.config/opencode/opencode.json"
run ajout
rc=$?
[ "$rc" -eq 1 ] && [ ! -f "$TD/appels" ] && grep -q 'config sans plugins non préparée' "$FH/.config/veille/loop.log"
verifie "config illisible : run annulé avant opencode (code $rc)" $?
echo '{"plugin":["garde-md"],"mcp":{"x":{}},"provider":{"deepseek":{"options":{"baseURL":"http://127.0.0.1:8787"}}}}' >"$FH/.config/opencode/opencode.json"

# Journal : la sortie brute de l'agent (39 280 lignes sur 47 460 le 2026-11-02) va dans son propre
# fichier ; loop.log ne garde que les lignes du cron, et un renvoi vers ce fichier.
J="$FH/.config/veille/loop.log"
A="$FH/.config/veille/loop-agent"
kb_neuve
rm -rf "$J" "$A"
run ajout >/dev/null
! grep -q 'sortie brute' "$J" && grep -lq 'sortie brute' "$A"/*.log 2>/dev/null && grep -q "sortie de l'agent : $A/" "$J"
verifie "sortie de l'agent hors de loop.log, dans loop-agent/, avec un renvoi" $?
kb_neuve
run echec >/dev/null
grep -q "ECHEC : opencode sorti en code 1, voir $A/" "$J"
verifie "échec d'opencode : loop.log renvoie au fichier de l'agent" $?

# Index : une note du run absente du _index.md de son topic se journalise (2 sur 27 le 2026-11-02),
# sans faire échouer le run ; une note indexée ne laisse aucune ligne.
kb_neuve
rm -f "$J"
run ajout >/dev/null
rc=$?
[ "$rc" -eq 0 ] && grep -q 'INDEX INCOMPLET : 1 notes du run absentes de leur _index.md : t/notes/n-ajout.md' "$J"
verifie "note hors index : INDEX INCOMPLET journalisé, run en succès (code $rc)" $?
kb_neuve
rm -f "$J"
run indexe >/dev/null
rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'INDEX INCOMPLET' "$J" && grep -q 'commit local OK' "$J"
verifie "note indexée : aucune ligne INDEX INCOMPLET (code $rc)" $?
# Des index ne citent que l'URL de la note, jamais son fichier (applewatch : 272 notes, mesure du
# 2026-11-03) : cherchée par son seul nom, la note y passait pour absente, un faux WARN.
kb_neuve
rm -f "$J"
run indexe-url >/dev/null
rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'INDEX INCOMPLET' "$J" && grep -q 'commit local OK' "$J"
verifie "note indexée par son URL seule : aucune ligne INDEX INCOMPLET (code $rc)" $?

# Rotation : au-delà de VEILLE_LOG_MAX octets, loop.log est réduit à ses lignes datées, les dernières.
kb_neuve
rm -rf "$J" "$A"
mkdir -p "$A"
{
	for i in $(seq 1 30); do echo "[2026-10-01 07:13:00] ===== veille-loop END (exit 0) ====="; echo "bruit d'agent non daté $i"; done
	echo "[2026-10-02 07:13:00] marqueur du dernier run"
} >"$J"
for i in $(seq -w 1 20); do : >"$A/2026-10-$i""_071300.log"; done
VEILLE_LOG_MAX=500 VEILLE_LOG_LIGNES=10 run ajout >/dev/null
! grep -q 'bruit' "$J" && grep -q 'marqueur du dernier run' "$J" && [ "$(grep -c '2026-10-01' "$J")" -le 9 ] && grep -q 'veille-loop END (exit 0)' "$J"
verifie "rotation : bruit retiré, dernières lignes datées gardées, run courant journalisé" $?
[ "$(ls "$A" | wc -l | tr -d ' ')" -eq 14 ] && [ ! -e "$A/2026-10-01_071300.log" ] && [ "$(ls "$A" | sort | tail -1)" \> 2026-10-20 ]
verifie "loop-agent/ : 14 fichiers gardés, les plus anciens supprimés, le run du jour présent" $?
kb_neuve
printf '[2026-10-02 07:13:00] court\nbruit court\n' >"$J"
run ajout >/dev/null
grep -q 'bruit court' "$J"
verifie "sous le seuil : loop.log laissé tel quel" $?

echo "---"
echo "$PASS ok, $FAIL échec(s)"
[ "$FAIL" -eq 0 ]
