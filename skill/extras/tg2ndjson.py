#!/usr/bin/env python3
# stdin = HTML de https://t.me/s/<canal>[?q=...][&before=...]
# stdout = NDJSON {id, title, url, published, source, summary}
# Aperçu web public de Telegram : ni compte, ni token, ni cookie.
# Mode d'échec : canal inexistant ou aperçu désactivé -> 200 avec 0 occurrence de
# `tgme_widget_message_wrap`, donc sortie vide. Ce n'est pas une erreur, ne pas insister.
import re, sys, html, json

s = sys.stdin.read()
for b in re.split(r'(?=<div class="tgme_widget_message_wrap)', s)[1:]:
    dp = re.search(r'data-post="([^"]+)"', b)
    if not dp:
        continue
    post = dp.group(1)                      # ex: data_secrets/9722
    tm = re.search(r'<time[^>]+datetime="([^"]+)"', b)
    tx = re.search(r'<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>\s*'
                   r'(?:<div class="tgme_widget_message_(?:footer|reply_markup)'
                   r'|<div class="tgme_widget_message_bubble_end)', b, re.S) \
         or re.search(r'<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>', b, re.S)
    txt = re.sub(r'<br\s*/?>', '\n', tx.group(1) if tx else '')
    txt = html.unescape(re.sub(r'<[^>]+>', '', txt)).strip()
    views = re.search(r'<span class="tgme_widget_message_views">([^<]+)</span>', b)
    print(json.dumps({
        "id": "tg-" + post.replace('/', '-'),
        "title": (txt.split('\n')[0][:110] or '(sans texte)'),
        "url": "https://t.me/" + post,
        "published": tm.group(1) if tm else None,
        "source": "Telegram/@" + post.split('/')[0],
        "summary": txt[:1500] + (' …' if len(txt) > 1500 else '')
                   + (f" [{views.group(1)} vues]" if views else ""),
    }, ensure_ascii=False))
