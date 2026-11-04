#!/usr/bin/env bash
# install.sh · installe la veille sur cette machine, sans rien écraser.
#
# Ce qu'il fait, dans cet ordre :
#   1. lie ~/.claude/skills/veille vers le skill/ de ce dépôt (refuse si un lien existe déjà) ;
#   2. crée la base de connaissances (VEILLE_KB, défaut ~/veille-kb), dépôt git initialisé ;
#   3. copie config/{channels,feeds}.example.txt vers ~/.config/veille/ si ces fichiers manquent ;
#   4. installe le binaire ytkb (cargo install), et dit quoi faire si Rust manque.
#
# Relançable : un deuxième passage ne modifie rien et ne duplique rien.
# Chaque échec affiche la commande qui le répare. Code de retour non nul dès qu'une étape a
# échoué, même quand les autres ont abouti.
#
#   bash install.sh              install
#   VEILLE_KB=~/ma-base bash install.sh   base de connaissances ailleurs

set -uo pipefail

R=$(cd "$(dirname "$0")" && pwd)
KB="${VEILLE_KB:-$HOME/veille-kb}"
CFG="$HOME/.config/veille"
CARGO_BIN="${CARGO_INSTALL_ROOT:-${CARGO_HOME:-$HOME/.cargo}}/bin"
FAIL=0

ko() {
	echo "KO   $1" >&2
	FAIL=$((FAIL + 1))
	return 0
}
ok() { echo "ok   $1"; }

echo "Installation de la veille"
echo

# --- 1. lien de la skill ---------------------------------------------------
LIEN="$HOME/.claude/skills/veille"
mkdir -p "$HOME/.claude/skills"
if [ -L "$LIEN" ]; then
	cible=$(readlink "$LIEN")
	if [ "$cible" = "$R/skill" ]; then
		ok "skill déjà liée : $LIEN -> $R/skill"
	else
		ko "$LIEN existe déjà, je n'y touche pas (il pointe vers $cible).
     Pour l'installer à la place, retire-le d'abord : rm \"$LIEN\""
	fi
elif [ -e "$LIEN" ]; then
	ko "$LIEN existe déjà, je n'y touche pas (c'est un dossier ou un fichier, pas un lien de ce dépôt).
     Pour l'installer à la place, déplace-le d'abord : mv \"$LIEN\" \"$LIEN.ancien\""
else
	ln -s "$R/skill" "$LIEN"
	ok "skill liée : $LIEN -> $R/skill"
fi

# --- 2. base de connaissances ---------------------------------------------
if [ ! -d "$KB" ]; then
	if mkdir -p "$KB"; then
		ok "base de connaissances créée : $KB"
	else
		ko "base de connaissances non créée : $KB
     Vérifie le chemin (VEILLE_KB=... pour en choisir un autre)."
	fi
fi

if [ -d "$KB" ]; then
	if [ ! -d "$KB/.git" ] && git -C "$KB" init -q; then
		ok "base initialisée en dépôt git : $KB"
	fi
	if [ -d "$KB/.git" ] && ! grep -qx '_loop-staging/' "$KB/.gitignore" 2>/dev/null; then
		printf '_loop-staging/\n' >>"$KB/.gitignore"
	fi
	if [ -d "$KB/.git" ] && ! git -C "$KB" rev-parse -q --verify HEAD >/dev/null 2>&1; then
		# Identité en options seulement : rien n'est écrit dans le gitconfig de la personne.
		nom=$(git config --global user.name 2>/dev/null)
		[ -n "$nom" ] || nom=veille
		mail=$(git config --global user.email 2>/dev/null)
		[ -n "$mail" ] || mail=veille@localhost
		if git -C "$KB" -c user.name="$nom" -c user.email="$mail" \
			commit -q --allow-empty -m "init: base de connaissances de la veille" >/dev/null 2>&1; then
			ok "premier commit créé dans la base"
		else
			ko "premier commit impossible dans $KB
     Réparation : git -C \"$KB\" commit --allow-empty -m init"
		fi
	fi
fi

# --- 3. listes de sources personnelles ------------------------------------
mkdir -p "$CFG"
for f in channels feeds; do
	exemple="$R/config/$f.example.txt"
	perso="$CFG/$f.txt"
	if [ -e "$perso" ]; then
		ok "$f.txt conservé : $perso"
	elif [ -f "$exemple" ]; then
		if cp "$exemple" "$perso"; then
			ok "$f.txt installé depuis l'exemple : $perso"
		else
			ko "$f.txt non copié
     Réparation : cp \"$exemple\" \"$perso\""
		fi
	else
		ko "exemple manquant : $exemple"
	fi
done

# --- 4. ytkb, le binaire YouTube ------------------------------------------
if [ -x "$CARGO_BIN/ytkb" ] && "$CARGO_BIN/ytkb" --help >/dev/null 2>&1; then
	ok "ytkb déjà installé : $CARGO_BIN/ytkb"
elif ! command -v cargo >/dev/null 2>&1; then
	ko "Rust absent, YouTube indisponible (le reste de la veille fonctionne).
     Réparation : installer Rust depuis le site officiel de rustup (sh.rustup.rs)
     puis relance : bash \"$R/install.sh\""
elif ! [ -f "$R/ytkb/Cargo.toml" ]; then
	ko "source de ytkb absente : $R/ytkb/Cargo.toml"
elif cargo install --quiet --locked --path "$R/ytkb" >/dev/null 2>&1; then
	ok "ytkb installé : $CARGO_BIN/ytkb"
else
	ko "compilation de ytkb échouée
     Réparation : cargo install --locked --path \"$R/ytkb\" (pour lire l'erreur)
     Puis : bash \"$R/install.sh\""
fi

# --- sortie ---------------------------------------------------------------
echo
if [ "$FAIL" = 0 ]; then
	echo "Prêt. Vérifie l'état de chaque source avec : bash \"$R/skill/doctor.sh\""
	exit 0
fi
echo "$FAIL étape(s) à réparer, commande dans le message ci-dessus." >&2
exit 1
