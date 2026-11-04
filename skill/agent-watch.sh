#!/usr/bin/env bash
#
# agent-watch.sh · dire si un sous-agent est vivant, muet ou fini, sans jamais deviner.
#
# POURQUOI CE SCRIPT EXISTE (run de veille du 2026-08-29, chiffres mesures)
#   L'orchestrateur a lance 164 sous-agents. Neuf ont depasse 60 minutes, le plus long 258
#   minutes. Aucune notification n'arrive quand un agent meurt, et la notification de fin
#   arrive parfois deux heures apres. Faute de signal, l'orchestrateur a juge les agents sur
#   leur silence, et tout ce qui a casse vient de la :
#     · 2 agents declares morts travaillaient encore. Ils ont rendu 1 h 36 et 2 h 40 plus
#       tard, un meilleur travail que la reparation manuelle faite entre temps, et ils ont
#       ecrase des fichiers deja commites ;
#     · 1 agent etait mort depuis 1 h 31 pendant que l'orchestrateur promettait de prevenir
#       quand il finirait ;
#     · 6 agents ont fini apres un commit et reecrit des notes deja validees.
#   Le signal fiable existait pourtant, personne ne le regardait : le mtime du fichier de
#   transcript. Un transcript qui bouge est un agent qui travaille.
#
# LES TROIS ETATS, ET CE QU'ILS PROUVENT
#   VIVANT · le transcript a ete ecrit il y a moins que le seuil (defaut 10 min).
#            Preuve positive : le processus ecrivait il y a peu.
#   MUET   · rien depuis plus que le seuil. CE N'EST PAS UNE PREUVE DE MORT. C'est une
#            invitation a verifier (un agent peut rester silencieux pendant un long appel
#            reseau, un gros telechargement, une transcription Whisper). Ne jamais relancer
#            ni reparer le travail d'un MUET sans avoir verifie autrement.
#   FINI   · une notification de fin de tache existe pour cet agent. Voir ci-dessous.
#
# LE MARQUEUR DE FIN : OU IL EST, ET POURQUOI PAS AILLEURS
#   Il n'y a AUCUN marqueur de fin fiable a l'interieur du transcript de l'agent. Mesure sur
#   les 166 transcripts du run : les seuls `type` presents sont assistant, user et attachment,
#   il n'existe pas d'evenement terminal. Le candidat evident (dernier enregistrement de type
#   assistant sans bloc tool_use) est faux : un meme tour d'assistant est eclate sur plusieurs
#   lignes JSONL partageant un `message.id` (2025 tours eclates sur 3020), donc un
#   enregistrement "texte seul" apparait 2075 fois EN COURS de transcript, dans les 166
#   fichiers, toujours suivi d'une autre ligne assistant. Un agent en plein travail presente
#   donc en permanence une derniere ligne qui ressemble a une fin. `stop_reason` ne sauve
#   rien : il vaut aussi bien end_turn (143 cas) que null (15 cas, sur des resumes finaux
#   complets) que stop_sequence (5 cas, qui sont en fait des morts par erreur d'API).
#
#   Le marqueur fiable est ailleurs, dans le transcript de la SESSION PARENTE : un
#   enregistrement `type: queue-operation`, `operation: enqueue`, dont le champ `content` est
#   une enveloppe <task-notification> portant <task-id> et <status> (completed, failed,
#   killed). Mesure : 174 notifications, toutes enregistrees entre -0,1 s et 8 s apres la
#   derniere ecriture du transcript concerne (mediane 2 s), et exactement 0 notification pour
#   les 2 agents qui tournaient encore. Ce qui arrive deux heures en retard, c'est la
#   LIVRAISON de la notification au modele, pas son enregistrement sur le disque.
#   Consequence : l'absence de notification ne prouve rien, sa presence prouve la fin.
#   Si le transcript de session est introuvable, l'etat FINI est annonce indisponible plutot
#   que devine.
#
#   LIMITE MESUREE LE 2026-10-17 · « sa presence prouve la fin » est faux pour un agent
#   REPRIS par SendMessage. Six agents coupes par une limite d'usage (notification `failed`)
#   ont ete relances par message : le script les a tous classes FINI alors que leur transcript
#   avait ete ecrit 10 a 220 secondes plus tot. La notification datait d'AVANT la reprise.
#   Tant que la date de la notification n'est pas comparee au mtime du transcript, un FINI
#   sur un agent qu'on a repris se recoupe par le mtime de tasks/<id>.output (stat -f %Sm).
#
# LE PIEGE EVITE (regle "detecteur texte vs etat")
#   Aucun etat n'est deduit d'une recherche de texte libre. Chercher "error", "completed" ou
#   "killed" dans un transcript classerait comme morts les agents qui distillaient un article
#   PARLANT d'erreurs. Tout passe par la structure : mtime du fichier, parsing JSON ligne par
#   ligne, type d'enregistrement. Le test anti-faux-positif du --self-test le prouve dans les
#   deux sens.
#
# LE PIEGE macOS
#   Les entrees du dossier tasks/ sont des LIENS SYMBOLIQUES vers les vrais transcripts. Le
#   mtime du lien est fige a la creation du lien, c'est a dire a l'heure de LANCEMENT de
#   l'agent : mesure sur un cas reel, lien a 00:50, cible a 00:58. Sans -L, on lit l'heure de
#   depart et on declare mort un agent qui ecrit. D'ou `stat -L`, teste par le --self-test.
#
# USAGE
#   agent-watch.sh <chemin-du-transcript> [seuil-minutes]
#   agent-watch.sh --dir <dossier-tasks> [seuil-minutes]
#   agent-watch.sh --self-test
#
# CODES DE RETOUR
#   0 aucun muet · 1 au moins un muet · 2 erreur d'usage ou d'acces

set -uo pipefail

SEUIL_DEFAUT=10
PROG=$(basename "$0")

usage() {
  cat >&2 <<USAGE
usage: $PROG <chemin-du-transcript> [seuil-minutes]
       $PROG --dir <dossier-tasks> [seuil-minutes]
       $PROG --self-test
Etats : VIVANT (ecrit recemment) · MUET (silence, a verifier, pas une preuve de mort) · FINI
(notification de fin enregistree). Seuil par defaut : ${SEUIL_DEFAUT} minutes.
Retour : 0 aucun muet, 1 au moins un muet, 2 erreur d'usage.
USAGE
}

# ---------------------------------------------------------------------------
# extraction des FAITS (structure pure, aucune recherche de texte libre)
# python3 lit les fichiers et rend du TSV ; bash decide des etats. La separation
# est volontaire : les faits d'un cote, la politique (seuil, libelles) de l'autre.
# champs : chemin id etat_lecture mtime taille evenements lignes_cassees notif
# ---------------------------------------------------------------------------
facts() {
  python3 - "$@" <<'PY'
import json, os, sys, glob, re

CHAMPS_ID = re.compile(r'^[A-Za-z0-9._-]+$')
_cache_notifs = {}

def entre(s, ouvrant, fermant):
    i = s.find(ouvrant)
    if i < 0:
        return None
    j = s.find(fermant, i + len(ouvrant))
    if j < 0:
        return None
    return s[i + len(ouvrant):j].strip()

def notifs(session):
    """Table {task-id: statut} lue dans le transcript de la session parente.
    Gate structurel : uniquement les enregistrements queue-operation/enqueue dont
    le content EST une enveloppe <task-notification>. Un texte d'agent qui cite
    une notification vit dans un enregistrement assistant ou user, jamais ici."""
    if session in _cache_notifs:
        return _cache_notifs[session]
    table = {}
    if session and CHAMPS_ID.match(session):
        motif = os.path.expanduser('~/.claude/projects/*/%s.jsonl' % session)
        for chemin in glob.glob(motif):
            try:
                fh = open(chemin, encoding='utf-8', errors='replace')
            except OSError:
                continue
            with fh:
                for ligne in fh:
                    if not ligne.strip():
                        continue
                    try:
                        rec = json.loads(ligne)
                    except Exception:
                        continue          # ligne cassee : on continue, on ne plante pas
                    if not isinstance(rec, dict):
                        continue
                    if rec.get('type') != 'queue-operation':
                        continue
                    if rec.get('operation') != 'enqueue':
                        continue
                    contenu = rec.get('content')
                    if not isinstance(contenu, str):
                        continue
                    if not contenu.lstrip().startswith('<task-notification>'):
                        continue
                    tid = entre(contenu, '<task-id>', '</task-id>')
                    statut = entre(contenu, '<status>', '</status>')
                    if tid and statut in ('completed', 'failed', 'killed'):
                        table[tid] = statut
            table.setdefault('__trouve__', '1')
    _cache_notifs[session] = table
    return table

def identifiant(chemin):
    nom = os.path.basename(chemin)
    for suffixe in ('.output', '.jsonl'):
        if nom.endswith(suffixe):
            nom = nom[:-len(suffixe)]
    if nom.startswith('agent-'):
        nom = nom[len('agent-'):]
    return nom

def session_du_dossier(chemin):
    # .../<slug-projet>/<session-id>/tasks/<fichier> : repli si le transcript ne
    # porte pas son sessionId (fichier vide, par exemple)
    d = os.path.dirname(os.path.abspath(chemin))
    if os.path.basename(d) == 'tasks':
        return os.path.basename(os.path.dirname(d))
    return ''

def examiner(chemin):
    # os.stat SUIT le lien symbolique : c'est l'equivalent du -L de stat(1), et
    # c'est la garde contre le piege macOS documente en tete. os.lstat lirait le
    # mtime du LIEN, donc l'heure de LANCEMENT de l'agent. Sabotage mesure :
    # remplacer os.stat par os.lstat fait tomber le test "lien vieux vers cible
    # fraiche" du --self-test. Un os.path.realpath() avant le stat serait, lui,
    # du code mort (son retrait ne change aucune sortie), il a ete supprime.
    try:
        st = os.stat(chemin)
    except OSError:
        return (chemin, identifiant(chemin), 'illisible', '0', '0', '0', '0', '')
    if not os.path.isfile(chemin):
        return (chemin, identifiant(chemin), 'illisible', '0', '0', '0', '0', '')
    evenements = casses = 0
    premier = None
    session = ''
    try:
        with open(chemin, encoding='utf-8', errors='replace') as fh:
            for ligne in fh:
                if not ligne.strip():
                    continue
                evenements += 1
                try:
                    rec = json.loads(ligne)
                except Exception:
                    casses += 1           # une ligne corrompue n'arrete pas la lecture
                    continue
                if not isinstance(rec, dict):
                    casses += 1
                    continue
                if premier is None:
                    premier = rec
                    if isinstance(rec.get('sessionId'), str):
                        session = rec['sessionId']
    except OSError:
        return (chemin, identifiant(chemin), 'illisible', '0', '0', '0', '0', '')

    if evenements == 0:
        lecture = 'vide'
    elif premier is None or 'type' not in premier:
        # du contenu, mais pas du JSONL d'agent : les tasks/ melangent les
        # transcripts d'agents et les sorties brutes de taches bash
        lecture = 'nontranscript'
    else:
        lecture = 'jsonl'

    statut = ''
    if lecture in ('jsonl', 'vide'):
        if not session:
            session = session_du_dossier(chemin)
        table = notifs(session)
        if not table:
            statut = 'SANS_SESSION'       # etat FINI indisponible, pas "pas fini"
        else:
            statut = table.get(identifiant(chemin), '')
    return (chemin, identifiant(chemin), lecture, str(int(st.st_mtime)),
            str(st.st_size), str(evenements), str(casses), statut)

# Un nom de fichier peut contenir tabulation ou saut de ligne : sans ce nettoyage
# il forge des champs TSV, et un champ numérique forgé (ex. PATH[$(cmd)]) est
# évalué par l'arithmétique bash, donc exécuté.
propre = lambda c: re.sub(r'[\t\r\n]', '?', c)
for arg in sys.argv[1:]:
    print('\t'.join(propre(c) for c in examiner(arg)))
PY
}

# ---------------------------------------------------------------------------
# mise en forme
# ---------------------------------------------------------------------------
format_age() {
  # $1 = age en secondes
  local s=$1
  if [ "$s" -lt 0 ]; then s=0; fi
  if [ "$s" -lt 60 ]; then
    printf '%d s' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%d min' $((s / 60))
  else
    printf '%d h %02d' $((s / 3600)) $(((s % 3600) / 60))
  fi
}

format_taille() {
  local o=$1
  if [ "$o" -lt 1024 ]; then
    printf '%d o' "$o"
  elif [ "$o" -lt 1048576 ]; then
    printf '%d Ko' $((o / 1024))
  else
    printf '%d,%d Mo' $((o / 1048576)) $(((o % 1048576) * 10 / 1048576))
  fi
}

# ---------------------------------------------------------------------------
# coeur : une ligne par agent. Remplit les compteurs globaux.
# ---------------------------------------------------------------------------
NB_VIVANTS=0; NB_MUETS=0; NB_FINIS=0; NB_IGNORES=0; NB_ILLISIBLES=0
PLUS_VIEUX_MUET=0; NB_SANS_SESSION=0

traiter_ligne() {
  local chemin=$1 id=$2 lecture=$3 mtime=$4 taille=$5 evts=$6 casses=$7 notif=$8
  local maintenant age court etat detail
  maintenant=$(date +%s)
  age=$((maintenant - mtime))
  court=${id:0:9}

  case "$lecture" in
    illisible)
      NB_ILLISIBLES=$((NB_ILLISIBLES + 1))
      printf '%-9s  %-6s  fichier illisible ou disparu · %s\n' "$court" "ERREUR" "$chemin"
      return ;;
    nontranscript)
      NB_IGNORES=$((NB_IGNORES + 1))
      return ;;   # sortie de tache bash, pas un agent : compte au recap, pas affiche
  esac

  if [ "$notif" != "" ] && [ "$notif" != "SANS_SESSION" ]; then
    etat=FINI
    detail="notification: $notif"
  # SABOTAGE-CIBLE : la comparaison ci-dessous est la garde de tout le script.
  elif [ "$age" -lt "$((SEUIL * 60))" ]; then
    etat=VIVANT
    detail="ecrit il y a $(format_age "$age")"
  else
    etat=MUET
    detail="silence depuis $(format_age "$age") · a verifier, pas une preuve de mort"
  fi

  case "$etat" in
    VIVANT) NB_VIVANTS=$((NB_VIVANTS + 1)) ;;
    FINI)   NB_FINIS=$((NB_FINIS + 1)) ;;
    MUET)   NB_MUETS=$((NB_MUETS + 1))
            [ "$age" -gt "$PLUS_VIEUX_MUET" ] && PLUS_VIEUX_MUET=$age ;;
  esac
  [ "$notif" = "SANS_SESSION" ] && NB_SANS_SESSION=$((NB_SANS_SESSION + 1))

  local extra=""
  [ "$lecture" = "vide" ] && extra=" · transcript vide"
  [ "$casses" -gt 0 ] && extra="$extra · $casses ligne(s) corrompue(s) ignoree(s)"

  local mot=evenements
  [ "$evts" -le 1 ] && mot=evenement
  printf '%-9s  %-6s  %-58s  %8s  %4s %s%s\n' \
    "$court" "$etat" "$detail" "$(format_taille "$taille")" "$evts" "$mot" "$extra"
}

sortie_finale() {
  if [ "$NB_SANS_SESSION" -gt 0 ]; then
    echo "note : transcript de session parente introuvable pour $NB_SANS_SESSION agent(s),"
    echo "       leur etat FINI est indisponible : un agent reellement fini y apparait"
    echo "       VIVANT ou MUET, jamais FINI."
  fi
  if [ "$NB_MUETS" -gt 0 ]; then return 1; fi
  return 0
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------
mode_fichier() {
  local cible=$1
  if [ ! -e "$cible" ]; then
    echo "$PROG: fichier introuvable : $cible" >&2
    return 2
  fi
  local ligne
  ligne=$(facts "$cible") || { echo "$PROG: lecture impossible : $cible" >&2; return 2; }
  # read et non « set -- $ligne » : un nom de fichier qui contient * serait étendu
  # par le glob et décalerait tous les champs.
  local c id lec mt tl ev ca no
  IFS=$'\t' read -r c id lec mt tl ev ca no <<< "$ligne"
  set -- "$c" "$id" "$lec" "$mt" "$tl" "$ev" "$ca" "${no:-}"
  if [ "$3" = "nontranscript" ]; then
    echo "$PROG: ce fichier n'est pas un transcript d'agent JSONL : $cible" >&2
    echo "       (le dossier tasks/ contient aussi les sorties brutes des taches bash)" >&2
    return 2
  fi
  if [ "$3" = "illisible" ]; then
    echo "$PROG: fichier illisible (lien casse, cible absente ?) : $cible" >&2
    return 2
  fi
  traiter_ligne "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8-}"
  sortie_finale
}

mode_dossier() {
  local dossier=$1
  if [ ! -d "$dossier" ]; then
    echo "$PROG: dossier introuvable : $dossier" >&2
    return 2
  fi
  local fichiers=()
  local f
  for f in "$dossier"/*; do
    [ -e "$f" ] || continue          # glob non resolu = dossier vide
    [ -d "$f" ] && continue
    fichiers+=("$f")
  done
  if [ ${#fichiers[@]} -eq 0 ]; then
    echo "aucun fichier dans $dossier : rien a surveiller."
    return 0
  fi

  local sortie
  sortie=$(facts "${fichiers[@]}") || { echo "$PROG: lecture impossible" >&2; return 2; }
  while IFS=$'\t' read -r c id lec mt tl ev ca no; do
    [ -n "${c:-}" ] || continue
    traiter_ligne "$c" "$id" "$lec" "$mt" "$tl" "$ev" "$ca" "${no:-}"
  done <<< "$sortie"

  local recap
  recap=$(printf 'Recap : %d vivant(s), %d muet(s), %d fini(s)' \
    "$NB_VIVANTS" "$NB_MUETS" "$NB_FINIS")
  [ "$NB_IGNORES" -gt 0 ] && recap="$recap, $NB_IGNORES fichier(s) ignore(s) (pas des transcripts)"
  [ "$NB_ILLISIBLES" -gt 0 ] && recap="$recap, $NB_ILLISIBLES illisible(s)"
  recap="$recap · seuil ${SEUIL} min"
  if [ "$NB_MUETS" -gt 0 ]; then
    recap="$recap · plus vieux muet : $(format_age "$PLUS_VIEUX_MUET")"
  fi
  echo "$recap"
  sortie_finale
}

# ---------------------------------------------------------------------------
# --self-test : fabrique des transcripts, verifie les deux sens
# ---------------------------------------------------------------------------
OK=0; KO=0
verif() {
  # $1 libelle · $2 attendu · $3 obtenu
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1)); printf '  ok   %-58s [%s]\n' "$1" "$3"
  else
    KO=$((KO + 1)); printf '  ECHEC %-57s attendu [%s], obtenu [%s]\n' "$1" "$2" "$3"
  fi
}

evt() {
  # une ligne JSONL d'agent plausible · $1 type, $2 texte, $3 sessionId
  python3 -c '
import json,sys
print(json.dumps({"parentUuid":None,"isSidechain":True,"agentId":"test","type":sys.argv[1],
 "message":{"role":"assistant","content":[{"type":"text","text":sys.argv[2]}],"stop_reason":None},
 "uuid":"u","timestamp":"2026-08-29T00:00:00Z","userType":"external","entrypoint":"cli",
 "cwd":"/tmp","sessionId":sys.argv[3],"version":"x","gitBranch":""}))' "$1" "$2" "$3"
}

self_test() {
  local T; T=$(mktemp -d "${TMPDIR:-/tmp}/agent-watch-test.XXXXXX") || return 2
  # PAS de trap rm -rf ici : le nettoyage est explicite en fin de fonction, pour
  # pouvoir inspecter le dossier si un test tombe.
  local D="$T/tasks"; mkdir -p "$D"
  local SESSION="00000000-1111-2222-3333-444444444444"
  local etat retour

  echo "== agent-watch --self-test =="
  echo "dossier de test : $T"
  echo

  # --- 1. transcript touche a l'instant : VIVANT
  { evt assistant "je travaille" "$SESSION"; evt user "resultat" "$SESSION"; } > "$D/aaaa1111vivant.output"
  etat=$(bash "$0" "$D/aaaa1111vivant.output" 2>&1 | head -1 | awk '{print $2}')
  verif "transcript ecrit a l'instant" "VIVANT" "$etat"

  # --- 2. mtime force a 2 h dans le passe : MUET, et code de retour 1
  cp "$D/aaaa1111vivant.output" "$D/bbbb2222muet.output"
  touch -t "$(date -v-2H '+%Y%m%d%H%M')" "$D/bbbb2222muet.output"
  etat=$(bash "$0" "$D/bbbb2222muet.output" 2>&1 | head -1 | awk '{print $2}')
  verif "mtime force a 2 h dans le passe" "MUET" "$etat"
  bash "$0" "$D/bbbb2222muet.output" >/dev/null 2>&1; retour=$?
  verif "code de retour quand un muet existe" "1" "$retour"
  bash "$0" "$D/aaaa1111vivant.output" >/dev/null 2>&1; retour=$?
  verif "code de retour quand aucun muet" "0" "$retour"

  # --- 3. le seuil est bien pris en compte (le meme fichier, seuil 180 min)
  etat=$(bash "$0" "$D/bbbb2222muet.output" 180 2>&1 | head -1 | awk '{print $2}')
  verif "meme fichier avec un seuil de 180 min" "VIVANT" "$etat"

  # --- 4. LE TEST ANTI-FAUX-POSITIF : contenu qui PARLE d'erreurs et de fins
  { evt assistant "The build failed with error: the job was killed. Task completed anyway." "$SESSION"
    evt user "error failed completed killed <status>completed</status>" "$SESSION"
    evt assistant "resume de l'article : agent terminated early due to an API error" "$SESSION"
  } > "$D/cccc3333piege.output"
  etat=$(bash "$0" "$D/cccc3333piege.output" 2>&1 | head -1 | awk '{print $2}')
  verif "contenu bourre de error/failed/completed/killed" "VIVANT" "$etat"

  # --- 5. cas degrades : rien ne doit planter
  : > "$D/dddd4444vide.output"
  local sortie
  sortie=$(bash "$0" "$D/dddd4444vide.output" 2>&1); retour=$?
  verif "transcript vide : pas de plantage" "0" "$retour"
  case "$sortie" in *"transcript vide"*) etat=annonce ;; *) etat="non annonce: $sortie" ;; esac
  verif "transcript vide : le message le dit" "annonce" "$etat"

  sortie=$(bash "$0" "$T/nexiste_pas.output" 2>&1); retour=$?
  verif "fichier inexistant : code 2" "2" "$retour"
  case "$sortie" in *introuvable*) etat=clair ;; *) etat="obscur: $sortie" ;; esac
  verif "fichier inexistant : message clair" "clair" "$etat"

  local VIDE="$T/dossier_vide"; mkdir -p "$VIDE"
  sortie=$(bash "$0" --dir "$VIDE" 2>&1); retour=$?
  verif "dossier vide : code 0" "0" "$retour"
  case "$sortie" in *"rien a surveiller"*) etat=clair ;; *) etat="obscur: $sortie" ;; esac
  verif "dossier vide : message clair" "clair" "$etat"

  # --- 6. ligne corrompue au milieu : on continue
  { evt assistant "debut" "$SESSION"
    printf '{"type":"assistant", ceci n est pas du JSON\n'
    evt assistant "suite" "$SESSION"
    evt assistant "fin" "$SESSION"; } > "$D/eeee5555casse.output"
  sortie=$(bash "$0" "$D/eeee5555casse.output" 2>&1); retour=$?
  etat=$(printf '%s' "$sortie" | head -1 | awk '{print $2}')
  verif "JSONL avec une ligne corrompue : etat lu quand meme" "VIVANT" "$etat"
  case "$sortie" in *"corrompue"*) etat=signale ;; *) etat="silencieux: $sortie" ;; esac
  verif "ligne corrompue : signalee, pas fatale" "signale" "$etat"
  verif "ligne corrompue : 4 evenements comptes" "4" \
    "$(printf '%s' "$sortie" | sed -n 's/.*  \([0-9][0-9]*\) evenement.*/\1/p')"

  # --- 7. le piege macOS : mtime du LIEN vs mtime de la CIBLE
  ln -s "$D/aaaa1111vivant.output" "$D/ffff6666lien.output"
  touch -h -t "$(date -v-2H '+%Y%m%d%H%M')" "$D/ffff6666lien.output"
  etat=$(bash "$0" "$D/ffff6666lien.output" 2>&1 | head -1 | awk '{print $2}')
  verif "lien vieux vers cible fraiche (stat -L)" "VIVANT" "$etat"

  # --- 8. fichier qui n'est pas un transcript (sortie de tache bash)
  printf 'Cloning into repo...\ndone.\n' > "$D/gggg7777bash.output"
  sortie=$(bash "$0" "$D/gggg7777bash.output" 2>&1); retour=$?
  verif "fichier non-JSONL en mode fichier : code 2" "2" "$retour"

  # --- 9. detection FINI, les DEUX sens, sur un faux transcript de session
  local PROJ="$T/home/.claude/projects/-fake"
  mkdir -p "$PROJ"
  {
    # vrai enregistrement de notification : structure queue-operation/enqueue
    python3 -c '
import json
c = ("<task-notification>\n<task-id>hhhh8888fini</task-id>\n"
     "<output-file>/x</output-file>\n<status>completed</status>\n"
     "<summary>Agent fini</summary>\n</task-notification>")
print(json.dumps({"type":"queue-operation","operation":"enqueue",
                  "timestamp":"2026-08-29T00:00:00Z","content":c}))'
    # PIEGE : un agent qui distille un article et CITE une notification entiere,
    # dans un enregistrement assistant. Ne doit jamais compter comme une fin.
    python3 -c '
import json
faux = ("<task-notification>\n<task-id>iiii9999piege</task-id>\n"
        "<status>completed</status>\n</task-notification>")
print(json.dumps({"type":"assistant","message":{"role":"assistant",
  "content":[{"type":"text","text":"Exemple lu dans la doc : "+faux}]},
  "sessionId":"x","timestamp":"2026-08-29T00:00:00Z"}))'
  } > "$PROJ/$SESSION.jsonl"

  { evt assistant "termine" "$SESSION"; } > "$D/hhhh8888fini.output"
  { evt assistant "je travaille encore" "$SESSION"; } > "$D/iiii9999piege.output"
  touch -t "$(date -v-2H '+%Y%m%d%H%M')" "$D/hhhh8888fini.output"
  touch -t "$(date -v-2H '+%Y%m%d%H%M')" "$D/iiii9999piege.output"

  etat=$(HOME="$T/home" bash "$0" "$D/hhhh8888fini.output" 2>&1 | head -1 | awk '{print $2}')
  verif "notification queue-operation reelle : FINI" "FINI" "$etat"
  etat=$(HOME="$T/home" bash "$0" "$D/iiii9999piege.output" 2>&1 | head -1 | awk '{print $2}')
  verif "meme enveloppe citee dans un texte d'agent" "MUET" "$etat"

  # sans transcript de session, FINI doit etre annonce indisponible, pas suppose
  sortie=$(HOME="$T/vide" bash "$0" "$D/hhhh8888fini.output" 2>&1)
  case "$sortie" in *"FINI est indisponible"*) etat=annonce ;; *) etat="silencieux: $sortie" ;; esac
  verif "session introuvable : FINI annonce indisponible" "annonce" "$etat"

  # --- 10. mode --dir : recap et comptes
  rm -f "$D/ffff6666lien.output"
  sortie=$(HOME="$T/home" bash "$0" --dir "$D" 2>&1); retour=$?
  echo
  echo "  --- sortie de --dir sur le jeu de test ---"
  printf '%s\n' "$sortie" | sed 's/^/  /'
  echo
  verif "--dir : code 1 (des muets existent)" "1" "$retour"
  local recap; recap=$(printf '%s' "$sortie" | grep '^Recap')
  case "$recap" in *"1 fini"*) etat=ok ;; *) etat="$recap" ;; esac
  verif "--dir : 1 fini au recap" "ok" "$etat"
  case "$recap" in *"2 muet"*) etat=ok ;; *) etat="$recap" ;; esac
  verif "--dir : 2 muets au recap (le 3e vieux est FINI)" "ok" "$etat"
  case "$recap" in *"4 vivant"*) etat=ok ;; *) etat="$recap" ;; esac
  verif "--dir : 4 vivants au recap" "ok" "$etat"
  case "$recap" in *"ignore"*) etat=ok ;; *) etat="$recap" ;; esac
  verif "--dir : le non-transcript est compte comme ignore" "ok" "$etat"
  case "$recap" in *"plus vieux muet : 2 h"*) etat=ok ;; *) etat="$recap" ;; esac
  verif "--dir : age du plus vieux muet" "ok" "$etat"

  # --- 11. lien casse : pas de plantage
  ln -s "$T/cible_absente.jsonl" "$D/jjjj0000casse.output"
  sortie=$(bash "$0" "$D/jjjj0000casse.output" 2>&1); retour=$?
  verif "lien symbolique casse : code 2, pas de plantage" "2" "$retour"

  echo
  echo "resultat : $OK ok, $KO echec(s)"
  rm -rf "$T"
  [ "$KO" -eq 0 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# entree
# ---------------------------------------------------------------------------
SEUIL=$SEUIL_DEFAUT

valider_seuil() {
  case "$1" in
    ''|*[!0-9]*) echo "$PROG: seuil invalide (entier de minutes attendu) : $1" >&2; exit 2 ;;
  esac
  [ "$1" -gt 0 ] || { echo "$PROG: le seuil doit etre superieur a 0" >&2; exit 2; }
  SEUIL=$1
}

case "${1-}" in
  --self-test)
    self_test; exit $? ;;
  -h|--help)
    usage; exit 0 ;;
  --dir)
    [ $# -ge 2 ] || { usage; exit 2; }
    [ $# -ge 3 ] && valider_seuil "$3"
    [ $# -gt 3 ] && { usage; exit 2; }
    mode_dossier "$2"; exit $? ;;
  '')
    usage; exit 2 ;;
  -*)
    echo "$PROG: option inconnue : $1" >&2; usage; exit 2 ;;
  *)
    [ $# -ge 2 ] && valider_seuil "$2"
    [ $# -gt 2 ] && { usage; exit 2; }
    mode_fichier "$1"; exit $? ;;
esac
