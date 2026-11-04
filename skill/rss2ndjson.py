#!/usr/bin/env python3
"""RSS 2.0 / Atom sur stdin → NDJSON sur stdout (1 item par ligne).

Stdlib uniquement · le python3 d'origine de macOS suffit, zéro dépendance.
Utilisé par le skill veille (volet veille web) pour normaliser toutes
les sources flux (Google News, subreddits, blogs…) dans un format unique,
filtrable en aval avec jq.

Champs émis : id (sha1 court de l'URL · clé d'idempotence), title, url,
published, source, summary (texte nu, tronqué à 500 caractères).
"""
import hashlib
import json
import re
import sys
import xml.etree.ElementTree as ET

ATOM = "{http://www.w3.org/2005/Atom}"


def strip_html(s):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", s or "")).strip()


def emit(title, url, published, source, summary):
    url = (url or "").strip()
    if not url:
        return
    # Reddit : la page de commentaires renvoie 403 à WebFetch, mais le corps du post
    # est DÉJÀ dans le flux (<content>). On le garde quasi entier (4000) pour que la
    # distillation s'appuie dessus sans fetch. Autres flux : 500 suffit pour la table.
    cap = 4000 if "reddit.com" in url else 500
    print(json.dumps({
        "id": hashlib.sha1(url.encode()).hexdigest()[:12],
        "title": strip_html(title),
        "url": url,
        "published": (published or "").strip(),
        "source": strip_html(source),
        "summary": strip_html(summary)[:cap],
    }, ensure_ascii=False))


data = sys.stdin.buffer.read()
# Garde anti billion-laughs/XXE sans dépendance : un flux légitime n'a jamais de DTD.
if re.search(rb"<!(DOCTYPE|ENTITY)", data[:4096], re.IGNORECASE):
    sys.exit("rss2ndjson: DTD/ENTITY détecté dans le flux · refusé (XML suspect)")
if not data.strip():
    sys.exit("rss2ndjson: flux vide · la source n'a rien rendu (URL morte, blocage, ou curl sans -L)")
try:
    root = ET.fromstring(data)
except ET.ParseError as e:
    sys.exit(f"rss2ndjson: XML illisible ({e}) · téléchargement tronqué ou page HTML d'erreur, relancer avec curl -sL --compressed --max-time 30")

rss_items = root.findall(".//item")
if rss_items:  # RSS 2.0
    chan_title = root.findtext(".//channel/title") or ""
    for it in rss_items:
        emit(it.findtext("title"), it.findtext("link"), it.findtext("pubDate"),
             it.findtext("source") or chan_title, it.findtext("description"))
else:  # Atom
    feed_title = root.findtext(f"{ATOM}title") or ""
    for e in root.findall(f"{ATOM}entry"):
        url = next((l.get("href") for l in e.findall(f"{ATOM}link")
                    if l.get("rel") in (None, "alternate")), None)
        emit(e.findtext(f"{ATOM}title"), url,
             e.findtext(f"{ATOM}published") or e.findtext(f"{ATOM}updated"),
             feed_title,
             e.findtext(f"{ATOM}summary") or e.findtext(f"{ATOM}content"))
