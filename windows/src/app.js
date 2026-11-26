import { STRINGS } from './i18n.js';
import { mockInvoke } from './mock.js';

// In the app the Rust side answers; in a plain browser (design preview) a mock does.
const invoke = window.__TAURI__?.core?.invoke ?? mockInvoke;

const SECTIONS = [
  { id: 'overview', tint: '#7C5CFF', deep: '#3B2A8F', icon: 'M4 15a8 8 0 1 1 16 0M12 15l4-5' },
  { id: 'smartScan', tint: '#FFAA3D', deep: '#FF5A3D', icon: 'M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16l.7 2 2 .7-2 .7-.7 2-.7-2-2-.7 2-.7z' },
  { id: 'cleanup', tint: '#2FD1A0', deep: '#0E7C6B', icon: 'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6' },
  { id: 'protection', tint: '#FF5C8A', deep: '#8E1F5E', icon: 'M12 3l7 3v6c0 4.5-3 7.8-7 9-4-1.2-7-4.5-7-9V6z' },
  { id: 'performance', tint: '#9BD12E', deep: '#2F6B12', icon: 'M13 3L5 14h6l-1 7 8-11h-6z' },
  { id: 'apps', tint: '#4C8DFF', deep: '#2230A8', icon: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z' },
  { id: 'clutter', tint: '#1FC8D6', deep: '#0D6B80', icon: 'M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z' },
  { id: 'diskMap', tint: '#F5C542', deep: '#6E4A0C', icon: 'M12 3a9 9 0 1 0 9 9h-9zM15 3.5A9 9 0 0 1 20.5 9H15z' },
];
const TABS = {
  cleanup: ['junk', 'caches', 'bin'],
  protection: ['privacy', 'permissions', 'suspicious'],
  performance: ['maintenance', 'startup', 'heavy'],
  apps: ['uninstall', 'leftovers', 'extensions'],
  clutter: ['downloads', 'large', 'duplicates'],
};

const store = (k, v) => { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch { return null; } };

const savedLang = store('cleanix.lang');
let lang = savedLang === 'ar' || savedLang === 'en' ? savedLang : (navigator.language.startsWith('ar') ? 'ar' : 'en');
let section = 'overview';
const tab = Object.fromEntries(Object.entries(TABS).map(([k, v]) => [k, v[0]]));
let sort = store('cleanix.sort') || 'largest';
const views = {}; // per scan key: { phase, items, selected, result }
const map = { trail: [], selected: new Set(), loading: false };
let overview = null;
let overviewLoading = false;
let overviewReady = !window.__TAURI__;
let windowVisible = !window.__TAURI__;
let cleaning = false;
const pageVisible = () => windowVisible && !document.hidden;

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

const localNumber = value => new Intl.NumberFormat(lang === 'ar' ? 'ar-EG' : 'en', { useGrouping: false }).format(value);
const percent = value => localNumber(value) + (lang === 'ar' ? '٪' : '%');

function flag(code) {
  const arab = '<rect width="22" height="15" fill="#16834a"/><path fill="#fff" d="M13.7 3.6a4.4 4.4 0 1 0 0 7.8 4.1 4.1 0 0 1 0-7.8z"/><path fill="#fff" d="m14 5 .55 1.55 1.65.04-1.3 1 .47 1.6L14 8.23l-1.37.96.47-1.6-1.3-1 1.65-.04z"/>';
  const uk = '<rect width="22" height="15" fill="#163568"/><path d="m0 0 22 15m0-15L0 15" stroke="#fff" stroke-width="3"/><path d="m0 0 22 15m0-15L0 15" stroke="#c8102e" stroke-width="1.15"/><path d="M11 0v15M0 7.5h22" stroke="#fff" stroke-width="4.5"/><path d="M11 0v15M0 7.5h22" stroke="#c8102e" stroke-width="2.5"/>';
  return `<svg class="flag" width="22" height="15" viewBox="0 0 22 15" aria-hidden="true">${code === 'ar' ? arab : uk}<rect x=".125" y=".125" width="21.75" height="14.75" rx="3" fill="none" stroke="#fff" stroke-width=".25"/></svg>`;
}

const icon = d => `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
const broomIcon = 'm12 12 7-9M10 11l4 3-2 2-5-3zM7 13c-1 3-3 5-5 6 3 2 7 3 10 2 1-2 1-3 0-5M7 20l2-3';

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
  $('#lang').innerHTML = flag(lang === 'en' ? 'ar' : 'en') + `<span>${t('lang.switch')}</span>`;
  $('#settings').textContent = t('settings.title');
  $('#update').hidden = !updateTag;
  if (updateTag) $('#update').textContent = t('update.available', updateTag.slice(5));
  render();
}

function render() {
  if (cleaning) return;
  const main = $('#main');
  if (section === 'overview') main.innerHTML = overviewView();
  else if (section === 'diskMap') main.innerHTML = mapView();
  else main.innerHTML = scanScreen();
  pumpFootprints();
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
  const custom = { bin: binView, uninstall: appsView, permissions: accessView, suspicious: () => startupView(true), startup: () => startupView(false), maintenance: maintView, heavy: heavyView, extensions: extensionsView };
  if (custom[key]) return header() + tabs() + custom[key]();
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

async function runCleaning(work) {
  const minimum = 2500;
  const finish = 180;
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const main = $('#main');
  const sidebar = $('.sidebar');
  cleaning = true;
  sidebar.inert = true;
  main.innerHTML = `${header()}<div class="center cleaning" style="--clean-ms:${minimum}ms;--finish-ms:${finish}ms">
    <div class="orb cleaning-orb">
      <svg viewBox="0 0 84 64" fill="none" aria-hidden="true">
        <g class="cleaning-dust" fill="currentColor">
          <circle cx="16" cy="50" r="2"/><circle cx="23" cy="44" r="1.5"/><circle cx="25" cy="55" r="2"/>
          <circle cx="60" cy="53" r="2"/><circle cx="67" cy="45" r="1.5"/><circle cx="72" cy="51" r="2"/>
        </g>
        <g class="cleaning-broom"><path transform="translate(15 4) scale(2.35)" stroke="currentColor"
          stroke-linecap="round" stroke-linejoin="round" d="${broomIcon}"/></g>
      </svg>
    </div>
    <h2 class="big-text" id="cleaning-title" role="status">${t('common.cleaning')}</h2>
    <div class="cleaning-track" role="progressbar" aria-labelledby="cleaning-title"><span></span></div>
  </div>`;
  main.focus();
  try {
    const [result] = await Promise.allSettled([Promise.resolve().then(work), wait(minimum)]);
    const track = $('.cleaning-track', main);
    track.classList.add('complete');
    track.setAttribute('aria-valuenow', '100');
    await wait(finish);
    if (result.status === 'rejected') throw result.reason;
    return result.value;
  } finally {
    cleaning = false;
    sidebar.inert = false;
  }
}

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
  const canUndo = r.freed > 0;
  return `<div class="center">
    <div class="orb done done-check">
      <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <circle cx="24" cy="24" r="21" pathLength="1" transform="rotate(-90 24 24)"/>
        <path d="m14 24 7 7 13-14" pathLength="1"/>
      </svg>
    </div>
    <h2 class="big-text done-title" role="status">${t('common.cleaned', fmt(r.freed))}</h2>
    ${r.failed.length ? `<p class="warn">${t('common.failed', r.failed.length)}</p>` : ''}
    <div class="result-actions">
      ${canUndo ? `<button type="button" class="orb done result-action undo" data-action="undoClean" aria-describedby="restore-note">${t('common.undo')}</button>` : ''}
      <button type="button" class="orb done result-action" data-action="scan">${t('common.rescan')}</button>
    </div>
    ${canUndo ? `<p class="result-note muted" id="restore-note">${t('common.restoreNote')}</p>` : ''}
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
let binRequest = null;
const binSummary = b => t(b.items === 1 ? 'bin.sizeOne' : 'bin.size', fmt(b.bytes), localNumber(b.items));

function binView() {
  if (bin === null) { refreshBin(); return spinner(); }
  if (bin === 'none') return `<div class="center"><p class="muted">${t('overview.unknown')}</p></div>`;
  return `<div class="center">
    <div class="orb${bin.items ? '' : ' done'}">${icon(bin.items ? SECTIONS[2].icon : 'M5 12.5l4.5 4.5L19 7.5')}</div>
    <h2 class="big-text">${binSummary(bin)}</h2>
    ${bin.items ? `<button type="button" class="btn big primary" data-action="binAsk">${t('bin.action')}</button>` : `<p>${t('bin.empty')}</p>`}
  </div>`;
}

function queryBin() {
  return binRequest ??= invoke('recycle_info').catch(() => null).finally(() => { binRequest = null; });
}

async function refreshBin() {
  const b = await queryBin();
  bin = b ?? 'none';
  const changed = overview && b && (overview.bin?.bytes !== b.bytes || overview.bin?.items !== b.items);
  if (changed) overview.bin = b;
  if (scanKey() === 'bin' || (section === 'overview' && changed)) render();
}

/* ---------- Overview ---------- */

function scoreRing(pct, label, text) {
  const c = 2 * Math.PI * 70;
  return `<svg viewBox="0 0 180 180" width="120" height="120" class="ring" role="img" aria-label="${esc(label)}">
    <circle cx="90" cy="90" r="70" class="track"/><circle cx="90" cy="90" r="70" class="fill" stroke-dasharray="${c * pct / 100} ${c}" ${pct ? '' : 'visibility="hidden"'}/>
    <text x="90" y="98" text-anchor="middle">${text}</text></svg>`;
}

function healthView(h, previousScore, checkFailed) {
  const refresh = `<button type="button" class="icon-btn health-refresh" data-action="healthRefresh" aria-label="${t('health.refresh')}" ${overviewLoading ? 'disabled aria-busy="true"' : ''}>${icon('M20 4v5h-5M20 9a8 8 0 1 0 .2 5')}</button>`;
  let status = '';
  if (checkFailed) status = t('health.checkFailed');
  else if (previousScore != null) status = previousScore === h.score
    ? t('health.unchanged', localNumber(h.score))
    : t('health.changed', localNumber(previousScore), localNumber(h.score));
  const note = `<p class="health-status muted" role="status">${status}</p>`;
  if (!h) return `<div class="panel health">${refresh}<button type="button" class="btn primary boost-btn" data-action="boostAsk" ${boostBusy ? 'disabled' : ''}>${t('boost.title')}</button>${note}</div>`;
  const band = h.score >= 80 ? 'good' : h.score >= 50 ? 'fair' : 'poor';
  const destinations = { disk: ['clutter', 'large'], memory: ['performance', 'heavy'], startup: ['performance', 'startup'], junk: ['cleanup', 'junk'] };
  return `<div class="panel health">
    ${refresh}
    <div class="health-score">${scoreRing(h.score, t('health.score', localNumber(h.score)), localNumber(h.score))}${note}</div>
    <div class="health-details">
      <h2>${t('health.' + band)}</h2>
      <p class="muted">${t('health.ram', h.ram.total ? fmt(h.ram.used) : '—', h.ram.total ? fmt(h.ram.total) : '—')}</p>
      ${h.issues.map(i => `<div class="tip"><span>${t('health.issue.' + i)}</span><button type="button" class="btn small" data-go="${destinations[i][0]}" data-go-tab="${destinations[i][1]}">${t('overview.go')}</button></div>`).join('')}
      <button type="button" class="btn primary boost-btn" data-action="boostAsk" ${boostBusy ? 'disabled' : ''}>${t('boost.title')}</button>
    </div>
  </div>`;
}

function overviewView() {
  if (!overview) { if (overviewReady && !overviewLoading) loadOverview(); return header() + spinner(''); }
  const { disk, bin: b, health, downloads } = overview;
  let ring = `<p class="muted">${t('overview.unknown')}</p>`;
  if (disk?.total) {
    const pct = Math.round((disk.total - disk.free) / disk.total * 100);
    const free = t('overview.free', fmt(disk.free), fmt(disk.total));
    ring = scoreRing(pct, free, percent(pct)) + `<p>${free}</p>`;
  }
  const tips = [
    ['cleanup', 'junk', t('overview.tipJunk')],
    ...(b && b.items ? [['cleanup', 'bin', t('overview.tipBin', binSummary(b))]] : []),
    ['clutter', 'large', t('overview.tipLarge')],
    ['apps', null, t('overview.tipApps')],
    ['performance', 'startup', t('overview.tipStartup')],
    ['diskMap', null, t('overview.tipMap')],
  ];
  return header() + `<div class="overview">
    ${healthView(health, overview.previousScore, overview.checkFailed)}
    <div class="panel disk"><h2>${t('overview.disk', 'C:')}</h2>${ring}</div>
    <div class="overview-stats">
      ${statTile('tab.bin', b ? binSummary(b) : '—', SECTIONS[2].icon, '#2FD1A0')}
      ${statTile('overview.downloads', downloads == null ? '—' : fmt(downloads), 'M12 3v12m-5-5 5 5 5-5M4 16v4h16v-4', '#4C8DFF')}
      ${statTile('tab.junk', health?.junk == null ? '—' : fmt(health.junk), broomIcon, '#FFAA3D')}
      ${health?.battery ? statTile('overview.battery', batteryValue(health.battery), 'M3 7h16v10H3zM21 10v4m-9-5-3 4h4l-2 2', '#9BD12E') : ''}
    </div>
    <div class="panel tips"><h2>${t('overview.tips')}</h2>
      ${tips.map(([s, k, text]) => `<div class="tip"><span>${text}</span><button type="button" class="btn small" data-go="${s}" data-go-tab="${k ?? ''}">${t('overview.go')}</button></div>`).join('')}
    </div></div>`;
}

function statTile(label, value, path, tint) {
  return `<div class="panel stat-tile">
    <span class="tinted-icon" style="--icon-tint:${tint}">${icon(path)}</span>
    <span class="stat-label">${t(label)}</span>
    <strong class="stat-value">${value}</strong>
  </div>`;
}

function batteryValue(battery) {
  const healthPercent = percent(battery.health);
  return battery.cycles == null ? healthPercent : `${healthPercent} <small>· ${t('overview.cycles', localNumber(battery.cycles))}</small>`;
}

async function loadOverview(refreshButton) {
  if (overviewLoading) return;
  const previous = overview;
  const restoreFocus = refreshButton && document.activeElement === refreshButton;
  overviewLoading = true;
  if (refreshButton) {
    refreshButton.disabled = true;
    refreshButton.setAttribute('aria-busy', 'true');
  }
  const [health, b, downloads] = await Promise.all([
    invoke('health').catch(() => null),
    queryBin(),
    invoke('downloads_size').catch(() => null),
  ]);
  const disk = health?.disk?.total ? health.disk : await invoke('disk_info').catch(() => null);
  if (overview === previous) {
    overview = {
      disk, bin: b ?? previous?.bin, health: health ?? previous?.health, downloads: downloads ?? previous?.downloads,
      previousScore: refreshButton && health ? previous?.health?.score : undefined,
      checkFailed: Boolean(refreshButton && !health),
    };
  }
  overviewLoading = false;
  if (section === 'overview') {
    const refocus = restoreFocus && (document.activeElement === document.body || document.activeElement === refreshButton);
    render();
    if (refocus) $('[data-action="healthRefresh"]')?.focus();
  }
}

let boostBusy = false;

async function askBoost() {
  if (cleaning || boostBusy || !$('#modal').hidden) return;
  boostBusy = true;
  render();
  const preview = await invoke('boost_preview').catch(() => null);
  boostBusy = false;
  render();
  if (cleaning || !$('#modal').hidden) return;
  if (!preview) return showMessage('boost.title', t('boost.failed'));
  confirmAction('boost.title', t('boost.confirm', fmt(preview.bytes)), 'boost.title', async () => {
    const result = await runCleaning(() => invoke('boost_run')).catch(() => null);
    overview = null;
    bin = null;
    render();
    if (!result) return showMessage('boost.title', t('boost.failed'));
    showMessage('boost.title', t('boost.result', fmt(result.freed), localNumber(result.ram_before), localNumber(result.ram_after)),
      result.failed.length ? t('common.failed', result.failed.length) : '');
  });
}

/* ---------- Apps ---------- */

const apps = { list: null, loading: false, q: '', note: '', expanded: new Set(), next: 0, active: 0, frame: null, dirty: false };
const inUninstall = () => section === 'apps' && scanKey() === 'uninstall';
const appCount = () => t('apps.count', apps.list.length, fmt(apps.list.reduce((sum, a) => sum + a.bytes, 0)));

function appsView() {
  if (apps.list === null) { if (!apps.loading) loadApps(); return spinner(); }
  if (!apps.list.length) return `<div class="center"><p class="muted">${t('apps.none')}</p></div>`;
  apps.dirty = false;
  return `<div class="bar">
      <input type="search" class="search" data-action="appSearch" value="${esc(apps.q)}" placeholder="${t('apps.search')}" aria-label="${t('apps.search')}">
      <span class="grow"></span>${sortMenu()}
      <button type="button" class="btn small" data-action="appsRefresh">${t('apps.refresh')}</button>
    </div>
    ${apps.note ? `<p class="note">${esc(apps.note)}</p>` : ''}
    <div class="panel list" id="appList">${appRows()}</div>
    <div class="actions split"><span class="muted" id="appCount">${appCount()}</span></div>`;
}

function appRows() {
  const q = apps.q.trim().toLowerCase();
  const found = sorted(apps.list.filter(a => !q || a.name.toLowerCase().includes(q) || a.publisher.toLowerCase().includes(q)));
  if (!found.length) return `<p class="muted pad">${t('common.nothing')}</p>`;
  return found.map(a => {
    const expanded = apps.expanded.has(a.id);
    const detailsId = 'appFolders-' + a.index;
    return `<div data-app="${esc(a.id)}">
      <div class="row">
        <button type="button" class="icon-btn app-chevron" data-action="appFolders" aria-expanded="${expanded}" aria-controls="${detailsId}" aria-label="${t('apps.folders', esc(a.name))}">${icon('m6 9 6 6 6-6')}</button>
        <div class="name"><b><bdi>${esc(a.name)}</bdi></b><small>${esc([a.publisher, a.version].filter(Boolean).join(' · '))}</small></div>
        <span class="size">${a.bytes || a.footprint ? fmt(a.bytes) : '—'}</span>
        <button type="button" class="btn small" data-action="appAsk">${t('apps.uninstall')}</button>
      </div>
      <div class="app-folders" id="${detailsId}" ${expanded ? '' : 'hidden'}>${expanded ? appFolders(a) : ''}</div>
    </div>`;
  }).join('');
}

function appFolders(app) {
  const footprint = app.footprint;
  if (!footprint?.files.length) {
    const key = footprint === undefined ? 'apps.measuring' : footprint === null ? 'apps.measureFailed' : 'apps.noFolders';
    return `<p class="muted">${t(key)}</p>`;
  }
  return `<ul>${footprint.files.map(({ path, bytes }) => `<li>
    <bdi>${esc(path)}</bdi><span class="size">${fmt(bytes)}</span>
  </li>`).join('')}</ul>`;
}

function updateAppRows() {
  const list = $('#appList');
  if (!list) return;
  const focused = list.contains(document.activeElement) ? document.activeElement : null;
  const focusedId = focused?.closest('[data-app]')?.dataset.app;
  const scrollTop = list.scrollTop;
  list.innerHTML = appRows();
  if (focusedId) {
    const row = [...list.children].find(row => row.dataset.app === focusedId);
    row?.querySelector(`[data-action="${focused.dataset.action}"]`)?.focus({ preventScroll: true });
  }
  list.scrollTop = scrollTop;
}

function scheduleAppUpdate() {
  if (!apps.dirty || apps.frame !== null || !pageVisible() || cleaning || !inUninstall()) return;
  apps.frame = requestAnimationFrame(() => {
    apps.frame = null;
    const count = $('#appCount');
    if (!apps.dirty || !count || !pageVisible() || cleaning || !inUninstall()) return;
    updateAppRows();
    count.textContent = appCount();
    apps.dirty = false;
  });
}

function pumpFootprints() {
  if (!pageVisible() || cleaning || !inUninstall() || !apps.list) return;
  const list = apps.list;
  while (apps.active < 4 && apps.next < list.length) {
    const app = list[apps.next++];
    apps.active++;
    invoke('app_footprint', { id: app.id }).catch(() => null).then(footprint => {
      app.footprint = footprint;
      if (footprint?.files?.length) app.bytes = footprint.total;
      apps.active--;
      if (apps.list === list) {
        apps.dirty = true;
        scheduleAppUpdate();
      }
      pumpFootprints();
    });
  }
}

async function loadApps() {
  apps.loading = true;
  const list = await invoke('list_apps').catch(() => []);
  apps.list = list.map((app, index) => ({ ...app, index }));
  apps.next = 0;
  apps.loading = false;
  if (inUninstall()) render();
}

/* ---------- Heavy apps and extensions ---------- */

let heavy = null;
let heavyLoading = false;
let heavyNote = '';
let browserExtensions = null;
let extensionsLoading = false;

function heavyView() {
  if (heavy === null) { if (!heavyLoading) loadHeavy(); return spinner(); }
  return `<div class="bar"><span class="grow"></span><button type="button" class="btn small" data-action="heavyRefresh">${t('apps.refresh')}</button></div>
    ${heavyNote ? `<p class="note">${esc(heavyNote)}</p>` : ''}
    <div class="panel list">${heavy.length ? heavy.map(a => `<div class="row" data-heavy="${esc(a.id)}">
      <div class="name"><b title="${esc(a.path)}"><bdi>${esc(a.name)}</bdi></b></div>
      <span class="size">${fmt(a.bytes)}</span><span class="size">${t('heavy.cpu', percent(a.cpu))}</span>
      <button type="button" class="btn small" data-action="heavyQuit">${t('heavy.quit')}</button>
    </div>`).join('') : `<p class="muted pad">${t('common.nothing')}</p>`}</div>`;
}

async function loadHeavy() {
  heavyLoading = true;
  heavy = await invoke('heavy_apps').catch(() => []);
  heavyLoading = false;
  if (scanKey() === 'heavy') render();
}

function extensionsView() {
  if (browserExtensions === null) {
    if (!extensionsLoading) {
      extensionsLoading = true;
      invoke('extensions').catch(() => []).then(rows => {
        browserExtensions = rows;
        extensionsLoading = false;
        if (scanKey() === 'extensions') render();
      });
    }
    return spinner();
  }
  const browsers = [...new Set(browserExtensions.map(e => e.browser))];
  return `<p class="note">${t('extensions.note')}</p><div class="panel list">${browsers.length ? browsers.map(browser =>
    `<h2>${esc(browser)}</h2>` + browserExtensions.filter(e => e.browser === browser).map(e => `<div class="row" data-path="${esc(e.path)}">
      <div class="name"><b><bdi>${esc(e.name)}</bdi></b><small><bdi>${esc(e.version)} · ${esc(e.profile)}</bdi></small></div>
      <span class="size">${fmt(e.bytes)}</span>
      <button type="button" class="btn small" data-action="reveal">${t('extensions.reveal')}</button>
    </div>`).join('')).join('') : `<p class="muted pad">${t('common.nothing')}</p>`}</div>`;
}

/* ---------- Start-up programs (Performance) and suspicious ones (Protection) ---------- */

const boot = { list: null, note: '', admin: false };
const toggleIcon = 'M5 12.5l4.5 4.5L19 7.5';

function startupView(onlySuspicious) {
  if (boot.list === null) { loadStartup(); return spinner(); }
  const list = onlySuspicious ? boot.list.filter(i => i.suspicious) : boot.list;
  if (!boot.list.length) return `<div class="center"><p class="muted">${t('startup.none')}</p></div>`;
  if (!list.length) return `<div class="center"><div class="orb done">${icon(toggleIcon)}</div><p>${t('suspicious.clean')}</p></div>`;
  const on = boot.list.filter(i => i.enabled).length;
  return `<div class="bar"><strong>${onlySuspicious ? t('suspicious.found', list.length) : t('startup.count', on, boot.list.length)}</strong><span class="grow"></span>
      <button type="button" class="btn small" data-action="startupRefresh">${t('apps.refresh')}</button></div>
    ${onlySuspicious ? `<p class="note">${t('suspicious.why')}</p>` : ''}
    ${boot.note ? `<p class="note">${esc(boot.note)}${boot.admin ? ` <button type="button" class="btn small" data-settings="startup">${t('common.openSettings')}</button>` : ''}</p>` : ''}
    <div class="panel list">${sorted(list.map(i => ({ ...i, bytes: 0 }))).map(i => `<div class="row" data-boot="${esc(i.id)}">
      <div class="name"><b><bdi>${esc(i.name)}</bdi> ${i.suspicious ? `<span class="badge risky">${t('suspicious.badge')}</span>` : ''}</b><small title="${esc(i.command)}">${esc(i.command)}</small></div>
      <label class="switch"><input type="checkbox" role="switch" data-action="bootToggle" ${i.enabled ? 'checked' : ''} aria-label="${esc(i.name)}"><span aria-hidden="true"></span></label>
    </div>`).join('')}</div>`;
}

async function loadStartup() {
  boot.list = await invoke('startup_list').catch(() => []);
  render();
}

/* ---------- Camera, microphone and location access (Protection) ---------- */

let access = null;
function accessView() {
  if (access === null) { invoke('privacy_access').catch(() => []).then(a => { access = a; render(); }); return spinner(); }
  if (!access.length) return `<div class="center"><p class="muted">${t('access.none')}</p></div>`;
  const date = s => s ? new Date(s * 1000).toLocaleDateString(lang === 'ar' ? 'ar-EG' : 'en-GB') : t('access.never');
  return `<p class="note">${t('access.why')}</p><div class="panel list">` + ['webcam', 'microphone', 'location'].map(cap => {
    const rows = access.filter(a => a.capability === cap).sort((a, b) => b.last_used - a.last_used);
    if (!rows.length) return '';
    return `<h2>${t('access.' + cap)} <button type="button" class="btn small" data-settings="${cap}">${t('common.openSettings')}</button></h2>` +
      rows.map(a => `<div class="row"><div class="name"><b><bdi>${esc(a.app)}</bdi></b><small>${t('access.lastUsed', date(a.last_used))}</small></div>
        <span class="badge ${a.allowed ? 'review' : 'safe'}">${t(a.allowed ? 'access.allowed' : 'access.denied')}</span></div>`).join('');
  }).join('') + '</div>';
}

/* ---------- Maintenance (Performance) ---------- */

const TASKS = [
  { id: 'dns', path: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c-5 5-5 13 0 18 5-5 5-13 0-18z', tint: '#1FC8D6' },
  { id: 'explorer', path: 'M12 19H5a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v2m0 2v4h-4m4 0-2-2a4 4 0 1 0 0 6', tint: '#F5C542' },
  { id: 'diskCleanup', path: broomIcon, tint: '#2FD1A0' },
  { id: 'storageSense', path: SECTIONS[0].icon, tint: '#7C5CFF' },
  { id: 'defender', path: SECTIONS[3].icon, tint: '#4C8DFF' },
];
const selectedTasks = new Set();
const taskState = {};
let tasksRunning = false;

function maintView() {
  return `<div class="tasks">${TASKS.map(({ id, path, tint }) => {
    const note = t('task.' + id + '.body');
    const status = taskState[id];
    return `<button type="button" class="panel task" data-task="${id}" aria-pressed="${selectedTasks.has(id)}"
      aria-labelledby="task-${id}-title" aria-describedby="task-${id}-note task-${id}-status" ${tasksRunning ? 'disabled' : ''}>
      <span class="tinted-icon" style="--icon-tint:${tint}">${icon(path)}</span>
      <span class="task-check" aria-hidden="true">${icon('m5 12 4 4 10-10')}</span>
      <strong id="task-${id}-title">${t('task.' + id)}</strong>
      <span id="task-${id}-note" class="task-note muted" title="${esc(note)}">${note}</span>
      <span id="task-${id}-status" class="task-status ${status === 'fail' ? 'warn' : status === 'done' ? 'ok' : 'muted'}" role="status">${status ? t('task.' + status) : ''}</span>
    </button>`;
  }).join('')}</div>
  <div class="actions"><button type="button" class="btn big primary" data-action="tasksRun" ${tasksRunning || !selectedTasks.size ? 'disabled' : ''}>${t('task.run')}</button></div>`;
}

function toggleTask(card) {
  const { task: id } = card.dataset;
  if (!selectedTasks.delete(id)) selectedTasks.add(id);
  card.setAttribute('aria-pressed', selectedTasks.has(id));
  $('[data-action="tasksRun"]').disabled = !selectedTasks.size;
}

async function runTasks(ids) {
  tasksRunning = true;
  for (const id of ids) delete taskState[id];
  for (const id of ids) {
    taskState[id] = 'running';
    render();
    taskState[id] = await invoke('run_task', { id }).then(() => 'done', () => 'fail');
  }
  tasksRunning = false;
  render();
}

/* ---------- Update notice ---------- */

async function checkUpdate() {
  const app = window.__TAURI__?.app;
  if (!app) return;
  try {
    const current = await app.getVersion();
    const list = await (await fetch('https://api.github.com/repos/moramadan91/cleanix/releases?per_page=30')).json();
    const num = v => v.split('.').map(Number);
    const newer = (a, b) => { const x = num(a), y = num(b); for (let i = 0; i < 3; i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0); return false; };
    const rel = list.find(r => r.tag_name?.startsWith('win-v') && !r.draft && !r.prerelease);
    if (rel && newer(rel.tag_name.slice(5), current)) {
      updateTag = rel.tag_name;
      renderShell();
    }
  } catch { /* offline: no notice */ }
}
let updateTag = null;

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
const closeModal = () => {
  $('#modal').hidden = true;
  $('#modal').innerHTML = '';
};

function confirmAction(title, message, action, onConfirm) {
  modal(`<h2>${t(title)}</h2><p>${message}</p><div class="actions">
    <button type="button" class="btn" data-modal="cancel">${t('common.cancel')}</button>
    <button type="button" class="btn primary" data-modal="ok">${t(action)}</button></div>`);
  pendingOk = async () => { closeModal(); await onConfirm(); };
}

function showMessage(title, message, detail = '') {
  modal(`<h2>${t(title)}</h2><p role="status">${message}</p>${detail ? `<p class="warn">${detail}</p>` : ''}
    <div class="actions"><button type="button" class="btn primary" data-modal="cancel">${t('common.close')}</button></div>`);
  pendingOk = null;
}

let settingsLoading = false;
async function openSettings() {
  if (settingsLoading) return;
  settingsLoading = true;
  const settings = await invoke('settings_get').catch(() => null);
  settingsLoading = false;
  if (cleaning) return;
  if (!settings) return showMessage('settings.title', t('settings.failed'));
  const switches = [
    ['openAtLogin', 'open_at_login', 'settings.login', 'settings.loginNote'],
    ['alertLowSpace', 'alert_low_space', 'settings.lowSpace'],
    ['alertWeekly', 'alert_weekly', 'settings.weekly'],
  ];
  modal(`<h2>${t('settings.title')}</h2><p>${t('settings.note')}</p>
    ${switches.map(([key, value, label, note]) => `<div class="row">
      <div class="name"><b id="${key}-label">${t(label)}</b>${note ? `<small>${t(note)}</small>` : ''}</div>
      <label class="switch"><input id="${key}" type="checkbox" role="switch" aria-labelledby="${key}-label" ${settings[value] ? 'checked' : ''}><span aria-hidden="true"></span></label>
    </div>`).join('')}
    <div class="actions"><button type="button" class="btn" data-modal="cancel">${t('common.cancel')}</button>
    <button type="button" class="btn primary" data-modal="ok">${t('settings.save')}</button></div>`);
  pendingOk = async () => {
    const args = Object.fromEntries(switches.map(([key]) => [key, $('#' + key).checked]));
    closeModal();
    await invoke('settings_set', args).catch(() => showMessage('settings.title', t('settings.failed')));
  };
}

function askClean(items, onDone) {
  const bytes = items.reduce((s, i) => s + i.bytes, 0);
  modal(`<h2>${t('preview.title')}</h2><p>${t('preview.body', items.length, fmt(bytes))}</p>
    <ul class="mini">${sorted(items).slice(0, 40).map(i => `<li><span>${esc(i.name)}</span><span>${fmt(i.bytes)}</span></li>`).join('')}</ul>
    <div class="actions"><button type="button" class="btn" data-modal="cancel">${t('common.cancel')}</button>
    <button type="button" class="btn primary" data-modal="ok">${t('preview.confirm')}</button></div>`);
  pendingOk = async () => {
    closeModal();
    const paths = items.map(i => i.path);
    const result = await runCleaning(() => invoke('clean', { paths })).catch(() => ({ freed: 0, removed: [], failed: paths }));
    overview = null;
    bin = null;
    onDone(result);
  };
}
let pendingOk = null;

/* ---------- events ---------- */

document.addEventListener('click', async e => {
  if (cleaning) return;
  const el = e.target.closest('[data-section],[data-tab],[data-action],[data-go],[data-crumb],[data-modal],[data-open],[data-settings],[data-task],#lang,#update,#settings');
  if (!el) return;
  if (el.id === 'update') return invoke('open_release', { tag: updateTag }).catch(() => {});
  if (el.dataset.settings) return invoke('open_settings', { page: el.dataset.settings }).catch(() => {});
  if (el.id === 'settings') return openSettings();
  if (el.dataset.task) return toggleTask(el);
  if (el.id === 'lang') {
    lang = lang === 'ar' ? 'en' : 'ar';
    store('cleanix.lang', lang);
    syncLang();
    return renderShell();
  }
  if (el.dataset.section) {
    section = el.dataset.section;
    if (scanKey() === 'bin') bin = null;
    renderShell();
    if (section === 'overview' && overview) refreshBin();
    return $('#main').focus();
  }
  if (el.dataset.tab) { tab[section] = el.dataset.tab; if (el.dataset.tab === 'bin') bin = null; return render(); }
  if (el.dataset.go) { section = el.dataset.go; if (el.dataset.goTab) tab[section] = el.dataset.goTab; if (el.dataset.goTab === 'bin') bin = null; return renderShell(); }
  if (el.dataset.crumb) { map.trail = map.trail.slice(0, +el.dataset.crumb + 1); map.selected = new Set(); return render(); }
  if (el.dataset.modal) {
    const action = pendingOk;
    pendingOk = null;
    if (el.dataset.modal === 'ok' && action) await action();
    else closeModal();
    return;
  }

  const path = el.closest('[data-path]')?.dataset.path;
  const v = views[scanKey()];
  const app = apps.list?.find(a => a.id === el.closest('[data-app]')?.dataset.app);
  switch (el.dataset.action) {
    case 'scan': return scan();
    case 'undoClean': return invoke('open_recycle_bin').catch(() => showMessage('common.undo', t('bin.openFailed')));
    case 'healthRefresh': return loadOverview(el);
    case 'tick': return; // handled on change
    case 'mapTick': return;
    case 'all': v.items.forEach(i => i.safety !== 'risky' && v.selected.add(i.path)); return render();
    case 'none': v.selected.clear(); return render();
    case 'reveal': return invoke('reveal', { path }).catch(() => {});
    case 'up': map.trail.pop(); map.selected = new Set(); return render();
    case 'preview':
      return askClean(v.items.filter(i => v.selected.has(i.path)), r => { v.result = r; v.phase = 'done'; render(); });
    case 'mapPreview': {
      const cur = map.trail.at(-1);
      return askClean(cur.nodes.filter(n => map.selected.has(n.path)), result => {
        reloadMap();
        if (result.failed.length) showMessage('common.remove', t('common.failed', result.failed.length));
      });
    }
    case 'startupRefresh': boot.list = null; boot.note = ''; return render();
    case 'appsRefresh':
      apps.list = null; apps.note = ''; apps.expanded.clear(); apps.dirty = false;
      return render();
    case 'appFolders': {
      const expanded = !apps.expanded.delete(app.id);
      if (expanded) apps.expanded.add(app.id);
      el.setAttribute('aria-expanded', expanded);
      const details = document.getElementById(el.getAttribute('aria-controls'));
      details.hidden = !expanded;
      details.innerHTML = expanded ? appFolders(app) : '';
      return;
    }
    case 'appAsk':
      modal(`<h2>${t('apps.confirmTitle', esc(app.name))}</h2><p>${t('apps.confirmBody', esc(app.name))}</p>
        <div class="actions"><button type="button" class="btn" data-modal="cancel">${t('common.cancel')}</button>
        <button type="button" class="btn danger" data-modal="ok">${t('apps.open')}</button></div>`);
      pendingOk = async () => {
        closeModal();
        const ok = await runCleaning(() => invoke('uninstall', { id: app.id })).then(() => true, () => false);
        apps.note = t(ok ? 'apps.launched' : 'apps.failed', app.name);
        render();
      };
      return;
    case 'binAsk':
      modal(`<h2>${t('bin.confirmTitle')}</h2><p>${t('bin.confirmBody')}</p>
        <div class="actions"><button type="button" class="btn" data-modal="cancel">${t('common.cancel')}</button>
        <button type="button" class="btn danger" data-modal="ok">${t('bin.action')}</button></div>`);
      pendingOk = async () => {
        closeModal();
        const ok = await runCleaning(() => invoke('empty_recycle', { confirmed: true })).then(() => true, () => false);
        overview = null;
        bin = null;
        await refreshBin();
        if (!ok) showMessage('bin.action', t('bin.emptyFailed'));
      };
      return;
    case 'boostAsk': return askBoost();
    case 'tasksRun': {
      if (tasksRunning || !selectedTasks.size) return;
      const ids = TASKS.map(({ id }) => id).filter(id => selectedTasks.has(id));
      if (ids.includes('explorer')) {
        return confirmAction('task.explorer', t('task.explorer.confirm'), 'task.run', () => runTasks(ids));
      }
      return runTasks(ids);
    }
    case 'heavyRefresh': heavy = null; heavyNote = ''; return render();
    case 'heavyQuit': {
      const app = heavy?.find(a => a.id === el.closest('[data-heavy]')?.dataset.heavy);
      if (!app) return;
      return confirmAction('heavy.quit', t('heavy.confirm', esc(app.name)), 'heavy.quit', async () => {
        heavyNote = await invoke('quit_app', { id: app.id }).then(() => '', () => t('heavy.failed', app.name));
        heavy = null;
        render();
      });
    }
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
  if (el.dataset.action === 'bootToggle') return toggleBoot(el);
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

async function toggleBoot(el) {
  const item = boot.list.find(i => i.id === el.closest('[data-boot]').dataset.boot);
  el.disabled = true;
  const err = await invoke('startup_set', { id: item.id, enabled: el.checked }).then(() => null, e => String(e));
  if (err === null) { item.enabled = el.checked; boot.note = ''; boot.admin = false; }
  else { boot.admin = err === 'admin'; boot.note = t(boot.admin ? 'startup.admin' : 'startup.failed', item.name); }
  render();
}

document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && !$('#modal').hidden) { closeModal(); pendingOk = null; }
  // Folder rows open with Enter like a click.
  if (e.key === 'Enter' && e.target.matches?.('.row.dir')) e.target.click();
});

let langUpdate = Promise.resolve();
function syncLang() {
  const selected = lang;
  langUpdate = langUpdate.then(() => invoke('set_lang', { lang: selected })).catch(() => {});
}
function syncVisibility() {
  const visible = pageVisible();
  document.documentElement.toggleAttribute('data-paused', !visible);
  if (!visible) {
    if (apps.frame !== null) cancelAnimationFrame(apps.frame);
    apps.frame = null;
    return;
  }
  if (!overviewReady) {
    overviewReady = true;
    if (section === 'overview') render();
    checkUpdate();
  } else if ((section === 'overview' && overview) || scanKey() === 'bin') {
    refreshBin();
  }
  scheduleAppUpdate();
  pumpFootprints();
}
document.addEventListener('visibilitychange', syncVisibility);
renderShell();
syncLang();
syncVisibility();
if (window.__TAURI__) {
  const api = window.__TAURI__;
  let receivedVisibilityEvent = false;
  const updateVisibility = visible => {
    receivedVisibilityEvent = true;
    windowVisible = visible;
    syncVisibility();
  };
  api.event.listen('tray-boost', askBoost).catch(() => {});
  Promise.all([
    api.event.listen('window-hidden', () => updateVisibility(false)),
    api.event.listen('window-shown', () => updateVisibility(true)),
  ]).then(async () => {
    const mainWindow = api.window.getCurrentWindow();
    const visible = await mainWindow.isVisible() && !(await mainWindow.isMinimized());
    if (!receivedVisibilityEvent) updateVisibility(visible);
  }).catch(() => {});
}
