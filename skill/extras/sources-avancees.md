# Sources avancées · Chine, Corée, Russie, Yandex

Livré en l'état, comme tout `extras/` : recettes mesurées sur la machine d'origine, aux dates indiquées. Ces sites changent ; une recette qui rend zéro item n'est pas forcément un jour calme, relancez d'abord le contrôle négatif de sa section. Chaque recette produit le même NDJSON que le volet web du cœur (`{id, title, url, published, source, summary}`), donc la suite (filtre, table de sélection de l'Étape 3, écriture dans `web/<id>.json`, distillation de l'Étape 7) ne change pas.

```bash
S=~/.claude/skills/veille   # rss2ndjson.py est à la racine, les scripts avancés dans $S/extras
```

Deux règles valent pour toutes les langues non latines. Les titres arrivent en chinois, coréen ou russe : ajoutez une traduction française courte entre parenthèses dans la table de sélection, c'est une table de décision, pas un dump. Et le filtre `$KW` doit lister les deux alphabets (`agent|агент`), sinon il jette des items pertinents sans rien dire (mesuré : 16 rejets sur 32 avec un filtre monolingue, 10 avec un filtre bi-alphabet).

## Chine

### Bilibili (`bili`, jamais yt-dlp)

Bilibili bloque yt-dlp (HTTP 412 systématique, avec ou sans cookies). Tout passe par la CLI `bili` (`pipx install bilibili-cli`, puis `pipx inject bilibili-cli av` pour l'audio), en lecture seule et sans login.

```bash
# Recherche : 2 ou 3 requêtes, dont AU MOINS UNE EN CHINOIS (« Claude Code » -> "Claude Code 技巧", "Claude 编程").
# L'API trie par pertinence, pas par date. Sortie YAML.
bili search "Claude 编程" --type video -n 15
# Détails d'une vidéo retenue : stats et sous-titres (champ subtitle.available)
bili video BV1KjoxBoEQJ
# Aussi utiles : bili hot -n 10 (tendances), bili rank -n 10 (classement)
```

Le bvid sert d'id : sautez la vidéo si `transcripts/<bvid>.json` existe déjà. Pour le transcript, deux cas. Si `subtitle.available` vaut `true`, le texte est dans la sortie de `bili video` (`subtitle.text`). Sinon (fréquent : les sous-titres IA de Bilibili exigent un login), repli audio plus whisper.cpp en local :

```bash
# 1. Audio découpé en segments WAV d'environ 25 s ; le dossier est affiché sur la ligne « 输出目录 »
bili audio BVxxx
# 2. Transcription locale (brew install whisper-cpp, plus un modèle ggml, par exemple large-v3-turbo)
for f in "<dossier affiché>"/seg_*.wav; do
  whisper-cli -m <chemin du modèle ggml> -l zh --no-timestamps "$f" 2>/dev/null
done >/tmp/bili-<bvid>.txt
```

Écrivez `transcripts/<bvid>.json` au même schéma que ytkb (`{id, title, url, channel, upload_date, duration_sec, lang: "zh", sub_kind: "bilibili-sub"|"whisper", text}`) : la distillation marche telle quelle, et la note sort en français. Piège : l'ASR chinois écorche phonétiquement les noms de produits occidentaux (« cardcode » pour Claude Code). Rappelez-le au sous-agent pour toute vidéo `lang: "zh"`.

### Presse chinoise (Google News zh-CN, China Daily)

```bash
# Même piège que toute langue non latine : sans --data-urlencode, la réponse est un XML valide à ZÉRO item.
curl -sL --compressed --max-time 30 -G 'https://news.google.com/rss/search' \
  --data-urlencode 'q=Kimi K3 when:7d' -d 'hl=zh-CN&gl=CN&ceid=CN:zh-Hans' |
  python3 "$S/rss2ndjson.py"
# China Daily répond 200 en curl direct avec un UA navigateur, texte entier, sans paywall.
curl -sL --compressed --max-time 25 -A 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' '<url>'
```

China Daily est le quotidien officiel anglophone de l'État chinois : annotez le biais narratif d'État dans `vend:` et croisez ses chiffres avec une source indépendante.

### V2EX (forum des développeurs chinois)

Retours d'usage, quotas, prix, comparatifs d'outils. Passe par [Agent-Reach](https://github.com/Panniantong/agent-reach) 1.6, sans login mais sans recherche : on lit des nœuds (catégories), puis on filtre par `$KW`. Chaque appel rend au plus 10 sujets, corps du premier message compris.

```bash
# Nœuds actifs au 2026-11-01 : openai claude deepseek cursor gemini vibecoding programmer share create.
# Un nœud mort rend ok:false avec items: [] ; sans le contrôle, la couverture paraît complète.
for n in openai claude deepseek cursor gemini vibecoding programmer; do
  out=$(agent-reach v2ex node "$n")
  printf '%s' "$out" | jq -e '.ok == true' >/dev/null 2>&1 ||
    echo "V2EX nœud $n en échec : $(printf '%s' "$out" | jq -r '.error.code // "réponse illisible"' 2>/dev/null)" >&2
  printf '%s\n' "$out"
done | jq -c '.items[]? | {id: ("v2ex-" + (.url | split("/") | last)), title, url, published: .published_at, source: "V2EX", summary: (.text // "" | .[0:500])}' |
  grep -iE "$KW"
agent-reach v2ex read <url>   # réponses d'un sujet retenu, souvent plus riches que le message
```

Les quotas et prix cités sont des témoignages : rangez-les en `## Claims douteux / à vérifier` tant qu'une source officielle ne les confirme pas.

### Xiaohongshu, Douyin, Kuaishou (fragiles)

- **Xiaohongshu** : par Agent-Reach (`agent-reach add xiaohongshu` une fois). Login XHS requis (sinon `NEED_LOGIN`, et c'est à vous de lancer `agent-reach login xiaohongshu`), jamais de lecture par note_id nu (le `xsec_token` vient d'une recherche), 2 à 3 s entre requêtes sinon captcha. Normalisez en `{id: "xhs-<note_id>", source: "Xiaohongshu", ...}` : le corps est déjà dans la réponse.
- **Douyin, Kuaishou** : aucune voie fiable testée. Pour une URL unitaire seulement, `yt-dlp -x --cookies-from-browser chrome <url>` puis whisper comme ci-dessus, en annonçant le best-effort.

## Corée

La Corée est un angle mort de Google : sur un topic de test, 58 des 60 billets de blog coréens manquaient au repli `site:blog.naver.com` par Google News.

### velog (blogs de développeurs, GraphQL ouvert)

```bash
# PIÈGE : l'endpoint est v2.velog.io ; v3.velog.io répond 200 avec un corps VIDE (panne silencieuse).
# Seul searchPosts marche, sans tri : paginer puis trier localement sur .published.
# Tokenisation en OR : lancer 3 ou 4 requêtes, larges ET étroites, puis filtrer sur $KW.
# Tester les DEUX transcriptions coréennes d'un mot emprunté (« harness » : 하네스 ET 하니스).
velog_search() { # $1 = requête, $2 = offset (défaut 0)
  curl -s --max-time 30 -X POST 'https://v2.velog.io/graphql' \
    -H 'content-type: application/json' -H 'Origin: https://velog.io' \
    -d "$(jq -nc --arg k "$1" --argjson o "${2:-0}" '{query:"query($k:String!,$o:Int){searchPosts(keyword:$k,offset:$o,limit:100){count posts{title url_slug released_at short_description tags user{username}}}}",variables:{k:$k,o:$o}}')" |
    jq -c '.data.searchPosts.posts[]? | {title, url:("https://velog.io/@"+.user.username+"/"+.url_slug), published:.released_at, source:"velog", summary:((.short_description // "")[0:500])}'
}
for q in '딥시크 하네스' 'DeepSeek Harness' '하네스 엔지니어링'; do velog_search "$q"; done |
  python3 -c 'import sys,json,hashlib
for l in sys.stdin:
    d=json.loads(l); d["id"]="velog-"+hashlib.sha1(d["url"].encode()).hexdigest()[:12]
    print(json.dumps(d,ensure_ascii=False))'
```

Corps complet d'un billet retenu, sans WebFetch (`username` et `url_slug` se lisent dans l'URL) :

```bash
curl -s -X POST 'https://v2.velog.io/graphql' -H 'content-type: application/json' -H 'Origin: https://velog.io' \
  -d '{"query":"query($u:String,$s:String){post(username:$u,url_slug:$s){title body released_at tags}}","variables":{"u":"<username>","s":"<url_slug>"}}' |
  jq -r '.data.post.body'
```

### Brunch (API de recherche interne, sans compte)

Le RSS de Brunch est mort, mais l'API que son front appelle est ouverte. Leçon générale : un RSS mort ne dit rien de l'API du site, regardez les requêtes XHR avant de conclure.

```bash
# DEUX PIÈGES SILENCIEUX :
#  1. Filtre $KW OBLIGATOIRE : l'API ne filtre pas vraiment (une requête absurde rend 19 items tendance).
#  2. `page` est ignoré : élargir par requêtes multiples, jamais par pagination.
KW='딥시크|deepseek|하네스|에이전트|agent'
brunch() {
  curl -sS -G --compressed --max-time 25 -A 'veille-skill/1.0' \
    'https://api.brunch.co.kr/v1/search/article' --data-urlencode "q=$1" -d 'page=0&size=20' |
    jq -c '.data.list[]? | select(.no != null) | {
      id: ("brunch-" + .userId + "-" + (.no|tostring)),
      title: (.title // ""),
      url: ("https://brunch.co.kr/@" + .userId + "/" + (.no|tostring)),
      published: (.publishTime / 1000 | todate),
      source: "Brunch",
      summary: (((.subTitle // "") + " " + (.contentSummary // "")) | .[0:500])
    }'
}
for q in '딥시크' '딥시크 하네스' '코딩 에이전트'; do brunch "$q"; done |
  jq -c --arg kw "$KW" 'select((.title + " " + .summary) | test($kw;"i"))' | sort -u
```

### Kakao (`dapi.kakao.com`, la source coréenne la plus large)

284 items sur 3 requêtes au premier essai, et surtout l'index de `blog.naver.com`, de Brunch et des forums de développeurs coréens (`okky.kr`, `clien.net`, `news.hada.io`...). La clé REST ne s'obtient pas en s'inscrivant : créez une APPLICATION dans `developers.kakao.com/console/app`, puis lisez la clé sous `config/platform-key`. Rangez-la dans `~/.config/veille/kakao_rest_key` (`chmod 600`) ; `bash $S/extras/doctor-extras.sh` la teste.

```bash
# sort=recency indispensable (défaut : pertinence). Requête absurde -> 0 item, clé bidon -> 401 : les deux sens sont mesurés.
# La clé passe par -H @<(...), jamais en argument : un argument se lit dans `ps`.
kakao() { # $1 = blog|web, $2 = requête
  curl -sS -G --compressed --max-time 25 "https://dapi.kakao.com/v2/search/$1" \
    -H @<(printf 'Authorization: KakaoAK %s\n' "$(cat ~/.config/veille/kakao_rest_key)") \
    --data-urlencode "query=$2" -d 'size=50&sort=recency' |
    jq -c --arg src "Kakao/$1" '.documents[]? | {
      title: (.title | gsub("<[^>]*>";"")),
      url, published: .datetime, source: $src,
      summary: ((.contents // "") | gsub("<[^>]*>";"") | .[0:500])
    }'
}
# Id par SHA1 de l'URL, jamais par base64 tronqué : 16 caractères de base64 n'encodent que « https://blog »,
# et 287 URL distinctes tombaient sur 114 ids (60 % des billets « déjà ingérés » à tort).
for q in '딥시크 하네스' 'DeepSeek Harness' '코딩 에이전트'; do kakao blog "$q"; kakao web "$q"; done |
  python3 -c 'import sys,json,html,hashlib
for l in sys.stdin:
    d=json.loads(l)
    d["id"]="kakao-"+hashlib.sha1(d["url"].encode()).hexdigest()[:12]
    d["title"]=html.unescape(d["title"]); d["summary"]=html.unescape(d["summary"])
    print(json.dumps(d,ensure_ascii=False))' | sort -u
```

Pièges mesurés :

- **Date fiable sur `/blog`, pas sur `/web`.** Sur `/web`, Kakao rend parfois la date de crawl sans le dire (2 fausses sur 4, jusqu'à 19 mois d'écart) : la fenêtre `when:7d` y ment. Pour tout item `/web` retenu, recoupez la date sur la page (`datePublished` ou `article:published_time`) avant de l'utiliser.
- **Homonymes.** En littérature ML, « harness » désigne le banc d'évaluation : une requête trop courte remonte des papiers sans rapport. Ajoutez un second terme discriminant.
- **`blog.naver.com` refuse WebFetch.** Contournement mesuré (HTTP 200) : `curl 'https://blog.naver.com/PostView.naver?blogId=<id>&logNo=<no>'`, les deux paramètres se lisent dans l'URL publique `blog.naver.com/<id>/<no>`.

Complétez avec la variante coréenne de Google News (`hl=ko&gl=KR&ceid=KR:ko`). Écartés après sonde : le scraping de Naver (Kakao rend les mêmes blogs proprement), Daum (0 octet rendu, même dans un navigateur), Tistory (pas de recherche globale), `namu.wiki` (HTTP 403 anti-bot : note minimale depuis le titre et l'extrait, marquée `(non lu · HTTP 403)`).

## Russie

### Habr

26 items sur 32 manquaient à Google News RU sur la même fenêtre de 30 jours. Zéro clé, zéro quota.

```bash
# Plafond dur : 20 items par requête, `page` et `order` sont ignorés. Élargir par requêtes multiples, trier sur .published.
for q in "DeepSeek harness" "харнесс" "кодинг агент" "дипсик"; do
  curl -sS -G -L --compressed --max-time 25 -A 'veille-skill/1.0' 'https://habr.com/ru/rss/search/' \
    --data-urlencode "q=$q" --data-urlencode 'target_type=posts' |
    python3 "$S/rss2ndjson.py" | jq -c '.url |= sub("\\?utm_source.*";"") | .source = "Habr"'
done
# Flux chronologique d'un hub, post-filtre $KW OBLIGATOIRE (sinon environ 90 % hors sujet).
# Hubs vérifiés : artificial_intelligence, machine_learning, programming, open_source, python, devops.
for h in artificial_intelligence open_source; do
  curl -sS -L --compressed --max-time 25 -A 'veille-skill/1.0' "https://habr.com/ru/rss/hub/$h/all/?fl=ru" |
    python3 "$S/rss2ndjson.py" | jq -c '.url |= sub("\\?utm_source.*";"") | .source = "Habr"'
done
```

### Telegram (aperçu web public, sans compte)

Le milieu tech russophone vit sur Telegram plus que sur VK. L'aperçu `t.me/s/<canal>` rend les posts publics sans compte ni token, avec recherche dans le canal. Mesuré : 10 canaux sur 10 en 200, dates exactes, et un sujet de test y sortait 4 jours avant partout ailleurs.

La liste des canaux vit dans `~/.config/veille/tg_channels.txt`, un handle par ligne, `#` en commentaire. Pour l'amorcer : `curl -sL 'https://tgstat.ru/tech' | grep -o '/channel/@[A-Za-z0-9_]*' | cut -d@ -f2 | sort -u`. Si la liste mélange canaux russophones et anglophones, gardez une requête de chaque alphabet : une requête cyrillique ne remonte rien sur un canal anglophone.

```bash
for ch in $(grep -v '^\s*#' ~/.config/veille/tg_channels.txt | grep .); do
  for q in 'deepseek' 'харнесс'; do
    curl -sS -L --compressed --max-time 25 -A 'veille-skill/1.0' \
      "https://t.me/s/$ch?q=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$q")" |
      python3 "$S/extras/tg2ndjson.py"
  done
done | python3 -c 'import sys,json
seen=set()
for l in sys.stdin:
    d=json.loads(l)
    if d["id"] not in seen: seen.add(d["id"]); print(l,end="")' >/tmp/veille-tg.ndjson
```

Au-delà de 20 résultats, rappelez avec `&before=<id du plus ancien message>`. Un canal inexistant ou à l'aperçu désactivé rend 200 et une sortie vide : c'est normal, n'insistez pas.

### VK (`vk.mjs`, sans compte VK)

VK n'a aucune voie directe (l'API exige un token, le token un compte développeur, le compte un téléphone). `vk.mjs` combine deux mécanismes : **chercher** par Yandex (`site:vk.com <requête>`, qui rend des URLs de posts directes et exige la session Yandex de `fx.mjs`), et **lire** par le site mobile `m.vk.com/wall<id>_<postid>`, rendu côté serveur, texte complet et date, sans compte. Leçon générale : devant une SPA fermée, essayez le site mobile avant de conclure (le desktop rendait 73 ko de coquille et 0 post).

```bash
node "$S/extras/vk.mjs" search "дипсик OR deepseek харнесс" 15   # recherche Yandex puis lecture
node "$S/extras/vk.mjs" wall -30666517 3                         # mur d'un groupe, 3 pages, SANS recherche
```

Mesuré : mur d'un groupe, 39 posts uniques sur 2 pages, 0 date nulle ; requête absurde, 0 post. Pièges : `?own=1` est indispensable sur un mur de groupe (sinon les posts des visiteurs entrent aussi) ; les murs de profils personnels exigent une session (date nulle attendue) ; `locale` ne prend pas sur un profil Playwright déjà créé, d'où un parseur de dates français et anglais.

### vc.ru

Registre business. API `api.vc.ru/v2.1/search` avec **`query=`, pas `q=`** (avec `q=` elle rend `{"items":[]}` même pour un terme qui a des articles : faux zéro), articles dans `.result.contents[].data`.

## Volet session · `fx.mjs` (Yandex et sources à compte)

Certaines sources tombent devant `curl` mais pas devant un navigateur : elles exigent un compte, ou jugent l'empreinte du client (Yandex et son SmartCaptcha). `fx.mjs` tient un profil Playwright persistant, séparé de votre navigateur (`~/.config/veille/fx-profile`, réglable par `VEILLE_FX_PROFILE`).

```bash
npm i -g playwright && npx playwright install firefox   # une fois
node "$S/extras/fx.mjs" login            # fenêtre visible : se connecter, puis FERMER la fenêtre soi-même
node "$S/extras/fx.mjs" status           # domaines qui ont des cookies (jamais les valeurs)
node "$S/extras/fx.mjs" fetch '<url>'    # corps brut, cookies partagés, sans JS : API, RSS, JSON
node "$S/extras/fx.mjs" dom '<url>'      # HTML APRÈS exécution du JS : SPA (VK, Yandex)
```

Une recette existante s'y branche sans réécriture : remplacez `curl -sS '<url>'` par `node "$S/extras/fx.mjs" fetch '<url>'`, le reste du pipe ne change pas.

**Yandex** : ses chemins sans navigateur sont morts (XML v1 en `error 4002`, API v2 en 401, News RSS en timeout depuis une IP française), mais `node fx.mjs dom 'https://yandex.ru/search/?text=…'` passe avec une session, là où `curl` tombe sur `/showcaptcha` dès le premier appel.

Pièges mesurés :

- **La session Yandex tient moins de 11 heures**, et elle est un point de défaillance unique pour deux sources (Yandex, et la recherche VK qui passe par lui). C'est pourquoi `doctor-extras.sh` teste le réseau par défaut. Réparation : `node fx.mjs login https://passport.yandex.ru/auth`, se connecter, fermer la fenêtre.
- **Firefox Playwright ne démarre plus sur macOS 27** (sandbox refusé, puis SIGKILL ; réinstaller la build ne corrige pas). `fx.mjs` et `vk.mjs` basculent automatiquement sur Chromium, avec un profil distinct (`fx-profile-chromium`), et l'annoncent sur stderr. Les cookies ne passent pas d'un moteur à l'autre : reconnectez chaque source une fois.
- **Un seul processus à la fois sur le profil** : Playwright le verrouille. Fermez la fenêtre de `login` avant `status`.
- **Des cookies sur un domaine ne prouvent pas une session** (23 cookies sur `.vk.ru` alors que la page disait « Se connecter »). Vérifiez le contenu rendu, jamais la seule présence de cookies.
- **`networkidle` ne suffit pas toujours pour une SPA lourde** : ajoutez une attente explicite (`waitForSelector`) avant de lire le DOM.
- **Ne jamais écrire une valeur de cookie ni une clé** dans un rapport, un log ou une note. Les secrets vivent dans `~/.config/veille/` et n'en sortent pas.

## Dépannage

| Symptôme                                          | Cause et réponse                                                                                                                                                     |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Bilibili par yt-dlp : HTTP 412                    | Attendu (anti-bot total). Toujours `bili`, jamais yt-dlp.                                                                                                            |
| `bili` introuvable                                | `pipx install bilibili-cli`                                                                                                                                          |
| `bili audio` : « 需要 PyAV 库 »                   | `pipx inject bilibili-cli av`                                                                                                                                        |
| Bilibili `subtitle.available: false`              | Normal (sous-titres IA réservés aux comptes) : repli `bili audio` plus `whisper-cli -l zh`.                                                                          |
| `bili video` : HTTP 412                           | Mesuré le 2026-09-30 sur 2 vidéos sur 2 : la recherche passe, l'info vidéo est refusée. Marquez l'item en échec, ne lancez pas d'agent sur un transcript inexistant. |
| XHS `NEED_LOGIN`                                  | `agent-reach login xiaohongshu`, se connecter soi-même, puis relancer.                                                                                               |
| Demande Douyin ou Kuaishou                        | Annoncer le best-effort d'emblée ; URL unitaire seulement, jamais de découverte.                                                                                     |
| `blog.naver.com` : `unable to fetch`              | `curl 'https://blog.naver.com/PostView.naver?blogId=<id>&logNo=<no>'`                                                                                                |
| Item `Kakao/web` à la date suspecte               | Recouper sur la page (`datePublished`) avant la fenêtre temporelle.                                                                                                  |
| `namu.wiki` : HTTP 403                            | Anti-bot, pas de contournement : note minimale marquée `(non lu · HTTP 403)`.                                                                                        |
| Yandex : SmartCaptcha                             | Session perdue : `node fx.mjs login https://passport.yandex.ru/auth`.                                                                                                |
| `fx.mjs` ou `vk.mjs` : Firefox meurt au lancement | Attendu sur macOS 27 : le repli Chromium est automatique, reconnectez chaque source une fois.                                                                        |
