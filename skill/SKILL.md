---
name: veille
description: Veille multi-sources (YouTube, Google News, Hacker News, Reddit, GitHub, flux RSS, X par URLs collées, web) qui construit une base de connaissance locale, bruts archivés, notes distillées en français et synthèse thématique. Se déclenche sur « /veille <sujet> », « fais une veille sur … » ou « veille sur … » ; le reste du message donne le sujet et/ou des URLs. Demande toujours quelles sources activer. Mode lecture, « cherche dans ma veille <question> » ou « d'après ma veille … », répond uniquement depuis la base, sources citées. Mode maintenance, « lint ma veille », lance un contrôle de santé en lecture seule (contradictions, claims périmés, orphelins, liens morts). Ne se déclenche jamais de façon proactive.
---

# veille · multi-sources → base de connaissance

Transforme des sources hétérogènes (vidéos YouTube, presse via Google News, Hacker News, Reddit, GitHub, flux RSS, tweets, recherche web) en savoir requêtable : bruts archivés, notes distillées, synthèse thématique vivante. Les mécanismes sont volontairement minces · `ytkb` pour YouTube, `curl` + `rss2ndjson.py` et `fetch_feeds.py` (à côté de ce fichier, python3 stdlib) pour les flux, FxTwitter pour X ; ce skill est la politique (où ranger, quoi distiller, comment fusionner). Marche pour n'importe quel sujet : un lancement de modèle IA, des recettes de pain au levain, une veille concurrentielle.

Les sources avancées (Chine, Corée, Russie, Yandex) et l'automatisation (récolte planifiée) vivent dans `extras/`, livrées en l'état : voir `extras/README.md`.

Les questions à l'utilisateur passent par l'outil de question de l'agent (AskUserQuestion dans Claude Code, question dans OpenCode), jamais en texte libre. Les sous-agents sont ceux de l'agent (Task / Agent dans Claude Code, sous-agents dans OpenCode).

## Étape 0 · Choix des sources (TOUJOURS en premier)

Dès qu'une veille est demandée, poser UNE question avant toute récolte :

`YouTube seul` / `Tout (YouTube + web)` / `Web seul` / `Je choisis finement`.

Si « finement » : question à choix multiples · `Google News` / `HN + Reddit` / `GitHub (repos et outils)` / `Blogs et communautés (dev.to, Indie Hackers, Product Hunt via site:)` / `Flux RSS perso` / `X (URLs collées)`. L'outil de question plafonne à 4 options : au-delà, scinder en DEUX questions. La recherche web générale (outil WebSearch) ne s'ajoute que si l'utilisateur la demande. GitHub est précieux dès que le sujet a une dimension outillage (le web et la vidéo parlent de SaaS payants, GitHub remonte les équivalents open source). Si l'utilisateur a déjà précisé les sources, sauter la question. Pour X, la veille ne cherche pas : l'utilisateur colle les URLs des tweets qui l'intéressent.

Dériver du sujet, en une passe : les **requêtes** (Google News, HN, GitHub · ex. « serveurs MCP » → `"mcp server"` + variante FR) et la **regex `$KW`** du filtre local (Reddit, flux perso, dev.to · ex. `mcp|model context protocol`). Les afficher à la sélection des items, pour que l'utilisateur corrige le tir.

**Désambiguïser les termes polysémiques AVANT la récolte complète.** Une requête se sonde d'abord sur 5 résultats dont on LIT les titres. Mesuré : `джейлбрейк` désigne surtout le jailbreak d'iPhone en russe, `越狱` pareil en chinois ; sept faux positifs distillés pour rien sur un seul run. La sonde coûte une requête, le faux positif coûte un sous-agent entier.

**Rendement mesuré par source** (run de 144 notes, note moyenne de pertinence sur 5, celle de la section `## Pertinence` de chaque note) :

| Source       | Note moyenne /5 |
| ------------ | --------------- |
| HN et presse | 3,49            |
| GitHub       | 3,45            |
| YouTube      | 3,10            |
| dev.to       | 1,50            |

**GitHub et HN portent le run** : les proposer en premier, ne jamais les couper. **dev.to se filtre durement** (regex `$KW` stricte, coupe basse à la sélection) : à 1,50 de moyenne, chaque item y consomme un sous-agent pour un contenu qui ne survit pas à la synthèse.

## Étape 1 · Sanity check

```bash
bash ~/.claude/skills/veille/doctor.sh   # lecture seule, zéro requête réseau
```

Il rend un tableau `SOURCE / ÉTAT / DÉTAIL / RÉPARATION`. **Toute ligne `KO` porte sa commande de réparation exacte** : l'appliquer avant de récolter, ne jamais lancer une récolte sur une source `KO` en espérant que ça passe. `SKIP` = source optionnelle désactivée (gh non connecté, liste perso vide), la veille tourne sans : le dire dans le rapport.

Pièges YouTube que le doctor ne voit pas :

- **yt-dlp périmé est LE failure mode n°1** : YouTube change, yt-dlp suit, un binaire de plus de deux mois finit en `nsig extraction failed` ou `Sign in to confirm you're not a bot` sur TOUTES les vidéos. Le doctor passe en `KO` au-delà de 60 jours ; `brew upgrade yt-dlp` (ou `pipx upgrade yt-dlp`).
- **Le bot-check peut tomber même avec le dernier yt-dlp.** Mesuré : 12 vidéos sur 12 en `Sign in to confirm`, débloquées par `ytkb --cookies-from-browser chrome` (ou `safari`, `firefox`). Valider sur UNE vidéo, puis lancer le lot.
- **Avec `--cookies-from-browser`, toujours ajouter `--lang en`** (ou la langue d'origine voulue). La session connectée transmet la langue du compte, et YouTube sert alors un doublage automatique étiqueté `fr-orig` que ytkb prend pour la piste originale : 7 transcripts sur 8 sortis en français traduit machine, termes techniques massacrés. Contrôle avant distillation : `jq -r '[.id,.lang] | @tsv' transcripts/*.json`.

## Layout et racine de la KB

**Racine `$KB`** : `$VEILLE_KB` si la variable est posée, sinon `~/veille-kb` (créée par `install.sh`, dépôt git local). Pour une KB propre à un projet : `export VEILLE_KB="$PWD/knowledge-base"`. Définir `$KB` en tête de CHAQUE bloc shell (le shell ne persiste pas entre appels) :

```bash
KB="${VEILLE_KB:-$HOME/veille-kb}"
```

```
$KB/<topic-slug>/
├── _index.md               # registre : 1 ligne par item (date, titre+lien, source, durée, piste, note /5, statut)
├── log.md                  # journal des opérations (ingest, lint), format `## [date] op | libellé`, greppable
├── SYNTHESIS.md            # document vivant THÉMATIQUE (jamais organisé par vidéo ou article)
├── transcripts/<id>.json   # sortie ytkb brute · source de vérité re-dérivable, ne jamais éditer
├── web/<id>.json           # item web brut normalisé · même rôle que transcripts/
└── notes/<id>.md           # distillation française par vidéo ; notes/web-<id>.md par article

$KB/_ENTITIES/<entite-slug>.md  # registre CROSS-TOPIC par entité (Étape 9bis)
```

Slug : minuscules, espaces → `-`, ascii (« Claude Fable 5 » → `fable-5`, « pain au levain » → `pain-au-levain`). Même règle pour les entités (« Andrej Karpathy » → `andrej-karpathy`).

### Frontières d'écriture (qui écrit quoi)

| Couche                         | Écrit par                                 | Interdit à                      |
| ------------------------------ | ----------------------------------------- | ------------------------------- |
| `transcripts/`, `web/` (bruts) | ytkb / jq uniquement (Étapes 5 et 6)      | TOUS les agents, sans exception |
| `notes/*.md`                   | les sous-agents de distillation (Étape 7) | le contexte principal           |
| `_index.md`, `log.md`          | le contexte principal (Étapes 8, 8bis)    | les sous-agents                 |
| `SYNTHESIS.md`                 | le contexte principal (Étape 9)           | les sous-agents                 |
| `_ENTITIES/`                   | l'unique sous-agent 9bis                  | les autres                      |

La couche brute est la source de vérité : inviolable par convention, et VÉRIFIABLE à l'Étape 10. La règle est dans le prompt, le contrôle d'intégrité la vérifie après coup.

## Volet YouTube

### Étape 2 · Résolution des sources

```bash
# A. URLs de vidéos directes → passer direct à l'étape 3

# B. Playlist ou chaîne → lister d'abord, JAMAIS de fetch direct (une chaîne = parfois 2000 vidéos)
ytkb --list 'https://www.youtube.com/@chaine' > /tmp/ytkb-cands.ndjson

# C. Sujet sans URLs → recherche triée par date (--recent) pour la veille
ytkb --search "claude fable 5" --recent --max 15 --list > /tmp/ytkb-cands.ndjson

# Table de présentation :
jq -r '[.id, .title, .channel // "?", ((.duration_sec // 0)/60 | floor | tostring)+" min", ((.view_count // 0)|tostring)+" vues"] | @tsv' /tmp/ytkb-cands.ndjson
```

Sans `--recent`, YouTube classe par pertinence (vieilles vidéos populaires) ; avec, par date d'upload, ce qu'on veut pour une veille. Les chaînes suivies de l'utilisateur sont dans `~/.config/veille/channels.txt` (une URL par ligne). Référence CLI : `ytkb --help` (`--lang fr,en`, `--segments`, `--cookies-from-browser chrome`, `--ytdlp-arg`).

Vidéos **sans sous-titres** : `--transcribe` (transcription audio locale par whisper.cpp). Plus lent, et demande `whisper-cli` plus un modèle (section transcription du README du dépôt) ; à réserver aux vidéos qui n'ont vraiment aucune caption.

### Étape 3 · Sélection humaine (jamais de fetch non consenti)

1. Afficher la table **numérotée** en markdown (n° | titre | chaîne | durée | vues).
2. UNE question, 4 options max : `Toutes (N)` / une présélection argumentée (ex. « Top 8 mix FR/EN ») / un sous-ensemble thématique / `Je donne les numéros`.
3. Le champ libre accepte des numéros (`1,3,7-9`) **ou des URLs collées** : cas fréquent, l'utilisateur arrive avec sa propre liste. Les accepter telles quelles.

### Étape 4 · Idempotence (l'incrémental est le cœur de la valeur)

```bash
KB="${VEILLE_KB:-$HOME/veille-kb}"
T="$KB/$TOPIC/transcripts"
mkdir -p "$T" "$KB/$TOPIC/notes"
# Ne garder que les URLs dont l'id n'est pas déjà ingéré :
while IFS= read -r url; do
  id=$(sed -E 's#.*(v=|youtu\.be/|shorts/|live/)([A-Za-z0-9_-]{11}).*#\2#' <<<"$url")
  [ -f "$T/$id.json" ] && echo "skip (déjà ingéré) : $id" >&2 || echo "$url"
done < /tmp/ytkb-selected.txt > /tmp/ytkb-urls.txt
```

Relancer la même veille une semaine plus tard ne télécharge que les nouveautés, et la synthèse se met à jour en append : c'est ça, construire une base de connaissance sur le long terme.

### Étape 5 · Fetch et split

```bash
ytkb -f /tmp/ytkb-urls.txt > /tmp/ytkb-batch.ndjson
# exit 0 = tout ok ; 1 = partiel (CONTINUER avec les réussites) ; 2 = rien (STOP, montrer stderr, ne rien écrire)

KB="${VEILLE_KB:-$HOME/veille-kb}"
jq -c 'select(.error == null)' /tmp/ytkb-batch.ndjson | while IFS= read -r rec; do
  printf '%s\n' "$rec" | jq . > "$KB/$TOPIC/transcripts/$(jq -r .id <<<"$rec").json"
done

jq -c 'select(.error != null) | {id,url,error}' /tmp/ytkb-batch.ndjson          # échecs → rapport final
jq -r 'select(.error == null and .text == null) | .id' /tmp/ytkb-batch.ndjson   # sans captions → --transcribe, note minimale, ou skip
```

ytkb choisit la piste la plus fidèle (manuelle > piste originale `*-orig` > traduction machine). Une vidéo italienne donne un transcript italien, c'est voulu : la traduction se fait à la distillation, pas par YouTube.

## Volet web

### Étape 6 · Récolte → filtre → sélection → écriture

Tout passe par le même format NDJSON `{id, title, url, published, source, summary}` · `id` = sha1 court de l'URL, clé d'idempotence.

```bash
S=~/.claude/skills/veille
KW='claude|anthropic'        # regex dérivée du sujet (la construire AVEC l'utilisateur si ambigu)

# Google News · filtré par la requête elle-même ; `when:7d` = fenêtre temporelle.
# Lancer une variante FR (hl=fr&gl=FR&ceid=FR:fr) ET une EN (hl=en-US&gl=US&ceid=US:en) si le sujet s'y prête.
# TOUJOURS -G + --data-urlencode pour q : une requête non latine concaténée à la main part cassée, et Google
# répond 200 avec un XML valide et ZÉRO item (mesuré : 18 items encodé, 0 non encodé, même requête).
curl -sL --compressed --max-time 30 -G 'https://news.google.com/rss/search' \
  --data-urlencode 'q="claude code" when:7d' -d 'hl=fr&gl=FR&ceid=FR:fr' \
| python3 "$S/rss2ndjson.py"

# Hacker News · API Algolia, JSON direct, tri par date.
# Fenêtre au lieu du tri : -G --data-urlencode "numericFilters=created_at_i>EPOCH". Le « > » DOIT être encodé :
# en clair, Algolia répond 400 et la boucle rend 0 item sans autre signe.
curl -s -G 'https://hn.algolia.com/api/v1/search_by_date' --data-urlencode 'query=claude code' -d 'tags=story&hitsPerPage=30' \
 | jq -c '.hits[] | {id: .objectID, title, url: (.url // ("https://news.ycombinator.com/item?id="+.objectID)), published: .created_at, source: "Hacker News", summary: ((.points|tostring)+" points, "+(.num_comments|tostring)+" comments")}'

# GitHub · repos open source (gh authentifié). 2-3 requêtes dérivées du sujet.
# Veille récurrente = NOUVEAUTÉS → --sort updated. One-shot « les meilleurs outils établis » → --sort stars.
gh search repos "google maps scraper" --sort updated --limit 15 \
   --json fullName,stargazersCount,description,pushedAt,url \
 | jq -c '.[] | {id: ("gh-"+(.fullName|gsub("/";"-"))), title: .fullName, url, published: .pushedAt, source: "GitHub", summary: ("★"+(.stargazersCount|tostring)+" · "+(.description // "(sans description)"))}'

# Flux RSS perso · ~/.config/veille/feeds.txt (1 URL par ligne, # = commentaire).
# fetch_feeds.py fait tout en un appel : fetch parallèle, fenêtre de jours, filtre $KW, dédup, tri.
# Sortie TSV (date \t source \t titre \t url \t résumé 300 car.), diagnostics sur stderr.
python3 "$S/fetch_feeds.py" 7 --filter "$KW"   # 7 jours ; omettre --filter sans $KW
# Variante NDJSON item par item, pour l'archivage brut d'un flux isolé :
curl -sL --compressed --max-time 30 "$URL_DU_FLUX" | python3 "$S/rss2ndjson.py"

# Blogs et communautés ciblés par mots-clés via l'opérateur site: de Google News. C'est LE moyen
# robuste de viser un site sans flux thématique (Indie Hackers, Product Hunt, un blog précis).
for dom in indiehackers.com producthunt.com; do
  curl -sL --compressed --max-time 15 -G 'https://news.google.com/rss/search' \
    --data-urlencode "q=site:${dom} google maps leads" -d 'hl=en-US&gl=US&ceid=US:en' | python3 "$S/rss2ndjson.py"
done

# dev.to · API par tag (JSON propre). Filtrer ensuite par $KW, durement.
for tag in saas webscraping automation; do
  curl -s --max-time 15 "https://dev.to/api/articles?tag=${tag}&per_page=20" \
   | jq -c '.[] | select(.title!=null) | {id:("devto-"+(.id|tostring)), title, url, published:.published_at, source:"dev.to", summary:(.description // "")}'
done

# Filtre mots-clés local, pour les sources larges (flux perso, dev.to, Reddit) :
jq -c --arg kw "$KW" 'select((.title+" "+.summary) | test($kw; "i"))'
```

**Trois pièges GitHub mesurés, à vérifier AVANT de retenir un repo :**

1. `pushedAt` n'est PAS le dernier commit de la branche par défaut (un mois d'écart mesuré sur un repo à 15k étoiles). Vérifier : `gh api repos/<o>/<r>/commits?per_page=1 --jq '.[0].commit.committer.date'`.
2. Le nombre d'étoiles n'est plus un filtre fiable sur les mots-clés à la mode (MCP, « skill », AEO). Mesuré : un compte à 1027 dépôts, dont 909 suffixés `-skill`, les 15 derniers créés le même jour avec exactement 8 étoiles chacun. Croiser avec `gh api users/<owner> --jq .public_repos` et la taille réelle du code.
3. Des faux dépôts remontent en `--sort updated` : README qui pointe vers des archives ZIP, installation `.exe` ou `.dmg`, dépannage qui conseille de DÉSACTIVER L'ANTIVIRUS, commits tous intitulés « Update README.md ». NE PAS télécharger les archives ; noter le repo 0/5 et passer.

**Reddit (optionnel, clé Firecrawl).** Les flux RSS de Reddit sont morts (old.reddit redirige vers `/login`, www rend 429 dès le deuxième appel) et Firecrawl refuse `reddit.com` en 403. La voie qui marche : chercher par Firecrawl, lire sur une instance redlib, qui rend le post ET ses commentaires. Clé dans `~/.config/veille/firecrawl_key` (`chmod 600`, plan gratuit 1000 crédits par mois) ; sans clé, Reddit est sauté et le rapport le dit.

```bash
K="$HOME/.config/veille/firecrawl_key"
# La clé passe par un fichier d'en-tête (-H @...), jamais en argument : les arguments se lisent dans ps.
fc() { curl -s -X POST "https://api.firecrawl.dev/v2/$1" -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$K")") -H 'Content-Type: application/json' -d "$2"; }

# 1) TROUVER (environ 4 crédits par recherche)
fc search '{"query":"site:reddit.com <sujet>","limit":15}' \
 | jq -c '(.data.web // .data // [])[]? | select(.url|test("reddit\\.com/r/")) | {url,title,description}'

# 2) LIRE (1 crédit) sur l'URL réécrite vers une instance redlib, en essayant plusieurs instances
for inst in redlib.catsarch.com safereddit.com; do
  rl=$(printf '%s' "$url" | sed "s#https://www\.reddit\.com#https://$inst#")
  md=$(fc scrape "$(jq -nc --arg u "$rl" '{url:$u,formats:["markdown"],onlyMainContent:false}')" \
       | jq -r 'if .success and .data.metadata.statusCode == 200 then .data.markdown else "" end')
  [ -n "$md" ] && break
done
```

Pièges mesurés : `success:true` ne suffit pas (une instance a rendu un statut 503 et un markdown vide, d'où le test du `statusCode`) ; enchaîner à 1 seconde fait échouer la moitié des scrapes de façon transitoire, 5 secondes de pause et 2 passes font tout passer ; le champ `description` de la recherche (100 à 150 caractères) n'est PAS le corps du post ; une page « Reddit rate limit exceeded » peut revenir comme un contenu valide, la chercher dans le corps et rescraper avec `"maxAge":0` après la pause. Choisir les subs AVEC l'utilisateur, jamais en silence.

**X / Twitter (URLs collées → FxTwitter)** : pas de recherche ni de scraping. Chaque URL `x.com|twitter.com/<user>/status/<id>` se résout en JSON via `api.fxtwitter.com`, gratuit, sans clé :

```bash
path="${url#https://}"; path="${path#x.com/}"; path="${path#twitter.com/}"; path="${path#mobile.twitter.com/}"
curl -s --max-time 15 -A 'veille-skill/1.0' "https://api.fxtwitter.com/${path}" \
 | jq -c '.tweet | {id: .id, title: (.author.name + " (@" + .author.screen_name + ")"), url: .url, published: .created_at, source: "X", summary: .text}'
# code != 200 (tweet privé ou supprimé) → jq sort vide : le signaler, passer au suivant.
```

La veille X par mots-clés n'a pas de voie gratuite fiable : ne jamais la présenter comme gratuite.

**Recherche web générale** (sur demande) : 2-3 requêtes datées via l'outil WebSearch (« <sujet> novembre 2026 ») ; normaliser à la main les résultats retenus dans le même NDJSON (`id=$(printf '%s' "$url" | shasum | cut -c1-12)`, `source: "websearch"`).

Fenêtre temporelle : Google News la gère via `when:7d`, HN via le tri par date (couper à la fenêtre), les flux perso via l'argument de `fetch_feeds.py` (défaut 7 jours).

Ensuite, même discipline que YouTube :

1. **Dédup** : skip tout item dont `web/<id>.json` existe déjà, et dédup intra-fournée par id (Google News FR et EN se recoupent). **Exception GitHub** : id stable (`gh-owner-repo`) mais contenu VIVANT, ré-ingérer si le `published` du candidat est plus récent que celui du `web/<id>.json` stocké.
2. **Table numérotée** (n° | date | source | titre) + **sélection humaine**, mêmes règles que l'Étape 3. Une fournée web peut faire 50 items et plus : proposer une présélection argumentée plutôt que tout distiller.
3. **Écriture** : chaque item retenu → `$KB/$TOPIC/web/<id>.json` (l'objet NDJSON, indenté).

## Étape 7 · Distillation par SOUS-AGENTS (règle de contexte ABSOLUE)

**Le contexte principal ne lit JAMAIS un transcript ni un article entier** (10k à 30k tokens pièce, 12 items = contexte explosé). Un sous-agent par item, lancés en parallèle.

**Vérifier qu'un transcript n'est pas VIDE avant de lancer un agent dessus.** Mesuré : deux transcripts Whisper vides ont produit deux notes à 0/5, deux sous-agents brûlés pour rien.

```bash
jq -r '.text | length' "$KB/$TOPIC/transcripts/<id>.json"   # 0 ou dérisoire → pas d'agent, item en échec
```

**Annoncer l'ETA AVANT de lancer, jamais après.** Formule : `items ÷ concurrence × durée médiane`. Mesures de référence (164 sous-agents) : **médiane 4,9 min par agent**, moyenne 13,2 min tirée par une longue traîne (c'est la MÉDIANE qui sert à estimer). L'ETA s'écrit dans le message qui précède le PREMIER lancement.

**Cadence : des vagues de 4 à 5 agents, jamais de 8 à 10.** Mesuré : une vague de 8 a saturé le classifieur de sécurité, 133 erreurs « temporarily unavailable » dans les agents et environ 40 % de lancements refusés. Et **remplir chaque créneau dès qu'il se libère** au lieu d'attendre la fin du lot, sinon le parallélisme réel s'effondre (7,2 agents en moyenne sur 20 possibles).

**Distillation en headless (OpenCode ou autre CLI)** : un pool bash suffit, `while IFS= read -r ligne; do bash -c "$ligne" </dev/null & while [ "$(pgrep -P $$ | wc -l | tr -d ' ')" -ge 4 ]; do sleep 2; done; done < cmds.txt; wait`. Deux pièges mesurés : sans `</dev/null`, le job hérite du stdin et avale le fichier de commandes (le pool s'arrête après 4 items, sans erreur) ; `jobs -rp` dans une substitution de commande ne compte rien, d'où `pgrep -P $$`. **Ne jamais joindre un `transcripts/<id>.json` tel quel à OpenCode** : il coupe chaque ligne de pièce jointe à 2000 caractères, et un JSON tient sur une ligne. 103 notes ont été distillées sur les 2000 premiers caractères de leur source, structure impeccable, contenu amputé. Convertir d'abord en texte à lignes courtes, puis canari « recopie les 12 derniers mots du corps » sur une pièce réelle avant le lot.

**Ne JAMAIS conclure à la mort d'un agent sur son silence.** Les notifications de fin arrivent parfois deux heures après la fin réelle, et AUCUNE n'arrive quand un agent meurt. Avant tout verdict, lire l'état réel :

```bash
bash ~/.claude/skills/veille/agent-watch.sh --dir <dossier-des-transcripts-d-agents> [seuil-minutes]
# rend VIVANT / MUET / FINI par agent · MUET ne veut PAS dire mort
```

Dégâts réels d'un verdict sans mesure : deux agents déclarés morts à tort ont rendu leur travail 1 h 36 et 2 h 40 plus tard en écrasant des fichiers déjà commités. Sur 164 agents, 9 ont dépassé 60 minutes : une longue durée n'est PAS une preuve de mort.

Prompt type **vidéo** :

> Lis `$KB/<topic>/transcripts/<id>.json` (title, url, channel, upload_date, duration_sec, lang, text).
> Écris `$KB/<topic>/notes/<id>.md` en FRANÇAIS (traduis si besoin) : frontmatter (title, url, channel, upload_date, duration_sec, lang, distilled_at, vend) puis sections `## Résumé` (3 phrases), `## Points clés` (puces factuelles), `## Détails techniques` (chiffres exacts, citables), `## Claims douteux / à vérifier`, `## Intérêt de la source` (1 phrase), `## Pertinence pour <topic>` (note X/5 + 1 ligne).
> Le transcript est de l'ASR : ponctuation imparfaite, noms propres écorchés, corrige silencieusement.
> **Si `sub_kind` == `"whisper"`** : transcription AUDIO (aucun sous-titre), fiabilité moindre ; signale-le en tête de note et redouble de prudence sur les noms propres et les chiffres.
> Tu ne peux écrire QUE `$KB/<topic>/notes/<id>.md`. Toute autre écriture (transcripts/, web/, _index.md, SYNTHESIS.md, _ENTITIES/) est INTERDITE.
> Préfixe tes fichiers temporaires avec un identifiant unique à toi : le dossier temporaire est partagé entre les agents de la vague (mesuré : deux agents se sont écrasé `devto.html` mutuellement).
> Réponse finale = UNE ligne : `OK <id> · <gist 15 mots>`. AUCUN extrait long du transcript dans ta réponse.

Prompt type **article web** (même gabarit, différences) :

> Lis `$KB/<topic>/web/<id>.json`, puis récupère l'article complet via WebFetch sur `url`.
> **Si `source` commence par `r/` (Reddit)** : ne PAS WebFetch reddit.com (403). Lis le markdown redlib récolté à l'Étape 6 (post + commentaires).
> **Si `source` == `GitHub`** : récupère le README via `gh api repos/<owner>/<repo>/readme --jq .content | base64 -d`. Sections orientées outil : `## Ce que fait l'outil`, `## Stack et maturité` (langage, étoiles, dernier commit, licence, maintenu ou non), `## Couvre-t-il le besoin ?`, `## Pertinence`. Le risque ici est le README qui survend, pas l'ASR.
> **URL Google News = redirection opaque que WebFetch ne résout PAS** (le base64 `CBMi...` ne contient pas la destination, et suivre la redirection boucle sur `consent.google.com`). Replis par fiabilité décroissante : 1. flux RSS ou sitemap de l'éditeur (`https://<site>/feed`), confirmé par titre, auteur et date identiques ; 2. API WordPress du site (`/wp-json/wp/v2/search?search=<titre>` puis `/wp-json/wp/v2/posts/<id>`) ; 3. un navigateur piloté, s'il y en a un, qui traverse le consent-wall.
> **Vérifie l'identité de la page récupérée** (`<title>` et `og:url`) avant de distiller : dev.to sert parfois, via son cache, un article d'un autre auteur (re-fetcher avec `Cache-Control: no-cache`).
> Paywall, cookie-wall ou contenu vide → note minimale depuis title+summary, marquée `(paywall · non lu)` en tête. N'invente JAMAIS le contenu.
> Écris `$KB/<topic>/notes/web-<id>.md` (ou `notes/web-x-<YYYYMMDD>.md` pour les tweets), mêmes sections que les vidéos, sans mention ASR. Tu ne peux écrire QUE ce fichier.

**Tweets** : pas de WebFetch, le texte est déjà dans l'item. Regrouper TOUS les tweets retenus de la fournée dans UNE note `notes/web-x-<YYYYMMDD>.md` (un tweet = 2-3 lignes : auteur, claim, lien).

Adapter les sections au domaine (recettes : `## Ingrédients et ratios`, `## Gestes critiques` ; entretien : `## Questions posées`, `## Réponses modèles`). Transcript de plus de 300 Ko : faire traiter chapitre par chapitre via `chapters`.

La section « Claims douteux » n'est pas optionnelle : youtubeurs comme rédactions mélangent faits et marketing, la séparer à la distillation évite d'empoisonner la synthèse. **`vend:` et `## Intérêt de la source` sont obligatoires** : `vend: <cours|SaaS|agence|affiliation|service|rien-apparent>`, et une phrase sur ce que l'auteur cherche à vendre, donc quels claims prendre avec des pincettes. Un YouTubeur qui finit sur « lien de ma formation » a intérêt à survendre la facilité. Ce champ alimente la pondération de l'Étape 9.

## Étape 8 · _index.md

Table append-only, une ligne par item : `| Ajouté le | Titre (lien) | Source | Durée | Piste | Note | Statut |`. `Source` : chaîne YouTube, ou `Google News/<média>`, `HN`, `r/<sub>`, `GitHub`, `X`, `blog`. `Durée` et `Piste` : vidéos uniquement (`·` pour le web). Statut : `distillé` → `synthétisé` ; cas dégradés `paywall` ou `échec` (raison en commentaire). La ligne s'écrit APRÈS la distillation, la note reprend la section `## Pertinence`.

## Étape 8bis · log.md

`$KB/<topic>/log.md` : la timeline des OPÉRATIONS, complémentaire de `_index.md` qui catalogue le contenu. Format fixe, greppable :

```markdown
## [2026-11-04] ingest | fable-5 · 3 vidéos, 2 articles web

## [2026-11-05] lint | 2 contradictions, 1 lien mort corrigé
```

`op` ∈ `ingest`, `lint`, `query`. `grep "^## \[" log.md | tail -5` = les 5 dernières opérations. Append uniquement, ne JAMAIS éditer une entrée existante. À lire en tête d'une veille append pour savoir ce qui s'est passé depuis la dernière fois.

## Étape 9 · Fusion dans SYNTHESIS.md

Entrées : la SYNTHESIS existante (si présente) + les NOUVELLES notes uniquement. Jamais les bruts, jamais les anciennes notes (sauf conflit à arbitrer).

- Organisation **par thèmes transverses** (prix, mécanisme X, limites, stratégies…), jamais par vidéo ou article.
- Chaque claim sourcé inline : `[chaîne ou média](url)`.
- Contradictions entre sources : les SIGNALER (`⚠ contradiction : A affirme X, B affirme Y`) au lieu de trancher en silence. Le croisement vidéo, presse et terrain (HN, Reddit) est précisément la valeur du multi-sources.
- Chiffres lus à l'écran par un youtubeur (ASR) : `(à recouper officiel)` ; idem pour un claim qui n'apparaît que dans des tweets.
- Ingestion ultérieure : marquer les ajouts `(nouveau · YYYY-MM-DD)`, mettre à jour les sections impactées, ne pas réécrire le document.
- Garder `## Claims douteux transverses` (ce qu'il ne faut PAS répéter sans vérification) et `## Intérêts des sources` (synthèse des champs `vend:`). Un claim répété par 5 sources qui vendent toutes la même chose n'est PAS une confirmation indépendante : `⚠ écho commercial, pas corroboration`.

**La fusion est un APPEND, et ce n'est pas une consigne, c'est une porte.** Mesuré : trois agents de synthèse ont reçu « ne rien supprimer sans raison » et ont quand même perdu 90 lignes de contenu antérieur. D'où le contrôle, qui compare la SYNTHESIS commitée à celle du disque :

```bash
KB="${VEILLE_KB:-$HOME/veille-kb}"
git -C "$KB" add -A && git -C "$KB" commit -q -m "veille: notes $TOPIC"   # AVANT la fusion : fige la référence
# ... fusion ...
bash ~/.claude/skills/veille/check-merge.sh "$TOPIC"        # 0 = aucune perte, 1 = perte
bash ~/.claude/skills/veille/check-merge.sh --self-test     # le détecteur détecte-t-il encore ?
```

Comparaison sur le texte normalisé (espaces écrasés) : une ligne réindentée ne compte pas comme perdue. S'il rend 1, réintégrer les lignes listées avant de continuer. Une disparition légitime (titre renommé, doublon réel) s'inscrit dans `<topic>/.synthesis-exceptions.txt` avec sa justification.

**Formulation du prompt de fusion · « fusionne mais ne supprime rien » est CONTRADICTOIRE, ne jamais l'écrire.** Mesuré : un agent a bouclé 17 fois sur le détecteur avant de mourir au bout de 258 minutes. La formulation qui marche, à recopier telle quelle :

> Restitue chaque ligne d'origine telle quelle, sur sa propre ligne, et place l'apport nouveau sur la ligne suivante, en paragraphe daté ou en sous-puce. Ne fusionne jamais deux informations sur une même ligne.

Ajouter : **copier les lignes d'origine par index depuis le fichier source, jamais les retaper**. Une ligne retapée dérive d'un caractère (apostrophe courbe, espace insécable perdue) et le détecteur la compte comme perdue.

## Étape 9bis · Entités cross-topic

Utile dès que la KB porte plusieurs topics. `SYNTHESIS.md` synthétise PAR topic, mais rien ne relie une entité (personne, outil, organisation, modèle) qui en traverse plusieurs. C'est le principe du « wiki cross-lié » (gist LLM Wiki d'Andrej Karpathy).

Un **seul** sous-agent, pas un par note (il doit voir toutes les nouvelles notes ensemble pour choisir des slugs cohérents) :

> Lis ces notes nouvellement distillées : `<liste de chemins absolus vers notes/*.md>`.
> Pour chaque entité significative (personne, outil ou produit, organisation, modèle · pas les mentions incidentes), mets à jour `$KB/_ENTITIES/<entite-slug>.md`. Avant de créer un fichier, `ls $KB/_ENTITIES/` pour vérifier qu'un slug proche n'existe pas (pas de `claude` et `claude-code` séparés si le contexte les traite comme une seule entité).
> Fichier existant : ajoute une ligne ; sinon crée-le avec `# <Nom>` en titre. Une ligne par (entité, note), jamais de doublon : `- [<topic>](../<topic>/notes/<id>.md) · <contexte en 1 phrase> (<date>)`.
> Réponse finale = UNE ligne : `OK <n> entités mises à jour : <liste>`.

## Étape 9ter · Versionnement

La KB est un dépôt git local (créé par `install.sh`). Committer APRÈS l'écriture ; ne jamais pousser d'office, un remote éventuel se pousse à la main.

```bash
KB="${VEILLE_KB:-$HOME/veille-kb}"
git -C "$KB" add -A
git -C "$KB" diff --cached --quiet || git -C "$KB" commit -q -m "veille: ${TOPIC:-mise à jour} ($(date +%F))"
```

`diff --cached --quiet ||` évite un commit vide. Le mode lecture n'écrit rien, donc ne committe pas.

## Étape 10 · Rapport final

Court : N ingérés par source / M échecs (avec raisons) / sources sautées (ex. Reddit sans clé) / liens vers `_index.md`, `log.md` et `SYNTHESIS.md` / 3 faits saillants de la fournée.

**Contrôle d'intégrité des bruts (OBLIGATOIRE)** : la couche brute n'a été touchée par aucun agent.

```bash
git -C "$KB" status --porcelain -- "$TOPIC/transcripts" "$TOPIC/web"   # vide attendu
```

**⚠ Ce contrôle ne mesure RIEN quand le topic est créé par le run lui-même** : tout le dossier est non suivi, donc la commande rend `?? <topic>/transcripts/` quoi qu'il se soit passé. Dans ce cas, passer par les mtimes **avec un contrôle positif dans le même appel**, sinon un zéro peut vouloir dire « aucune mesure » au lieu de « aucun résultat » :

```bash
find "$KB/$TOPIC/transcripts" "$KB/$TOPIC/web" -type f -newermt "<heure de début de distillation>" | wc -l   # 0 attendu
find "$KB/$TOPIC/notes" -type f -newermt "<heure de début de distillation>" | wc -l                         # > 0 attendu
```

**Rapport de COUVERTURE obligatoire** : pour chaque source à couverture partielle, le taux réel · Reddit `posts lus/visés`, GitHub `repos vus/cap`, flux perso `flux OK/total`. Un trou doit être VISIBLE : « 20 flux sur 30 » vaut mieux qu'un rapport qui laisse croire à 30 sur 30.

## Interroger la KB · « cherche dans ma veille <question> »

Mode **lecture**, aucune ingestion. Déclencheurs : « cherche dans ma veille … », « d'après ma veille … », « qu'est-ce qui a été dit sur … », « cherche dans `<topic>` … ».

1. **Cibler** le `<topic>` et la question. Sujet ambigu → `ls "$KB"/` puis demander lequel.
2. **Chercher, du distillé vers le brut :**

   ```bash
   KB="${VEILLE_KB:-$HOME/veille-kb}"
   cat "$KB/$TOPIC/SYNTHESIS.md"                                     # a) la synthèse d'abord, souvent LA réponse
   rg -i -l 'mot1|mot2|mot3' "$KB/$TOPIC"/{notes,transcripts,web}   # b) pré-filtre pour le détail ou le verbatim
   ```

   Lire `SYNTHESIS.md`, puis **uniquement les fichiers que `rg` remonte** (notes d'abord, bruts ensuite). Le pré-filtre fait que ça tient jusqu'à des centaines d'items sans index. Question centrée sur une **entité** (« que sait ma veille sur Karpathy ? ») : commencer par `$KB/_ENTITIES/<slug>.md`, qui pointe déjà vers toutes les notes pertinentes, tous topics confondus.

3. **Répondre, règles strictes :**
   - **Uniquement depuis la KB.** Si elle ne couvre pas la question, le dire. Ne JAMAIS combler avec des connaissances générales.
   - **Chaque affirmation sourcée** : `[chaîne ou média](url)`.
   - **Distinguer** « ce que disent les sources » de « fait vérifié » ; signaler chiffres ASR et claims marketing.
   - Sources qui se contredisent → le signaler (⚠), ne pas trancher en douce.

## Linter la KB · « lint ma veille »

Déclencheurs : « lint ma veille », « linte ma KB », « health check de ma veille ». Opération de MAINTENANCE, lecture seule par défaut : un rapport, des corrections seulement après accord explicite. C'est le garde-fou contre la dérive, le failure mode n°1 du pattern wiki-LLM : à l'ingestion, le modèle sous-met à jour les références croisées et les pages se pétrifient en silence.

1. **Cibler** un `<topic>` ou toute la KB.
2. **Chasser les 4 classes de dérive :**
   a. **Contradictions non signalées** : une note récente contredit un claim de `SYNTHESIS.md` SANS marqueur `⚠ contradiction`.
   b. **Claims périmés** : `à recouper officiel` vieux de plusieurs mois, notes `paywall` jamais relues, ajouts `nouveau` de plus de 30 jours jamais intégrés au corps.
   c. **Orphelins et liens morts** : `_ENTITIES/` qui pointe vers des notes inexistantes, entités citées sans fichier, liens de `_index.md` ou `SYNTHESIS.md` vers des fichiers supprimés.
   d. **Veille morte** : topic sans ingestion depuis plus de 30 jours (60 pour un sujet lent).
3. **Rapport** : liste numérotée, une sévérité par ligne (`contradiction` / `périmé` / `orphelin` / `lien mort` / `veille morte`), `fichier:ligne` quand possible. Rien trouvé = le dire franchement, un lint à 0 est un bon résultat.
4. **Corrections, uniquement sur accord** (question : `Corrige tout` / `Contradictions seules` / `Rien`). Corriger = éditer `SYNTHESIS.md` ou `_ENTITIES/`. Ne JAMAIS supprimer un fichier : l'orphelin reste signalé, la suppression est une décision humaine.
5. **Journal** : `## [date] lint | <N problèmes, M corrigés>` dans `log.md`, puis commit comme à l'Étape 9ter si des corrections ont été écrites.

## Failure modes

| Cas                                             | Comportement                                                                                                                                  |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `ytkb` introuvable                              | `bash install.sh` à la racine du dépôt veille (build de ytkb, cargo requis)                                                                   |
| `nsig` / `Sign in to confirm`                   | `brew upgrade yt-dlp`, retry UNE fois ; si ça persiste : `ytkb --cookies-from-browser chrome --lang en`                                       |
| ytkb exit 1 (partiel)                           | Continuer avec les réussites, lister les échecs dans le rapport                                                                               |
| ytkb exit 2 (rien)                              | STOP, montrer le stderr, ne rien écrire dans la KB                                                                                            |
| `.text == null` (pas de captions)               | Proposer `--transcribe` (whisper.cpp local, voir le README) ; sinon note minimale depuis description et chapitres, ou skip                    |
| 0 candidat en recherche                         | Reformuler la requête avec l'utilisateur ; essayer sans `--recent`                                                                            |
| Topic déjà existant                             | Mode append : lire `_index.md` et `log.md` d'abord, dédup par id, fusionner la synthèse                                                       |
| Playlist ou chaîne géante                       | JAMAIS de fetch direct : toujours `--list` + sélection humaine                                                                                |
| `rss2ndjson: DTD/ENTITY détecté`                | Ce n'est PAS un flux, c'est souvent une page HTML d'erreur. Trouver la vraie URL du flux, ne jamais désactiver la garde (anti billion-laughs) |
| `rss2ndjson: XML illisible` ou `flux vide`      | Téléchargement tronqué ou URL morte → `curl -sL --compressed --max-time 30`                                                                   |
| Google News : 0 item sur une requête non latine | Requête non encodée : `-G --data-urlencode 'q=…'`                                                                                             |
| URL Google News illisible                       | Redirection opaque : replis de l'Étape 7 (flux de l'éditeur, API WordPress, navigateur piloté)                                                |
| Page récupérée ≠ page attendue                  | Comparer `<title>` et `og:url` AVANT de distiller, re-fetcher avec `Cache-Control: no-cache`                                                  |
| Article paywallé                                | Note minimale depuis title+summary, marquée `(paywall · non lu)`, ne JAMAIS inventer                                                          |
| PDF arXiv illisible par WebFetch                | Télécharger le PDF et `pdftotext -layout`, ou lire la notice `arxiv.org/abs/<id>`                                                             |
| Reddit sans clé Firecrawl                       | Source sautée, le dire dans le rapport ; ne pas retenter les flux RSS de Reddit (morts)                                                       |
| Reddit : `success:true` mais markdown vide      | Instance redlib en panne : essayer la suivante ; 5 s de pause et 2 passes                                                                     |
| Tweet : `code` != 200 chez FxTwitter            | Tweet privé, supprimé ou compte protégé : le signaler, passer à l'URL suivante                                                                |
| Veille X « sur un sujet » sans URLs             | Expliquer que X se fait par URLs collées ; la recherche par mots-clés est payante                                                             |
| `feeds.txt` absent ou vide                      | `cp config/feeds.example.txt ~/.config/veille/feeds.txt`, puis proposer à l'utilisateur d'y mettre SES flux (ne pas la remplir à sa place)    |
| `gh` absent ou non connecté                     | `brew install gh` puis `gh auth login` (interactif, à taper par l'utilisateur) ; sans ça, source GitHub sautée                                |
| GitHub search rate limit                        | 30 requêtes par minute authentifié ; espacer, `gh api rate_limit --jq .resources.search`                                                      |
| Repo GitHub abandonné                           | Le signaler dans la note (`maintenu : non, dernier commit AAAA-MM`) ; ne pas recommander un outil mort                                        |
| `check-merge.sh` rend 1                         | Lignes perdues à la fusion : les réintégrer avant de continuer, ou les excuser dans `.synthesis-exceptions.txt` avec justification            |
| Agent silencieux depuis longtemps               | `agent-watch.sh` avant tout verdict ; MUET n'est pas mort                                                                                     |
| Run headless : écriture hors workspace refusée  | Lancer le run depuis un dossier qui contient la KB ; vérifier les sorties sur disque, pas le récit de l'agent                                 |
| Recherche sur un topic inexistant               | `ls "$KB"/` ; sinon proposer d'en créer un (« fais une veille sur … »)                                                                        |
| Question hors KB                                | Le dire franchement, ne PAS répondre depuis des connaissances générales                                                                       |
| Corrections de lint refusées                    | Rien n'est écrit, pas de commit ; le rapport reste la seule sortie                                                                            |
