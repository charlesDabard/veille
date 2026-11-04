#!/usr/bin/env python3
"""Récap RSS multi-flux → TSV compact sur stdout (pattern camilleroux/veille-techno).

Fait 100% du travail mécanique en Python (fetch parallèle, parse RSS 2.0/Atom,
filtre par date, filtre regex optionnel, dédup par URL, tri) pour que le modèle
ne reçoive qu'un TSV court à formater : économie de tokens vs une boucle de
curl par flux. Stdlib uniquement, zéro dépendance.

Usage :
    fetch_feeds.py [JOURS] [--feeds FICHIER] [--filter REGEX]

    JOURS    : fenêtre en jours (défaut 7)
    --feeds  : liste de flux, 1 URL/ligne, # = commentaire
               (défaut ~/.config/veille/feeds.txt)
    --filter : regex casse-insensible appliquée à titre+résumé (le $KW du skill)

Sortie TSV (1 item/ligne, tabs et retours ligne nettoyés) :
    date ISO \t source \t titre \t url \t résumé (300 car.)
Diagnostics (flux en erreur, comptes) sur stderr uniquement.
"""
import argparse
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path

ATOM = "{http://www.w3.org/2005/Atom}"
UA = "veille-skill/1.0 (personal RSS reader)"


def strip_html(s):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", s or "")).strip()


def parse_date(s):
    s = (s or "").strip()
    if not s:
        return None
    try:  # RFC 822 (RSS 2.0)
        return parsedate_to_datetime(s)
    except (TypeError, ValueError):
        pass
    try:  # ISO 8601 (Atom)
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_feed(data, feed_url):
    """→ liste de (dt, source, titre, url, résumé).

    Garde anti billion-laughs/XXE sans dépendance (un flux légitime n'a jamais
    de DTD) : scan du document ENTIER, pas seulement du prologue, car du padding
    peut repousser la DTD au-delà des premiers Ko.
    """
    if b"\x00" in data[:4]:
        raise ValueError("flux UTF-16/UTF-32 refusé (la garde DTD ne lit que l'UTF-8)")
    if re.search(rb"<!(DOCTYPE|ENTITY)", data, re.IGNORECASE):
        raise ValueError("DTD/ENTITY détecté (XML suspect)")
    root = ET.fromstring(data)
    items = []
    rss_items = root.findall(".//item")
    if rss_items:  # RSS 2.0
        source = strip_html(root.findtext(".//channel/title")) or feed_url
        for it in rss_items:
            items.append((parse_date(it.findtext("pubDate")), source,
                          strip_html(it.findtext("title")),
                          (it.findtext("link") or "").strip(),
                          strip_html(it.findtext("description"))))
    else:  # Atom
        source = strip_html(root.findtext(f"{ATOM}title")) or feed_url
        for e in root.findall(f"{ATOM}entry"):
            url = next((l.get("href") for l in e.findall(f"{ATOM}link")
                        if l.get("rel") in (None, "alternate")), None)
            items.append((parse_date(e.findtext(f"{ATOM}published")
                                     or e.findtext(f"{ATOM}updated")), source,
                          strip_html(e.findtext(f"{ATOM}title")), (url or "").strip(),
                          strip_html(e.findtext(f"{ATOM}summary")
                                     or e.findtext(f"{ATOM}content"))))
    return items


def fetch(feed_url):
    req = urllib.request.Request(feed_url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return parse_feed(resp.read(), feed_url)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("days", nargs="?", type=int, default=7)
    ap.add_argument("--feeds", default=str(Path.home() / ".config/veille/feeds.txt"))
    ap.add_argument("--filter", default=None, metavar="REGEX")
    args = ap.parse_args()

    lines = Path(args.feeds).read_text().splitlines()
    urls = [l.strip() for l in lines if l.strip() and not l.strip().startswith("#")]
    if not urls:
        sys.exit(f"fetch_feeds: aucun flux dans {args.feeds}")

    cutoff = datetime.now(timezone.utc) - timedelta(days=args.days)
    kw = re.compile(args.filter, re.IGNORECASE) if args.filter else None

    all_items, errors = [], []
    with ThreadPoolExecutor(max_workers=min(8, len(urls))) as pool:
        for url, fut in [(u, pool.submit(fetch, u)) for u in urls]:
            try:
                all_items.extend(fut.result())
            except Exception as e:
                errors.append(f"  ✗ {url} : {e}")

    seen, kept = set(), []
    for dt, source, title, url, summary in all_items:
        if not url or url in seen:
            continue
        seen.add(url)
        if dt is None or dt.tzinfo is None:
            dt = (dt or datetime.now(timezone.utc)).replace(tzinfo=timezone.utc)
        if dt < cutoff:
            continue
        if kw and not (kw.search(title) or kw.search(summary)):
            continue
        kept.append((dt, source, title, url, summary[:300]))

    kept.sort(key=lambda t: t[0], reverse=True)
    clean = lambda s: re.sub(r"[\t\r\n]+", " ", s)
    for dt, source, title, url, summary in kept:
        print("\t".join([dt.strftime("%Y-%m-%d"), clean(source), clean(title),
                         clean(url), clean(summary)]))

    print(f"fetch_feeds: {len(urls)} flux, {len(all_items)} items bruts, "
          f"{len(kept)} gardés (fenêtre {args.days} j"
          f"{', filtre ' + repr(args.filter) if args.filter else ''})", file=sys.stderr)
    if errors:
        print("\n".join(errors), file=sys.stderr)


if __name__ == "__main__":
    main()
