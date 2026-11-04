#!/usr/bin/env bash
# fetch_feeds.test.sh · la sortie TSV garde 5 champs par ligne quel que soit le contenu du flux, et la garde DTD tient aussi en UTF-16.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fetch-feeds-test.XXXXXX")
ko=0
verifie() { if [ "$2" = 0 ]; then echo "ok · $1"; else echo "ÉCHEC · $1"; ko=1; fi; }
date_rss=$(python3 -c 'import email.utils,time; print(email.utils.formatdate(time.time(), usegmt=True))')
# Un lien qui porte une tabulation et un saut de ligne encodés : sans nettoyage, il fabrique un faux enregistrement.
cat > "$T/onglet.xml" <<XML
<?xml version="1.0"?><rss version="2.0"><channel><title>Flux</title><item><title>Vrai titre</title><link>https://example.org/a&#9;2099-01-01&#10;2099-01-01	FAUX	Faux titre	https://evil.example/</link><pubDate>$date_rss</pubDate><description>corps</description></item></channel></rss>
XML
printf 'file://%s\n' "$T/onglet.xml" > "$T/feeds.txt"
out=$(python3 "$R/skill/fetch_feeds.py" --feeds "$T/feeds.txt" 7 2>/dev/null)
verifie "contrôle positif : l'item est bien sorti" "$([ -n "$out" ] && echo 0 || echo 1)"
verifie "une seule ligne en sortie" "$([ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && echo 0 || echo 1)"
verifie "exactement 5 champs" "$([ "$(printf '%s\n' "$out" | awk -F'\t' '{print NF}' | head -1)" = 5 ] && echo 0 || echo 1)"
# DTD cachée dans un flux UTF-16 : la regex sur octets ne la voit pas, le parseur si.
python3 -c 'import sys; sys.stdout.buffer.write("<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE r [<!ENTITY a \"x\">]><rss version=\"2.0\"><channel><title>&a;</title><item><title>t</title><link>https://example.org/u</link></item></channel></rss>".encode("utf-16"))' > "$T/u16.xml"
printf 'file://%s\n' "$T/u16.xml" > "$T/feeds16.txt"
out=$(python3 "$R/skill/fetch_feeds.py" --feeds "$T/feeds16.txt" 7 2>&1)
verifie "DTD en UTF-16 : flux refusé, aucun item" "$(printf '%s' "$out" | grep -q 'example.org/u' && echo 1 || echo 0)"
verifie "DTD en UTF-16 : erreur nommée" "$(printf '%s' "$out" | grep -qi 'DTD\|UTF-16' && echo 0 || echo 1)"
rm -rf "$T"
exit $ko
