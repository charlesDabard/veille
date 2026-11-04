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
# Garde DTD : une DTD repoussée après 4 Ko de commentaire, ou cachée dans un document UTF-16, doit être refusée comme une DTD en tête.
pad=$(python3 -c 'print("<!--" + "x"*5000 + "-->")')
out=$(printf '%s<!DOCTYPE r [<!ENTITY a "x">]><rss version="2.0"><channel><title>&a;</title><item><title>t</title><link>https://example.org/p</link></item></channel></rss>' "$pad" | python3 "$R/skill/rss2ndjson.py" 2>&1); rc=$?
verifie "DTD après 5 Ko de padding : refusée" "$([ $rc != 0 ] && printf '%s' "$out" | grep -q 'DTD' && echo 0 || echo 1)"
out=$(python3 -c 'import sys; sys.stdout.buffer.write("<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE r [<!ENTITY a \"x\">]><rss version=\"2.0\"><channel><title>&a;</title><item><title>t</title><link>https://example.org/u</link></item></channel></rss>".encode("utf-16"))' | python3 "$R/skill/rss2ndjson.py" 2>&1); rc=$?
verifie "DTD dans un flux UTF-16 : refusée" "$([ $rc != 0 ] && printf '%s' "$out" | grep -qi 'DTD\|UTF-16' && echo 0 || echo 1)"
exit $ko
