#!/usr/bin/env node
// fx.mjs · session Firefox persistante pour la veille (sources qui exigent un compte).
//
// Pourquoi Playwright et pas le Firefox du système : Playwright pilote Firefox par le
// protocole Juggler, qui n'existe que dans SA build. Pointer `executablePath` sur un
// Firefox installé donne un timeout de 30 s au lancement. Sa build embarquée est
// elle-même un Nightly (`ms-playwright/firefox-<n>/firefox/Nightly.app`), donc rien ne manque.
//
// Le profil est PERSISTANT : on se connecte une fois en fenêtre visible, et tous les
// runs suivants sont authentifiés. Vérifié le 2026-08-25 : cookie posé au run 1,
// retrouvé au run 2, absent d'un profil vierge (contrôle négatif).
//
// Usage :
//   node fx.mjs login [url ...]     ouvre une fenêtre visible ; se connecter, puis fermer la fenêtre
//   node fx.mjs status              liste les domaines qui ont des cookies (sans jamais les afficher)
//   node fx.mjs fetch <url>         corps brut via l'API HTTP (cookies partagés) · pour JSON/RSS/API
//   node fx.mjs dom <url>           HTML APRÈS exécution du JS · pour les SPA (VK, Brunch)
//

import { createRequire } from "module";
import { execSync } from "child_process";
import os from "os";
import path from "path";

// Résolution de playwright · NODE_PATH ne marche PAS ici. Node l'ignore pour les modules
// ESM et résout les imports nus en remontant les node_modules depuis CE fichier, dont il
// n'existe aucun entre ~/.claude/skills/veille et la racine. Mesuré le 2026-08-31 :
// ERR_MODULE_NOT_FOUND alors que playwright était bien installé en global. On le résout
// donc à l'exécution via `npm root -g`, ce qui reste portable d'une machine à l'autre.
const requireGlobal = createRequire(import.meta.url);
let firefox, chromium;
try {
  ({ firefox, chromium } = requireGlobal("playwright"));
} catch {
  const globalRoot = execSync("npm root -g", { encoding: "utf8" }).trim();
  ({ firefox, chromium } = requireGlobal(path.join(globalRoot, "playwright")));
}

const PROFILE =
  process.env.VEILLE_FX_PROFILE ||
  path.join(os.homedir(), ".config", "veille", "fx-profile");

const DEFAULT_LOGIN_URLS = [
  "https://vk.com/login",
  "https://passport.yandex.ru/auth",
  "https://developers.kakao.com/",
  "https://nid.naver.com/nidlogin.login",
];

const [cmd, ...rest] = process.argv.slice(2);

// Moteur réellement utilisé, pour que `login` affiche le bon binaire.
let ENGINE = "firefox";

async function open(headless) {
  const opts = {
    headless,
    viewport: { width: 1400, height: 900 },
    locale: "fr-FR",
    // 15 s : un Firefox sain démarre en quelques secondes ; sur une build cassée
    // (macOS 27, cf. commentaire du catch), il part en SIGKILL sans jamais répondre
    // et il ne faut PAS payer une à deux minutes d'attente à chaque appel.
    timeout: 15000,
  };
  try {
    const ctx = await firefox.launchPersistentContext(PROFILE, opts);
    ENGINE = "firefox";
    return ctx;
  } catch (e) {
    // PANNE MESURÉE LE 2026-09-23 : la build Firefox de Playwright (firefox-1538,
    // plugin-container signé ad hoc) est tuée par SIGKILL au lancement sur macOS 27
    // (sandbox_extension_issue_file_to_process ... Operation not permitted).
    // La réinstallation de la build ne corrige PAS. Repli Chromium, profil DISTINCT
    // (`-chromium`) car les cookies ne sont pas portables d'un moteur à l'autre :
    // une session par source est à refaire une fois. Le repli est annoncé, jamais muet.
    console.error(
      `firefox Playwright KO (${String(e.message).split("\n")[0].slice(0, 100)}) · repli Chromium, profil ${PROFILE}-chromium (re-login par source une fois)`,
    );
    ENGINE = "chromium";
    return chromium.launchPersistentContext(`${PROFILE}-chromium`, opts);
  }
}

if (cmd === "login") {
  const urls = rest.length ? rest : DEFAULT_LOGIN_URLS;
  const ctx = await open(false);
  console.error(`profil : ${PROFILE}`);
  console.error(`binaire : ${(ENGINE === "firefox" ? firefox : chromium).executablePath()}`);
  for (const u of urls) {
    const p = await ctx.newPage();
    p.goto(u, { waitUntil: "domcontentloaded", timeout: 45000 }).catch((e) =>
      console.error(`  ouverture ${u} : ${e.message.split("\n")[0]}`),
    );
  }
  console.error(
    `\n${urls.length} onglets ouverts. Se connecter, puis FERMER la fenêtre.`,
  );
  // BUG PAYÉ LE 2026-08-25 : tuer le processus au `pkill` coupe Firefox avant qu'il écrive
  // ses cookies sur disque, donc la session est PERDUE alors que l'utilisateur s'était bien
  // connecté (constaté deux fois de suite, et à tort mis sur le dos de l'utilisateur).
  // On intercepte SIGTERM/SIGINT pour fermer le contexte proprement d'abord.
  let closing = false;
  const graceful = async (sig) => {
    if (closing) return;
    closing = true;
    console.error(
      `\n${sig} reçu : fermeture propre du contexte pour enregistrer la session.`,
    );
    try {
      await ctx.close();
    } catch {}
    process.exit(0);
  };
  process.on("SIGTERM", () => graceful("SIGTERM"));
  process.on("SIGINT", () => graceful("SIGINT"));

  // Fin quand l'utilisateur ferme la fenêtre, ou au bout de 45 min.
  await Promise.race([
    new Promise((r) => ctx.on("close", r)),
    new Promise((r) => setTimeout(r, 45 * 60 * 1000)),
  ]);
  console.error("session fermée, profil enregistré.");
  process.exit(0);
}

if (cmd === "status") {
  const ctx = await open(true);
  const cookies = await ctx.cookies();
  const byDomain = {};
  for (const c of cookies) byDomain[c.domain] = (byDomain[c.domain] || 0) + 1;
  const rows = Object.entries(byDomain).sort((a, b) => b[1] - a[1]);
  console.log(`profil : ${PROFILE}`);
  console.log(
    `domaines avec cookies : ${rows.length} · cookies au total : ${cookies.length}`,
  );
  for (const [d, n] of rows) console.log(`  ${String(n).padStart(4)}  ${d}`);
  await ctx.close();
  process.exit(0);
}

if (cmd === "fetch" || cmd === "dom") {
  const url = rest[0];
  if (!url) {
    console.error("url manquante");
    process.exit(2);
  }
  const ctx = await open(true);
  try {
    if (cmd === "fetch") {
      // APIRequestContext : partage le cookie jar, pas de rendu, pas de JS. Idéal API/RSS.
      const r = await ctx.request.get(url, { timeout: 30000 });
      console.error(`HTTP ${r.status()}`);
      process.stdout.write(await r.text());
    } else {
      const p = await ctx.newPage();
      const r = await p.goto(url, { waitUntil: "networkidle", timeout: 45000 });
      console.error(`HTTP ${r ? r.status() : "?"}`);
      process.stdout.write(await p.content());
    }
  } finally {
    await ctx.close();
  }
  process.exit(0);
}

console.error(`usage : node fx.mjs login|status|fetch <url>|dom <url>`);
process.exit(2);
