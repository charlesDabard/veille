#!/usr/bin/env bash
# rss2ndjson.test.sh · un flux valide sort en NDJSON ; un flux mort ou tronqué sort en erreur lisible, sans trace Python.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
ko=0
verifie() { if [ "$2" = 0 ]; then echo "ok · $1"; else echo "ÉCHEC · $1"; ko=1; fi; }
rss='<?xml version="1.0"?><rss version="2.0"><channel><title>T</title><item><title>Un titre</title><link>https://example.org/a</link><pubDate>Tue, 04 Nov 2026 10:00:00 GMT</pubDate><description>corps</description></item></channel></rss>'
out=$(printf '%s' "$rss" | python3 "$R/skill/rss2ndjson.py" 2>&1); rc=$?
verifie "flux valide : code 0 et une ligne JSON" "$([ $rc = 0 ] && printf '%s' "$out" | jq -e '.url == "https://example.org/a"' >/dev/null && echo 0 || echo 1)"
for cas in vide tronque; do
	case $cas in vide) entree='' ;; tronque) entree='<?xml version="1.0"?><rss><channel><item><title>coupé' ;; esac
	out=$(printf '%s' "$entree" | python3 "$R/skill/rss2ndjson.py" 2>&1); rc=$?
	verifie "flux $cas : code non nul" "$([ $rc != 0 ] && echo 0 || echo 1)"
	verifie "flux $cas : pas de trace Python" "$(printf '%s' "$out" | grep -q Traceback && echo 1 || echo 0)"
	verifie "flux $cas : message rss2ndjson lisible" "$(printf '%s' "$out" | grep -q '^rss2ndjson:' && echo 0 || echo 1)"
done
exit $ko
