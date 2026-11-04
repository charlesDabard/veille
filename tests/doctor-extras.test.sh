#!/usr/bin/env bash
# doctor-extras.test.sh · la clé Kakao part dans l'en-tête HTTP mais jamais dans les arguments de curl (visibles par tout utilisateur via ps).
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/doctor-extras-test.XXXXXX")
ko=0
verifie() { if [ "$2" = 0 ]; then echo "ok · $1"; else echo "ÉCHEC · $1"; ko=1; fi; }
mkdir -p "$T/home/.config/veille" "$T/bin"
printf 'CLE-TEST-0123456789\n' > "$T/home/.config/veille/kakao_rest_key"
# curl factice : note ses arguments, recopie tout en-tête lu depuis un fichier (-H @fichier), répond 200
cat > "$T/bin/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$T/argv.log"
for a in "\$@"; do case "\$a" in @*) cat "\${a#@}" >> "$T/entetes.log" ;; esac; done
printf '200'
STUB
chmod +x "$T/bin/curl"
sortie=$(HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" bash "$R/skill/extras/doctor-extras.sh" 2>&1)
verifie "contrôle positif : la ligne Kakao ressort OK" "$(printf '%s' "$sortie" | grep -q 'Kakao dapi.*OK' && echo 0 || echo 1)"
verifie "contrôle positif : la clé est bien envoyée en en-tête" "$(grep -q 'KakaoAK CLE-TEST-0123456789' "$T/entetes.log" 2>/dev/null && echo 0 || echo 1)"
verifie "la clé n'apparaît pas dans les arguments de curl" "$(grep -q 'CLE-TEST' "$T/argv.log" && echo 1 || echo 0)"
rm -rf "$T"
exit $ko
