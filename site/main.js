import gsap from 'https://cdn.jsdelivr.net/npm/gsap@3.12.5/+esm';
import { ScrollTrigger } from 'https://cdn.jsdelivr.net/npm/gsap@3.12.5/ScrollTrigger/+esm';
import Lenis from 'https://cdn.jsdelivr.net/npm/lenis@1.1.13/+esm';

gsap.registerPlugin(ScrollTrigger);
const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];
const motionOK = matchMedia('(prefers-reduced-motion: no-preference)').matches;
const html = document.documentElement;
const arabicDigits = new Intl.NumberFormat('ar-EG', { numberingSystem: 'arab' });

/* Seeded noise (mulberry32): the junk lands in the same places on every visit. */
function rng(seed) {
  return () => {
    seed |= 0; seed = seed + 0x6D2B79F5 | 0;
    let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}

/* ---------- language ---------- */
const langBtn = $('#lang');
let lenis = null; // set below when motion is on
function applyLang(l) {
  html.lang = l; html.dir = l === 'ar' ? 'rtl' : 'ltr';
  langBtn.textContent = l === 'ar' ? 'English' : 'العربية';
  document.title = l === 'ar' ? 'Cleanix — نضّف الماك ببلاش' : 'Cleanix — Clean your Mac, free';
  try { localStorage.setItem('cleanix.lang', l); } catch (e) {}
  fillTicker();
}
let saved = null;
try { saved = localStorage.getItem('cleanix.lang'); } catch (e) {}
// shortcut: the cut is a one-off bands wipe, so the switch reads like a channel change.
langBtn.addEventListener('click', () => {
  const next = html.lang === 'ar' ? 'en' : 'ar';
  if (!motionOK) { applyLang(next); warmShots(); ScrollTrigger.refresh(); scrollTo(0, 0); return; }
  const cut = $('#cut'), bands = $$('i', cut);
  gsap.timeline()
    .set(cut, { visibility: 'visible' })
    .fromTo(bands, { scaleX: 0, transformOrigin: i => (i % 2 ? '0% 50%' : '100% 50%') },
      { scaleX: 1, duration: 0.22, ease: 'power3.in', stagger: { each: 0.018, from: 'random' } })
    // Behind the cut: new language, and the page starts over from the top.
    .call(() => { applyLang(next); warmShots(); ScrollTrigger.refresh(); lenis.scrollTo(0, { immediate: true, force: true }); })
    .to(bands, { scaleX: 0, transformOrigin: i => (i % 2 ? '100% 50%' : '0% 50%'), duration: 0.26, ease: 'power3.out', stagger: { each: 0.018, from: 'random' } })
    .set(cut, { visibility: 'hidden' });
});

/* ---------- ticker words follow the language ---------- */
const TICK = {
  ar: [['فحص شامل', 'كاش', 'بقايا برامج', 'صور متشابهة', 'سلة المهملات', 'تسريع فوري', 'حالة الماك'], ['خريطة القرص', 'الفرّامة', 'المكرر', 'التنزيلات', 'الخصوصية', 'إضافات المتصفح', 'التطبيقات التقيلة']],
  en: [['Smart Scan', 'Caches', 'Leftovers', 'Similar photos', 'Trash', 'Quick Boost', 'Mac health'], ['Disk Map', 'Shredder', 'Duplicates', 'Downloads', 'Privacy', 'Extensions', 'Heavy apps']],
};
function fillTicker() {
  const set = TICK[html.lang === 'en' ? 'en' : 'ar'];
  [$('#tick1'), $('#tick2')].forEach((row, r) => {
    const words = [...set[r], ...set[r], ...set[r], ...set[r]];
    row.innerHTML = words.map(w => `<span>${w}</span>`).join('');
  });
}
applyLang(saved || (navigator.language.startsWith('ar') ? 'ar' : 'en'));

/* Feature screenshots are small (~30 KB): fetch the shown language's set once the page has loaded, so a
   scene never opens on an empty frame while a lazy image is still downloading on a phone. */
function warmShots() { $$('.screen img').forEach(i => { if (getComputedStyle(i).display !== 'none') i.loading = 'eager'; }); }
if (document.readyState === 'complete') warmShots(); else addEventListener('load', warmShots);

/* ---------- latest version on the download buttons ---------- */
fetch('https://api.github.com/repos/moramadan91/cleanix/releases/latest')
  .then(r => (r.ok ? r.json() : null))
  .then(j => { if (j?.tag_name) $$('.ver').forEach(v => { v.textContent = j.tag_name; }); })
  .catch(() => {});

if (motionOK) {
  // The page is a story that starts with the intro: a reload opens at the top (a #section link still works).
  // ScrollTrigger owns history.scrollRestoration, so set it through its API.
  if (!location.hash) { ScrollTrigger.clearScrollMemory('manual'); scrollTo(0, 0); }
  // Phones: the address bar showing/hiding resizes the screen; don't recompute every scene for that.
  ScrollTrigger.config({ ignoreMobileResize: true });
  /* ---------- one loop: GSAP drives Lenis, ScrollTrigger reads it ---------- */
  lenis = new Lenis({ lerp: 0.1, autoRaf: false, anchors: { offset: -60 } });
  lenis.on('scroll', ScrollTrigger.update);
  gsap.ticker.add(t => lenis.raf(t * 1000));
  gsap.ticker.lagSmoothing(0);

  buildMess();
  $$('.scene').forEach(buildScene);
  buildTicker();
  buildSafety();
  buildGet();
  document.fonts?.ready.then(() => ScrollTrigger.refresh());
  addEventListener('load', () => ScrollTrigger.refresh());
}

/* ---------- 1. the mess ---------- */
function buildMess() {
  const FILES = [
    ['cache.db', '48 MB', 'log'], ['Installer-old.dmg', '1.2 GB', 'zip'], ['IMG_2041 copy.jpg', '6 MB', 'img'],
    ['backup (1).zip', '340 MB', 'zip'], ['system.log', '12 MB', 'log'], ['render-final-v3.mov', '2.4 GB', 'vid'],
    ['DerivedData', '3.1 GB', 'doc'], ['Screenshot 2024.png', '4 MB', 'img'], ['report-final-FINAL.pdf', '9 MB', 'doc'],
    ['Slack Cache', '610 MB', 'log'], ['IMG_2041.jpg', '6 MB', 'img'], ['node_modules', '890 MB', 'doc'],
    ['Downloads.zip', '1.6 GB', 'zip'], ['temp-export.mov', '780 MB', 'vid'], ['Chrome Cache', '1.1 GB', 'log'],
    ['old-video.mov', '150 MB', 'vid'], ['crash-report.ips', '2 MB', 'log'], ['IMG_2041 (2).jpg', '6 MB', 'img'],
    ['setup.pkg', '220 MB', 'zip'], ['.DS_Store', '12 KB', 'doc'], ['Mail Downloads', '95 MB', 'doc'],
    ['photo-edit.psd', '410 MB', 'img'], ['Zoom.pkg', '90 MB', 'zip'], ['debug.log', '30 MB', 'log'],
  ];
  const ICON = {
    doc: '<path d="M6 3h8l4 4v14H6Z"/><path d="M14 3v4h4"/>',
    zip: '<path d="M6 3h12v18H6Z"/><path d="M12 3v2m0 2v2m0 2v2"/><rect x="10.5" y="13" width="3" height="4" rx="1"/>',
    img: '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="9" cy="10" r="2"/><path d="m21 16-5-5-8 8"/>',
    vid: '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/>',
    log: '<path d="M6 3h12v18H6Z"/><path d="M9 8h6M9 12h6M9 16h4"/>',
  };
  const box = $('#junk'), rand = rng(20261122);
  const wide = innerWidth > 860, N = wide ? 34 : 18;
  for (let i = 0; i < N; i++) {
    const [name, size, kind] = FILES[i % FILES.length];
    let fx, fy;
    do { fx = rand(); fy = rand(); } while (((fx - 0.5) / 0.3) ** 2 + ((fy - 0.5) / 0.34) ** 2 < 1); // keep the middle free
    const el = document.createElement('div');
    el.className = `chip k-${kind}`;
    el.style.left = `calc(${fx} * (100% - ${wide ? 230 : 160}px) + 8px)`; el.style.top = `calc(${fy} * (100% - 120px) + 60px)`;
    el.innerHTML = `<div class="ci" style="--d:${4 + rand() * 4}s;--dl:${-rand() * 6}s;--r:${(rand() - 0.5) * 16}deg"><svg viewBox="0 0 24 24">${ICON[kind] === undefined ? ICON.doc : ICON[kind]}</svg><span>${name}</span><small>${size}</small></div>`;
    box.appendChild(el);
  }
  const chips = $$('.chip', box), pin = $('.mess-pin'), mark = $('#heroMark');
  const glitch = () => { mark.classList.remove('hit'); void mark.offsetWidth; mark.classList.add('hit'); };

  // Arrival: the logo tears in, the junk pops up around it.
  gsap.timeline({ delay: 0.15 })
    .from(mark, { scale: 1.25, opacity: 0, duration: 0.5, ease: 'expo.out', onStart: glitch })
    .from('.t-before', { yPercent: 40, opacity: 0, duration: 0.7, ease: 'expo.out' }, 0.25)
    .from(chips, { scale: 0, opacity: 0, duration: 0.6, ease: 'back.out(2)', stagger: { each: 0.025, from: 'random' } }, 0.3)
    .from('.scroll-hint', { opacity: 0, y: 10, duration: 0.5 }, 0.9);

  // Scroll: everything is pulled into the mark.
  const toCenter = (el, axis) => () => {
    const r = pin.getBoundingClientRect();
    return axis === 'x'
      ? r.width / 2 - (el.offsetLeft + el.offsetWidth / 2)
      : r.height / 2 - (el.offsetTop + el.offsetHeight / 2);
  };
  const order = chips.map((el, i) => ({ el, d: Math.hypot(el.offsetLeft - pin.clientWidth / 2, el.offsetTop - pin.clientHeight / 2), i }))
    .sort((a, b) => a.d - b.d);
  const count = { n: 0 }, out = $('#count');
  let clean = false;
  const tl = gsap.timeline({
    scrollTrigger: {
      trigger: '.mess', start: 'top top', end: 'bottom bottom', scrub: 0.6, invalidateOnRefresh: true,
      onUpdate(st) {
        const now = st.progress > 0.78;
        if (now === clean) return;
        clean = now; glitch();
        gsap.to('.t-before', { opacity: now ? 0 : 1, yPercent: now ? -30 : 0, duration: 0.3, overwrite: true });
        gsap.to('.t-after', { opacity: now ? 1 : 0, yPercent: now ? 0 : 30, duration: 0.3, overwrite: true });
      },
    },
  });
  tl.to('.scroll-hint', { opacity: 0, duration: 0.04 }, 0)
    .to('.counter', { opacity: 1, duration: 0.05 }, 0.03)
    .to('.vortex', { opacity: 1, duration: 0.1 }, 0.04)
    .to('.vortex .v1', { rotation: 900, svgOrigin: '0 0', ease: 'none', duration: 0.9 }, 0.04)
    .to('.vortex .v2', { rotation: -620, svgOrigin: '0 0', ease: 'none', duration: 0.9 }, 0.04)
    .to('.vortex .v3', { rotation: 1100, svgOrigin: '0 0', ease: 'none', duration: 0.9 }, 0.04)
    .to(count, { n: chips.length, duration: 0.72, ease: 'none', onUpdate: () => { out.textContent = Math.round(count.n); } }, 0.08);
  order.forEach(({ el }, k) => {
    const spin = (k % 2 ? 1 : -1) * (300 + (k * 37) % 300);
    // Explicit start values: a refresh during the arrival pop (or a reload mid-page) must not record "hidden" as the start.
    tl.fromTo(el, { x: 0, y: 0, rotation: 0, scale: 1, opacity: 1 },
      { x: toCenter(el, 'x'), y: toCenter(el, 'y'), rotation: spin, scale: 0.05, opacity: 0, ease: 'power3.in', duration: 0.2, immediateRender: false },
      0.08 + (k / order.length) * 0.58);
  });
  tl.fromTo(mark, { scale: 1, opacity: 1 }, { scale: 1.18, duration: 0.12, ease: 'power2.out', immediateRender: false }, 0.7)
    .to(mark, { scale: 1, duration: 0.1, ease: 'power2.in' }, 0.82)
    .to('.vortex', { opacity: 0, scale: 1.4, duration: 0.12 }, 0.8)
    .to('.counter', { opacity: 0.6, duration: 0.1 }, 0.9);
}

/* ---------- 2. scenes ---------- */
function splitWords(h) {
  $$('span[data-ar], span[data-en]', h).forEach(s => {
    // The space lives inside each word: between inline-blocks Chrome drops most spaces in Arabic.
    const words = s.textContent.trim().split(/\s+/);
    s.innerHTML = words.map((w, i) => `<span class="w">${w}${i < words.length - 1 ? ' ' : ''}</span>`).join('');
  });
}
function buildScene(sec) {
  const h = $('h2', sec), p = $('.scene-copy p:last-child', sec), stage = $('.stage', sec);
  const screen = $('.screen', sec), imgs = $$('img', screen), orb = $('.orb', sec);
  splitWords(h);
  // Starts while the scene is still sliding in, so the next feature is already showing under the current one.
  const tl = gsap.timeline({ scrollTrigger: { trigger: sec, start: 'top 75%', end: 'bottom bottom', scrub: 1.2 } });
  tl.from($('.scene-no', sec), { opacity: 0, x: -20, duration: 0.08 }, 0)
    .from($$('.w', h), { yPercent: 120, rotation: 8, opacity: 0, duration: 0.18, stagger: 0.02, ease: 'back.out(1.6)' }, 0.02)
    .from(p, { opacity: 0, y: 24, duration: 0.12 }, 0.12)
    .from(orb, { scale: 0, rotation: -140, duration: 0.18, ease: 'back.out(1.8)' }, 0.04)
    .to(orb, { rotation: 20, duration: 0.12 }, 0.22)
    // the icon opens into the real screen
    .to(screen, { clipPath: 'circle(80% at 50% 50%)', duration: 0.2, ease: 'power3.inOut' }, 0.3)
    .to(orb, { scale: 3.2, opacity: 0, duration: 0.18, ease: 'power2.in' }, 0.3)
    .fromTo(stage, { y: 60 }, { y: -30, duration: 1, ease: 'none' }, 0);
  if (imgs.length) tl.to(imgs, { opacity: 1, duration: 0.1 }, 0.4);

  const kind = sec.dataset.scene;
  if (kind === 'scan') {
    const beam = $('.beam', sec);
    tl.set(beam, { top: '0%' }, 0.5)
      .to(beam, { opacity: 1, duration: 0.02 }, 0.5)
      .to(beam, { top: '100%', duration: 0.16, ease: 'none' }, 0.52)
      .to(beam, { top: '0%', duration: 0.16, ease: 'none' }, 0.68)
      .to(beam, { opacity: 0, duration: 0.03 }, 0.84)
      .to(screen, { scale: 1.03, duration: 0.05, yoyo: true, repeat: 1 }, 0.84);
  }
  if (kind === 'apps') {
    const box = $('.shards', sec), r = rng(7);
    for (let i = 0; i < 16; i++) {
      const s = document.createElement('i');
      s.style.left = `${70 + (i % 4) * 4}%`; s.style.top = `${10 + Math.floor(i / 4) * 6}%`;
      box.appendChild(s);
    }
    const shards = $$('i', box);
    tl.to(shards, { opacity: 1, duration: 0.06, stagger: 0.004 }, 0.5)
      .to(shards, {
        x: () => (r() - 0.3) * 520, y: () => 160 + r() * 360, rotation: () => (r() - 0.5) * 720,
        scale: () => 0.3 + r() * 0.6, opacity: 0, duration: 0.3, ease: 'power2.in', stagger: { each: 0.01, from: 'random' },
      }, 0.62);
  }
  if (kind === 'clutter') {
    const cards = $$('.dupes i', sec);
    tl.fromTo(cards, { opacity: 0, x: 0, rotation: 0, scale: 0.6 },
      { opacity: 1, scale: 1, x: i => (i - 2) * 120, y: i => Math.abs(i - 2) * 18, rotation: i => (i - 2) * 9, duration: 0.14, ease: 'back.out(1.5)', stagger: 0.015 }, 0.5)
      .to(cards, { x: 0, y: 0, rotation: 0, duration: 0.14, ease: 'power3.in' }, 0.7)
      .to(cards.slice(1), { opacity: 0, duration: 0.02 }, 0.84)
      .to(cards[0], { scale: 1.25, duration: 0.05, ease: 'power2.out' }, 0.84)
      .to(cards[0], { scale: 0, opacity: 0, duration: 0.08, ease: 'power2.in' }, 0.9);
  }
  if (kind === 'disk') {
    const svg = $('.ring', sec), C = 2 * Math.PI * 50, cols = ['#F5C542', '#FFE08A', '#C99212', '#FFF1C2', '#E0A82E', '#8A5A0E'];
    let off = 0;
    [0.24, 0.18, 0.15, 0.13, 0.12, 0.1].forEach((f, i) => {
      const c = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      c.setAttribute('r', 50); c.setAttribute('stroke', cols[i]);
      c.setAttribute('stroke-dasharray', `${f * C - 3} ${C}`); c.setAttribute('stroke-dashoffset', -off * C);
      svg.appendChild(c); off += f;
    });
    const arcs = $$('circle', svg);
    tl.fromTo(arcs, { opacity: 0, scale: 0.3, rotation: -200, svgOrigin: '0 0' },
      { opacity: 1, scale: 1, rotation: 0, svgOrigin: '0 0', duration: 0.18, ease: 'back.out(1.4)', stagger: 0.02 }, 0.5)
      .to(arcs, { scale: i => 1.3 + i * 0.12, opacity: 0, rotation: i => (i % 2 ? 60 : -60), svgOrigin: '0 0', duration: 0.16, ease: 'power2.in', stagger: 0.01 }, 0.78);
  }
  if (kind === 'health') {
    const ring = $('.health-ring', sec), arc = $('.health-progress', ring), score = $('text', ring);
    const health = { value: 0 };
    tl.to(ring, { opacity: 1, duration: 0.04 }, 0.5)
      .to(health, {
        value: 100, duration: 0.24, ease: 'none',
        onUpdate() {
          const value = Math.round(health.value);
          arc.setAttribute('stroke-dashoffset', 100 - health.value);
          score.textContent = html.lang === 'ar' ? arabicDigits.format(value) : String(value);
        },
      }, 0.5)
      .to(ring, { scale: 1.25, opacity: 0, duration: 0.1, ease: 'power2.in' }, 0.74);
  }
  if (kind === 'menubar') {
    const button = $('.boost-button', sec), confirm = $('.boost-confirm', sec), result = $('.boost-result', sec);
    const ramAr = $('[data-ar] .boost-ram', sec), ramEn = $('[data-en] .boost-ram', sec);
    const cpuAr = $('[data-ar] .boost-cpu', sec), cpuEn = $('[data-en] .boost-cpu', sec);
    const memoryBar = $('.boost-memory-bar', sec), cpuBar = $('.boost-cpu-bar', sec);
    const usage = { ram: 78, cpu: 41 };
    tl.to(button, { scale: 0.92, duration: 0.035, ease: 'power2.in' }, 0.5)
      .to(button, { scale: 1, duration: 0.055, ease: 'power2.out' }, 0.535)
      .to(confirm, { opacity: 1, duration: 0.04 }, 0.57)
      .to(confirm, { opacity: 0, duration: 0.04 }, 0.67)
      .to(result, { opacity: 1, duration: 0.05 }, 0.71)
      .to(usage, {
        ram: 61, cpu: 12, duration: 0.13, ease: 'none',
        onUpdate() {
          const ram = Math.round(usage.ram), cpu = Math.round(usage.cpu);
          ramAr.textContent = arabicDigits.format(ram);
          cpuAr.textContent = arabicDigits.format(cpu);
          ramEn.textContent = String(ram);
          cpuEn.textContent = String(cpu);
          memoryBar.style.width = `${usage.ram}%`;
          cpuBar.style.width = `${usage.cpu}%`;
        },
      }, 0.71);
  }
  tl.to(stage, { scale: 0.9, opacity: 0.3, rotationX: 12, transformPerspective: 900, duration: 0.1 }, 0.88)
    .to($('.scene-copy', sec), { opacity: 0, y: -30, duration: 0.08 }, 0.88);
}

/* ---------- 3. ticker: drifts on its own, speeds up with the scroll ---------- */
function buildTicker() {
  const rows = [$('#tick1'), $('#tick2')];
  const loops = rows.map((row, i) => gsap.fromTo(row, { xPercent: i ? -50 : 0 }, { xPercent: i ? 0 : -50, duration: 40, ease: 'none', repeat: -1 }));
  ScrollTrigger.create({
    trigger: '.more', start: 'top bottom', end: 'bottom top',
    onUpdate(st) {
      const v = Math.min(Math.abs(st.getVelocity()) / 200, 12);
      loops.forEach(l => gsap.to(l, { timeScale: 1 + v, duration: 0.3, overwrite: true }));
    },
  });
  gsap.from('.more-list li', { opacity: 0, y: 30, stagger: 0.06, duration: 0.6, ease: 'power3.out', scrollTrigger: { trigger: '.more-list', start: 'top 80%' } });
}

/* ---------- 4. safety: into quarantine, the days run, Undo brings it back ---------- */
function buildSafety() {
  const chip = $('.travel'), boxEl = $('.box'), vault = $('.vault'), days = { d: 30 }, out = $('#days');
  const toBox = () => vault.clientWidth - boxEl.offsetWidth / 2 - chip.offsetWidth / 2;
  gsap.timeline({ scrollTrigger: { trigger: '.safety', start: 'top top', end: 'bottom bottom', scrub: 0.6, invalidateOnRefresh: true } })
    // fromTo, not from: invalidateOnRefresh would re-read a hidden start state as the end state.
    .fromTo('.safety-copy > *', { opacity: 0, y: 30 }, { opacity: 1, y: 0, stagger: 0.05, duration: 0.15 }, 0)
    .to(chip, { x: toBox, scale: 0.7, rotation: -6, duration: 0.25, ease: 'power3.inOut' }, 0.12)
    .to(chip, { opacity: 0.3, duration: 0.05 }, 0.34) // stored behind the countdown, so the number stays readable
    .to(boxEl, { borderColor: '#6035F5', borderStyle: 'solid', duration: 0.05 }, 0.34)
    .to(days, { d: 1, duration: 0.3, ease: 'none', onUpdate: () => { out.textContent = Math.round(days.d); } }, 0.38)
    .to('.undo', { opacity: 1, y: -10, duration: 0.06, ease: 'back.out(2)' }, 0.7)
    .to('.undo', { scale: 0.92, duration: 0.03, yoyo: true, repeat: 1 }, 0.78)
    .to(chip, { x: 0, scale: 1, rotation: 0, opacity: 1, duration: 0.18, ease: 'power3.inOut' }, 0.82)
    .to(boxEl, { borderColor: 'rgba(234,228,255,0.4)', borderStyle: 'dashed', duration: 0.05 }, 0.85);
}

/* ---------- 5. the wordmark draws itself, then the steps ---------- */
function buildGet() {
  gsap.fromTo('.huge-word', { clipPath: 'inset(0 100% 0 0)' },
    { clipPath: 'inset(0 0% 0 0)', ease: 'none', scrollTrigger: { trigger: '.get', start: 'top 85%', end: 'top 25%', scrub: 0.6 } });
  gsap.from('.get h2, .get .cta-row', { opacity: 0, y: 30, stagger: 0.1, duration: 0.7, ease: 'power3.out', scrollTrigger: { trigger: '.get h2', start: 'top 85%' } });
  gsap.from('.steps li', { opacity: 0, y: 40, stagger: 0.08, duration: 0.7, ease: 'power3.out', scrollTrigger: { trigger: '.steps', start: 'top 85%' } });
  gsap.from('.intro > *', { opacity: 0, y: 40, stagger: 0.1, duration: 0.8, ease: 'power3.out', scrollTrigger: { trigger: '.intro', start: 'top 70%' } });
}
