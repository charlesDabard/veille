#!/usr/bin/env bash
# scan-secrets.sh · refuse tout chemin personnel, secret ou outil du setup d'origine.
# Usage : bash scripts/scan-secrets.sh [dossier]   (défaut : racine du dépôt)
# Sortie : 0 si propre ; 1 avec la liste fichier:ligne:texte sinon.
set -euo pipefail
cible=${1:-$(cd "$(dirname "$0")/.." && pwd)}
motifs='/Users/|charlesdabard|neurodabard|\.dotfiles|docs/kb|apify_token|cmux|firefox-pilote|md-guard|cdlabs\.fr|ghp_[A-Za-z0-9]{20,}|github_pat_|sk-[A-Za-z0-9]{20,}|xox[bp]-|AKIA[0-9A-Z]{16}|Bearer [A-Za-z0-9._-]{16,}'
trouve=$(grep -rnEI --exclude-dir=.git --exclude-dir=target --exclude-dir=screenshots --exclude=scan-secrets.sh --exclude=scan-secrets.test.sh "$motifs" "$cible" || true)
if command -v gitleaks >/dev/null && [ -d "$cible/.git" ]; then
	gitleaks detect --source "$cible" --no-banner --redact >/dev/null 2>&1 || trouve="$trouve"$'\n'"gitleaks : fuite détectée (gitleaks detect --source $cible)"
fi
[ -z "$trouve" ] && exit 0
printf '%s\n' "$trouve"
exit 1
