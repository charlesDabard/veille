#!/usr/bin/env bash
# harvest15-run.sh : run PONCTUEL (hors loop) · récupère les transcripts des URLs
# listées dans un TSV (id<TAB>lang<TAB>url), une vidéo à la fois, sauvegarde immédiate
# dans le staging KB, reprenable (saute les .json déjà présents). Fallback Whisper.
#
# Usage : harvest15-run.sh <tsv> [stage_dir]
set -uo pipefail

TSV="${1:?tsv requis}"
STAGE="${2:-${VEILLE_KB:-$HOME/veille-kb}/_loop-staging}"
LOG="$STAGE/harvest15.log"
mkdir -p "$STAGE/transcripts"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.cargo/bin:$PATH"

TOTAL=$(grep -cvE '^\s*$' "$TSV")
i=0; ok=0; skip=0; fail=0
echo "===== $(date '+%F %T') START harvest15 : $TOTAL URLs -> $STAGE/transcripts =====" | tee -a "$LOG"

while IFS=$'\t' read -r id lang url; do
  [ -z "${url:-}" ] && continue
  i=$((i+1))
  dest="$STAGE/transcripts/$id.json"
  if [ -s "$dest" ]; then
    skip=$((skip+1)); continue
  fi
  # Une vidéo à la fois. --transcribe = fallback whisper si pas de sous-titres.
  rec="$(ytkb --lang de,fr,en,es --transcribe --whisper-model large-v3 "$url" 2>>"$LOG")"
  if [ -n "$rec" ] && printf '%s' "$rec" | jq -e 'select(.error==null) | .id' >/dev/null 2>&1; then
    printf '%s' "$rec" | jq . > "$dest"
    ok=$((ok+1))
    printf '[%s] %4d/%4d OK   %s (%s)\n' "$(date '+%H:%M:%S')" "$i" "$TOTAL" "$id" "$lang" | tee -a "$LOG"
  else
    fail=$((fail+1))
    err="$(printf '%s' "$rec" | jq -r '.error // "vide"' 2>/dev/null)"
    printf '[%s] %4d/%4d FAIL %s (%s) : %s\n' "$(date '+%H:%M:%S')" "$i" "$TOTAL" "$id" "$lang" "${err:-?}" | tee -a "$LOG"
  fi
done < "$TSV"

echo "===== $(date '+%F %T') DONE : ok=$ok skip=$skip fail=$fail total=$TOTAL =====" | tee -a "$LOG"
