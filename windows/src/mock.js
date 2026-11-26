// Design-preview stand-in for the Rust side, used only when the page runs outside the app.
const H = 'C:\\Users\\Demo';
const mk = (path, bytes, group, safety = 'safe') => ({ path, name: path.split('\\').pop(), bytes, group, safety });
const MB = 1024 * 1024;
const installed = [
  ['Adobe Photoshop 2025', 'Adobe Inc.', '26.1', 4800],
  ['Google Chrome', 'Google LLC', '131.0', 620],
  ['Zoom Workplace', 'Zoom Communications', '6.2.5', 310],
  ['7-Zip 24.08 (x64)', 'Igor Pavlov', '24.08', 5],
  ['Steam', 'Valve Corporation', '2.10', 0],
  ['Microsoft Teams', 'Microsoft Corporation', '24295', 740],
  ['Unity', 'Unity Technologies', '6000.0', 600],
].map(([name, publisher, version, mb], i) => ({ id: 'lm64\\app' + i, name, publisher, version, bytes: mb * MB }));
const footprints = [
  [['C:\\Program Files\\Adobe\\Adobe Photoshop 2025', 5150], [H + '\\AppData\\Roaming\\Adobe Photoshop 2025', 320]],
  [['C:\\Program Files\\Google\\Chrome\\Application', 620], [H + '\\AppData\\Local\\Google Chrome', 390]],
  [[H + '\\AppData\\Local\\Programs\\Zoom Workplace', 390]],
  [['C:\\Program Files\\7-Zip', 6]],
  [['C:\\Program Files (x86)\\Steam', 22150], [H + '\\AppData\\Local\\Steam', 580]],
  [[H + '\\AppData\\Local\\Programs\\Microsoft Teams', 810], ['C:\\ProgramData\\Microsoft Teams', 160]],
  [['C:\\Program Files\\Unity', 32160], [H + '\\AppData\\Roaming\\Unity', 440], ['C:\\ProgramData\\Unity Technologies\\Unity', 120]],
];
const DATA = {
  junk: [
    mk(H + '\\AppData\\Local\\Temp\\setup_4821', 912 * MB, 'temp'),
    mk(H + '\\AppData\\Local\\Temp\\chrome_installer.log', 2 * MB, 'temp'),
    mk(H + '\\AppData\\Local\\CrashDumps\\explorer.exe.dmp', 96 * MB, 'crash'),
    mk('C:\\Windows\\Temp\\MpCmdRun.log', 12 * MB, 'winTemp'),
  ],
  caches: [
    mk(H + '\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Cache', 820 * MB, 'Chrome'),
    mk(H + '\\AppData\\Local\\Microsoft\\Edge\\User Data\\Default\\Code Cache', 210 * MB, 'Edge'),
    mk(H + '\\AppData\\Roaming\\discord\\Cache', 340 * MB, 'Discord'),
    mk(H + "\\AppData\\Local\\npm-cache", 160 * MB, 'npm'),
    mk(H + "\\AppData\\Local\\pip\\Cache", 213 * MB, 'pip'),
    mk(H + "\\AppData\\Local\\Yarn\\Cache", 132 * MB, 'Yarn'),
    mk(H + "\\AppData\\Local\\NuGet\\v3-cache", 98 * MB, 'NuGet'),
    mk(H + "\\AppData\\Roaming\\Apple Computer\\iTunes\\iPhone Software Updates", 600 * MB, 'iosUpdates'),
    { ...mk(H + "\\Apple\\MobileSync\\Backup\\demo-phone", 3600 * MB, 'iosBackups', 'review'), name: 'iPhone · 2026-10-15' },
  ],
  downloads: [mk(H + '\\Downloads\\Windows11.iso', 5400 * MB, 'downloads', 'review'), mk(H + '\\Downloads\\old-project.zip', 230 * MB, 'downloads', 'review')],
  privacy: [mk(H + '\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\History', 48 * MB, 'Chrome', 'review'), mk(H + '\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Network\\Cookies', 3 * MB, 'Chrome', 'review')],
  leftovers: [mk(H + '\\AppData\\Roaming\\OldGameStudio', 640 * MB, 'roaming', 'review'), mk(H + '\\AppData\\Local\\TrialEditor', 210 * MB, 'local', 'review')],
  duplicates: [mk(H + '\\Documents\\report (1).pdf', 14 * MB, 'report.pdf', 'review'), mk(H + '\\Desktop\\IMG_2041 copy.jpg', 6 * MB, 'IMG_2041.jpg', 'review')],
  large: [mk(H + '\\Videos\\wedding.mp4', 3100 * MB, 'large', 'review')],
};
const dirs = {
  [H]: [['Videos', 41000, 'review', 1], ['AppData', 23000, 'risky', 1], ['Downloads', 9800, 'review', 1], ['Documents', 4200, 'review', 1], ['NTUSER.DAT', 12, 'risky', 0]],
};
const disk = { total: 512 * 1024 * MB, free: 92 * 1024 * MB };
let ram = { used: 13 * 1024 * MB, total: 16 * 1024 * MB };
let junk = DATA.junk.slice();
let bin = { bytes: 1300 * MB, items: 214 };
let boostPaths = null;
const settings = { open_at_login: false, alert_low_space: false, alert_weekly: false,
  last_scan: 0, last_low_space_alert: 0, last_weekly_alert: 0, lang: 'en' };
let heavy = [
  { id: 'chrome', name: 'chrome.exe', path: 'C:/Program Files/Google/Chrome/Application/chrome.exe', bytes: 2200 * MB, cpu: 12, count: 14 },
  { id: 'discord', name: 'Discord.exe', path: H + '/AppData/Local/Discord/Discord.exe', bytes: 850 * MB, cpu: 3, count: 4 },
];
const extensions = [
  ['Chrome', 'Default', 'reader', 'Reader view', '1.3.2', 'Google/Chrome'],
  ['Chrome', 'Profile 2', 'tabs', 'Tab organizer', '2.0.1', 'Google/Chrome'],
  ['Edge', 'Default', 'notes', 'Web notes', '4.1.0', 'Microsoft/Edge'],
  ['Brave', 'Default', 'contrast', 'Better contrast', '1.0.3', 'BraveSoftware/Brave-Browser'],
].map(([browser, profile, id, name, version, root], i) => ({
  browser, profile, id, name, version, path: H + `/AppData/Local/${root}/User Data/${profile}/Extensions/${id}/${version}_0`, bytes: (i + 1) * MB,
}));
const bytesOf = items => items.reduce((sum, item) => sum + item.bytes, 0);
const ramPercent = () => Math.round(100 * ram.used / ram.total);
const recordScan = () => { settings.last_scan = Math.floor(Date.now() / 1000); };
const wait = ms => new Promise(r => setTimeout(r, ms));
export async function mockInvoke(cmd, args = {}) {
  await wait(cmd === 'scan' || cmd === 'health' ? 700 : 150);
  switch (cmd) {
    case 'scan':
      if (args.kind === 'junk' || args.kind === 'caches') recordScan();
      return structuredClone(args.kind === 'junk' ? junk : DATA[args.kind] ?? []);
    case 'health': {
      recordScan();
      const memoryHigh = ramPercent() > 75;
      const junkBytes = bytesOf(junk);
      const junkHigh = junkBytes >= 1_000_000_000;
      return { score: 82 - (memoryHigh ? 10 : 0) - (junkHigh ? 5 : 0),
        issues: ['disk', ...(memoryHigh ? ['memory'] : []), 'startup', ...(junkHigh ? ['junk'] : [])],
        disk, ram, startup: 10, junk: junkBytes, battery: { design: 50000, full: 46000, cycles: 312, health: 92 } };
    }
    case 'boost_preview':
      boostPaths = junk.slice();
      return { bytes: bytesOf(boostPaths), ram_used: ram.used, ram_total: ram.total };
    case 'boost_run': {
      if (!boostPaths) throw new Error('no boost preview');
      const freed = bytesOf(boostPaths);
      bin.bytes += freed;
      bin.items += boostPaths.length;
      junk = junk.filter(i => !boostPaths.includes(i));
      boostPaths = null;
      const before = ramPercent();
      ram = { ...ram, used: 10 * 1024 * MB };
      return { freed, failed: [], ram_before: before, ram_after: ramPercent() };
    }
    case 'heavy_apps': return structuredClone(heavy);
    case 'quit_app': heavy = heavy.filter(a => a.id !== args.id); return null;
    case 'extensions': return structuredClone(extensions);
    case 'settings_get': return { ...settings };
    case 'settings_set':
      settings.open_at_login = args.openAtLogin;
      settings.alert_low_space = args.alertLowSpace;
      settings.alert_weekly = args.alertWeekly;
      return { ...settings };
    case 'set_lang': settings.lang = args.lang; return null;
    case 'home': return H;
    case 'disk_children': {
      const p = args.path ?? H;
      return (dirs[p] ?? [['file.bin', 300, 'review', 0], ['Cache', 120, 'safe', 1]]).map(([n, mb, safety, dir]) => ({ path: p + '\\' + n, name: n, bytes: mb * MB, safety, dir: !!dir }));
    }
    case 'clean': {
      const freed = args.paths.reduce((sum, path) => sum + (junk.find(item => item.path === path)?.bytes ?? 50 * MB), 0);
      junk = junk.filter(item => !args.paths.includes(item.path));
      bin.bytes += freed;
      bin.items += args.paths.length;
      return { freed, removed: args.paths, failed: [] };
    }
    case 'disk_info': return disk;
    case 'downloads_size': return dirs[H].find(([name]) => name === 'Downloads')[1] * MB;
    case 'list_apps': return installed.map(app => ({ ...app }));
    case 'app_footprint': {
      const folders = footprints[installed.findIndex(app => app.id === args.id)];
      if (!folders) throw new Error('unknown program');
      const files = folders.map(([path, mb]) => ({ path, bytes: mb * MB }));
      return { total: bytesOf(files), files };
    }
    case 'uninstall': return null;
    case 'startup_list': return [
      ['cu|Spotify', 'Spotify', '"C:\\Users\\Demo\\AppData\\Roaming\\Spotify\\Spotify.exe" /minimized', true, false],
      ['cu|Updater', 'Updater', 'C:\\Users\\Demo\\AppData\\Local\\Temp\\upd.exe', true, true],
      ['lm64|SecurityHealth', 'SecurityHealth', '%windir%\\system32\\SecurityHealthSystray.exe', true, false],
      ['fu|Zoom.lnk', 'Zoom', 'C:\\Users\\Demo\\...\\Startup\\Zoom.lnk', false, false],
    ].map(([id, name, command, enabled, suspicious]) => ({ id, name, command, enabled, suspicious }));
    case 'startup_set': if (args.id.startsWith('lm')) throw 'admin'; return null;
    case 'privacy_access': return [
      { capability: 'webcam', app: 'Zoom', allowed: true, last_used: 1795000000 },
      { capability: 'microphone', app: 'Discord', allowed: true, last_used: 1795300000 },
      { capability: 'location', app: 'WindowsMaps', allowed: false, last_used: 0 },
    ];
    case 'run_task': if (args.id === 'defender') throw 'x'; return null;
    case 'recycle_info': return { ...bin };
    case 'open_recycle_bin': return null;
    case 'empty_recycle':
      if (!args.confirmed) throw new Error('not confirmed');
      bin = { bytes: 0, items: 0 };
      return null;
    default: return null;
  }
}
