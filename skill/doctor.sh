#!/usr/bin/env bash
# doctor.sh · la veille est-elle prête à tourner MAINTENANT ?
#
# Lecture seule, zéro requête réseau. Chaque ligne dit si un outil ou une source du cœur
# est utilisable, et sinon la commande exacte qui la répare.
#
#   bash doctor.sh          tableau lisible
#   bash doctor.sh --json   sortie machine
#
# États : OK (prêt), KO (le cœur ne tournera pas, à réparer), SKIP (source optionnelle
# désactivée, la veille tourne sans). Code de retour : 0 sans KO, 1 sinon.
#
# Le piège le plus fréquent est yt-dlp périmé : YouTube change, yt-dlp suit, un binaire de
# plus de deux mois finit en « nsig extraction failed » ou « Sign in to confirm you're not a
# bot » sur TOUTES les vidéos. D'où le contrôle d'âge ci-dessous.
#
# Les sources avancées (Kakao, Yandex, VK, Telegram, Playwright) ont leur propre doctor :
# extras/doctor-extras.sh.

set -uo pipefail
CFG="$HOME/.config/veille"
KB="${VEILLE_KB:-$HOME/veille-kb}"
REPARE="bash install.sh (à la racine du dépôt veille)"
AGE_MAX=60 # jours
JSON=0
[ "${1:-}" = "--json" ] && JSON=1
ROWS=()
FAIL=0

row() { # $1=source $2=OK|KO|SKIP $3=detail $4=reparation
	ROWS+=("$1|$2|$3|$4")
	[ "$2" = "KO" ] && FAIL=$((FAIL + 1))
	return 0
}

# --- 1. outils de base ---
for b in curl jq python3 git; do
	if command -v "$b" >/dev/null 2>&1; then
		row "$b" "OK" "présent" "-"
	else
		row "$b" "KO" "binaire absent" "brew install $b (ou le paquet de ta distribution)"
	fi
done

# --- 2. yt-dlp, et son âge ---
if ! command -v yt-dlp >/dev/null 2>&1; then
	row "yt-dlp" "KO" "binaire absent" "brew install yt-dlp (ou pipx install yt-dlp)"
else
	v=$(yt-dlp --version 2>/dev/null | head -1)
	age=$(python3 -c 'import sys,datetime as d
try: print((d.date.today()-d.datetime.strptime(sys.argv[1][:10],"%Y.%m.%d").date()).days)
except Exception: print(-1)' "$v" 2>/dev/null || echo -1)
	if [ "$age" -lt 0 ]; then
		row "yt-dlp" "OK" "version $v (âge illisible)" "-"
	elif [ "$age" -gt "$AGE_MAX" ]; then
		row "yt-dlp" "KO" "version $v, vieille de $age jours" "brew upgrade yt-dlp (ou pipx upgrade yt-dlp)"
	else
		row "yt-dlp" "OK" "version $v ($age jours)" "-"
	fi
fi

# --- 3. ytkb, le binaire YouTube du dépôt ---
if command -v ytkb >/dev/null 2>&1; then
	row "ytkb" "OK" "présent" "-"
else
	row "ytkb" "KO" "binaire absent, YouTube indisponible" "$REPARE"
fi

# --- 4. gh, source GitHub optionnelle ---
if ! command -v gh >/dev/null 2>&1; then
	row "gh" "SKIP" "absent, source GitHub désactivée" "brew install gh && gh auth login"
elif ! gh auth status >/dev/null 2>&1; then
	row "gh" "SKIP" "non connecté, source GitHub désactivée" "gh auth login"
else
	row "gh" "OK" "connecté" "-"
fi

# --- 5. la base de connaissance ---
if [ ! -d "$KB" ]; then
	row "KB" "KO" "absente : $KB" "$REPARE"
elif [ ! -w "$KB" ]; then
	row "KB" "KO" "non inscriptible : $KB" "chmod u+w \"$KB\""
elif ! git -C "$KB" rev-parse --git-dir >/dev/null 2>&1; then
	row "KB" "KO" "pas un dépôt git (le contrôle de synthèse en a besoin)" "git -C \"$KB\" init"
else
	row "KB" "OK" "$KB" "-"
fi

# --- 6. listes de sources personnelles ---
for f in feeds channels; do
	if [ -s "$CFG/$f.txt" ]; then
		nb=$(grep -cv '^[[:space:]]*\(#\|$\)' "$CFG/$f.txt" 2>/dev/null || echo 0)
		row "$f.txt" "OK" "$nb entrée(s)" "-"
	else
		row "$f.txt" "SKIP" "absent, la liste perso est vide" "cp config/$f.example.txt ~/.config/veille/$f.txt"
	fi
done

# --- sortie ---
if [ "$JSON" = "1" ]; then
	printf '{"pret":%s,"sources":[' "$([ "$FAIL" -eq 0 ] && echo true || echo false)"
	sep=""
	for r in "${ROWS[@]}"; do
		IFS='|' read -r n s d rep <<<"$r"
		printf '%s{"source":"%s","statut":"%s","detail":"%s","reparation":"%s"}' "$sep" "$n" "$s" "$d" "$rep"
		sep=","
	done
	printf ']}\n'
else
	printf '%-12s %-5s %-46s %s\n' "SOURCE" "ÉTAT" "DÉTAIL" "RÉPARATION"
	for r in "${ROWS[@]}"; do
		IFS='|' read -r n s d rep <<<"$r"
		printf '%-12s %-5s %-46s %s\n' "$n" "$s" "$d" "$rep"
	done
	echo
	if [ "$FAIL" -eq 0 ]; then echo "Tout est prêt."; else echo "$FAIL panne(s) à réparer, commandes dans la colonne de droite."; fi
fi
[ "$FAIL" -eq 0 ]
