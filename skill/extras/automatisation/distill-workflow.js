export const meta = {
  name: 'veille-distill',
  description: 'Distille en parallèle une work-list de sources de veille (1 sous-agent par item, écrit une note FR par item) sans charger les bruts dans le contexte principal',
  phases: [
    { title: 'Distillation', detail: 'un agent par item : lit le brut, fetch si besoin, écrit la note' },
  ],
}

// args attendu :
// { topic: "<slug>", kbPath: "<racine KB absolue>",
//   items: [ { id, noteName, rawPath, source, url, kind } ] }
//   kind ∈ "video" | "article" | "github" | "social"

// args peut arriver comme objet OU comme chaîne JSON selon l'appelant : normaliser.
let A = args
if (typeof A === 'string') { try { A = JSON.parse(A) } catch (e) { A = {} } }
A = A || {}

const topic = A.topic || 'topic'
const kbPath = A.kbPath || '.'
// Date passée par la skill (Date est indisponible dans un workflow). Défaut neutre sinon.
const distilledAt = A.distilledAt || 'à dater'
const items = Array.isArray(A.items) ? A.items : []

const notesDir = `${kbPath}/${topic}/notes`

// Gabarit de sections commun (aligné sur le skill veille).
const SECTIONS = [
  '`## Résumé` (3 phrases)',
  '`## Points clés` (bullets factuels)',
  '`## Détails techniques` (chiffres exacts, citables)',
  '`## Claims douteux / à vérifier`',
  '`## Intérêt de la source` (frontmatter `vend: <cours|SaaS|agence|affiliation|service|rien-apparent>` + 1 phrase : que cherche à vendre l\'auteur, donc quels claims prendre avec des pincettes)',
  '`## Pertinence pour ' + topic + '` (note X/5 + 1 ligne)',
].join(' · ')

function buildPrompt(item) {
  const notePath = `${notesDir}/${item.noteName}`
  const head =
    `Tu es un sous-agent de distillation de veille. Topic : "${topic}".\n` +
    `Lis le brut JSON : ${item.rawPath}\n` +
    `Écris la note en FRANÇAIS dans : ${notePath}\n` +
    `Frontmatter (title, url, source, published, distilled_at: ${distilledAt}, vend) puis sections : ${SECTIONS}.\n` +
    `N'utilise JAMAIS le tiret cadratin (U+2014) (virgule, deux-points, point, ou "·").\n`

  let body = ''
  if (item.kind === 'video') {
    body =
      `Le brut contient un transcript (champ "text"). C'est de l'ASR : ponctuation imparfaite, noms propres écorchés, corrige silencieusement. ` +
      `Si "sub_kind" == "whisper", signale une fiabilité moindre en tête de note. NE fetch RIEN.`
  } else if (item.kind === 'social') {
    body =
      `Le brut peut contenir UN ou PLUSIEURS posts (Bluesky/X). NE fetch RIEN (le texte est dans le brut). ` +
      `Si plusieurs posts : 2-3 lignes par post (auteur, claim, lien). Reste sceptique : un post social = un claim non vérifié, marque-le.`
  } else if (item.kind === 'github') {
    body =
      `Récupère le README via WebFetch sur "${item.url}" (ou gh api). Sections orientées outil : ## Ce que fait l'outil, ## Stack & maturité ` +
      `(langage, étoiles, dernier commit, licence, maintenu ou non), ## Couvre-t-il le besoin ?, ## Pertinence. Risque = README sur-promesse/marketing.`
  } else {
    // article (Google News, HN, RSS, Lobsters, blog)
    body =
      `Récupère l'article complet via WebFetch sur "${item.url}". ` +
      `Si source commence par "r/" (Reddit) : NE fetch PAS (page commentaires = 403), distille depuis le champ "summary" du brut, marque "(commentaires non lus Â· Reddit 403)". ` +
      `URL Google News = redirection : suis la destination. Paywall/contenu vide → note minimale depuis title+summary, marquée "(paywall Â· non lu)".`
  }

  const tail =
    `\nLa section "Claims douteux" n'est pas optionnelle (sépare faits et marketing). ` +
    `Réponse finale = UNE seule ligne : "OK ${item.id} Â· <gist 15 mots>". AUCUN extrait long du brut dans ta réponse.`

  return head + body + tail
}

if (!items.length) {
  log('Aucun item dans la work-list : rien à distiller.')
  return { distilled: 0, results: [] }
}

phase('Distillation')
log(`${items.length} item(s) à distiller en parallèle vers ${notesDir}`)

// pipeline = pas de barrière : chaque item est distillé dès qu'un slot se libère.
const results = await pipeline(
  items,
  (prev, item, i) =>
    agent(buildPrompt(item), {
      label: `distill:${item.source || ''}:${item.id}`,
      phase: 'Distillation',
    }).then(
      (out) => ({ id: item.id, noteName: item.noteName, ok: true, gist: (out || '').trim() }),
      () => ({ id: item.id, noteName: item.noteName, ok: false, gist: 'échec distillation' })
    )
)

const ok = results.filter((r) => r && r.ok)
const ko = results.filter((r) => !r || !r.ok)
log(`Distillation terminée : ${ok.length} OK, ${ko.length} échec(s).`)

return {
  topic,
  distilled: ok.length,
  failed: ko.length,
  notes: ok.map((r) => r.noteName),
  failures: ko.map((r) => r && r.id),
  results,
}
