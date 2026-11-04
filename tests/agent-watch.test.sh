#!/usr/bin/env bash
# agent-watch.test.sh · un nom de fichier piégé (tabulation, glob, $(...)) ne doit ni forger les champs, ni exécuter de commande. Lance aussi le --self-test du script.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
W="$R/skill/agent-watch.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/agent-watch-pieges.XXXXXX")
ko=0
verifie() { if [ "$2" = 0 ]; then echo "ok · $1"; else echo "ÉCHEC · $1"; ko=1; fi; }
ligne='{"type":"user","sessionId":"s","message":{"role":"user","content":"x"}}'
mkdir -p "$T/home" "$T/cwd" "$T/d1" "$T/d2"
# 1. tabulations + substitution de commande dans le nom, à côté d'un transcript normal
printf '%s\n' "$ligne" > "$T/d1/normal.output"
printf '%s\n' "$ligne" > "$T/d1/"$'PATH[$(touch PIEGE)]\tb\tc.output'
sortie=$(cd "$T/cwd" && HOME="$T/home" bash "$W" --dir "$T/d1" 2>&1)
verifie "contrôle positif : le transcript normal ressort VIVANT" "$(printf '%s' "$sortie" | grep -q '^normal .*VIVANT' && echo 0 || echo 1)"
verifie "aucune commande exécutée depuis un nom de fichier" "$([ -e "$T/cwd/PIEGE" ] && echo 1 || echo 0)"
verifie "le fichier piégé est lu comme un agent, pas comme des champs forgés" "$([ "$(printf '%s' "$sortie" | grep -cE '^[^ ]+ +VIVANT ')" = 2 ] && echo 0 || echo 1)"
# 2. glob dans le nom, en mode fichier : il ne doit pas s'étendre aux voisins
for n in 'g*' g1 g2; do printf '%s\n' "$ligne" > "$T/d2/$n"; done
etat=$(HOME="$T/home" bash "$W" "$T/d2/g*" 2>&1 | head -1 | awk '{print $2}')
verifie "nom avec * en mode fichier : VIVANT" "$([ "$etat" = VIVANT ] && echo 0 || echo 1)"
# 3. le self-test d'origine reste vert
bash "$W" --self-test >"$T/self.txt" 2>&1
verifie "--self-test d'origine vert" "$?"
rm -rf "$T"
exit $ko
