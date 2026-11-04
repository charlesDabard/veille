#!/usr/bin/env bash
# Prouve que scan-secrets.sh accepte un dossier propre ET refuse chaque type de fuite.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
echo 'echo propre' >"$t/ok.sh"
if bash "$here/scan-secrets.sh" "$t" >/dev/null; then echo "ok · dossier propre accepté"; else echo "ÉCHEC · dossier propre refusé"; exit 1; fi
for leurre in 'KB=/Users/quelquun/docs/kb' 'source ~/.dotfiles/x' 'tok=ghp_abcdefghijklmnopqrstuvwxyz0123456789' 'curl -H "Authorization: Bearer abcdef1234567890abcd"' 'cat ~/.config/veille/apify_token'; do # gitleaks:allow (leurres du test, aucun vrai secret)
	echo "$leurre" >"$t/fuite.sh"
	if bash "$here/scan-secrets.sh" "$t" >/dev/null; then echo "ÉCHEC · fuite non vue : $leurre"; exit 1; else echo "ok · fuite vue : $leurre"; fi
done
