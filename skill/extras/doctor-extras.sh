#!/usr/bin/env bash
# doctor-extras.sh · état des sources AVANCÉES (extras, livrées en l'état) qui demandent autre chose que curl.
# Le cœur a son propre doctor : ../doctor.sh.
#
# Lecture seule, aucune écriture. Chaque ligne dit si la source est utilisable MAINTENANT,
# et sinon la commande exacte qui la répare.
#
#   bash doctor-extras.sh            DÉFAUT : teste vraiment la clé et la session (2 requêtes)
#   bash doctor-extras.sh --offline  config seule, zéro requête réseau
#
# Pourquoi le réseau est le défaut : sans lui, un doctor qui affiche « OK · session non
# testée » ment le jour où la session Yandex expire, et DEUX sources meurent en silence
# (Yandex, et la recherche VK qui passe par lui). Un vert doit vouloir dire vert.
#   bash doctor-extras.sh --json     sortie machine
#
# Garde-fou conservé : 2 requêtes au total, UNE par domaine, jamais de boucle, jamais de retry.
# Limites connues au 2026-08-26 : Kakao documente 25 000 appels/jour ; Yandex ne publie rien
# (vérifié, pas de /llms.txt ni de page de quotas), d'où le refus d'y toucher par défaut.
#
# Les sources en pur curl (Google News, HN, GitHub, RSS, Habr, Telegram, Brunch, velog)
# n'ont ni clé ni session ni binaire : elles ne sont pas ici, elles marchent ou pas au run.

set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HOME/.config/veille"
JSON=0
LIVE=1                     # le réseau est le DÉFAUT, cf. en-tête
for a in "$@"; do
	case "$a" in
	--json) JSON=1 ;;
	--live) LIVE=1 ;;      # conservé pour compatibilité, sans effet
	--offline) LIVE=0 ;;
	esac
done
ROWS=()
FAIL=0

row() { # $1=source $2=OK|KO|SKIP $3=detail $4=reparation
	ROWS+=("$1|$2|$3|$4")
	[ "$2" = "KO" ] && FAIL=$((FAIL + 1))
	return 0
}

# --- 1. node + playwright, socle de fx.mjs et vk.mjs ---
if ! command -v node >/dev/null 2>&1; then
	row "node" "KO" "binaire absent" "brew install node"
else
	export NODE_PATH="${NODE_PATH:-$(npm root -g 2>/dev/null)}"
	# Ce test doit reproduire la resolution REELLE de fx.mjs et vk.mjs, qui sont des .mjs :
	# Node IGNORE NODE_PATH pour les modules ESM (mesure du 2026-08-31, ERR_MODULE_NOT_FOUND
	# avec playwright pourtant installe en global). Les deux scripts resolvent donc via
	# `npm root -g` a l'execution. Un test base sur NODE_PATH mentirait dans les deux sens.
	if node -e "const{createRequire}=require('module');const{execSync}=require('child_process');const r=createRequire(process.cwd()+'/probe.js');try{r.resolve('playwright')}catch(e){r.resolve(execSync('npm root -g',{encoding:'utf8'}).trim()+'/playwright')}" 2>/dev/null; then
		FF=$(node -e "const{createRequire}=require('module');const{execSync}=require('child_process');const r=createRequire(process.cwd()+'/probe.js');let pw;try{pw=r('playwright')}catch(e){pw=r(execSync('npm root -g',{encoding:'utf8'}).trim()+'/playwright')}console.log(pw.firefox.executablePath())" 2>/dev/null)
		if [ -x "$FF" ]; then
			row "playwright" "OK" "$(echo "$FF" | sed -E 's#.*(firefox-[0-9]+).*#\1#')" "-"
		else
			row "playwright" "KO" "module présent, binaire Firefox absent" "npx playwright install firefox"
		fi
	else
		row "playwright" "KO" "introuvable, ni en local ni sous npm root -g" "npm i -g playwright && npx playwright install firefox"
	fi
fi

# --- 2. profil Firefox persistant ---
if [ -f "$CFG/fx-profile/cookies.sqlite" ]; then
	row "profil fx" "OK" "$CFG/fx-profile" "-"
else
	row "profil fx" "KO" "profil absent ou jamais utilisé" "node $S/fx.mjs login"
fi
# Verrou du profil. PIÈGE PAYÉ le 2026-08-26 : `.parentlock` est un fichier ORDINAIRE que
# Firefox laisse derrière lui même après une sortie propre. Le tester revenait à signaler un
# verrou sur un profil parfaitement sain (faux positif constaté sur ce doctor lui-même, alors
# que la ligne Yandex du MÊME run prouvait que Firefox venait de se lancer).
# Le vrai verrou est le symlink `lock`, et la vraie panne est un PROCESSUS encore vivant :
# c'est lui qui fait sortir Firefox aussitôt au lancement suivant.
if pgrep -f "veille/fx-profile" >/dev/null 2>&1; then
  row "verrou fx" "KO" "un Firefox tient déjà le profil" "fermer la fenêtre, ou : pkill -TERM -f veille/fx-profile"
elif [ -L "$CFG/fx-profile/lock" ]; then
  row "verrou fx" "KO" "symlink lock orphelin, le lancement échouera" "rm -f $CFG/fx-profile/lock"
else
  row "verrou fx" "OK" "profil libre" "-"
fi

# --- 3. clé REST Kakao ---
# La clé passe par un fichier d'en-tête (-H @fichier), jamais en argument de curl :
# les arguments d'un process sont lisibles par tout utilisateur via ps.
if [ ! -s "$CFG/kakao_rest_key" ]; then
	row "Kakao dapi" "KO" "clé absente" "créer une APP sur developers.kakao.com, clé sous config/platform-key, puis: echo '<cle>' > $CFG/kakao_rest_key && chmod 600 $CFG/kakao_rest_key"
elif [ "$LIVE" = "1" ]; then
	CODE=$(curl -sS -o /dev/null -w '%{http_code}' -G 'https://dapi.kakao.com/v2/search/web' \
		-H @<(printf 'Authorization: KakaoAK %s\n' "$(cat "$CFG/kakao_rest_key")") \
		--data-urlencode 'query=ping' --max-time 15 2>/dev/null)
	[ "$CODE" = "200" ] &&
		row "Kakao dapi" "OK" "HTTP 200 (1 requête)" "-" ||
		row "Kakao dapi" "KO" "HTTP $CODE" "clé invalide ou révoquée : developers.kakao.com -> config/platform-key"
else
	row "Kakao dapi" "OK" "clé présente (non testée, mode --offline)" "-"
fi

# --- 4. session Yandex, dont dépend AUSSI la recherche VK ---
if [ ! -f "$CFG/fx-profile/cookies.sqlite" ] || ! command -v node >/dev/null 2>&1; then
	row "Yandex+VK" "KO" "prérequis manquant (node ou profil)" "voir les lignes ci-dessus"
elif [ "$LIVE" = "1" ]; then
	# PIEGE CORRIGE le 2026-09-01 : la version precedente ne comptait que les occurrences de
	# 'showcaptcha' dans la sortie. Quand fx.mjs plantait (playwright absent), stderr partait a
	# /dev/null, stdout etait vide, grep -c rendait 0, et le doctor annoncait "aucun captcha, OK".
	# Un crash etait donc rapporte comme un succes. Il faut gater sur le CODE DE SORTIE et sur un
	# CONTROLE POSITIF (la page doit contenir quelque chose), pas sur l'absence d'un motif.
	YXOUT=$(NODE_PATH="${NODE_PATH:-$(npm root -g 2>/dev/null)}" timeout 90 node "$S/fx.mjs" dom \
		'https://yandex.ru/search/?text=ping' 2>/dev/null)
	YXRC=$?
	YXLEN=${#YXOUT}
	if [ "$YXRC" -ne 0 ] || [ "$YXLEN" -lt 2000 ]; then
		row "Yandex+VK" "KO" "fx.mjs a echoue (code $YXRC, ${YXLEN} octets rendus)" "verifier la ligne playwright ci-dessus, puis relancer"
	elif printf '%s' "$YXOUT" | grep -q 'showcaptcha\|SmartCaptcha'; then
		row "Yandex+VK" "KO" "SmartCaptcha : session perdue" "node $S/fx.mjs login https://passport.yandex.ru/auth"
	else
		row "Yandex+VK" "OK" "aucun captcha, ${YXLEN} octets rendus" "-"
	fi
else
	row "Yandex+VK" "OK" "profil présent (session NON testée, mode --offline)" "-"
fi

# --- 5. canaux Telegram ---
if [ -s "$CFG/tg_channels.txt" ]; then
	NB=$(grep -vc '^[[:space:]]*#' "$CFG/tg_channels.txt" 2>/dev/null || echo 0)
	row "Telegram" "OK" "$NB canaux configurés" "-"
else
	row "Telegram" "KO" "liste de canaux absente" "curl -sL 'https://tgstat.ru/tech' | grep -o '/channel/@[A-Za-z0-9_]*' | cut -d@ -f2 | sort -u > $CFG/tg_channels.txt"
fi

# --- 6. helpers livrés avec le skill ---
for f in tg2ndjson.py fx.mjs vk.mjs ../rss2ndjson.py; do
	if [ -f "$S/$f" ]; then
		row "${f#../}" "OK" "présent" "-"
	else row "${f#../}" "KO" "absent" "git pull (ou re-cloner le dépôt veille)"; fi
done

# --- sortie ---
if [ "$JSON" = "1" ]; then
	printf '{"pret":%s,"live":%s,"sources":[' \
		"$([ "$FAIL" -eq 0 ] && echo true || echo false)" \
		"$([ "$LIVE" = "1" ] && echo true || echo false)"
	sep=""
	for r in "${ROWS[@]}"; do
		IFS='|' read -r n s d rep <<<"$r"
		printf '%s{"source":"%s","statut":"%s","detail":"%s","reparation":"%s"}' "$sep" "$n" "$s" "$d" "$rep"
		sep=","
	done
	printf ']}\n'
else
	printf '%-16s %-5s %-50s %s\n' "SOURCE" "ÉTAT" "DÉTAIL" "RÉPARATION"
	printf '%.0s-' {1..118}
	echo
	for r in "${ROWS[@]}"; do
		IFS='|' read -r n s d rep <<<"$r"
		printf '%-16s %-5s %-50s %s\n' "$n" "$s" "$d" "$rep"
	done
	echo
	if [ "$FAIL" -eq 0 ]; then
		echo "Tout est prêt.$([ "$LIVE" = "0" ] && echo "  ATTENTION : mode --offline, ni la clé ni la session ne sont testées.")"
	else
		echo "$FAIL source(s) à réparer, commandes dans la colonne de droite."
	fi
fi
exit 0
