#!/usr/bin/env bash
# check-merge.sh · controle de NON-REGRESSION d'un merge SYNTHESIS (Etape 9 du skill veille).
#
# Motif, mesure du 2026-08-29 : trois agents de synthese ont recu la consigne ecrite
# "ne rien supprimer sans raison" et ont quand meme perdu 90 lignes (19,7 Ko) de
# contenu anterieur, dont 57 lignes sur firecrawl-alternatives. La consigne n'etait
# verifiee par rien. Un garde-fou non branche est un garde-fou absent : ce script est
# le branchement.
#
# Usage :
#   bash check-merge.sh <topic> [ref-git]      # defaut ref-git = HEAD
#   bash check-merge.sh --self-test            # verifie que le detecteur detecte
#
# Comparaison sur le texte NORMALISE (espaces ecrases) : une ligne seulement
# reindentee ou re-wrappee ne compte pas comme perdue, seule la disparition du
# contenu compte. En revanche une REFORMULATION compte comme une perte, et c'est
# voulu : reecrire une alerte datee effacerait l'historique qui fait sa valeur.
#
# Exceptions : une ligne peut legitimement disparaitre (titre renomme, doublon reel).
# Dans ce cas SEULEMENT, l'inscrire dans <topic>/.synthesis-exceptions.txt au format
#   <ligne exacte><TAB><justification>
# Les commentaires de ce fichier commencent par ';;' et non par '#', puisqu'une ligne
# a excuser est souvent elle-meme un titre markdown commencant par '#'.
# Le script cesse alors de la compter comme perte MAIS l'affiche quand meme avec son
# motif : on peut deroger, on ne peut pas deroger en silence. Une exception sans
# justification s'affiche comme telle.
#
# Code de retour : 0 si aucune perte non excusee, 1 si perte, 2 si erreur d'usage.
set -euo pipefail

KB="${VEILLE_KB:-$HOME/veille-kb}"
HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-merge.py"

perte() {  # $1 = ancien, $2 = nouveau, $3 = fichier d'exceptions (optionnel)
	python3 "$HELPER" "$1" "$2" "${3:-}"
}

if [ "${1:-}" = "--self-test" ]; then
	tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
	printf 'alpha\nbeta\ngamma\n' >"$tmp/a"
	printf 'alpha\nbeta\ngamma\ndelta\n' >"$tmp/b"
	if perte "$tmp/a" "$tmp/b" >/dev/null; then n=ok; else n=ECHEC; fi
	printf 'alpha\ngamma\n' >"$tmp/c"
	out=$(perte "$tmp/a" "$tmp/c" || true)
	[ "$out" = "beta" ] && p=ok || p=ECHEC
	printf '   alpha\n\tbeta\ngamma\n' >"$tmp/d"
	if perte "$tmp/a" "$tmp/d" >/dev/null; then r=ok; else r=ECHEC; fi
	# exception documentee : beta manque mais est excusee, doit rendre 0 ET s'afficher
	printf 'beta\tsupprimee volontairement, doublon\n' >"$tmp/x"
	if outx=$(perte "$tmp/a" "$tmp/c" "$tmp/x"); then e=ok; else e=ECHEC; fi
	case "$outx" in *"doublon"*) em=ok;; *) em=ECHEC;; esac
	# exception NON documentee ne doit PAS excuser une autre ligne
	printf 'zzz\tligne sans rapport\n' >"$tmp/y"
	if perte "$tmp/a" "$tmp/c" "$tmp/y" >/dev/null; then f=ECHEC; else f=ok; fi
	echo "self-test · rien-ne-manque=$n  ligne-retiree=$p  reindentation=$r  exception-excuse=$e  exception-affichee=$em  exception-hors-sujet-n-excuse-pas=$f"
	[ "$n$p$r$e$em$f" = "okokokokokok" ] || { echo "SELF-TEST EN ECHEC" >&2; exit 1; }
	exit 0
fi

topic="${1:-}"; ref="${2:-HEAD}"
[ -n "$topic" ] || { echo "usage : check-merge.sh <topic> [ref-git] | --self-test" >&2; exit 2; }
f="$KB/$topic/SYNTHESIS.md"
[ -f "$f" ] || { echo "introuvable : $f" >&2; exit 2; }

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
if ! git -C "$KB" show "$ref:$topic/SYNTHESIS.md" >"$tmp" 2>/dev/null; then
	echo "pas de version anterieure sous $ref pour $topic (topic neuf ?), rien a comparer"
	exit 0
fi

if perte "$tmp" "$f" "$KB/$topic/.synthesis-exceptions.txt"; then
	echo "OK · aucune ligne de $ref perdue dans $topic/SYNTHESIS.md"
	exit 0
else
	echo "---" >&2
	echo "PERTE DETECTEE dans $topic/SYNTHESIS.md par rapport a $ref (lignes ci-dessus)." >&2
	echo "Le merge doit etre un APPEND : reintegrer ce contenu, ou le documenter dans" >&2
	echo "$KB/$topic/.synthesis-exceptions.txt avec sa justification." >&2
	exit 1
fi
