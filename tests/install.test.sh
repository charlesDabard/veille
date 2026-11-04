#!/usr/bin/env bash
# install.test.sh · install.sh dans des HOME jetables, avec le vrai Rust (CARGO_HOME et RUSTUP_HOME réels,
# ytkb installé sous le HOME jetable par CARGO_INSTALL_ROOT : le ytkb de la machine n'est jamais touché).
#   bash tests/install.test.sh              -> tout doit passer (une compilation de ytkb, environ une minute)
set -uo pipefail
unset VEILLE_KB CARGO_INSTALL_ROOT
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
REEL_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
REEL_RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
echo_ko=0
verifie() { # $1=nom du cas, $2=0 si la condition tient
	if [ "$2" = 0 ]; then echo "ok · $1"; else
		echo "ÉCHEC · $1"
		echo_ko=1
	fi
}
vrai() { # sortie muette : sinon la sortie de la commande testée se mêle au 0/1
	if "$@" >/dev/null 2>&1; then echo 0; else echo 1; fi
}

# Outils de base sans cargo : des liens dans un bin à part, pour un PATH où cargo n'existe pas.
mkdir -p "$T/outils"
for b in jq yt-dlp; do
	p=$(command -v "$b") && ln -s "$p" "$T/outils/$b"
done
SANS_CARGO="$T/outils:/usr/bin:/bin"
AVEC_CARGO="$REEL_CARGO_HOME/bin:$SANS_CARGO"

lance() { # $1=HOME, $2=PATH, reste = variables en plus ; sortie dans $T/out, code dans $T/rc
	local h="$1" p="$2"
	shift 2
	env "$@" HOME="$h" PATH="$p" CARGO_HOME="$REEL_CARGO_HOME" RUSTUP_HOME="$REEL_RUSTUP_HOME" \
		CARGO_INSTALL_ROOT="$h/.cargo" CARGO_TARGET_DIR="$T/target" \
		bash "$R/install.sh" >"$T/out" 2>&1
	echo $? >"$T/rc"
}
rc() { cat "$T/rc"; }

# --- cas nominal ---
H="$T/h1"
mkdir -p "$H"
lance "$H" "$AVEC_CARGO"
verifie "nominal : code 0 (obtenu $(rc))" "$(vrai [ "$(rc)" = 0 ])"
verifie "nominal : ~/.claude/skills/veille pointe vers le dépôt" "$(vrai [ "$(readlink "$H/.claude/skills/veille")" = "$R/skill" ])"
verifie "nominal : KB créée, dépôt git avec un HEAD" "$(vrai git -C "$H/veille-kb" rev-parse -q --verify HEAD)"
verifie "nominal : staging de la boucle ignoré par git" "$(vrai grep -qx '_loop-staging/' "$H/veille-kb/.gitignore")"
verifie "nominal : channels.txt copié de l'exemple" "$(vrai cmp -s "$H/.config/veille/channels.txt" "$R/config/channels.example.txt")"
verifie "nominal : feeds.txt copié de l'exemple" "$(vrai cmp -s "$H/.config/veille/feeds.txt" "$R/config/feeds.example.txt")"
verifie "nominal : ytkb construit et répond" "$(vrai "$H/.cargo/bin/ytkb" --help)"
[ "$(rc)" = 0 ] || sed 's/^/    /' "$T/out"

# --- vigilance 2 : relance, rien ne bouge, la liste perso est gardée ---
echo 'en	https://www.youtube.com/@ma-chaine/videos' >"$H/.config/veille/channels.txt"
sleep 1
touch "$T/repere"
lance "$H" "$AVEC_CARGO"
verifie "relance : code 0 (obtenu $(rc))" "$(vrai [ "$(rc)" = 0 ])"
bouge=$(find "$H" -newer "$T/repere" | head -5)
verifie "relance : aucun fichier modifié dans le HOME${bouge:+ ($bouge)}" "$(vrai [ -z "$bouge" ])"
verifie "relance : channels.txt personnel intact" "$(vrai grep -q 'ma-chaine' "$H/.config/veille/channels.txt")"

# --- vigilance 4 : KB dont le chemin contient une espace ---
lance "$H" "$AVEC_CARGO" VEILLE_KB="$H/ma veille"
verifie "KB avec espace : code 0 (obtenu $(rc))" "$(vrai [ "$(rc)" = 0 ])"
verifie "KB avec espace : dépôt git créé" "$(vrai git -C "$H/ma veille" rev-parse -q --verify HEAD)"

# --- vigilance 1 : un ~/.claude/skills/veille existant n'est jamais écrasé ---
H="$T/h2"
mkdir -p "$H/.claude/skills" "$H/autre"
ln -s "$H/autre" "$H/.claude/skills/veille"
lance "$H" "$AVEC_CARGO"
verifie "lien existant : code non nul (obtenu $(rc))" "$(vrai [ "$(rc)" != 0 ])"
verifie "lien existant : message « existe déjà, je n'y touche pas »" "$(vrai grep -q "existe déjà, je n'y touche pas" "$T/out")"
verifie "lien existant : le lien n'a pas bougé" "$(vrai [ "$(readlink "$H/.claude/skills/veille")" = "$H/autre" ])"

# --- vigilance 3 : sans cargo, la skill est liée et la réparation est donnée ---
H="$T/h3"
mkdir -p "$H"
lance "$H" "$SANS_CARGO"
verifie "sans cargo : code non nul (obtenu $(rc))" "$(vrai [ "$(rc)" != 0 ])"
verifie "sans cargo : la skill est quand même liée" "$(vrai [ "$(readlink "$H/.claude/skills/veille")" = "$R/skill" ])"
verifie "sans cargo : la commande d'installation de Rust est donnée" "$(vrai grep -q 'sh.rustup.rs' "$T/out")"

echo "---"
[ "$echo_ko" = 0 ] && echo "install.test.sh : tout passe" || echo "install.test.sh : ÉCHEC"
[ "$echo_ko" = 0 ]
