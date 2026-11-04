#!/usr/bin/env bash
# loop-harvest.sh : récolte incrémentale pour la veille en loop quotidienne.
# Liste les dernières vidéos de chaque chaîne de ~/.config/veille/channels.txt,
# écarte celles déjà ingérées (idempotence sur tout $VEILLE_KB/*/transcripts/),
# plafonne le volume, récupère les transcripts des NOUVELLES dans un staging,
# et émet une work-list JSON pour le workflow de distillation.
#
# Usage : loop-harvest.sh [LATEST_PAR_CHAINE=2] [MAX_TOTAL=15]
# Sortie : $STAGE/worklist.json (tableau {id,noteName,rawPath,source,url,kind,lang,title})
#          + lignes de log sur stderr ; sur stdout, le chemin du worklist et le compte.
set -uo pipefail

LATEST="${1:-2}"
MAX_TOTAL="${2:-15}"
KB="${VEILLE_KB:-$HOME/veille-kb}"
CFG="$HOME/.config/veille/channels.txt"
STAGE="$KB/_loop-staging"
NEW_TSV="/tmp/veille-loop-new.tsv"
CAP_TSV="/tmp/veille-loop-capped.tsv"
URLS="/tmp/veille-loop-urls.txt"
BATCH="/tmp/veille-loop-batch.ndjson"

[ -f "$CFG" ] || {
	echo "channels.txt absent : $CFG" >&2
	exit 2
}
mkdir -p "$STAGE/transcripts" "$STAGE/notes"

# Ids déjà ingérés, tous topics confondus SAUF le staging (clé d'idempotence).
# Un transcript sans texte (text null, vidéo sautée avant que le fallback whisper n'existe)
# ne compte PAS comme ingéré : il sera retenté au prochain run (leçon du 2026-09-28).
existing="$(find "$KB" -path '*/transcripts/*.json' -not -path '*/_loop-staging/*' 2>/dev/null | while IFS= read -r f; do
	/usr/bin/grep -qE '"text": *(null|"")' "$f" && continue
	basename "$f" .json
done | sort -u)"

# File de la boîte iPhone (inbox.sh) : prise par renommage atomique, pour qu'un partage arrivé
# pendant la récolte atterrisse dans une nouvelle file au lieu d'être écrasé. Une file « en cours »
# restée d'un run interrompu est reprise.
QUEUE="$HOME/.config/veille/inbox-queue.txt"
EN_COURS="$QUEUE.en-cours"
INBOX_TSV="/tmp/veille-loop-inbox.tsv"
[ -f "$QUEUE" ] && { cat "$QUEUE" >>"$EN_COURS" && rm -f "$QUEUE"; }
: >"$INBOX_TSV"
[ -f "$EN_COURS" ] && sed -nE 's#^https://youtu\.be/([A-Za-z0-9_-]{11})$#\1#p' "$EN_COURS" | while IFS= read -r id; do
	printf '%s\n' "$existing" | grep -qx -e "$id" && continue
	printf '%s\tauto\thttps://youtu.be/%s\n' "$id" "$id"
done >"$INBOX_TSV"

# Bilibili : les UP主 de ~/.config/veille/bilibili.txt, listés AVANT YouTube pour réserver leurs places
# dans le plafond (au plus BILI_MAX). Jamais yt-dlp ici (HTTP 412), toujours `bili`. Bilibili
# rend des 412 par intermittence (mesuré le 2026-11-01 : 4 UP主 sur 8 au premier passage, 2 au
# second) : une relance par UP主, une pause entre deux, et un UP主 qui échoue est sauté pour ce run.
BILI_CFG="${VEILLE_BILI_CFG:-$HOME/.config/veille/bilibili.txt}"
BILI_MAX="${VEILLE_BILI_MAX:-3}"
BILI_PAUSE="${VEILLE_BILI_PAUSE:-3}"
BILI_TSV="$(mktemp /tmp/veille-loop-bili.XXXXXX)"
trap 'rm -f "$BILI_TSV"' EXIT
bili_liste() { # $1 uid -> bvids récents, un par ligne
	local r
	r="$(bili user-videos "$1" -n "$LATEST" --json 2>/dev/null)"
	if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"$r"; then
		sleep "$((BILI_PAUSE * 3))"
		r="$(bili user-videos "$1" -n "$LATEST" --json 2>/dev/null)"
	fi
	jq -r '.data[]?.bvid // empty' 2>/dev/null <<<"$r"
}
: >"$BILI_TSV"
if [ -f "$BILI_CFG" ] && command -v bili >/dev/null 2>&1; then
	grep -vE '^\s*(#|$)' "$BILI_CFG" | while IFS=$'\t' read -r uid nom; do
		bvids="$(bili_liste "$uid")"
		[ -z "$bvids" ] && echo "bilibili : rien de lisible pour $uid ($nom), sauté ce run" >&2
		printf '%s\n' "$bvids" | while IFS= read -r bv; do
			[ -z "$bv" ] && continue
			printf '%s\n' "$existing" | grep -qx -e "$bv" && continue
			printf '%s\tzh\thttps://www.bilibili.com/video/%s\n' "$bv" "$bv"
		done
		sleep "$BILI_PAUSE"
	done | awk -F'\t' '!vu[$1]++' | head -n "$BILI_MAX" >"$BILI_TSV"
fi
NB_BILI=$(wc -l <"$BILI_TSV" | tr -d ' ')

: >"$NEW_TSV"
# Pour chaque chaîne : derniers LATEST ids, on ne garde que les nouveaux.
# NB: yt-dlp --print sort '\t' LITTÉRAL, donc on ne récupère QUE l'id (un champ, pas de séparateur).
grep -vE '^\s*#' "$CFG" | grep -vE '^\s*$' | while IFS=$'\t' read -r lang url; do
	[ -z "${url:-}" ] && continue
	yt-dlp --no-warnings --flat-playlist --playlist-end "$LATEST" \
		--print '%(id)s' "$url" 2>/dev/null | while IFS= read -r id; do
		id="$(printf '%s' "$id" | tr -d '[:space:]')"
		[ -z "${id:-}" ] && continue
		printf '%s\n' "$existing" | grep -qx -e "$id" && continue
		printf '%s\t%s\thttps://youtu.be/%s\n' "$id" "$lang" "$id" # printf bash gère \t (vraie tab)
	done
done >>"$NEW_TSV"

# Dédup par id + plafond global (lissage de la montée en charge initiale). La boîte iPhone passe
# en tête : une vidéo envoyée à la main ne doit pas être évincée par le plafond.
{
	cat "$INBOX_TSV"
	sort -u -t$'\t' -k1,1 "$NEW_TSV"
} | awk -F'\t' '!vu[$1]++' | head -n "$((MAX_TOTAL > NB_BILI ? MAX_TOTAL - NB_BILI : 0))" >"$CAP_TSV"
NB_YT=$(wc -l <"$CAP_TSV" | tr -d ' ')
NB=$((NB_YT + NB_BILI))
echo "nouvelles vidéos retenues : $NB dont $NB_BILI Bilibili (plafond $MAX_TOTAL, $LATEST/chaîne, boîte iPhone : $(wc -l <"$INBOX_TSV" | tr -d ' ') candidate(s) en tête)" >&2

# Reprise du staging : un transcript resté là après un run en échec n'est plus une nouveauté (sa
# chaîne a publié depuis), la liste ci-dessus ne le reprend donc jamais. Mesuré le 2026-11-02 :
# 48 transcripts des 19 jours de panne d'octobre dormaient en staging, jamais distillés, alors que
# le runbook les disait « en attente du run suivant ». On les remet au worklist, plus ancien
# d'abord, hors plafond des nouveautés, au plus REPRISE_MAX par run pour tenir le timeout de
# l'agent. Sans texte ou déjà ingéré ailleurs : écarté (la récolte normale s'en charge).
REPRISE_MAX="${VEILLE_REPRISE_MAX:-10}"
REPRISE_TSV="$(mktemp /tmp/veille-loop-reprise.XXXXXX)"
trap 'rm -f "$BILI_TSV" "$REPRISE_TSV" "$REPRISE_TSV.pris"' EXIT
cut -f1 "$CAP_TSV" "$BILI_TSV" >"$REPRISE_TSV.pris"
ls -tr "$STAGE/transcripts" 2>/dev/null | grep '\.json$' | while IFS= read -r f; do
	id="${f%.json}"
	grep -qxF -e "$id" "$REPRISE_TSV.pris" && continue
	printf '%s\n' "$existing" | grep -qx -e "$id" && continue
	jq -r 'select((.text // "") != "") | [(.lang // ""), (.url // "")] | @tsv' "$STAGE/transcripts/$f" 2>/dev/null |
		while IFS=$'\t' read -r lang url; do
			case "$url" in
			*bilibili.com*) printf '%s\t%s\thttps://www.bilibili.com/video/%s\tBilibili\n' "$id" "${lang:-zh}" "$id" ;;
			*) printf '%s\t%s\thttps://youtu.be/%s\tYouTube\n' "$id" "${lang:-auto}" "$id" ;;
			esac
		done
done | head -n "$REPRISE_MAX" >"$REPRISE_TSV"
NB_REPRISE=$(wc -l <"$REPRISE_TSV" | tr -d ' ')
[ "$NB_REPRISE" -gt 0 ] && echo "reprise du staging : $NB_REPRISE transcript(s) resté(s) d'un run précédent (au plus $REPRISE_MAX)" >&2

# La file garde seulement ce que le plafond a laissé de côté ; le reste est tenté maintenant (un
# échec de transcript se lit dans le journal, il n'est pas retenté indéfiniment).
if [ -f "$EN_COURS" ]; then
	cut -f1 "$CAP_TSV" >"$CAP_TSV.ids"
	cut -f1 "$INBOX_TSV" | grep -vxF -f "$CAP_TSV.ids" | sed 's#^#https://youtu.be/#' >>"$QUEUE"
	[ -s "$QUEUE" ] || rm -f "$QUEUE"
	rm -f "$EN_COURS" "$CAP_TSV.ids"
fi

if [ "$NB" -eq 0 ] && [ "$NB_REPRISE" -eq 0 ]; then
	echo "RIEN_DE_NEUF"
	exit 0
fi

# Fetch des transcripts (de,fr,en,es) vers le staging, URL = colonne 3.
# Fallback whisper local (turbo, Metal) quand aucune piste de sous-titres n'existe :
# mesuré le 2026-09-28, ~47 min de vidéo transcrites en 1 min 24. sub_kind=whisper,
# l'agent signale la fiabilité moindre en tête de note.
if [ "$NB_YT" -gt 0 ]; then
	cut -f3 "$CAP_TSV" >"$URLS"
	ytkb -f "$URLS" --lang de,fr,en,es --transcribe --whisper-model large-v3-turbo >"$BATCH" 2>/tmp/veille-loop.err
	jq -c 'select(.error==null)' "$BATCH" | while IFS= read -r rec; do
		id=$(jq -r .id <<<"$rec")
		printf '%s\n' "$rec" | jq . >"$STAGE/transcripts/$id.json"
	done
fi

# Transcript Bilibili, même schéma que ytkb. Les sous-titres exigent presque toujours un login :
# repli audio + whisper local en chinois (mesuré le 2026-11-01 : 6 min 46 de vidéo en 35 s).
WHISPER_MODEL="${VEILLE_WHISPER_MODEL:-$HOME/.local/share/ytkb/models/ggml-large-v3-turbo.bin}"
bili_transcript() { # $1 bvid -> $STAGE/transcripts/<bvid>.json ; code 1 si rien d'exploitable
	local bv="$1" meta tmp txt kind
	meta="$(bili video "$bv" --json 2>/dev/null)"
	if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"$meta"; then
		echo "bilibili : $bv, détails illisibles" >&2
		return 1
	fi
	if jq -e '.data.subtitle.available == true' >/dev/null <<<"$meta"; then
		txt="$(jq -r '.data.subtitle.text // ""' <<<"$meta")"
		kind=bilibili-sub
	else
		tmp="$(mktemp -d /tmp/veille-bili.XXXXXX)"
		TMPDIR="$tmp/" bili audio "$bv" >/dev/null 2>&1
		txt="$(find "$tmp" -name 'seg_*.wav' | sort | while IFS= read -r f; do
			whisper-cli -m "$WHISPER_MODEL" -l zh --no-timestamps "$f" 2>/dev/null
		done)"
		rm -rf "$tmp"
		kind=whisper
	fi
	if [ -z "$(printf '%s' "$txt" | tr -d '[:space:]')" ]; then
		echo "bilibili : $bv, aucun texte ($kind)" >&2
		return 1
	fi
	jq -n --arg text "$txt" --arg kind "$kind" --argjson v "$(jq '.data.video' <<<"$meta")" \
		'{id: $v.bvid, title: $v.title, url: $v.url, channel: $v.owner.name, upload_date: null,
		  duration_sec: $v.duration_seconds, lang: "zh", sub_kind: $kind, text: $text}' \
		>"$STAGE/transcripts/$bv.json"
}
cut -f1 "$BILI_TSV" | while IFS= read -r bv; do
	bili_transcript "$bv"
done

# Work-list : colonnes des TSV = id, lang, url (séparées par de vraies tabulations)
{
	awk '{print $0 "\tYouTube"}' "$CAP_TSV"
	awk '{print $0 "\tBilibili"}' "$BILI_TSV"
	awk '{print $0 "\treprise"}' "$REPRISE_TSV"
} | jq -R -s --arg stage "$STAGE" '
  split("\n") | map(select(length>0)) | map(split("\t")) |
  map({id: .[0], lang: .[1],
       noteName: (.[0]+".md"),
       rawPath: ($stage+"/transcripts/"+.[0]+".json"),
       source: .[3], url: .[2], kind: "video"}
      + (if .[4] == "reprise" then {reprise: true} else {} end))
' >"$STAGE/worklist.json"

# Ne garder dans la work-list que les transcripts réellement récupérés
jq --slurpfile present <(ls "$STAGE/transcripts" | sed 's/\.json$//' | jq -R . | jq -s .) '
  map(select(.id as $i | ($present[0] | index($i))))
' "$STAGE/worklist.json" >"$STAGE/worklist.tmp" && mv "$STAGE/worklist.tmp" "$STAGE/worklist.json"

OK=$(jq 'length' "$STAGE/worklist.json")
echo "transcripts récupérés : $OK / $NB" >&2
echo "$STAGE/worklist.json"
echo "WORKLIST_COUNT=$OK"
