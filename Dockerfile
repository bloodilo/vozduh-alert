# syntax=docker/dockerfile:1
# воздух-алерт.рф — карта тревог БПЛА по каналу t.me/vrv_radar.
# Всё в одном контейнере: nginx (статика+микрокэш+TLS) + redis (active.json в памяти)
#                         + parser (цикл 60с) + api (aiohttp).
# Требуется BuildKit (docker 23+, либо DOCKER_BUILDKIT=1 при docker 20.10+).
# Сборка:  docker build -t vozduh-alert .
# Запуск:  см. docker-compose.yml (порты 80+443, волюмы ./data, ./certs, ./acme).
#   TLS: nginx внутри слушает 443; серты кладутся в волюм /certs
#   (fullchain.pem + privkey.pem), без них старт с самоподписанным.
#   80-й отдаёт ACME-webroot из /acme и редиректит на https.
#   env TME_PROXY — прокся для чтения t.me, если из ДЦ он недоступен:
#       http://user:pass@host:port | socks5://... | socks5h://... (рекомендуется).
#       Через проксю ходит только t.me, Nominatim — напрямую.
FROM python:3.12-alpine

RUN apk add --no-cache nginx redis openssl \
 && pip install --no-cache-dir aiohttp redis "requests[socks]"

# Leaflet 1.9.4 самохостом и иконка БПЛА (качаются при сборке)
RUN mkdir -p /www/vendor/leaflet/images /www/regions /data /acme /certs \
 && cd /www/vendor/leaflet \
 && wget -q https://unpkg.com/leaflet@1.9.4/dist/leaflet.css \
            https://unpkg.com/leaflet@1.9.4/dist/leaflet.js \
 && cd images \
 && for f in marker-icon.png marker-icon-2x.png marker-shadow.png layers.png layers-2x.png; do \
      wget -q https://unpkg.com/leaflet@1.9.4/dist/images/$f; done \
 && wget -q -O /www/free-icon-uav-8598680.png \
      https://cdn-icons-png.flaticon.com/512/8598/8598680.png \
 && wget -q -O /www/vendor/protomaps-leaflet.js \
      https://unpkg.com/protomaps-leaflet@5.1.0/dist/protomaps-leaflet.js
# Подложка — свои векторные тайлы (см. basemap.pmtiles в docker-compose:
# файл большой, в образ не зашивается, монтируется волюмом)

COPY <<'HTMLEOF' /www/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Радар ВРВ — карта тревог</title>
<link rel="stylesheet" href="vendor/leaflet/leaflet.css">
<style>
  html, body { margin: 0; height: 100%; }
  #map { height: 100%; }
  .panel {
    position: absolute; top: 12px; right: 12px; z-index: 1000;
    background: rgba(255,255,255,.93); border-radius: 10px;
    box-shadow: 0 2px 10px rgba(0,0,0,.25);
    padding: 12px 16px; font: 14px/1.45 system-ui, sans-serif;
    max-width: 260px; max-height: calc(100vh - 24px); overflow-y: auto;
    box-sizing: border-box;
  }
  .panel h1 { margin: 0 0 6px; font-size: 16px; }
  .panel .meta { color: #666; font-size: 12px; margin-bottom: 8px; }
  .panel ul { margin: 8px 0 0; padding: 8px 0 0; border-top: 1px solid #ddd; list-style: none; }
  .panel li { margin: 2px 0; }
  .panel summary { cursor: pointer; }
  .panel summary:hover { color: #000; }
  .panel details .det { color: #555; font-size: 12px; padding: 2px 0 4px 16px; }
  .panel details.dim > summary { opacity: .4; }
  .panel .rgroup > summary { font-weight: 600; }
  .panel .sub { list-style: none; margin: 0; padding: 0 0 2px 16px; border-top: none; }
  .panel .empty { color: #888; font-style: italic; }
  .legend { margin: 8px 0 6px; padding-top: 8px; border-top: 1px solid #ddd; font-size: 12px; }
  .legend div { display: flex; align-items: center; gap: 6px; margin: 3px 0; }
  .legend b { margin-left: auto; padding-left: 8px; align-self: center; }
  .legend .lbl { line-height: 1.25; }
  .legend .sw { width: 14px; height: 14px; border-radius: 3px; flex: none; }
  .legend .sw.region { background: rgba(255,149,0,.35); border: 1.5px solid #c25e00; }
  .legend .sw.district { background: rgba(255,59,48,.45); border: 1.5px solid #d40000; }
  .legend .sw.fixzone { background: rgba(255,59,48,.12); border: 1.5px dashed #d40000; }
  .legend .sw.drone { background: none; border: none; display: flex; align-items: center; justify-content: center; }
  .legend .sw.drone img { width: 16px; height: 16px; }
  .legend .sw.stale { background: none; border: none; font-size: 13px; display: flex; align-items: center; justify-content: center; }
  .staleic { cursor: help; }
  .drone-div { background: none; border: none; }
  .drones { display: flex; align-items: center; }
  .drones img { width: 26px; height: 26px;
    filter: drop-shadow(0 0 1.5px #fff) drop-shadow(0 1px 2px rgba(0,0,0,.45)); }
  .drones img + img { margin-left: -18px; } /* колода: каждая следующая поверх, хвосты слева */
  .drones .more { font: bold 12px system-ui, sans-serif; color: #1a1a1a;
    text-shadow: 0 0 2px #fff, 0 0 2px #fff; margin-right: 3px; }

  /* бегущая строка событий */
  #ticker { position: absolute; left: 0; right: 0; bottom: 0; z-index: 1000;
    display: flex; align-items: center; height: 30px;
    background: rgba(255,255,255,.93); border-top: 1px solid #ddd;
    font: 12px/30px system-ui, sans-serif; }
  #followBtn { flex: none; border: none; background: none; color: #666;
    padding: 0 10px; cursor: pointer; height: 100%; display: flex; align-items: center; }
  #followBtn.on { color: #1a73e8; background: #cfe1ff; box-shadow: inset 0 -2px 0 #1a73e8; }
  html.dark #followBtn { color: #9a9aa0; }
  html.dark #followBtn.on { color: #cfe1ff; background: #44608f; box-shadow: inset 0 -2px 0 #8ab4f8; }
  .tickwrap { flex: 1; overflow: hidden; }
  #tick { display: inline-flex; white-space: nowrap;
    animation: tickmove 60s linear infinite; }
  .tickitem { padding-right: 70px; }
  .tickwrap:hover #tick { animation-play-state: paused; }
  @keyframes tickmove { to { transform: translateX(-50%); } }
  #themeBtn { flex: none; border: none; background: none; font-size: 15px;
    padding: 0 10px; cursor: pointer; height: 100%; }
  .leaflet-bottom { bottom: 30px; }

  /* отбои в панели */
  .panel .clearedgrp > summary { font-weight: 600; color: #2e7d32; }
  .panel .clearedit { color: #2e7d32; font-size: 12px; margin: 2px 0; cursor: pointer; }
  .panel .clearedit:hover { color: #1b5e20; }

  /* мобилка: панель в нижний левый угол, компактнее */
  @media (max-width: 640px) {
    .panel {
      top: auto; right: auto; bottom: 42px; left: 12px;
      max-width: min(80vw, 300px); max-height: 46vh;
      font-size: 13px; padding: 10px 12px;
    }
  }

  /* тёмная тема: класс html.dark; при загрузке берётся из localStorage
     или системной настройки, переключается кнопкой 🌓 */
  html.dark .leaflet-container { background: #111; }
  html.dark .leaflet-container .leaflet-control-attribution { background: rgba(28,28,30,.8); color: #9a9aa0; }
  html.dark .leaflet-control-attribution a { color: #8ab4f8; }
  html.dark .leaflet-popup-content-wrapper, html.dark .leaflet-popup-tip { background: #232326; color: #e4e4e6; }
  html.dark .leaflet-bar a { background: #232326; color: #e4e4e6; border-color: #46464c; }
  html.dark .panel { background: rgba(28,28,30,.92); color: #e4e4e6; }
  html.dark .panel a { color: #8ab4f8; }
  html.dark .panel .meta { color: #9a9aa0; }
  html.dark .panel summary:hover { color: #fff; }
  html.dark .panel details .det { color: #a7a7ad; }
  html.dark .panel ul, html.dark .legend { border-color: #46464c; }
  html.dark .legend .sw.fixzone { background: rgba(255,59,48,.18); }
  html.dark .drones .more { color: #eee; text-shadow: 0 0 2px #000, 0 0 2px #000; }
  html.dark #ticker { background: rgba(28,28,30,.92); border-color: #46464c; color: #e4e4e6; }
  html.dark .panel .clearedgrp > summary, html.dark .panel .clearedit { color: #66bb6a; }
  html.dark .panel .clearedit:hover { color: #a5d6a7; }
</style>
</head>
<body>
<div id="map"></div>
<div class="panel">
  <h1>Опасность БПЛА</h1>
  <div class="meta">по данным <a href="https://t.me/vrv_radar" target="_blank" rel="noopener">Радар ВРВ</a></div>
  <div class="meta" id="updated">загрузка…</div>
  <div class="legend">
    <div><span class="sw region"></span> опасность по всей области<b id="n-region"></b></div>
    <div><span class="sw district"></span> опасность в районе / округе<b id="n-district"></b></div>
    <div><span class="sw fixzone"></span><span class="lbl">только фиксация,<br>опасность не объявлена</span><b id="n-fixzone"></b></div>
    <div><span class="sw drone" id="drone-sw"></span> фиксация БПЛА<b id="n-uav"></b></div>
    <div id="stale-row"><span class="sw stale">⏳</span><span class="lbl">без обновлений &gt;100 ч<br>(возможно, пропущен отбой)</span><b id="n-stale"></b></div>
  </div>
  <ul id="list"></ul>
</div>
<div id="ticker">
  <button id="followBtn" title="Автослежение: зумить карту к новым событиям"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M1 12s4-7 11-7 11 7 11 7-4 7-11 7S1 12 1 12z"/><circle cx="12" cy="12" r="3"/></svg></button>
  <div class="tickwrap"><div id="tick"></div></div>
  <button id="themeBtn" title="Светлая/тёмная тема">🌓</button>
</div>
<script src="vendor/leaflet/leaflet.js"></script>
<script src="vendor/protomaps-leaflet.js"></script>
<script>
const map = L.map('map');
map.fitBounds([[43, 25], [62, 60]]); // европейская часть РФ; после загрузки данных подгонимся под зоны
map.attributionControl.setPrefix(false);
map.on('click', () => { // клик по пустому месту: снять выделение / показать все тревоги
  if (suppressMapClick) { suppressMapClick = false; return; }
  if (selected) { selected = null; applySelection(); }
  resetView();
});

// кнопка «показать всё»: сброс выделения + общий вид
const HomeCtl = L.Control.extend({
  options: { position: 'topleft' },
  onAdd() {
    const div = L.DomUtil.create('div', 'leaflet-bar');
    const a = L.DomUtil.create('a', '', div);
    a.href = '#';
    a.innerHTML = '⌂';
    a.title = 'Все зоны (сброс выделения)';
    L.DomEvent.on(a, 'click', (e) => {
      L.DomEvent.stop(e);
      setFollow(false);
      if (selected) { selected = null; applySelection(); }
      resetView();
    });
    return div;
  }
});
map.addControl(new HomeCtl());
// подложка — свои векторные тайлы (basemap.pmtiles): подписи name:ru,
// слой границ выключен, тёмная тема — родным тёмным стилем
let baseLayer = null;
function makeBasemap() {
  if (baseLayer) map.removeLayer(baseLayer);
  baseLayer = protomapsL.leafletLayer({
    url: 'basemap.pmtiles',
    flavor: document.documentElement.classList.contains('dark') ? 'dark' : 'light',
    lang: 'ru',
    maxDataZoom: 12,
    maxZoom: 18,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
  });
  // слой границ выключаем: paintRules — публичное свойство слоя
  baseLayer.paintRules = baseLayer.paintRules.filter(r => r.dataLayer !== 'boundaries');
  baseLayer.addTo(map);
}

let layer = L.featureGroup().addTo(map);
let fitted = false;
let allBounds = null;              // рамка всех активных зон — «дефолтный вид»
let follow = false;                // режим автослежения (кнопка-глаз)
let lastEvAt = null;
let lastEvs = [];
let followIdx = 0;                 // какое событие ленты показываем сейчас
let activeNames = new Set();       // зоны, видимые на карте сейчас
let freshClearNames = new Set();   // свежие отбои (<30 мин, есть призрак)
let lastCities = [];               // активные зоны последнего обновления
let tickStatic = false;            // лента влезает в экран и не бежит

// в ленте нет видимых событий — летим к самой свежей активной зоне
function fallbackFollow() {
  const zs = lastCities.filter(c => c.lat != null);
  if (!zs.length) return;
  const c = zs.reduce((a, b) =>
    new Date(b.fix_at || b.since) > new Date(a.fix_at || a.since) ? b : a);
  followTo({ at: c.fix_at || c.since, type: c.fix ? 'fix' : 'danger',
             fix: c.fix, group: c.group, names: [c.name], lat: c.lat, lon: c.lon });
}

// лента — история; летаем только туда, где сейчас что-то видно
function evVisible(e) {
  const n = e.names && e.names[0];
  if (!n || e.lat == null) return false;
  if (activeNames.has(n)) return true;
  return e.type === 'clear' && freshClearNames.has(n);
}
const ghostLayer = L.layerGroup().addTo(map); // зелёные «призраки» свежих отбоев

function resetView(floor5) {
  // floor5 — только для автоподгонки при загрузке («не мельчить»);
  // явный сброс показывает ВСЕ тревоги целиком, без пола зума
  if (allBounds && allBounds.isValid()) {
    map.fitBounds(allBounds.pad(0.05));
    if (floor5 && map.getZoom() < 5) map.setView(allBounds.getCenter(), 5);
  }
}

function setFollow(v) {
  follow = v;
  document.getElementById('followBtn').classList.toggle('on', v);
}

function evLabel(e) {
  const t = new Date(e.at).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
  const what = e.type === 'clear' ? 'Отбой'
    : e.type === 'danger' ? 'Опасность'
    : 'Фиксация' + (e.group ? ' группы БПЛА' : e.fix > 1 ? ` ${e.fix} БПЛА` : ' БПЛА');
  const names = e.names.slice(0, 2).join(', ')
    + (e.names.length > 2 ? ` +${e.names.length - 2}` : '');
  return `${t} ${what} — ${names}`;
}

function followTo(e) {
  if (e.lat == null) return;
  map.setView([e.lat, e.lon], e.names[0] && e.names[0].includes('(') ? 9 : 7);
  const div = document.createElement('div'); // textContent — имена из канала не должны стать HTML
  div.textContent = evLabel(e);
  // офсет вверх, чтобы не накрывать стопку дронов в этой же точке
  L.popup({ offset: [0, -22] }).setLatLng([e.lat, e.lon]).setContent(div).openOn(map);
}
const openNames = new Set(); // раскрытые пункты списка переживают автообновление
const detEls = new Map();    // ключ → элемент <details> текущего списка

let selected = null;         // {level, name, rname} — выбранная зона
let zoneLayers = [];         // слои карты по зонам для приглушения
let suppressMapClick = false;

function applySelection() {
  for (const z of zoneLayers) {
    const on = !selected
      || (selected.level === 'region' ? z.rname === selected.rname
                                      : z.c.name === selected.name);
    for (const p of z.paths) p.setStyle({ opacity: on ? 1 : .15, fillOpacity: on ? z.fill : .04 });
    for (const m of z.markers) {
      const el = m.getElement();
      if (el) el.style.opacity = on ? '' : '.2';
    }
  }
  for (const [key, el] of detEls) {
    let on = true;
    if (selected) {
      on = selected.level === 'region'
        ? key === 'R:' + selected.rname || key.endsWith('(' + selected.rname + ')')
        : key === selected.name || key === 'R:' + selected.rname;
    }
    el.classList.toggle('dim', !on);
  }
}

function setSelected(sel, toggle) {
  const same = selected && sel && selected.level === sel.level
    && selected.rname === sel.rname
    && (sel.level === 'region' || selected.name === sel.name);
  selected = (toggle && same) ? null : sel;
  applySelection();
  return selected != null;
}

async function zoomTo(c) {
  if (c.poly) {
    const gj = await getPoly(c.poly);
    if (gj) { map.fitBounds(L.geoJSON(gj).getBounds().pad(0.2)); return; }
  }
  if (c.lat != null) map.setView([c.lat, c.lon], 9);
}

async function zoomToGroup(g) {
  if (g.region) return zoomTo(g.region);
  let b = null;
  for (const d of g.districts) {
    let db = null;
    if (d.poly) {
      const gj = await getPoly(d.poly);
      if (gj) db = L.geoJSON(gj).getBounds();
    }
    if (!db && d.lat != null) db = L.latLngBounds([[d.lat, d.lon], [d.lat, d.lon]]);
    if (db) b = b ? b.extend(db) : db;
  }
  if (b) map.fitBounds(b.pad(0.2));
}

function focusZone(c, bounds) {
  suppressMapClick = true;
  setFollow(false);
  if (bounds) map.fitBounds(bounds.pad(0.2));
  else if (c.lat != null) map.setView([c.lat, c.lon], 9);
  const rname = c.level === 'region' ? c.name : (c.name.match(/\((.+)\)$/) || [])[1];
  setSelected({ level: c.level, name: c.name, rname });
  const keys = ['R:' + rname];
  if (c.level === 'district') keys.push(c.name);
  for (const key of keys) {
    openNames.add(key);
    const el = detEls.get(key);
    if (el) el.open = true;
  }
  const target = detEls.get(keys[keys.length - 1]);
  if (target) target.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
}

const DRONE_IMG = '<img src="free-icon-uav-8598680.png" alt="БПЛА">';
document.getElementById('drone-sw').innerHTML = DRONE_IMG;

function droneMarker(c) {
  if (!c.fix || c.lat == null) return null;
  const count = c.group ? Math.max(2, c.fix) : c.fix;
  let html, w;
  if (count <= 3) { // до трёх — колодой, дальше не читается
    html = '<div class="drones">' + DRONE_IMG.repeat(count) + '</div>';
    w = 26 + (count - 1) * 8;
  } else {          // больше — цифрой: «10 ×🛩»
    html = '<div class="drones"><span class="more">' + count + '&nbsp;×</span>'
      + DRONE_IMG + '</div>';
    w = 26 + 15 + String(count).length * 8;
  }
  return L.marker([c.lat, c.lon], {
    icon: L.divIcon({ html, className: 'drone-div', iconSize: [w, 26], iconAnchor: [w / 2, 13] })
  });
}
const polyCache = {};

async function getPoly(url) {
  if (!(url in polyCache)) {
    try {
      const r = await fetch(url);
      if (!r.ok) return null;
      polyCache[url] = await r.json();
    } catch (e) { return null; }
  }
  return polyCache[url];
}

function fmtSince(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  return isNaN(d) ? '' : d.toLocaleString('ru-RU', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

async function refresh() {
  try {
    const r = await fetch('active.json', { cache: 'no-store' });
    if (!r.ok) throw new Error(r.status);
    const data = await r.json();
    const cities = data.cities || [];
    lastCities = cities;
    activeNames = new Set(cities.map(c => c.name));

    layer.clearLayers();
    zoneLayers = [];
    const list = document.getElementById('list');
    list.innerHTML = '';

    const infoFor = c => {
      const info = [];
      if (c.danger) info.push('опасность с ' + fmtSince(c.since));
      if (c.fix) info.push('фиксация: ' + (c.group ? 'группа БПЛА' : c.fix + ' БПЛА')
        + (c.fix_at ? ' (' + fmtSince(c.fix_at) + ')' : ''));
      if (!info.length) info.push('тревога с ' + fmtSince(c.since));
      return info;
    };

    for (const c of cities) {
      const region = c.level === 'region';
      const popup = `<b>${c.name}</b><br>` + infoFor(c).join('<br>');

      // заливка = объявленная опасность; только фиксация — пунктир
      const base = region
        ? { color: '#c25e00', weight: 1.5, fillColor: '#ff9500' }
        : { color: '#d40000', weight: 1.5, fillColor: '#ff3b30' };
      const style = c.danger
        ? { ...base, fillOpacity: region ? .25 : .35 }
        : { ...base, fillOpacity: .12, dashArray: '4 3' };

      const zrec = {
        c,
        rname: region ? c.name : ((c.name.match(/\((.+)\)$/) || [])[1]),
        paths: [], markers: [], fill: style.fillOpacity
      };
      let drawn = false;
      let zb = null;
      if (c.poly) {
        const gj = await getPoly(c.poly);
        if (gj) {
          const gl = L.geoJSON(gj, { style }).addTo(layer).bindPopup(popup);
          zb = gl.getBounds();
          gl.on('click', () => focusZone(c, zb));
          zrec.paths.push(gl);
          drawn = true;
        }
      }
      if (!drawn && c.lat != null && c.lon != null) {
        const cm = L.circleMarker([c.lat, c.lon], {
          ...style, weight: 2, fillOpacity: style.fillOpacity + .2, radius: region ? 16 : 9
        }).addTo(layer).bindPopup(popup).on('click', () => focusZone(c, zb));
        zrec.paths.push(cm);
      }
      const dm = droneMarker(c);
      if (dm) {
        dm.addTo(layer).bindPopup(popup).on('click', () => focusZone(c, zb));
        zrec.markers.push(dm);
      }
      zoneLayers.push(zrec);

    }

    // список: области по алфавиту, их районы — внутри
    detEls.clear();
    const mkDetails = (key, label) => {
      const det = document.createElement('details');
      const sum = document.createElement('summary');
      sum.textContent = label;
      det.appendChild(sum);
      if (openNames.has(key)) det.open = true;
      det.addEventListener('toggle', () => {
        if (det.open) openNames.add(key); else openNames.delete(key);
      });
      detEls.set(key, det);
      return det;
    };
    const groups = new Map();
    for (const c of cities) {
      const m = c.name.match(/\((.+)\)$/);
      const rname = c.level === 'region' ? c.name : (m ? m[1] : 'Прочее');
      if (!groups.has(rname)) groups.set(rname, { region: null, districts: [] });
      if (c.level === 'region') groups.get(rname).region = c;
      else groups.get(rname).districts.push(c);
    }
    // ⏳ — тревога без событий дольше исторического максимума (100 ч по
    // анализу канала за 2 недели): скорее всего, отбой не публиковался
    const STALE_MS = 100 * 3600e3;
    const isStale = c => c && Date.now() - new Date(c.fix_at || c.since) > STALE_MS;
    const markStale = (det, c) => {
      if (!isStale(c)) return;
      const s = document.createElement('span');
      s.className = 'staleic';
      s.textContent = ' ⏳';
      s.title = 'без обновлений дольше 100 часов (возможно, пропущен отбой)';
      det.querySelector('summary').appendChild(s);
    };
    // отбои — первой секцией: тревог может быть много, а отбои есть всегда
    const clearedArr = data.cleared || [];
    freshClearNames = new Set(clearedArr
      .filter(z => Date.now() - new Date(z.at) < 30 * 60e3).map(z => z.name));
    ghostLayer.clearLayers();
    if (clearedArr.length) {
      const li = document.createElement('li');
      const det = mkDetails('CLEARED', `Отбои (${clearedArr.length})`);
      det.className = 'clearedgrp';
      const sub = document.createElement('ul');
      sub.className = 'sub';
      for (const z of clearedArr) {
        const t = new Date(z.at).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
        let dur = '';
        if (z.since) {
          const h = (new Date(z.at) - new Date(z.since)) / 3600e3;
          dur = h >= 1 ? `, шла ${h.toFixed(h < 10 ? 1 : 0)} ч` : `, шла ${Math.round(h * 60)} мин`;
        }
        const zli = document.createElement('li');
        zli.className = 'clearedit';
        zli.textContent = `✓ ${z.name} — отбой ${t}${dur}`;
        if (z.lat != null) {
          zli.addEventListener('click',
            () => map.setView([z.lat, z.lon], z.level === 'region' ? 7 : 9));
        }
        sub.appendChild(zli);
        if (z.poly && Date.now() - new Date(z.at) < 30 * 60e3) {
          getPoly(z.poly).then(gj => {
            if (gj) L.geoJSON(gj, {
              style: { color: '#2e7d32', weight: 1.5, dashArray: '3 3',
                       fillColor: '#43a047', fillOpacity: .15 }
            }).addTo(ghostLayer).bindPopup(`<b>${z.name}</b><br>отбой в ${t}`);
          });
        }
      }
      det.appendChild(sub);
      li.appendChild(det);
      list.appendChild(li);
    }

    for (const rname of [...groups.keys()].sort((a, b) => a.localeCompare(b, 'ru'))) {
      const g = groups.get(rname);
      g.districts.sort((a, b) => a.name.localeCompare(b.name, 'ru'));
      const li = document.createElement('li');
      const det = mkDetails('R:' + rname,
        rname + (g.districts.length ? ` (${g.districts.length})` : ''));
      det.className = 'rgroup';
      det.querySelector('summary').addEventListener('click', (e) => {
        e.preventDefault(); // раскрытием управляет выделение, не нативный toggle
        setFollow(false);
        const now = setSelected({ level: 'region', name: rname, rname }, true);
        det.open = now;
        if (now) zoomToGroup(g); else resetView();
      });
      markStale(det, g.region);
      if (g.region) {
        const dd = document.createElement('div');
        dd.className = 'det';
        dd.innerHTML = infoFor(g.region).join('<br>');
        det.appendChild(dd);
      }
      if (g.districts.length) {
        const sub = document.createElement('ul');
        sub.className = 'sub';
        for (const d of g.districts) {
          const dli = document.createElement('li');
          const ddet = mkDetails(d.name, d.name.replace(/\s*\(.+\)$/, ''));
          ddet.querySelector('summary').addEventListener('click', (e) => {
            e.preventDefault();
            setFollow(false);
            const now = setSelected({ level: 'district', name: d.name, rname }, true);
            ddet.open = now;
            if (now) zoomTo(d); else resetView();
          });
          markStale(ddet, d);
          const dd = document.createElement('div');
          dd.className = 'det';
          dd.innerHTML = infoFor(d).join('<br>');
          ddet.appendChild(dd);
          dli.appendChild(ddet);
          sub.appendChild(dli);
        }
        det.appendChild(sub);
      }
      li.appendChild(det);
      list.appendChild(li);
    }

    if (!cities.length) {
      const li = document.createElement('li');
      li.className = 'empty';
      li.textContent = 'тревог нет';
      list.appendChild(li);
    }

    // бегущая строка: только живые события — зона активна или свежий отбой;
    // если таких нет, крутим статусы текущих тревог
    lastEvs = (data.events || []).slice(0, 10).filter(evVisible);
    if (!lastEvs.length) {
      lastEvs = cities.filter(c => c.lat != null)
        .map(c => ({ at: c.fix_at || c.since, type: c.fix ? 'fix' : 'danger',
                     fix: c.fix, group: c.group, names: [c.name],
                     lat: c.lat, lon: c.lon }))
        .sort((a, b) => new Date(b.at) - new Date(a.at)).slice(0, 10);
    }
    const tickEl = document.getElementById('tick');
    tickEl.textContent = '';
    if (lastEvs.length) {
      const addItems = () => {
        for (const e of lastEvs) {
          const s = document.createElement('span');
          s.className = 'tickitem';
          s.textContent = evLabel(e);
          tickEl.appendChild(s);
        }
      };
      addItems();
      if (tickEl.scrollWidth <= tickEl.parentElement.clientWidth) {
        tickStatic = true;              // помещается — стоим
        tickEl.style.animation = 'none';
      } else {
        tickStatic = false;
        addItems();                     // вторая копия — бесшовный цикл
        tickEl.style.animation = '';
        tickEl.style.animationDuration =
          Math.max(30, Math.round(tickEl.scrollWidth / 2 / 35)) + 's'; // ~35 px/с
      }
    }
    if (follow && lastEvs.length && lastEvs[0].at !== lastEvAt) {
      lastEvAt = lastEvs[0].at; // свежее событие перебивает очередь
      followIdx = 0;
      if (evVisible(lastEvs[0])) followTo(lastEvs[0]);
    }
    const nUav = cities.reduce((s, c) => s + (c.fix || 0), 0);
    const counts = {
      'n-region': cities.filter(c => c.level === 'region' && c.danger).length,
      'n-district': cities.filter(c => c.level === 'district' && c.danger).length,
      'n-fixzone': cities.filter(c => !c.danger).length,
      'n-uav': nUav ? (cities.some(c => c.group) ? '≥' + nUav : nUav) : 0,
      'n-stale': cities.filter(isStale).length
    };
    for (const [id, v] of Object.entries(counts))
      document.getElementById(id).textContent = String(v); // 0 показываем явно
    // строка ⏳ видна только когда такие зоны есть
    document.getElementById('stale-row').style.display = counts['n-stale'] ? '' : 'none';
    // если выбранная зона исчезла (отбой) — снять выделение, затем применить
    if (selected && !zoneLayers.some(z => selected.level === 'region'
        ? z.rname === selected.rname : z.c.name === selected.name)) {
      selected = null;
    }
    applySelection();

    allBounds = layer.getBounds();
    if (!fitted && cities.length && allBounds.isValid()) {
      resetView(true); // стартовая подгонка с полом зума 5 — не мельчить
      fitted = true;
    }
    const upd = data.updated ? new Date(data.updated) : new Date();
    document.getElementById('updated').textContent = 'обновлено: ' + upd.toLocaleString('ru-RU',
      { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch (e) {
    document.getElementById('updated').textContent = 'ошибка загрузки данных';
  }
}

// тема: сохранённый выбор, иначе системная настройка
if ((localStorage.getItem('theme')
    || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')) === 'dark') {
  document.documentElement.classList.add('dark');
}
makeBasemap(); // подложка создаётся после установки темы
document.getElementById('themeBtn').addEventListener('click', () => {
  const dark = document.documentElement.classList.toggle('dark');
  localStorage.setItem('theme', dark ? 'dark' : 'light');
  makeBasemap(); // перерисовать подложку в новом стиле
});

document.getElementById('followBtn').addEventListener('click', () => {
  setFollow(!follow);
  if (follow && lastEvs.length) {
    lastEvAt = lastEvs[0].at;
    followIdx = 0;
    const first = lastEvs.findIndex(evVisible);
    if (first >= 0) {
      followIdx = first;
      followTo(lastEvs[first]);
    } else {
      fallbackFollow();
    }
  }
});

// перелистывание карусели на следующее ВИДИМОЕ событие
function followAdvance() {
  if (!follow || !lastEvs.length) return;
  for (let step = 1; step <= lastEvs.length; step++) {
    const i = (followIdx + step) % lastEvs.length;
    if (evVisible(lastEvs[i])) {
      followIdx = i;
      followTo(lastEvs[i]);
      return;
    }
  }
}
// строка бежит — по кругу анимации; стоит (всё влезло) — по таймеру
document.getElementById('tick').addEventListener('animationiteration', followAdvance);
setInterval(() => { if (tickStatic) followAdvance(); }, 30000);

refresh();
setInterval(refresh, 60000);
</script>
</body>
</html>
HTMLEOF

COPY <<'NGEOF' /etc/nginx/http.d/default.conf
# 80: ACME-webroot + редирект на https; 443: сайт.
# Серты: волюм /certs (fullchain.pem + privkey.pem); нет — start.sh делает самоподписанный.
proxy_cache_path /tmp/ngcache keys_zone=micro:2m max_size=10m;

server {
    listen 80;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /acme;
    }
    location = /healthz {
        proxy_pass http://127.0.0.1:8080;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name xn----8sbeihi5atyufy.xn--p1ai _;

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;

    root /www;
    index index.html;

    # active.json — из Redis через api; микрокэш 1с гасит хайлоад
    location = /active.json {
        proxy_pass http://127.0.0.1:8080;
        proxy_cache micro;
        # api шлёт no-store для браузера; nginx его игнорирует, иначе микрокэш мёртв
        proxy_ignore_headers Cache-Control Expires;
        proxy_cache_valid 200 1s;
        proxy_cache_lock on;
        proxy_cache_use_stale updating error timeout;
        add_header X-Cache-Status $upstream_cache_status;
    }
    location = /healthz {
        proxy_pass http://127.0.0.1:8080;
    }
    location /regions/ { expires 1h; }
    location /vendor/  { expires 7d; }
    location ~* \.png$ { expires 7d; }
    location / { try_files $uri $uri/ =404; }
}
NGEOF

COPY <<'APPEOF' /app.py
"""active.json из Redis. Единственный маршрут; наплыв гасит nginx-микрокэш."""
import os

import redis.asyncio as aioredis
from aiohttp import web

r = aioredis.from_url("redis://" + os.environ.get("REDIS_HOST", "127.0.0.1") + ":6379")
EMPTY = b'{"updated": null, "cities": []}'


async def active(request):
    data = await r.get("active_json")
    return web.Response(
        body=data or EMPTY,
        content_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


async def health(request):
    ts = await r.get("active_ts")
    return web.Response(text=(ts or b"none").decode())


app = web.Application()
app.router.add_get("/active.json", active)
app.router.add_get("/healthz", health)
web.run_app(app, port=8080, access_log=None)
APPEOF

COPY <<'PARSEOF' /parser_loop.py
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
PARSEOF

COPY <<'SHEOF' /start.sh
#!/bin/sh
mkdir -p /etc/nginx/ssl
if [ -s /certs/fullchain.pem ] && [ -s /certs/privkey.pem ]; then
    ln -sf /certs/fullchain.pem /etc/nginx/ssl/fullchain.pem
    ln -sf /certs/privkey.pem /etc/nginx/ssl/privkey.pem
else
    echo "WARN: в /certs нет fullchain.pem+privkey.pem — временно самоподписанный;"
    echo "      положите настоящие и сделайте: docker exec vozduh-alert nginx -s reload"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=vozduh-alert" \
        -keyout /etc/nginx/ssl/privkey.pem -out /etc/nginx/ssl/fullchain.pem 2>/dev/null
fi
redis-server --save '' --appendonly no --daemonize yes
(while :; do python /app.py; sleep 2; done) &
(while :; do python /parser_loop.py; sleep 5; done) &
exec nginx -g 'daemon off;'
SHEOF
RUN chmod +x /start.sh

VOLUME /data
EXPOSE 80 443
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s CMD wget -qO- http://127.0.0.1/healthz || exit 1
CMD ["/start.sh"]
