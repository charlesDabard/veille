#!/usr/bin/env bash
# Prouve que scan-secrets.sh accepte un dossier propre ET refuse chaque type de fuite.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
echo 'echo propre' >"$t/ok.sh"
if bash "$here/scan-secrets.sh" "$t" >/dev/null; then echo "ok · dossier propre accepté"; else
	echo "ÉCHEC · dossier propre refusé"
	exit 1
fi
for leurre in 'KB=/Users/quelquun/docs/kb' 'source ~/.dotfiles/x' 'tok=ghp_abcdefghijklmnopqrstuvwxyz0123456789' 'curl -H "Authorization: Bearer abcdef1234567890abcd"' 'cat ~/.config/veille/apify_token'; do # gitleaks:allow (leurres du test, aucun vrai secret)
	echo "$leurre" >"$t/fuite.sh"
	if bash "$here/scan-secrets.sh" "$t" >/dev/null; then
		echo "ÉCHEC · fuite non vue : $leurre"
		exit 1
	else echo "ok · fuite vue : $leurre"; fi
done
rm -f "$t/fuite.sh"
# L'exclusion du dossier d'état de l'agent (.opencode/) ne doit pas rendre le scan aveugle ailleurs.
mkdir -p "$t/.opencode" "$t/.claude"
echo 'session /Users/quelquun/Applications/veille' >"$t/.opencode/log.jsonl"
if bash "$here/scan-secrets.sh" "$t" >/dev/null; then echo "ok · état de l'agent ignoré (.opencode/)"; else
	echo "ÉCHEC · le bruit de .opencode/ fait échouer le scan"
	exit 1
fi
echo 'KB=/Users/quelquun/docs/kb' >"$t/.claude/fuite.md"
if bash "$here/scan-secrets.sh" "$t" >/dev/null; then
	echo "ÉCHEC · l'exclusion .opencode/ a masqué une fuite réelle"
	exit 1
else echo "ok · fuite ailleurs toujours vue"; fi
