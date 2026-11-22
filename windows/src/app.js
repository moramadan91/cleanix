import { STRINGS } from './i18n.js';
import { mockInvoke } from './mock.js';

// In the app the Rust side answers; in a plain browser (design preview) a mock does.
const invoke = window.__TAURI__?.core?.invoke ?? mockInvoke;

const SECTIONS = [
  { id: 'overview', tint: '#7C5CFF', deep: '#3B2A8F', icon: 'M4 15a8 8 0 1 1 16 0M12 15l4-5' },
  { id: 'smartScan', tint: '#FFAA3D', deep: '#FF5A3D', icon: 'M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z' },
  { id: 'cleanup', tint: '#2FD1A0', deep: '#0E7C6B', icon: 'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6' },
  { id: 'apps', tint: '#4C8DFF', deep: '#2230A8', icon: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z' },
  { id: 'clutter', tint: '#1FC8D6', deep: '#0D6B80', icon: 'M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z' },
  { id: 'diskMap', tint: '#F5C542', deep: '#6E4A0C', icon: 'M12 3a9 9 0 1 0 9 9h-9zM15 3.5A9 9 0 0 1 20.5 9H15z' },
];
const TABS = { cleanup: ['junk', 'caches', 'bin'], clutter: ['downloads', 'large'] };

const store = (k, v) => { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch { return null; } };

let lang = store('cleanix.lang') || (navigator.language.startsWith('ar') ? 'ar' : 'en');
let section = 'overview';
const tab = { cleanup: 'junk', clutter: 'downloads' };
let sort = store('cleanix.sort') || 'largest';
const views = {}; // per scan key: { phase, items, selected, result }
const map = { trail: [], selected: new Set(), loading: false };
let overview = null;

const $ = (s, el = document) => el.querySelector(s);
const t = (k, ...a) => (STRINGS[lang][k] ?? STRINGS.en[k] ?? k).replace(/\{(\d)\}/g, (_, i) => a[i]);
const groupTitle = g => STRINGS[lang]['group.' + g] ?? g;
const esc = s => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

function fmt(bytes) {
  const units = lang === 'ar' ? ['بايت', 'كيلو', 'ميجا', 'جيجا', 'تيرا'] : ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = bytes;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 100 || i === 0 ? Math.round(v) : v.toFixed(1)} ${units[i]}`;
}

const icon = d => `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;

function sorted(list) {
  const by = { largest: (a, b) => b.bytes - a.bytes, smallest: (a, b) => a.bytes - b.bytes, nameAZ: (a, b) => a.name.localeCompare(b.name, lang) };
  return [...list].sort(by[sort]);
}

/* ---------- shell ---------- */

function renderShell() {
  document.documentElement.lang = lang;
  document.documentElement.dir = lang === 'ar' ? 'rtl' : 'ltr';
  const s = SECTIONS.find(x => x.id === section);
  document.body.style.setProperty('--tint', s.tint);
  document.body.style.setProperty('--deep', s.deep);
  $('#nav').innerHTML = SECTIONS.map(x => `
    <button type="button" class="nav-item${x.id === section ? ' on' : ''}" data-section="${x.id}" style="--c:${x.tint}" ${x.id === section ? 'aria-current="page"' : ''}>
      ${icon(x.icon)}<span>${t(`section.${x.id}.title`)}</span>
    </button>`).join('');
  $('#lang').textContent = t('lang.switch');
  render();
}

function render() {
  const main = $('#main');
  if (section === 'overview') main.innerHTML = overviewView();
  else if (section === 'diskMap') main.innerHTML = mapView();
  else if (section === 'apps') main.innerHTML = appsView();
  else main.innerHTML = scanScreen();
}

function header(extra = '') {
  return `<header class="head">
    <div><h1>${t(`section.${section}.title`)}</h1><p>${t(`section.${section}.subtitle`)}</p></div>${extra}
  </header>`;
}

function tabs() {
  const list = TABS[section];
  if (!list) return '';
  return `<div class="tabs" role="tablist">${list.map(k => `<button type="button" role="tab" aria-selected="${tab[section] === k}" class="tab${tab[section] === k ? ' on' : ''}" data-tab="${k}">${t('tab.' + k)}</button>`).join('')}</div>`;
}

/* ---------- scan screens ---------- */

const scanKey = () => (section === 'smartScan' ? 'smart' : tab[section]);
const view = key => (views[key] ??= { phase: 'intro', items: [], selected: new Set() });

function scanScreen() {
  const key = scanKey();
  if (key === 'bin') return header() + tabs() + binView();
  const v = view(key);
  let body;
  if (v.phase === 'intro') body = `<div class="hero"><div class="orb">${icon(SECTIONS.find(x => x.id === section).icon)}</div>
      <button type="button" class="btn big primary" data-action="scan">${t('common.scan')}</button></div>`;
  else if (v.phase === 'scanning') body = spinner();
  else if (v.phase === 'done') body = doneView(v.result);
  else body = resultsView(v);
  return header() + tabs() + body;
}

const spinner = (text = t('common.scanning')) => `<div class="center"><div class="spin" role="status"></div><p>${text}</p></div>`;

function resultsView(v) {
  if (!v.items.length) return `<div class="center"><p class="muted">${t('common.nothing')}</p><button type="button" class="btn big primary" data-action="scan">${t('common.rescan')}</button></div>`;
  const chosen = v.items.filter(i => v.selected.has(i.path));
  const bytes = chosen.reduce((s, i) => s + i.bytes, 0);
  const groups = [...new Set(v.items.map(i => i.group))];
  const total = g => v.items.filter(i => i.group === g).reduce((s, i) => s + i.bytes, 0);
  groups.sort((a, b) => sort === 'nameAZ' ? groupTitle(a).localeCompare(groupTitle(b), lang) : sort === 'smallest' ? total(a) - total(b) : total(b) - total(a));
  return `
    <div class="bar">
      <strong>${t('common.selected', chosen.length, fmt(bytes))}</strong>
      <span class="grow"></span>
      ${sortMenu()}
      <button type="button" class="btn small" data-action="all">${t('common.selectAll')}</button>
      <button type="button" class="btn small" data-action="none">${t('common.selectNone')}</button>
    </div>
    <div class="panel list">
      ${groups.map(g => `<h2>${esc(groupTitle(g))} <span>${fmt(total(g))}</span></h2>` +
        sorted(v.items.filter(i => i.group === g)).map(i => row(i, v.selected.has(i.path))).join('')).join('')}
    </div>
    <div class="actions"><button type="button" class="btn big primary" data-action="preview" ${chosen.length ? '' : 'disabled'}>${t('common.clean')}</button></div>`;
}

function row(i, on, extra = '') {
  return `<div class="row${on ? ' on' : ''}" data-path="${esc(i.path)}">
    <label class="check"><input type="checkbox" ${on ? 'checked' : ''} ${i.safety === 'risky' ? 'disabled' : ''} data-action="tick"><span aria-hidden="true"></span><span class="sr">${esc(i.name)}</span></label>
    <div class="name"><b title="${esc(i.path)}">${esc(i.name)}</b><small>${extra || esc(i.path)}</small></div>
    <span class="size">${fmt(i.bytes)}</span>
    <button type="button" class="icon-btn" data-action="reveal" title="${t('common.reveal')}" aria-label="${t('common.reveal')}">${icon('M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2zM12 11v5M9.5 13.5 12 11l2.5 2.5')}</button>
  </div>`;
}

function sortMenu() {
  return `<label class="sort"><span class="sr">sort</span><select data-action="sort">
    ${['largest', 'smallest', 'nameAZ'].map(k => `<option value="${k}" ${k === sort ? 'selected' : ''}>${t('sort.' + k)}</option>`).join('')}
  </select></label>`;
}

function doneView(r) {
  return `<div class="center">
    <div class="orb done">${icon('M5 12.5l4.5 4.5L19 7.5')}</div>
    <h2 class="big-text">${t('common.cleaned', fmt(r.freed))}</h2>
    ${r.failed.length ? `<p class="warn">${t('common.failed', r.failed.length)}</p>` : ''}
    <button type="button" class="btn big primary" data-action="scan">${t('common.rescan')}</button>
  </div>`;
}

async function scan() {
  const key = scanKey();
  const v = view(key);
  v.phase = 'scanning'; render();
  try {
    v.items = key === 'smart'
      ? (await Promise.all([invoke('scan', { kind: 'junk' }), invoke('scan', { kind: 'caches' })])).flat()
      : await invoke('scan', { kind: key });
  } catch { v.items = []; }
  // Safe items start ticked; files that need the user's eye do not.
  v.selected = new Set(v.items.filter(i => i.safety === 'safe').map(i => i.path));
  v.phase = 'results'; render();
}

/* ---------- Recycle Bin ---------- */

let bin = null;
function binView() {
  if (bin === null) { refreshBin(); return spinner(); }
  if (bin === 'none') return `<div class="center"><p class="muted">${t('overview.unknown')}</p></div>`;
  if (!bin.items) return `<div class="center"><div class="orb done">${icon('M5 12.5l4.5 4.5L19 7.5')}</div><p>${t('bin.empty')}</p></div>`;
  return `<div class="center">
    <div class="orb">${icon(SECTIONS[2].icon)}</div>
    <h2 class="big-text">${t('bin.size', bin.items, fmt(bin.bytes))}</h2>
    <button type="button" class="btn big primary" data-action="binAsk">${t('bin.action')}</button>
  </div>`;
}

async function refreshBin() {
  try { bin = (await invoke('recycle_info')) ?? 'none'; } catch { bin = 'none'; }
  render();
}

/* ---------- Overview ---------- */

function overviewView() {
  if (!overview) { loadOverview(); return header() + spinner(''); }
  const { disk, bin: b } = overview;
  let ring = `<p class="muted">${t('overview.unknown')}</p>`;
  if (disk) {
    const used = disk.total - disk.free, pct = used / disk.total, c = 2 * Math.PI * 70;
    ring = `<svg viewBox="0 0 180 180" width="180" height="180" class="ring" role="img" aria-label="${t('overview.free', fmt(disk.free), fmt(disk.total))}">
        <circle cx="90" cy="90" r="70" class="track"/><circle cx="90" cy="90" r="70" class="fill" stroke-dasharray="${c * pct} ${c}"/>
        <text x="90" y="98" text-anchor="middle">${Math.round(pct * 100)}%</text></svg>
      <p>${t('overview.free', fmt(disk.free), fmt(disk.total))}</p>`;
  }
  const tips = [
    ['cleanup', 'junk', t('overview.tipJunk')],
    ...(b && b.items ? [['cleanup', 'bin', t('overview.tipBin', fmt(b.bytes))]] : []),
    ['clutter', 'large', t('overview.tipLarge')],
    ['apps', null, t('overview.tipApps')],
    ['diskMap', null, t('overview.tipMap')],
  ];
  return header() + `<div class="overview">
    <div class="panel disk"><h2>${t('overview.disk', 'C:')}</h2>${ring}</div>
    <div class="panel tips"><h2>${t('overview.tips')}</h2>
      ${tips.map(([s, k, text]) => `<div class="tip"><span>${text}</span><button type="button" class="btn small" data-go="${s}" data-go-tab="${k ?? ''}">${t('overview.go')}</button></div>`).join('')}
    </div></div>`;
}

async function loadOverview() {
  const [disk, b] = await Promise.all([invoke('disk_info').catch(() => null), invoke('recycle_info').catch(() => null)]);
  overview = { disk, bin: b };
  if (section === 'overview') render();
}

/* ---------- Apps ---------- */

const apps = { list: null, q: '', note: '' };

function appsView() {
  if (apps.list === null) { loadApps(); return header() + spinner(); }
  if (!apps.list.length) return header() + `<div class="center"><p class="muted">${t('apps.none')}</p></div>`;
  const total = apps.list.reduce((s, a) => s + a.bytes, 0);
  return header() + `<div class="bar">
      <input type="search" class="search" data-action="appSearch" value="${esc(apps.q)}" placeholder="${t('apps.search')}" aria-label="${t('apps.search')}">
      <span class="grow"></span>${sortMenu()}
      <button type="button" class="btn small" data-action="appsRefresh">${t('apps.refresh')}</button>
    </div>
    ${apps.note ? `<p class="note">${esc(apps.note)}</p>` : ''}
    <div class="panel list" id="appList">${appRows()}</div>
    <div class="actions split"><span class="muted">${t('apps.count', apps.list.length, fmt(total))}</span></div>`;
}

function appRows() {
  const q = apps.q.trim().toLowerCase();
  const found = sorted(apps.list.filter(a => !q || a.name.toLowerCase().includes(q) || a.publisher.toLowerCase().includes(q)));
  if (!found.length) return `<p class="muted pad">${t('common.nothing')}</p>`;
  return found.map(a => `<div class="row" data-app="${esc(a.id)}">
      <div class="name"><b><bdi>${esc(a.name)}</bdi></b><small>${esc([a.publisher, a.version].filter(Boolean).join(' · '))}</small></div>
      <span class="size">${a.bytes ? fmt(a.bytes) : '—'}</span>
      <button type="button" class="btn small" data-action="appAsk">${t('apps.uninstall')}</button>
    </div>`).join('');
}

async function loadApps() {
  apps.list = await invoke('list_apps').catch(() => []);
  if (section === 'apps') render();
}

/* ---------- Disk Map ---------- */

function mapView() {
  if (!map.trail.length) { openDir(null); return header() + spinner(); }
  const cur = map.trail.at(-1);
  const crumbs = map.trail.map((n, i) => `<button type="button" class="crumb${i === map.trail.length - 1 ? ' on' : ''}" data-crumb="${i}">${esc(n.name)}</button>`).join('<span class="sep" aria-hidden="true">›</span>');
  const top = Math.max(1, ...cur.nodes.map(n => n.bytes));
  const total = cur.nodes.reduce((s, n) => s + n.bytes, 0);
  const chosen = cur.nodes.filter(n => map.selected.has(n.path));
  const body = map.loading ? spinner() : `<div class="panel list">${cur.nodes.length ? cur.nodes.map(n => mapRow(n, top)).join('') : `<p class="muted pad">${t('common.nothing')}</p>`}</div>`;
  return header() + `<div class="bar">
      <button type="button" class="icon-btn" data-action="up" ${map.trail.length < 2 ? 'disabled' : ''} aria-label="back">${icon(lang === 'ar' ? 'M9 6l6 6-6 6' : 'M15 6l-6 6 6 6')}</button>
      <nav class="crumbs">${crumbs}</nav>
    </div>${body}
    <div class="actions split">
      <button type="button" class="btn primary" data-action="mapPreview" ${chosen.length ? '' : 'disabled'}>${t('common.remove')}</button>
      <span class="muted">${t('map.inside', esc(cur.name), fmt(total))}</span>
    </div>`;
}

function mapRow(n, top) {
  const on = map.selected.has(n.path);
  return `<div class="row map${on ? ' on' : ''}${n.dir ? ' dir' : ''}" data-path="${esc(n.path)}" ${n.dir ? 'data-open="1" tabindex="0"' : ''}>
    <label class="check"><input type="checkbox" ${on ? 'checked' : ''} ${n.safety === 'risky' ? 'disabled' : ''} data-action="mapTick"><span aria-hidden="true"></span><span class="sr">${esc(n.name)}</span></label>
    <div class="name"><b>${esc(n.name)}</b><small><span class="badge ${n.safety}">${t('safety.' + n.safety)}</span></small>
      <i class="meter" style="--w:${(n.bytes / top * 100).toFixed(1)}%"></i></div>
    <span class="size">${fmt(n.bytes)}</span>
    <button type="button" class="icon-btn" data-action="reveal" title="${t('common.reveal')}" aria-label="${t('common.reveal')}">${icon('M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z')}</button>
  </div>`;
}

async function openDir(node) {
  if (map.loading) return;
  map.loading = true;
  if (node) map.trail.push({ ...node, nodes: [] });
  render();
  const path = node ? node.path : null;
  const nodes = await invoke('disk_children', { path }).catch(() => []);
  if (!node) {
    const home = await invoke('home').catch(() => '~');
    map.trail = [{ path: home, name: home.split(/[\\/]/).filter(Boolean).pop() || '~', nodes }];
  } else map.trail.at(-1).nodes = nodes;
  map.selected = new Set();
  map.loading = false;
  render();
}

/* ---------- dialogs ---------- */

function modal(html) {
  const m = $('#modal');
  m.innerHTML = `<div class="sheet panel" role="dialog" aria-modal="true">${html}</div>`;
  m.hidden = false;
  $('button', m)?.focus();
}
const closeModal = () => { $('#modal').hidden = true; $('#modal').innerHTML = ''; };

function askClean(items, onDone) {
  const bytes = items.reduce((s, i) => s + i.bytes, 0);
  modal(`<h2>${t('preview.title')}</h2><p>${t('preview.body', items.length, fmt(bytes))}</p>
    <ul class="mini">${sorted(items).slice(0, 40).map(i => `<li><span>${esc(i.name)}</span><span>${fmt(i.bytes)}</span></li>`).join('')}</ul>
    <div class="actions"><button type="button" class="btn" data-modal="cancel">${t('common.cancel')}</button>
    <button type="button" class="btn primary" data-modal="ok">${t('preview.confirm')}</button></div>`);
  pendingOk = async () => {
    closeModal();
    const result = await invoke('clean', { paths: items.map(i => i.path) }).catch(() => ({ freed: 0, removed: [], failed: items.map(i => i.path) }));
    onDone(result);
  };
}
let pendingOk = null;

/* ---------- events ---------- */

document.addEventListener('click', async e => {
  const el = e.target.closest('[data-section],[data-tab],[data-action],[data-go],[data-crumb],[data-modal],[data-open],#lang');
  if (!el) return;
  if (el.id === 'lang') { lang = lang === 'ar' ? 'en' : 'ar'; store('cleanix.lang', lang); return renderShell(); }
  if (el.dataset.section) { section = el.dataset.section; renderShell(); return $('#main').focus(); }
  if (el.dataset.tab) { tab[section] = el.dataset.tab; if (el.dataset.tab === 'bin') bin = null; return render(); }
  if (el.dataset.go) { section = el.dataset.go; if (el.dataset.goTab) tab[section] = el.dataset.goTab; if (el.dataset.goTab === 'bin') bin = null; return renderShell(); }
  if (el.dataset.crumb) { map.trail = map.trail.slice(0, +el.dataset.crumb + 1); map.selected = new Set(); return render(); }
  if (el.dataset.modal) { if (el.dataset.modal === 'ok' && pendingOk) await pendingOk(); else closeModal(); pendingOk = null; return; }

  const path = el.closest('[data-path]')?.dataset.path;
  const v = views[scanKey()];
  const app = apps.list?.find(a => a.id === el.closest('[data-app]')?.dataset.app);
  switch (el.dataset.action) {
    case 'scan': return scan();
    case 'tick': return; // handled on change
    case 'mapTick': return;
    case 'all': v.items.forEach(i => i.safety !== 'risky' && v.selected.add(i.path)); return render();
    case 'none': v.selected.clear(); return render();
    case 'reveal': return invoke('reveal', { path }).catch(() => {});
    case 'up': map.trail.pop(); map.selected = new Set(); return render();
    case 'preview':
      return askClean(v.items.filter(i => v.selected.has(i.path)), r => { v.result = r; v.phase = 'done'; overview = null; render(); });
    case 'mapPreview': {
      const cur = map.trail.at(-1);
      return askClean(cur.nodes.filter(n => map.selected.has(n.path)), () => { overview = null; reloadMap(); });
    }
    case 'appsRefresh': apps.list = null; apps.note = ''; return render();
    case 'appAsk':
      modal(`<h2>${t('apps.confirmTitle', esc(app.name))}</h2><p>${t('apps.confirmBody', esc(app.name))}</p>
        <div class="actions"><button type="button" class="btn" data-modal="cancel">${t('common.cancel')}</button>
        <button type="button" class="btn danger" data-modal="ok">${t('apps.open')}</button></div>`);
      pendingOk = async () => {
        closeModal();
        const ok = await invoke('uninstall', { id: app.id }).then(() => true, () => false);
        apps.note = t(ok ? 'apps.launched' : 'apps.failed', app.name);
        render();
      };
      return;
    case 'binAsk':
      modal(`<h2>${t('bin.confirmTitle')}</h2><p>${t('bin.confirmBody')}</p>
        <div class="actions"><button type="button" class="btn" data-modal="cancel">${t('common.cancel')}</button>
        <button type="button" class="btn danger" data-modal="ok">${t('bin.action')}</button></div>`);
      pendingOk = async () => { closeModal(); bin = null; render(); await invoke('empty_recycle', { confirmed: true }).catch(() => {}); overview = null; refreshBin(); };
      return;
  }
  // Clicking a folder row (not its controls) opens it.
  if (el.dataset.open && !e.target.closest('label,button')) openDir(map.trail.at(-1).nodes.find(n => n.path === path));
});

async function reloadMap() {
  const cur = map.trail.at(-1);
  map.loading = true; render();
  cur.nodes = await invoke('disk_children', { path: cur.path }).catch(() => []);
  map.selected = new Set(); map.loading = false; render();
}

document.addEventListener('change', e => {
  const el = e.target;
  if (el.dataset.action === 'sort') { sort = el.value; store('cleanix.sort', sort); return render(); }
  const path = el.closest('[data-path]')?.dataset.path;
  const set = el.dataset.action === 'mapTick' ? map.selected : el.dataset.action === 'tick' ? views[scanKey()].selected : null;
  if (!set || !path) return;
  el.checked ? set.add(path) : set.delete(path);
  render();
});

// Search updates only the list so the field keeps focus while typing.
document.addEventListener('input', e => {
  if (e.target.dataset.action !== 'appSearch') return;
  apps.q = e.target.value;
  $('#appList').innerHTML = appRows();
});

document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && !$('#modal').hidden) { closeModal(); pendingOk = null; }
  // Folder rows open with Enter like a click.
  if (e.key === 'Enter' && e.target.matches?.('.row.dir')) e.target.click();
});

renderShell();
