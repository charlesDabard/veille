#!/usr/bin/env node
// vk.mjs · récolte VK pour la veille, SANS compte VK.
//
// VK n'a aucune voie directe : l'API exige un token, le token exige un compte développeur,
// le compte exige un téléphone. Mesuré le 2026-08-25, tous les chemins first-party fermés.
// La voie qui marche, mesurée le 2026-08-26, combine DEUX mécanismes distincts :
//
//   RECHERCHE · Yandex `site:vk.com <requête>` rend des URLs de posts VK directes.
//               Exige la session Yandex du profil `fx.mjs` (sinon SmartCaptcha).
//   LECTURE   · `m.vk.com/wall<id>_<postid>` est rendu SERVEUR : texte complet, date,
//               sans compte, sans token, sans cookie. C'est le site mobile qui sauve tout,
//               le site desktop ne rend qu'une coquille SPA.
//
// Le mur entier d'un groupe se lit aussi sans recherche :
//   `m.vk.com/wall-<gid>?own=1&offset=N` (20 posts par page, offset par pas de 20).
//
// Usage :
//   node vk.mjs search "<requête>" [n]     recherche via Yandex puis lecture, NDJSON sur stdout
//   node vk.mjs wall <-gid> [pages]        mur d'un groupe, sans recherche, NDJSON sur stdout
//

import { createRequire } from "module";
import { execSync } from "child_process";
import os from "os";
import path from "path";
import crypto from "crypto";

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

// Dates VK localisées, et sans année quand c'est l'année courante.
// PIÈGE MESURÉ le 2026-08-26 : `locale` passé à launchPersistentContext NE PREND PAS sur un
// profil DÉJÀ CRÉÉ, le profil garde sa langue (ici fr-FR). Symptôme : 3 dates nulles sur 4,
// et un champ source qui disait « Post sur le mur » au lieu de « Wall post ».
// On parse donc les DEUX langues au lieu de compter sur le forçage de locale.
const MOIS = {
  jan: 0, feb: 1, mar: 2, apr: 3, may: 4, jun: 5,
  jul: 6, aug: 7, sep: 8, oct: 9, nov: 10, dec: 11,
  janv: 0, fevr: 1, avri: 3, mai: 4, juin: 5,
  juil: 6, aout: 7, sept: 8, octo: 9, nove: 10, dece: 11,
};
// « é » et « û » cassent le match : on translittère avant de chercher le mois.
const norm = (s) =>
  s.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "")
   .replace(/[^a-z0-9: ]/g, " ").replace(/\s+/g, " ").trim();

function parseDate(s, refIso) {
  if (!s) return null;
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return new Date(s).toISOString();
  const t = norm(s);
  const ref = new Date(refIso);
  const hm = t.match(/(\d{1,2}):(\d{2})/);
  const h = hm ? +hm[1] : 12, mi = hm ? +hm[2] : 0;
  const jour = (delta) =>
    new Date(Date.UTC(ref.getUTCFullYear(), ref.getUTCMonth(), ref.getUTCDate() - delta, h, mi)).toISOString();
  if (/today|aujourd/.test(t)) return jour(0);
  if (/yesterday|hier/.test(t)) return jour(1);
  // « 25 mai a 12:47 », « 4 fevr 2025 », « 25 may at 12:47 »
  const m = t.match(/(\d{1,2}) ([a-z]{3,4})[a-z]*(?: (\d{4}))?/);
  if (!m) return null;
  // « mars » et « mar » collident : 4 lettres d'abord, 3 en repli.
  const mois = MOIS[m[2].slice(0, 4)] ?? MOIS[m[2].slice(0, 3)];
  if (mois === undefined) return null;
  // Sans année explicite, VK sous-entend l'année courante ; si ça tombe dans le futur, c'est l'an dernier.
  const an = m[3] ? +m[3] : ref.getUTCFullYear();
  const d = new Date(Date.UTC(an, mois, +m[1], h, mi));
  if (!m[3] && d > ref) d.setUTCFullYear(an - 1);
  return d.toISOString();
}

const sid = (u) =>
  "vk-" + crypto.createHash("sha1").update(u).digest("hex").slice(0, 12);

async function open() {
  const opts = {
    headless: true,
    viewport: { width: 900, height: 1200 },
    locale: "en-GB", // dates parsables, cf. parseDate
    extraHTTPHeaders: { "Accept-Language": "en-GB,en;q=0.9" },
    // 15 s : un Firefox sain démarre en quelques secondes ; sur la build cassée
    // (macOS 27, cf. catch), il part en SIGKILL sans répondre.
    timeout: 15000,
  };
  try {
    return await firefox.launchPersistentContext(PROFILE, opts);
  } catch (e) {
    // Même panne que fx.mjs, même repli (mesuré le 2026-09-23) : la build Firefox de
    // Playwright est SIGKILL au lancement sur macOS 27, la réinstallation ne corrige
    // pas. Chromium avec profil distinct (`-chromium`) : le profil Firefox n'est pas
    // portable, donc la session Yandex (utile au mode search) est à refaire une fois.
    console.error(
      `firefox Playwright KO (${String(e.message).split("\n")[0].slice(0, 100)}) · repli Chromium, profil ${PROFILE}-chromium (re-login Yandex une fois pour le mode search)`,
    );
    return chromium.launchPersistentContext(`${PROFILE}-chromium`, opts);
  }
}

// Lit UN post sur le site mobile. Rend null si le post est inaccessible (supprimé, privé).
async function lirePost(ctx, url, refIso) {
  const m = url.replace(
    /^https?:\/\/(m\.)?vk\.(com|ru)\//,
    "https://m.vk.com/",
  );
  const p = await ctx.newPage();
  try {
    await p.goto(m, { waitUntil: "domcontentloaded", timeout: 30000 });
    await p.waitForTimeout(2500);
    const r = await p.evaluate(() => {
      const el = document.querySelector(
        '.pi_text, .wall_post_text, [class*="post_text"]',
      );
      const tm = document.querySelector("time");
      return {
        txt: (el?.innerText || "").trim(),
        date:
          tm?.getAttribute("datetime") ||
          document.querySelector('.pi_date, [class*="date"]')?.innerText ||
          "",
        auteur: (
          document.querySelector(
            '.pi_author, [class*="author"], h1, .op_header',
          )?.innerText || ""
        )
          .trim()
          .slice(0, 80),
      };
    });
    if (!r.txt || r.txt.length < 20) return null;
    return {
      id: sid(url),
      title: r.txt.split("\n")[0].slice(0, 110),
      url,
      published: parseDate(r.date, refIso),
      source: "VK" + (r.auteur ? "/" + r.auteur.replace(/\s+/g, " ") : ""),
      summary: r.txt.slice(0, 1500) + (r.txt.length > 1500 ? " …" : ""),
    };
  } catch {
    return null;
  } finally {
    await p.close();
  }
}

const [cmd, arg, arg2] = process.argv.slice(2);
const refIso = process.env.VEILLE_NOW || new Date().toISOString();

if (cmd === "search") {
  if (!arg) {
    console.error("requête manquante");
    process.exit(2);
  }
  const ctx = await open();
  const p = await ctx.newPage();
  await p.goto(
    `https://yandex.ru/search/?text=${encodeURIComponent("site:vk.com " + arg)}`,
    { waitUntil: "domcontentloaded", timeout: 45000 },
  );
  await p.waitForTimeout(5000);
  const { captcha, urls } = await p.evaluate(() => ({
    captcha: /showcaptcha|Подтвердите, что запросы/i.test(
      document.body.innerHTML,
    ),
    urls: [
      ...new Set(
        [...document.querySelectorAll('a[href*="vk.com"]')]
          .map((a) => a.href)
          .filter((h) => /vk\.com\/wall-?\d+_\d+/.test(h))
          .map((h) => h.split("?")[0]),
      ),
    ],
  }));
  await p.close();
  if (captcha) {
    console.error(
      "SmartCaptcha : la session Yandex est perdue. Relancer `node fx.mjs login` et se reconnecter.",
    );
    await ctx.close();
    process.exit(3);
  }
  console.error(`Yandex : ${urls.length} posts VK trouvés`);
  const max = Math.min(urls.length, arg2 ? +arg2 : 20);
  for (const u of urls.slice(0, max)) {
    const o = await lirePost(ctx, u, refIso);
    if (o) console.log(JSON.stringify(o));
  }
  await ctx.close();
  process.exit(0);
}

if (cmd === "wall") {
  if (!arg) {
    console.error("gid manquant (ex: -30666517)");
    process.exit(2);
  }
  const pages = arg2 ? +arg2 : 2;
  const ctx = await open();
  const vus = new Set();
  for (let i = 0; i < pages; i++) {
    const p = await ctx.newPage();
    try {
      await p.goto(`https://m.vk.com/wall${arg}?own=1&offset=${i * 20}`, {
        // networkidle, PAS domcontentloaded. Mesuré le 2026-08-31 : avec domcontentloaded
        // plus une attente fixe, le mur rend 0 noeud même à 8 s, alors que networkidle en
        // rend 90. La note de 2026-08-26 disant l'inverse portait sur le VK desktop.
        waitUntil: "networkidle",
        timeout: 45000,
      });
      await p.waitForTimeout(2000);
      const posts = await p.evaluate(() => {
        const out = [];
        document.querySelectorAll("[data-post-id]").forEach((el) => {
          const pid = el.getAttribute("data-post-id");
          const txt = (
            el.querySelector('.pi_text, [class*="post_text"]')?.innerText || ""
          ).trim();
          const tm = el.querySelector("time");
          const date =
            tm?.getAttribute("datetime") ||
            el.querySelector('.pi_date, [class*="date"]')?.innerText ||
            "";
          if (pid && txt.length > 20) out.push({ pid, txt, date });
        });
        return out;
      });
      for (const q of posts) {
        const url = `https://vk.com/wall${q.pid}`;
        if (vus.has(url)) continue;
        vus.add(url);
        console.log(
          JSON.stringify({
            id: sid(url),
            title: q.txt.split("\n")[0].slice(0, 110),
            url,
            published: parseDate(q.date, refIso),
            source: "VK/wall" + arg,
            summary: q.txt.slice(0, 1500) + (q.txt.length > 1500 ? " …" : ""),
          }),
        );
      }
    } catch (e) {
      console.error(`page ${i} : ${e.message.split("\n")[0]}`);
    } finally {
      await p.close();
    }
  }
  console.error(`${vus.size} posts uniques sur ${pages} pages`);
  await ctx.close();
  process.exit(0);
}

console.error(
  'usage : node vk.mjs search "<requête>" [n] | wall <-gid> [pages]',
);
process.exit(2);
