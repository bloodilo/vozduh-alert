#!/usr/bin/env python3
"""Парсер канала t.me/vrv_radar → Redis (ключ active_json) + контуры в /www/regions.

Цикл раз в 60 с. Состояние и геокэши — на волюме /data.
Канал читается напрямую, а если задан TME_PROXY — через проксю
(http://, socks5://, socks5h://); Nominatim всегда ходит напрямую.

Логика разбора идентична /opt/vrv-radar/parser.py с тачки 233:
активация «Опасность по БПЛА», фиксации «Фиксация [от N] БПЛА» (max за тревогу,
группа — флаг), «Отбой…» снимает; «опасность сохраняется» держит область.
"""
import hashlib
import html
import json
import os
import re
import time
import traceback
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import redis
import requests

DATA = "/data"
STATE_F = os.path.join(DATA, "state.json")
GEO_F = os.path.join(DATA, "geocache.json")
POLY_F = os.path.join(DATA, "polycache.json")
POLY_DIR = "/www/regions"
CHANNEL = "vrv_radar"
# только ASCII: urllib кодирует заголовки в latin-1, кириллица тут всё уронит
UA = "vozduh-alert/1.0 (https://xn----8sbeihi5atyufy.xn--p1ai)"
BACKFILL_MSGS = 200   # глубина истории при первом запуске
BACKFILL_PAGES_CAP = 20
CATCHUP_PAGES = 10    # потолок долистывания до last_id при шквале
TME_PROXY = os.environ.get("TME_PROXY", "")  # напр. socks5h://10.0.0.1:1080

R = redis.Redis(host=os.environ.get("REDIS_HOST", "127.0.0.1"), port=6379)

RE_CLEAR = re.compile(r"отбой", re.I)
RE_DANGER = re.compile(r"опасность по бпла|беспилотная опасность", re.I)
RE_FIX = re.compile(r"фиксац", re.I)
RE_REGION = re.compile(
    r"область|край|республика|автономн\w+ округ|москва|санкт-петербург|севастополь", re.I)
RE_KEEP = re.compile(r"опасность сохраняется", re.I)
RE_DISTLIKE = re.compile(r"район|округ|^ГО\b|^МО\b|город", re.I)


def fetch_page(query):
    """query: 'vrv_radar' или 'vrv_radar?before=123'."""
    r = requests.get(
        "https://t.me/s/" + query,
        headers={"User-Agent": "Mozilla/5.0"},
        proxies={"http": TME_PROXY, "https": TME_PROXY} if TME_PROXY else None,
        timeout=20)
    r.raise_for_status()
    return r.text


def parse_page(page):
    msgs = []
    for block in re.split(r'data-post="%s/' % CHANNEL, page)[1:]:
        mid = int(block.split('"', 1)[0])
        m = re.search(r'class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>', block, re.S)
        if not m:
            continue
        txt = re.sub(r"<br\s*/?>", "\n", m.group(1))
        txt = html.unescape(re.sub(r"<[^>]+>", "", txt))
        d = re.search(r'datetime="([^"]+)"', block)
        msgs.append((mid, d.group(1) if d else "", txt))
    return msgs


def classify(txt):
    lines = [l.strip() for l in txt.split("\n") if l.strip()]
    locs, event, keep = [], None, False
    fix_n, fix_group = 0, False
    for l in lines:
        if event is None:
            if RE_CLEAR.search(l):
                event = "clear"
            elif RE_FIX.search(l):
                event = "fix"
                m = re.search(r"от\s*(\d+)", l)
                fix_n = int(m.group(1)) if m else 1
                fix_group = bool(re.search(r"групп", l, re.I))
            elif RE_DANGER.search(l):
                event = "danger"
            else:
                locs.append(l)
        elif RE_KEEP.search(l):
            keep = True
    if event is None or not locs or len(locs) > 15:
        return None
    for l in locs:
        if len(l) > 60 or re.search(r"[!@:;]|http", l):
            return None
    return locs, event, keep, fix_n, fix_group


def units_of(locs):
    units, pending = [], []
    for l in locs:
        norm = re.sub(r"\s+", " ", l).strip(" .")
        if RE_REGION.search(norm):
            if pending:
                units += [(norm, d) for d in pending]
                pending = []
            else:
                units.append((norm, None))
        else:
            pending.append(norm)
    units += [(None, d) for d in pending if RE_DISTLIKE.search(d)]
    return units


def pretty(region, dist):
    return f"{dist} ({region})" if dist and region else (dist or region)


def apply(state, units, event, keep, when, fix_n=0, fix_group=False):
    active = state["active"]

    def close(key):  # снятая зона уходит в список отбоев
        info = active.pop(key, None)
        if info is not None:
            d, r = key.split("|", 1)
            state["cleared"].insert(0, {
                "key": key, "name": pretty(r or None, d or None),
                "level": "district" if d else "region",
                "since": info.get("since"), "at": when,
            })

    for region, dist in units:
        key = f"{dist or ''}|{region or ''}"
        if event == "clear":
            close(key)
            if dist is None and region:
                for k in [k for k in active if k.endswith("|" + region)]:
                    close(k)
            if keep and region:
                active.setdefault("|" + region, {"since": when, "danger": True})
        else:
            e = active.setdefault(key, {"since": when})
            if event == "danger":
                e["danger"] = True
            else:
                e["fix"] = max(e.get("fix", 0), fix_n)
                if fix_group:
                    e["group"] = True
                e["fix_at"] = when
    del state["cleared"][10:]


def build_queries(region, dist):
    name = re.sub(r"^(ГО|МО|г\.?|город)\s+", "", dist or region)
    names = [name]
    # «Туапсе и близлежащие» — выдумка канала; ищем сам топоним
    clean = re.sub(r"\s+и\s+близлежащ\w*.*$", "", name).strip()
    if clean and clean != name:
        names.append(clean)
    queries = []
    for nm in names:
        queries.append(", ".join(x for x in (nm, region if dist else None, "Россия") if x))
        if "район" in nm:
            for alt in (nm.replace("район", "муниципальный округ"),
                        nm.replace("район", "").strip()):
                queries.append(", ".join(x for x in (alt, region if dist else None) if x))
    return queries


def nominatim(q, extra=""):
    url = ("https://nominatim.openstreetmap.org/search?format=json&limit=1"
           + extra + "&q=" + urllib.parse.quote(q))
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        data = json.load(urllib.request.urlopen(req, timeout=30))
    except Exception:
        return None
    time.sleep(1.1)
    return data


def geocode(cache, region, dist):
    key = f"{dist or ''}|{region or ''}"
    if key in cache:
        return cache[key]
    for q in build_queries(region, dist):
        data = nominatim(q)
        if data is None:
            return None
        if data:
            cache[key] = [float(data[0]["lat"]), float(data[0]["lon"])]
            return cache[key]
    cache[key] = None
    return None


def get_polygon(polycache, region, dist):
    key = f"{dist or ''}|{region or ''}"
    if key in polycache:
        rel = polycache[key]
        # если файл контура пропал (контейнер пересоздали без волюма) —
        # выкидываем запись из кэша и перекачиваем
        if rel is None or os.path.exists(os.path.join(POLY_DIR, os.path.basename(rel))):
            return rel
        del polycache[key]
    for q in build_queries(region, dist):
        data = nominatim(q, "&polygon_geojson=1&polygon_threshold=0.01")
        if data is None:
            return None
        geom = data[0].get("geojson") if data else None
        if geom and geom.get("type") in ("Polygon", "MultiPolygon"):
            os.makedirs(POLY_DIR, exist_ok=True)
            rel = "regions/" + hashlib.md5(key.encode()).hexdigest()[:12] + ".json"
            dump_atomic(os.path.join(POLY_DIR, os.path.basename(rel)), geom)
            polycache[key] = rel
            return rel
    polycache[key] = None
    return None


def dump_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def load(path, default):
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return default


def cycle():
    state = load(STATE_F, {"last_id": 0, "active": {}})
    state.setdefault("events", [])   # лента последних событий (бегущая строка)
    state.setdefault("cleared", [])  # последние отбои
    cache = load(GEO_F, {})
    polycache = load(POLY_F, {})

    msgs = parse_page(fetch_page(CHANNEL))
    if not msgs:
        raise RuntimeError("empty page — разметка t.me изменилась?")
    # первый запуск — тянем последние BACKFILL_MSGS событий;
    # дальше — долистываем назад до last_id, чтобы шквал не терял сообщения
    first_run = state["last_id"] == 0
    oldest = msgs[0][0]
    pages = 0
    while (len(msgs) < BACKFILL_MSGS and pages < BACKFILL_PAGES_CAP) if first_run \
            else (oldest > state["last_id"] + 1 and pages < CATCHUP_PAGES):
        older = parse_page(fetch_page(f"{CHANNEL}?before={oldest}"))
        if not older:
            break
        msgs = older + msgs
        oldest = older[0][0]
        pages += 1

    new = sorted(m for m in msgs if m[0] > state["last_id"])
    for mid, when, txt in new:
        state["last_id"] = max(state["last_id"], mid)
        c = classify(txt)
        if not c:
            continue
        locs, event, keep, fix_n, fix_group = c
        units = units_of(locs)
        apply(state, units, event, keep, when, fix_n, fix_group)
        if units:
            state["events"].insert(0, {
                "at": when, "type": event, "fix": fix_n, "group": fix_group,
                "names": [pretty(r, d) for r, d in units],
                "key": f"{units[0][1] or ''}|{units[0][0] or ''}",
            })
    del state["events"][20:]

    cities = []
    for key, info in sorted(state["active"].items()):
        dist, region = key.split("|", 1)
        coords = geocode(cache, region or None, dist or None)
        entry = {
            "name": f"{dist} ({region})" if dist and region else (dist or region),
            "lat": coords[0] if coords else None,
            "lon": coords[1] if coords else None,
            "since": info["since"],
            "level": "district" if dist else "region",
            "danger": bool(info.get("danger")),
            "fix": info.get("fix", 0),
            "group": bool(info.get("group")),
            "fix_at": info.get("fix_at"),
            "poly": get_polygon(polycache, region or None, dist or None),
        }
        cities.append(entry)

    # лента событий и отбои — с координатами для зума/призраков на карте
    def coords_of(key):
        d, r = key.split("|", 1)
        c = geocode(cache, r or None, d or None)
        if not c and d and r:  # составное имя района не нашлось — центр области
            c = geocode(cache, r, None)
        return c

    events = []
    for e in state["events"]:
        c = coords_of(e["key"])
        events.append({"at": e["at"], "type": e["type"], "fix": e["fix"],
                       "group": e["group"], "names": e["names"],
                       "lat": c[0] if c else None, "lon": c[1] if c else None})
    cleared = []
    for e in state["cleared"]:
        d, r = e["key"].split("|", 1)
        c = coords_of(e["key"])
        cleared.append({"name": e["name"], "level": e["level"],
                        "since": e["since"], "at": e["at"],
                        "lat": c[0] if c else None, "lon": c[1] if c else None,
                        "poly": get_polygon(polycache, r or None, d or None)})

    dump_atomic(STATE_F, state)
    dump_atomic(GEO_F, cache)
    dump_atomic(POLY_F, polycache)

    now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    payload = json.dumps({"updated": now, "cities": cities,
                          "events": events, "cleared": cleared}, ensure_ascii=False)
    R.set("active_json", payload)
    R.set("active_ts", now)
    if new:
        print(f"{time.strftime('%F %T')} +{len(new)} msgs (last {state['last_id']}), "
              f"active={len(cities)}", flush=True)


if __name__ == "__main__":
    # при старте забываем кэшированные «не найдено»: после улучшений
    # геокодера такие имена могут начать находиться
    for _f in (GEO_F, POLY_F):
        try:
            _c = load(_f, {})
            _c2 = {k: v for k, v in _c.items() if v is not None}
            if len(_c2) != len(_c):
                dump_atomic(_f, _c2)
        except Exception:
            traceback.print_exc()
    while True:
        try:
            cycle()
        except Exception:
            traceback.print_exc()
        time.sleep(60)
