#!/usr/bin/env bash
# loop-cron.sh : veille quotidienne (transcripts YouTube), lancée par launchd chaque matin.
# Runner : OpenCode headless, modèle réglable par VEILLE_MODEL.
#
# Architecture : la récolte est déterministe (bash, coût LLM zéro), la distillation est faite par
# l'agent opencode `veille-loop`, et le script committe EN LOCAL uniquement les fichiers touchés
# pendant le run (jamais `git add -A` : le dépôt contient parfois du travail non committé d'autres
# sessions). Jamais de push.
#
# Test manuel : bash ~/.claude/skills/veille/extras/automatisation/loop-cron.sh

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

KB="${VEILLE_KB:-$HOME/veille-kb}"
CFGDIR="$HOME/.config/veille"
LOG="$CFGDIR/loop.log"
AGENTDIR="$CFGDIR/loop-agent"        # sortie brute d'opencode, un fichier par run, les 14 derniers gardés
LOG_MAX="${VEILLE_LOG_MAX:-1048576}" # surchargés par loop-cron.test.sh
LOG_LIGNES="${VEILLE_LOG_LIGNES:-2000}"
MODEL="${VEILLE_MODEL:-deepseek/deepseek-flash}"
TIMEOUT_S=2700
OPENCODE="${VEILLE_OPENCODE:-opencode}" # surchargé par loop-cron.test.sh, jamais en production
# Chemins résolus depuis ce script : la garde est à la racine de la skill, la récolte à côté.
# VEILLE_CHECK_MERGE et VEILLE_HARVEST ne servent qu'au banc (sabotage, récolte simulée).
ICI="$(cd "$(dirname "$0")" && /bin/pwd)"
GARDE="${VEILLE_CHECK_MERGE:-$ICI/../../check-merge.sh}"
RECOLTE="${VEILLE_HARVEST:-$ICI/loop-harvest.sh}"

mkdir -p "$CFGDIR" "$AGENTDIR"
log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }

# Préflight : les chemins absolus doivent exister (leçon du 2026-09-28 : /usr/bin/cat n'existe
# pas sur macOS, son échec silencieux avait fait rater les transcripts du lot 1).
for bin in /usr/bin/mktemp /usr/bin/git /usr/bin/find /usr/bin/sort /usr/bin/comm /usr/bin/cut \
	/usr/bin/sed /usr/bin/grep /usr/bin/wc /usr/bin/tr /usr/bin/tail /usr/bin/stat /bin/cat /bin/mkdir /bin/ln /bin/mv /bin/rm; do
	[ -x "$bin" ] || {
		echo "[$(date '+%F %T')] ECHEC préflight : $bin introuvable" >>"$LOG"
		exit 1
	}
done

# Rotation : au-delà de LOG_MAX octets, loop.log ne garde que ses LOG_LIGNES dernières lignes datées.
# Le 2026-11-02 il pesait 7,5 Mo, dont 39 280 lignes sur 47 460 de sortie d'agent, où un « ECHEC »
# cité dans une note se confondait avec un échec du cron. Pour suivre la boucle, le dernier END
# réussi suffit : les lignes datées suffisent.
if [ -f "$LOG" ] && [ "$(/usr/bin/stat -f %z "$LOG")" -gt "$LOG_MAX" ]; then
	/usr/bin/grep -a '^\[20[0-9-]* [0-9:]*\] ' "$LOG" | /usr/bin/tail -n "$LOG_LIGNES" >"$LOG.rot" && /bin/mv "$LOG.rot" "$LOG"
fi

echo "" >>"$LOG"
log "===== veille-loop START ====="

[ -d "$KB" ] || {
	log "ECHEC : KB absente ($KB)"
	log "===== veille-loop END (exit 1) ====="
	exit 1
}

# 1. Récolte déterministe (yt-dlp + ytkb) vers le staging. Aucun coût LLM.
#    VEILLE_LATEST et VEILLE_MAX permettent un run de rattrapage manuel, ex :
#    VEILLE_LATEST=10 VEILLE_MAX=30 bash .../loop-cron.sh
HARVEST_LATEST="${VEILLE_LATEST:-2}"
HARVEST_MAX="${VEILLE_MAX:-15}"
HARVEST_OUT="$(bash "$RECOLTE" "$HARVEST_LATEST" "$HARVEST_MAX" 2>>"$LOG")"
rc=$?
if [ "$rc" -ne 0 ]; then
	log "ECHEC récolte (code $rc)"
	log "===== veille-loop END (exit $rc) ====="
	exit "$rc"
fi
if printf '%s' "$HARVEST_OUT" | /usr/bin/grep -q 'RIEN_DE_NEUF'; then
	log "récolte : RIEN_DE_NEUF, rien à distiller"
	log "===== veille-loop END (exit 0) ====="
	exit 0
fi
log "récolte OK : $(printf '%s\n' "$HARVEST_OUT" | /usr/bin/tail -n 1)"

# 2. Distillation par l'agent opencode veille-loop (lecture des transcripts, notes, classement,
#    index, synthèses, nettoyage du staging). Le script committe à l'étape 3.
# Config sans plugins : la CLI 2.x a retiré --pure et --dir (« Unrecognized flag », code 1 sans
# appel du modèle) ; du 12 au 31/10/2026, chaque run a fini ainsi, 19 jours sans une note. Un
# `opencode run` nu passe par le service de fond, qui charge les plugins de la config globale :
# un plugin garde-fou qui bloque l'écriture de markdown refuserait chaque note de la KB. D'où un
# serveur privé (--standalone, qui hérite de l'environnement) lancé sur une config à part : la
# vraie moins `plugin` et `mcp` (les réglages `provider` sont gardés), plus des liens vers les
# agents et vers AGENTS.md. Mesuré le 2026-10-31 avec témoin :
# 0 plugin chargé contre 1, aucun MCP. Le dossier de travail se donne par un cd.
PUR="$(/usr/bin/mktemp -d /tmp/veille-loop-pur.XXXXXX)" || PUR=""
if [ -z "$PUR" ] || ! /bin/mkdir -p "$PUR/opencode" ||
	! /bin/ln -s "$HOME/.config/opencode/agent" "$PUR/opencode/agent" ||
	! /bin/ln -s "$HOME/.config/opencode/AGENTS.md" "$PUR/opencode/AGENTS.md" ||
	! jq -e 'del(.plugin, .mcp)' "$HOME/.config/opencode/opencode.json" >"$PUR/opencode/opencode.json" 2>>"$LOG"; then
	log "ECHEC : config sans plugins non préparée, run annulé"
	[ -n "$PUR" ] && rm -rf "$PUR"
	log "===== veille-loop END (exit 1) ====="
	exit 1
fi
STAMP="$(/usr/bin/mktemp /tmp/veille-loop-stamp.XXXXXX)"
touch "$STAMP"
BEFORE_STATUS="$(/usr/bin/mktemp /tmp/veille-loop-before.XXXXXX)"
/usr/bin/git -C "$KB" status --porcelain=v1 | /usr/bin/sort >"$BEFORE_STATUS"
PROMPT="Run de veille du $(date '+%F'). La récolte est déjà faite. Applique le runbook et réponds en une ligne."
# Un échec (timeout ou blocage au démarrage) est retenté UNE fois après 60 s : mesuré le
# 2026-09-28, les blocages se lèvent souvent d'eux-mêmes, et un cron qui abandonne au premier
# hoquet perd la journée entière.
# `</dev/null` obligatoire : `opencode run` lit son entrée standard jusqu'au bout avant même de
# résoudre le modèle. Sous launchd c'est déjà /dev/null ; lancé en tâche de fond par une session
# Claude Code, c'est une socket qui ne se ferme jamais. Le 2026-10-31, un run manuel est resté
# 30 min sans créer de session ni joindre DeepSeek. Banc : tuyau ouvert 25 s, réponse en 25 s ;
# /dev/null, 0 à 1 s. Déjà mesuré le 2026-10-10 dans deleguer.sh.
AGENT_LOG="$AGENTDIR/$(date '+%F_%H%M%S').log"
log "sortie de l'agent : $AGENT_LOG"
/usr/bin/find "$AGENTDIR" -name '*.log' | /usr/bin/sort -r | /usr/bin/tail -n +14 | while read -r vieux; do /bin/rm -f "$vieux"; done
attempt=1
while :; do
	(cd "$KB" && XDG_CONFIG_HOME="$PUR" timeout "$TIMEOUT_S" "$OPENCODE" run --standalone --agent veille-loop -m "$MODEL" -- "$PROMPT" </dev/null) >>"$AGENT_LOG" 2>&1
	code=$?
	[ "$code" -eq 0 ] && break
	if [ "$attempt" -ge 2 ]; then break; fi
	log "échec (code $code), nouvel essai dans 60 s"
	sleep "${VEILLE_RELANCE_S:-60}" # surchargé par loop-cron.test.sh, jamais en production
	attempt=$((attempt + 1))
done
rm -rf "$PUR"
case "$code" in
0) log "opencode OK" ;;
124) log "ECHEC : opencode bloqué (timeout ${TIMEOUT_S} s, code 124), voir $AGENT_LOG" ;;
*) log "ECHEC : opencode sorti en code $code, voir $AGENT_LOG" ;;
esac

# 3. Commit local des SEULS fichiers touchés ou apparus pendant le run. Jamais de push.
#    Deux détecteurs : find -newer (fichiers réécrits) ET diff de git status avant/après
#    (fichiers déplacés : `mv` préserve la mtime, donc un transcript classé vers un topic
#    n'apparaîtrait jamais avec find -newer seul).
AFTER_STATUS="$(/usr/bin/mktemp /tmp/veille-loop-after.XXXXXX)"
/usr/bin/git -C "$KB" status --porcelain=v1 | /usr/bin/sort >"$AFTER_STATUS"
NEW_PATHS="$(/usr/bin/mktemp /tmp/veille-loop-new.XXXXXX)"
/usr/bin/comm -13 "$BEFORE_STATUS" "$AFTER_STATUS" | /usr/bin/cut -c4- | /usr/bin/sed 's/^.* -> //' >"$NEW_PATHS"
TOUCHED_LIST="$(/usr/bin/mktemp /tmp/veille-loop-touched.XXXXXX)"
/usr/bin/find "$KB" -type f -newer "$STAMP" -not -path '*/.git/*' 2>/dev/null >"$TOUCHED_LIST"
/bin/cat "$NEW_PATHS" >>"$TOUCHED_LIST"
/usr/bin/sort -u "$TOUCHED_LIST" -o "$TOUCHED_LIST"
# Normaliser en chemins relatifs AVANT le dédoublonnage final : find -newer donne des chemins
# absolus et le diff de status des chemins relatifs, donc sans ça chaque note comptait double
# (message de commit « 82 notes » au lieu de 41, lot du 2026-09-28).
TOUCHED_NORM="$(/usr/bin/mktemp /tmp/veille-loop-touched-norm.XXXXXX)"
/usr/bin/sed "s|^$KB/||" "$TOUCHED_LIST" | /usr/bin/sort -u >"$TOUCHED_NORM"
mv "$TOUCHED_NORM" "$TOUCHED_LIST"
NEW_N="$(/usr/bin/grep -c . "$NEW_PATHS" || true)"
: "${NEW_N:=0}"
rm -f "$STAMP" "$BEFORE_STATUS" "$AFTER_STATUS" "$NEW_PATHS"
TOUCHED_N="$(/usr/bin/wc -l <"$TOUCHED_LIST" | /usr/bin/tr -d ' ')"
NOTES_N="$(/usr/bin/grep -c '/notes/.*\.md$' "$TOUCHED_LIST" || true)"
: "${NOTES_N:=0}"

# Index : chaque note du run doit avoir sa ligne dans le _index.md de son topic (étape 5 du
# runbook). Le 2026-11-02, 2 notes de la loop sur 27 en manquaient, sans que rien ne le dise.
# Non bloquant : journalisé, et oc-doctor relaie la ligne en WARN.
INDEX_MANQUE=""
while IFS= read -r f; do
	case "$f" in
	[!_]*/notes/*.md)
		[ -f "$KB/$f" ] || continue
		id="${f##*/}"
		idx="$KB/${f%%/*}/_index.md"
		/usr/bin/grep -qF -- "${id%.md}" "$idx" 2>/dev/null && continue
		# Des index citent la note par son URL seule (applewatch, opencode) : l'URL du front-matter
		# compte aussi. Mesure fausse du 2026-11-02 sans elle : 1 018 « absentes », 50 en réalité.
		url="$(/usr/bin/sed -n '1,30s/^url:[[:space:]]*"\{0,1\}\([^"[:space:]]*\).*/\1/p' "$KB/$f" | /usr/bin/head -1)"
		[ -n "$url" ] && /usr/bin/grep -qF -- "${url%/}" "$idx" 2>/dev/null && continue
		INDEX_MANQUE="$INDEX_MANQUE $f"
		;;
	esac
done <"$TOUCHED_LIST"
[ -n "$INDEX_MANQUE" ] && log "INDEX INCOMPLET : $(echo $INDEX_MANQUE | /usr/bin/wc -w | /usr/bin/tr -d ' ') notes du run absentes de leur _index.md :$INDEX_MANQUE"

if [ "$code" -eq 0 ] && [ "$TOUCHED_N" -gt 0 ]; then
	if ! /usr/bin/git -C "$KB" diff --cached --quiet; then
		log "ATTENTION : des fichiers étaient déjà dans l'index avant le commit, commit automatique annulé"
	else
		# Garde des SYNTHESIS : check-merge.sh existait depuis le 2026-08-29 (90 lignes perdues par
		# des agents de synthèse) mais seul le /veille manuel l'appelait, alors que la loop réécrit
		# des SYNTHESIS chaque matin. Une SYNTHESIS qui perd une ligne reste sur le disque, hors du
		# commit, et le run sort en échec pour qu'oc-doctor le voie.
		PERTES=0
		while IFS= read -r f; do
			[ -z "$f" ] && continue
			case "$f" in
			*/SYNTHESIS.md)
				if ! KB="$KB" bash "$GARDE" "${f%/SYNTHESIS.md}" HEAD >>"$LOG" 2>&1; then
					log "ECHEC $f perd des lignes (détail ci-dessus) : exclue du commit, laissée sur le disque"
					PERTES=$((PERTES + 1))
					continue
				fi
				;;
			_ENTITIES/*.md)
				# Même règle pour les fiches d'entités (étape 5bis, depuis le 2026-11-01) : on
				# ajoute, on ne retire rien. Une fiche neuve n'a pas d'ancienne version à comparer.
				ancien="$(/usr/bin/mktemp /tmp/veille-entite.XXXXXX)"
				if /usr/bin/git -C "$KB" show "HEAD:./$f" >"$ancien" 2>/dev/null &&
					! python3 "${GARDE%.sh}.py" "$ancien" "$KB/$f" >>"$LOG" 2>&1; then
					rm -f "$ancien"
					log "ECHEC $f perd des lignes (détail ci-dessus) : exclue du commit, laissée sur le disque"
					PERTES=$((PERTES + 1))
					continue
				fi
				rm -f "$ancien"
				;;
			esac
			if [ -f "$KB/$f" ] || [ -f "$f" ]; then
				/usr/bin/git -C "$KB" add -- "$f"
			fi
		done <"$TOUCHED_LIST"
		if ! /usr/bin/git -C "$KB" diff --cached --quiet; then
			# Le pre-commit de la KB (tools/githooks/kb-pre-commit, depuis le 2026-11-01) peut
			# refuser. Sans ce contrôle, le refus était journalisé « commit OK », et l'index resté
			# chargé faisait annuler le commit de chaque run suivant : un blocage muet. On vide
			# l'index (les fichiers restent sur le disque) et le run sort en échec, ce que
			# oc-doctor voit.
			if /usr/bin/git -C "$KB" commit -q -m "veille-loop: $(date '+%F') ($NOTES_N notes)" >>"$LOG" 2>&1; then
				log "commit local OK ($TOUCHED_N fichiers touchés dont $NEW_N apparus/déplacés, $NOTES_N notes)"
			else
				/usr/bin/git -C "$KB" reset -q
				log "ECHEC commit refusé (pre-commit ?), fichiers laissés sur le disque, voir les lignes ci-dessus"
				code=1
			fi
		else
			log "rien à committer ($TOUCHED_N fichiers touchés mais identiques à l'index)"
		fi
		[ "$PERTES" -gt 0 ] && code=1
	fi
else
	log "pas de commit (code $code, $TOUCHED_N fichiers touchés, laissés en place pour inspection)"
fi
rm -f "$TOUCHED_LIST"

log "===== veille-loop END (exit $code) ====="
exit "$code"
