#!/usr/bin/env bash
# doctor.test.sh · le doctor du cœur dit vert quand tout est là, et nomme chaque panne avec sa réparation.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo_ko=0
verifie() { # $1=nom du cas, $2=0 si la condition tient
	if [ "$2" = 0 ]; then echo "ok · $1"; else echo "ÉCHEC · $1"; echo_ko=1; fi
}
prepare() { # HOME jetable complet : stubs, KB git, flux
	rm -rf "$T/h" "$T/bin"; mkdir -p "$T/bin" "$T/h/.config/veille"
	printf '#!/bin/sh\necho %s\n' "$(date +%Y.%m.%d)" >"$T/bin/yt-dlp"
	printf '#!/bin/sh\necho ytkb 0.1\n' >"$T/bin/ytkb"
	printf '#!/bin/sh\nexit 0\n' >"$T/bin/gh"
	chmod +x "$T/bin/"*
	mkdir -p "$T/h/veille-kb" && git -C "$T/h/veille-kb" init -q
	echo 'https://example.org/feed.xml' >"$T/h/.config/veille/feeds.txt"
	echo 'EN	https://www.youtube.com/@exemple/videos' >"$T/h/.config/veille/channels.txt"
}
lance() { HOME="$T/h" PATH="$T/bin:/usr/bin:/bin" bash "$R/skill/doctor.sh" "$@" >"$T/out" 2>&1; echo $? >"$T/rc"; }

prepare; lance
verifie "tout présent : code 0" "$([ "$(cat "$T/rc")" = 0 ] && echo 0 || echo 1)"
verifie "tout présent : « Tout est prêt »" "$(grep -q 'Tout est prêt' "$T/out" && echo 0 || echo 1)"

prepare; rm "$T/bin/ytkb"; lance
verifie "ytkb absent : code non nul" "$([ "$(cat "$T/rc")" != 0 ] && echo 0 || echo 1)"
verifie "ytkb absent : ligne KO avec install.sh" "$(grep -Eq '^ytkb +KO .*install\.sh' "$T/out" && echo 0 || echo 1)"

prepare; printf '#!/bin/sh\necho 2020.01.01\n' >"$T/bin/yt-dlp"; lance
verifie "yt-dlp périmé : ligne KO avec upgrade" "$(grep -Eq '^yt-dlp +KO .*upgrade' "$T/out" && echo 0 || echo 1)"

prepare; rm -rf "$T/h/veille-kb"; lance
verifie "KB absente : ligne KO" "$(grep -Eq '^KB +KO' "$T/out" && echo 0 || echo 1)"

prepare; rm "$T/bin/gh"; lance
verifie "gh absent : SKIP, pas une panne" "$(grep -Eq '^gh +SKIP' "$T/out" && [ "$(cat "$T/rc")" = 0 ] && echo 0 || echo 1)"

prepare; printf '#!/bin/sh\nexit 1\n' >"$T/bin/gh"; lance
verifie "gh non connecté : SKIP" "$(grep -Eq '^gh +SKIP' "$T/out" && echo 0 || echo 1)"

prepare; rm "$T/h/.config/veille/feeds.txt"; lance
verifie "flux absents : SKIP avec la commande de copie" "$(grep -Eq '^feeds\.txt +SKIP .*feeds\.example\.txt' "$T/out" && echo 0 || echo 1)"

prepare; mkdir -p "$T/h/ma veille" && git -C "$T/h/ma veille" init -q
HOME="$T/h" VEILLE_KB="$T/h/ma veille" PATH="$T/bin:/usr/bin:/bin" bash "$R/skill/doctor.sh" >"$T/out" 2>&1
verifie "VEILLE_KB avec espace : KB OK" "$(grep -Eq '^KB +OK' "$T/out" && echo 0 || echo 1)"

exit $echo_ko
